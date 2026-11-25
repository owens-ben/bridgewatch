import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, test } from '@jest/globals';
import {
  Census,
  CENSUS_VERSION,
  CENSUS_WRITE_INTERVAL_MS,
  MAX_CENSUS_DATES,
  isPositionReport,
  type CensusIo,
  type CensusRecord,
} from './census';
import type { VesselExtras, VesselUpdate } from './types';

const T0 = Date.parse('2026-11-10T12:00:00.000Z');
let clock = T0;
let dir: string;
let file: string;
let logs: string[];
const log = (m: string) => logs.push(m);

beforeEach(() => {
  clock = T0;
  logs = [];
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'census-test-'));
  file = path.join(dir, 'census.json');
});
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

const position = (mmsi: number, timestamp: string): VesselUpdate => ({ mmsi, lat: 40.7, lon: -73.99, timestamp });
const statics = (mmsi: number, timestamp: string, name?: string, shipType?: number): VesselUpdate => ({
  mmsi,
  name,
  shipType,
  lat: 40.7,
  lon: -73.99,
  timestamp,
});
const make = (over: Partial<ConstructorParameters<typeof Census>[0]> = {}) => new Census({ now: () => clock, log, ...over });
const only = (c: Census, mmsi: number): CensusRecord => {
  const r = c.report(5000).vessels.find((v) => v.mmsi === mmsi);
  if (!r) throw new Error(`no record for ${mmsi}`);
  return r;
};

describe('Census records', () => {
  test('a position report starts a record and counts; static data adds identifiers', () => {
    const c = make();
    c.observe(position(1, '2026-11-10T11:00:00.000Z'), { navStatus: 0 });
    c.observe(position(1, '2026-11-10T11:05:00.000Z'));
    const extras: VesselExtras = { imo: 9123453, callSign: 'WDC1234', length: 30, beam: 9, destination: 'NYC' };
    c.observe(statics(1, '2026-11-10T11:06:00.000Z', 'HARBOR LARK', 60), extras);
    expect(only(c, 1)).toEqual({
      mmsi: 1,
      name: 'HARBOR LARK',
      shipType: 60,
      length: 30,
      beam: 9,
      callSign: 'WDC1234',
      imo: 9123453,
      firstSeen: '2026-11-10T11:00:00.000Z',
      lastSeen: '2026-11-10T11:06:00.000Z',
      daysSeen: 1,
      positions: 2,
      lastDates: ['2026-11-10'],
    });
    // Nothing about where the vessel was, and nothing beyond the identifiers.
    expect(JSON.stringify(c.report())).not.toMatch(/lat|lon|destination|navStatus/);
  });

  test('isPositionReport: static data or extras beyond navStatus make a message static', () => {
    expect(isPositionReport(position(1, 'x'))).toBe(true);
    expect(isPositionReport(position(1, 'x'), { navStatus: 5 })).toBe(true);
    expect(isPositionReport(statics(1, 'x', 'A'))).toBe(false);
    expect(isPositionReport(position(1, 'x'), { draught: 3 })).toBe(false);
  });

  test('the latest name and type replace older ones; a message without them keeps them; names are cleaned', () => {
    const c = make();
    c.observe(statics(1, '2026-11-10T10:00:00.000Z', 'OLD NAME', 60));
    c.observe(statics(1, '2026-11-10T11:00:00.000Z', 'NEW\nNAME  ​', 70));
    c.observe(position(1, '2026-11-10T11:30:00.000Z'));
    expect(only(c, 1)).toMatchObject({ name: 'NEW NAME', shipType: 70 });
  });

  test('an older, out-of-order message fills only what is missing and moves firstSeen back', () => {
    const c = make();
    c.observe(statics(1, '2026-11-10T11:00:00.000Z', 'NEWER'), { length: 40 });
    c.observe(statics(1, '2026-11-10T09:00:00.000Z', 'OLDER', 60), { length: 10, callSign: 'AB1' });
    expect(only(c, 1)).toMatchObject({
      name: 'NEWER',
      shipType: 60,
      length: 40,
      callSign: 'AB1',
      firstSeen: '2026-11-10T09:00:00.000Z',
      lastSeen: '2026-11-10T11:00:00.000Z',
    });
  });

  test('daysSeen counts distinct UTC dates, across midnight', () => {
    const c = make();
    c.observe(position(1, '2026-11-10T23:59:59.000Z'));
    c.observe(position(1, '2026-11-10T23:59:59.500Z'));
    c.observe(position(1, '2026-11-11T00:00:00.000Z'));
    c.observe(position(1, '2026-11-11T00:30:00.000Z'));
    clock = Date.parse('2026-11-13T00:00:00.000Z');
    c.observe(position(1, '2026-11-12T08:00:00.000Z'));
    const r = only(c, 1);
    expect(r.daysSeen).toBe(3);
    expect(r.positions).toBe(5);
    expect(r.lastDates).toEqual(['2026-11-10', '2026-11-11', '2026-11-12']);
  });

  test('lastDates is bounded to the newest 60, daysSeen keeps counting, an older date is not recounted', () => {
    const c = make();
    clock = Date.parse('2027-06-01T00:00:00.000Z');
    const day = (i: number) => new Date(Date.UTC(2026, 11, 1 + i)).toISOString();
    for (let i = 0; i < 100; i++) c.observe(position(1, day(i)));
    const r = only(c, 1);
    expect(r.daysSeen).toBe(100);
    expect(r.lastDates).toHaveLength(MAX_CENSUS_DATES);
    expect(r.lastDates[0]).toBe(day(40).slice(0, 10));
    expect(r.lastDates.at(-1)).toBe(day(99).slice(0, 10));
    c.observe(position(1, day(0)));
    expect(only(c, 1).daysSeen).toBe(100);
  });

  test('a message with a bad or far-future timestamp is ignored', () => {
    const c = make();
    c.observe(position(1, 'not a date'));
    c.observe(position(2, '2026-11-20T00:00:00.000Z'));
    expect(c.size).toBe(0);
  });

  test('past the cap the least recently seen vessel is evicted, never the new one', () => {
    const c = make({ maxRecords: 3 });
    c.observe(position(1, '2026-11-10T10:00:00.000Z'));
    c.observe(position(2, '2026-11-10T10:03:00.000Z'));
    c.observe(position(3, '2026-11-10T10:02:00.000Z'));
    c.observe(position(1, '2026-11-10T10:04:00.000Z')); // 1 is fresh again; 3 (10:02) is now the stalest
    c.observe(position(4, '2026-11-10T09:00:00.000Z')); // older than everyone, yet kept: it is the new one
    expect(c.size).toBe(3);
    expect(c.report().vessels.map((v) => v.mmsi).sort()).toEqual([1, 2, 4]);
  });
});

describe('Census report', () => {
  const filled = () => {
    const c = make();
    clock = Date.parse('2026-11-12T12:00:00.000Z');
    // 5: 2 days, 1 position; 6: 2 days, 3 positions; 7: 1 day, 9 positions; 3 and 4: 1 day, 1 position.
    c.observe(position(5, '2026-11-10T10:00:00.000Z'));
    c.observe(position(5, '2026-11-11T10:00:00.000Z'));
    for (let i = 0; i < 3; i++) c.observe(position(6, `2026-11-1${i % 2}T10:00:00.000Z`));
    for (let i = 0; i < 9; i++) c.observe(position(7, '2026-11-11T10:00:00.000Z'));
    c.observe(position(4, '2026-11-11T10:00:00.000Z'));
    c.observe(position(3, '2026-11-11T10:00:00.000Z'));
    return c;
  };

  test('sorted by daysSeen, then positions, then mmsi, with version and generatedAt', () => {
    const c = filled();
    const report = c.report();
    expect(report.version).toBe(CENSUS_VERSION);
    expect(report.generatedAt).toBe('2026-11-12T12:00:00.000Z');
    expect(report.vessels.map((v) => v.mmsi)).toEqual([6, 5, 7, 3, 4]);
  });

  test('limit: capped at 5000, a bad one uses the default 500', () => {
    const c = make({ maxRecords: 6000 });
    for (let i = 1; i <= 600; i++) c.observe(position(i, '2026-11-10T10:00:00.000Z'));
    expect(c.report().vessels).toHaveLength(500);
    expect(c.report(2).vessels).toHaveLength(2);
    expect(c.report(0).vessels).toHaveLength(500);
    expect(c.report(-3).vessels).toHaveLength(500);
    expect(c.report(1.5).vessels).toHaveLength(500);
    expect(c.report(99999).vessels).toHaveLength(600);
  });
});

describe('Census persistence', () => {
  test('without a file nothing is written, whatever the time or the shutdown', () => {
    const c = make();
    c.observe(position(1, '2026-11-10T11:00:00.000Z'));
    clock += CENSUS_WRITE_INTERVAL_MS * 3;
    expect(c.flush()).toBe(false);
    expect(c.flush(true)).toBe(false);
    expect(fs.readdirSync(dir)).toEqual([]);
  });

  test('a round trip through the file keeps every field', () => {
    const c = make({ file });
    c.observe(statics(1, '2026-11-10T11:00:00.000Z', 'HARBOR LARK', 60), { imo: 9123453, length: 30, beam: 9, callSign: 'WDC1234' });
    c.observe(position(1, '2026-11-11T11:00:00.000Z'));
    c.observe(position(2, '2026-11-11T11:00:00.000Z'));
    expect(c.flush(true)).toBe(true);
    const text = fs.readFileSync(file, 'utf8');
    expect(JSON.parse(text).version).toBe(CENSUS_VERSION);
    expect(fs.readdirSync(dir)).toEqual(['census.json']); // no temp file left
    const again = make({ file });
    expect(again.report().vessels).toEqual(c.report().vessels);
    expect(logs.at(-1)).toContain('loaded 2 vessel(s)');
    // And it carries on counting from what it loaded.
    clock = Date.parse('2026-11-12T12:00:00.000Z');
    again.observe(position(1, '2026-11-12T00:00:00.000Z'));
    expect(only(again, 1)).toMatchObject({ daysSeen: 3, positions: 2 });
  });

  test.each([
    ['missing', undefined, 'does not exist'],
    ['empty', '', 'is empty'],
    ['whitespace', '  \n', 'is empty'],
    ['truncated', '{"version":1,"vessels":[{"mmsi":', 'not valid JSON'],
    ['not an object', '[1,2]', 'version none'],
    ['wrong version', JSON.stringify({ version: 2, vessels: [] }), 'version 2'],
    ['no version', JSON.stringify({ vessels: [] }), 'version undefined'],
    ['no vessels list', JSON.stringify({ version: 1 }), 'version 1'],
  ])('a %s file starts empty, logs once, and never throws', (_name, content, message) => {
    if (content !== undefined) fs.writeFileSync(file, content);
    const c = make({ file });
    expect(c.size).toBe(0);
    expect(logs).toHaveLength(1);
    expect(logs[0]).toContain(message);
    c.observe(position(1, '2026-11-10T11:00:00.000Z'));
    expect(c.flush(true)).toBe(true); // a bad file is replaced by the next write
    expect(JSON.parse(fs.readFileSync(file, 'utf8')).vessels).toHaveLength(1);
  });

  test('records that are not valid are skipped and the rest kept; a file over the cap keeps the most recent', () => {
    fs.writeFileSync(
      file,
      JSON.stringify({
        version: 1,
        vessels: [
          { mmsi: 1, firstSeen: '2026-11-10T00:00:00.000Z', lastSeen: '2026-11-10T00:00:00.000Z', daysSeen: 1, positions: 1, lastDates: ['2026-11-10'] },
          { mmsi: 'x', firstSeen: '2026-11-10T00:00:00.000Z', lastSeen: '2026-11-10T00:00:00.000Z' },
          { mmsi: 2, firstSeen: 'nope', lastSeen: 'nope' },
          { mmsi: 3, firstSeen: '2026-11-09T00:00:00.000Z', lastSeen: '2026-11-09T00:00:00.000Z', daysSeen: 1, positions: 1, lastDates: [] },
          null,
        ],
      }),
    );
    const c = make({ file, maxRecords: 1 });
    expect(c.report().vessels.map((v) => v.mmsi)).toEqual([1]);
  });

  test('writes are throttled to one per five minutes, and only when something changed', () => {
    const c = make({ file });
    expect(c.flush()).toBe(false); // nothing observed
    c.observe(position(1, '2026-11-10T12:00:00.000Z'));
    expect(c.flush()).toBe(false); // too soon after start
    clock += CENSUS_WRITE_INTERVAL_MS - 1;
    expect(c.flush()).toBe(false);
    clock += 1;
    expect(c.flush()).toBe(true);
    const mtime = () => fs.statSync(file).mtimeMs;
    const written = mtime();

    clock += CENSUS_WRITE_INTERVAL_MS * 2;
    expect(c.flush()).toBe(false); // unchanged since the write
    expect(c.flush(true)).toBe(false); // not even on shutdown
    expect(mtime()).toBe(written);

    c.observe(position(1, '2026-11-10T12:20:00.000Z'));
    expect(c.flush()).toBe(true); // changed, and over five minutes since the last
    c.observe(position(1, '2026-11-10T12:21:00.000Z'));
    expect(c.flush()).toBe(false); // changed again, but too soon
    expect(c.flush(true)).toBe(true); // shutdown ignores the interval
    expect(JSON.parse(fs.readFileSync(file, 'utf8')).vessels[0].positions).toBe(3);
  });

  describe('a write that fails', () => {
    /** Real file operations, with each step able to fail. */
    function io(fail: { write?: boolean; rename?: boolean }): CensusIo {
      return {
        readFile: (f) => fs.readFileSync(f, 'utf8'),
        writeFile: (f, data) => {
          // A partial temp file before the error, as a full disk would leave.
          fs.writeFileSync(f, fail.write ? data.slice(0, 10) : data);
          if (fail.write) throw new Error('ENOSPC');
        },
        rename: (from, to) => {
          if (fail.rename) throw new Error('EIO');
          fs.renameSync(from, to);
        },
        unlink: (f) => fs.unlinkSync(f),
      };
    }

    const cases: [string, { write?: boolean; rename?: boolean }][] = [['writing', { write: true }], ['renaming', { rename: true }]];
    test.each(cases)(
      'while %s leaves the previous file whole and no temp file, and is counted and logged once per streak',
      (_name, fail) => {
        const failing = { ...fail };
        const c = make({ file, io: io(failing) });
        c.observe(position(1, '2026-11-10T12:00:00.000Z'));
        const good = io({});
        const first = make({ file, io: good });
        first.observe(position(9, '2026-11-10T12:00:00.000Z'));
        expect(first.flush(true)).toBe(true);
        const before = fs.readFileSync(file, 'utf8');

        for (let i = 1; i <= 3; i++) {
          clock += CENSUS_WRITE_INTERVAL_MS;
          expect(() => c.flush()).not.toThrow();
          expect(c.flush()).toBe(false);
          expect(c.writeFailures).toBe(i);
        }
        expect(fs.readFileSync(file, 'utf8')).toBe(before); // atomic: the old file, complete
        expect(JSON.parse(before).vessels).toHaveLength(1);
        expect(fs.readdirSync(dir)).toEqual(['census.json']);
        expect(logs.filter((l) => l.includes('cannot write'))).toHaveLength(1);

        // It recovers on the next interval, and says so.
        failing.write = false;
        failing.rename = false;
        clock += CENSUS_WRITE_INTERVAL_MS;
        expect(c.flush()).toBe(true);
        expect(logs.at(-1)).toContain('works again');
        expect(JSON.parse(fs.readFileSync(file, 'utf8')).vessels.map((v: CensusRecord) => v.mmsi)).toEqual([1]);

        // A new streak logs again.
        failing.rename = fail.rename ?? false;
        failing.write = fail.write ?? false;
        c.observe(position(1, '2026-11-10T13:00:00.000Z'));
        clock += CENSUS_WRITE_INTERVAL_MS;
        c.flush();
        expect(logs.filter((l) => l.includes('cannot write'))).toHaveLength(2);
      },
    );

    test('a file in an unwritable place (missing directory) is a failure, not a crash', () => {
      const c = make({ file: path.join(dir, 'missing', 'census.json') });
      c.observe(position(1, '2026-11-10T12:00:00.000Z'));
      expect(c.flush(true)).toBe(false);
      expect(c.writeFailures).toBe(1);
    });
  });
});
