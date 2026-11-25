import fs from 'node:fs';
import path from 'node:path';
import { cleanText, NAME_MAX } from './normalizer';
import type { Logger, VesselExtras, VesselUpdate } from './types';

/** The census file's and /census's format; a file with any other version is ignored (started over, logged once). */
export const CENSUS_VERSION = 1;
/** Records held. Past it the least recently seen vessel goes, so the file stays under about 2 MB. */
export const MAX_CENSUS_RECORDS = 5000;
/** Distinct UTC dates kept per vessel (`lastDates`); `daysSeen` keeps counting past it. */
export const MAX_CENSUS_DATES = 60;
/** At most one write per this long, and only when something changed (shutdown writes regardless of the interval). */
export const CENSUS_WRITE_INTERVAL_MS = 5 * 60_000;
export const DEFAULT_CENSUS_LIMIT = 500;
export const MAX_CENSUS_LIMIT = 5000;
/** A message dated further ahead of the clock than this is a bad timestamp, not a sighting. */
const MAX_FUTURE_MS = 24 * 3_600_000;

/**
 * One vessel as seen over days: identifiers and counts only. Never a position, a track or anything about people
 * (relay/README.md, "Census").
 */
export interface CensusRecord {
  mmsi: number;
  /** Latest name, cleaned like /v2's. */
  name?: string;
  shipType?: number;
  /** Meters. */
  length?: number;
  beam?: number;
  callSign?: string;
  /** Only an IMO number that passed the normalizer's validity rules. */
  imo?: number;
  /** ISO times of the oldest and newest message. */
  firstSeen: string;
  lastSeen: string;
  /** Distinct UTC dates with a message, counted past what `lastDates` keeps. */
  daysSeen: number;
  /** Position reports received. */
  positions: number;
  /** The newest `MAX_CENSUS_DATES` distinct UTC dates (YYYY-MM-DD), oldest first. */
  lastDates: string[];
}

export interface CensusReport {
  version: number;
  generatedAt: string;
  vessels: CensusRecord[];
}

/** The file operations the census uses, replaceable in tests. */
export interface CensusIo {
  readFile(file: string): string;
  writeFile(file: string, data: string): void;
  rename(from: string, to: string): void;
  unlink(file: string): void;
}

const nodeIo: CensusIo = {
  readFile: (file) => fs.readFileSync(file, 'utf8'),
  writeFile: (file, data) => fs.writeFileSync(file, data, { mode: 0o644 }),
  rename: (from, to) => fs.renameSync(from, to),
  unlink: (file) => fs.unlinkSync(file),
};

export interface CensusOptions {
  /** Where the census is kept between runs (`CENSUS_FILE`). Without it the census lives in memory only. */
  file?: string;
  log?: Logger;
  now?: () => number;
  io?: CensusIo;
  maxRecords?: number;
}

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const posInt = (v: unknown): v is number => typeof v === 'number' && Number.isInteger(v) && v > 0;
const count = (v: unknown): number => (typeof v === 'number' && Number.isInteger(v) && v >= 0 ? v : 0);
const optStr = (v: unknown): string | undefined => (typeof v === 'string' && v !== '' ? v : undefined);
const optNum = (v: unknown): number | undefined => (typeof v === 'number' && Number.isFinite(v) ? v : undefined);
const isoTime = (v: unknown): string | undefined => {
  const t = typeof v === 'string' ? Date.parse(v) : NaN;
  return Number.isNaN(t) ? undefined : new Date(t).toISOString();
};

/** A record read from a file, or undefined if it isn't one. Unknown keys are dropped. */
function readRecord(v: unknown): CensusRecord | undefined {
  if (!isObj(v) || !posInt(v.mmsi)) return undefined;
  const firstSeen = isoTime(v.firstSeen);
  const lastSeen = isoTime(v.lastSeen);
  if (!firstSeen || !lastSeen) return undefined;
  const lastDates = Array.isArray(v.lastDates)
    ? [...new Set(v.lastDates.filter((d): d is string => typeof d === 'string' && DATE_RE.test(d)))].sort().slice(-MAX_CENSUS_DATES)
    : [];
  const r: CensusRecord = {
    mmsi: v.mmsi,
    firstSeen,
    lastSeen,
    daysSeen: Math.max(count(v.daysSeen), lastDates.length),
    positions: count(v.positions),
    lastDates,
  };
  const name = optStr(v.name);
  if (name !== undefined) r.name = name;
  for (const key of ['shipType', 'length', 'beam', 'imo'] as const) {
    const n = optNum(v[key]);
    if (n !== undefined) r[key] = n;
  }
  const callSign = optStr(v.callSign);
  if (callSign !== undefined) r.callSign = callSign;
  return r;
}

/** A message is a position report when it carries no static data (the normalizer's position updates never do). */
export function isPositionReport(update: VesselUpdate, extras?: VesselExtras): boolean {
  if (update.name !== undefined || update.shipType !== undefined) return false;
  return !extras || Object.keys(extras).every((k) => k === 'navStatus');
}

/**
 * Which vessels the relay sees, and on how many days (README, "Census"): one record per MMSI, fed by every
 * normalized AIS message. Kept in a JSON file when `file` is set, written atomically at most every
 * `CENSUS_WRITE_INTERVAL_MS`, only when changed, and on shutdown. Nothing here ever throws into the relay: a bad file
 * starts the census empty and a failed write is logged once per failure streak and counted.
 */
export class Census {
  private readonly records = new Map<number, CensusRecord>();
  private readonly log: Logger;
  private readonly now: () => number;
  private readonly io: CensusIo;
  private readonly maxRecords: number;
  private dirty = false;
  private lastAttempt: number;
  private failing = false;
  private failures = 0;

  constructor(private readonly o: CensusOptions = {}) {
    this.log = o.log ?? (() => {});
    this.now = o.now ?? Date.now;
    this.io = o.io ?? nodeIo;
    this.maxRecords = o.maxRecords ?? MAX_CENSUS_RECORDS;
    this.lastAttempt = this.now();
    if (o.file) this.load(o.file);
  }

  /** Records held. */
  get size(): number {
    return this.records.size;
  }

  /** Writes that failed since start. */
  get writeFailures(): number {
    return this.failures;
  }

  private load(file: string): void {
    let text: string;
    try {
      text = this.io.readFile(file);
    } catch (err) {
      const missing = (err as NodeJS.ErrnoException).code === 'ENOENT';
      this.log(missing ? `census: ${file} does not exist yet; starting empty` : `census: cannot read ${file} (${String(err)}); starting empty`);
      return;
    }
    if (text.trim() === '') {
      this.log(`census: ${file} is empty; starting empty`);
      return;
    }
    let data: unknown;
    try {
      data = JSON.parse(text);
    } catch {
      this.log(`census: ${file} is not valid JSON; starting empty (the file is replaced at the next write)`);
      return;
    }
    if (!isObj(data) || data.version !== CENSUS_VERSION || !Array.isArray(data.vessels)) {
      const version = isObj(data) ? String(data.version) : 'none';
      this.log(`census: ${file} has version ${version}, expected ${CENSUS_VERSION}; starting empty (the file is replaced at the next write)`);
      return;
    }
    for (const v of data.vessels) {
      const r = readRecord(v);
      if (r) this.records.set(r.mmsi, r);
    }
    while (this.records.size > this.maxRecords) this.evict();
    this.log(`census: loaded ${this.records.size} vessel(s) from ${file}`);
  }

  /**
   * Counts one normalized AIS message. `update.timestamp` is the message's time, which dates the sighting. Static
   * data (a name, type or extras) updates the record's identifiers; a position report adds to `positions`.
   */
  observe(update: VesselUpdate, extras?: VesselExtras): void {
    const ts = Date.parse(update.timestamp);
    if (Number.isNaN(ts) || ts > this.now() + MAX_FUTURE_MS || !posInt(update.mmsi)) return;
    const iso = new Date(ts).toISOString();
    let r = this.records.get(update.mmsi);
    if (!r) {
      r = { mmsi: update.mmsi, firstSeen: iso, lastSeen: iso, daysSeen: 0, positions: 0, lastDates: [] };
      this.records.set(r.mmsi, r);
      if (this.records.size > this.maxRecords) this.evict(r.mmsi);
    }
    if (iso < r.firstSeen) r.firstSeen = iso;
    if (iso > r.lastSeen) r.lastSeen = iso;
    this.addDate(r, iso.slice(0, 10));
    if (isPositionReport(update, extras)) r.positions++;
    // The newest message's static data wins; an older one (out of order) only fills what is missing.
    const newest = iso >= r.lastSeen;
    const rec = r;
    const set = <K extends 'name' | 'shipType' | 'length' | 'beam' | 'callSign' | 'imo'>(key: K, value: CensusRecord[K] | undefined) => {
      if (value !== undefined && (newest || rec[key] === undefined)) rec[key] = value;
    };
    set('name', cleanText(update.name, NAME_MAX));
    set('shipType', update.shipType);
    set('length', extras?.length);
    set('beam', extras?.beam);
    set('callSign', extras?.callSign);
    set('imo', extras?.imo);
    this.dirty = true;
  }

  private addDate(r: CensusRecord, date: string): void {
    const dates = r.lastDates;
    if (dates.includes(date)) return;
    // A date older than everything kept, with the list full, can't be told apart from one already counted.
    if (dates.length >= MAX_CENSUS_DATES && date < dates[0]) return;
    dates.push(date);
    dates.sort();
    if (dates.length > MAX_CENSUS_DATES) dates.shift();
    r.daysSeen++;
  }

  /** Drops the least recently seen record, never `keep`. */
  private evict(keep?: number): void {
    let oldest: CensusRecord | undefined;
    for (const r of this.records.values()) {
      if (r.mmsi !== keep && (!oldest || r.lastSeen < oldest.lastSeen)) oldest = r;
    }
    if (oldest) this.records.delete(oldest.mmsi);
  }

  /** The /census body: `limit` vessels (default 500, at most 5000), most days seen first. */
  report(limit = DEFAULT_CENSUS_LIMIT): CensusReport {
    const n = Number.isInteger(limit) && limit >= 1 ? Math.min(limit, MAX_CENSUS_LIMIT) : DEFAULT_CENSUS_LIMIT;
    const vessels = [...this.records.values()]
      .sort((a, b) => b.daysSeen - a.daysSeen || b.positions - a.positions || a.mmsi - b.mmsi)
      .slice(0, n);
    return { version: CENSUS_VERSION, generatedAt: new Date(this.now()).toISOString(), vessels };
  }

  /**
   * Writes the file if there is one, something changed, and the last attempt was at least
   * `CENSUS_WRITE_INTERVAL_MS` ago (`force`: skip the interval, for shutdown). Returns whether it wrote. Never throws.
   */
  flush(force = false): boolean {
    const file = this.o.file;
    const t = this.now();
    if (!file || !this.dirty || (!force && t - this.lastAttempt < CENSUS_WRITE_INTERVAL_MS)) return false;
    this.lastAttempt = t;
    // Temp file in the same directory (same filesystem, so the rename is atomic), then rename over the old file: a
    // crash or failure leaves the previous file whole.
    const tmp = path.join(path.dirname(file), `.${path.basename(file)}.tmp`);
    try {
      this.io.writeFile(tmp, JSON.stringify(this.report(MAX_CENSUS_LIMIT)) + '\n');
      this.io.rename(tmp, file);
    } catch (err) {
      try {
        this.io.unlink(tmp);
      } catch {
        // No temp file to remove.
      }
      this.failures++;
      if (!this.failing) this.log(`census: cannot write ${file} (${String(err)}); will retry, further failures are only counted`);
      this.failing = true;
      return false;
    }
    if (this.failing) this.log(`census: writing ${file} works again`);
    this.failing = false;
    this.dirty = false;
    return true;
  }
}
