/**
 * Ground elevation for the subway extract, from the USGS Elevation Point Query Service (EPQS, 3DEP bare earth,
 * meters above NAVD88): https://epqs.nationalmap.gov/v1/json. The answers are kept in data/elevation.json, which is
 * committed, so re-running the extractor is deterministic and offline; it only asks EPQS for a point the file lacks,
 * and only when run with --fetch-elevation. Over water EPQS answers the water surface or nothing: `null` is stored
 * for a point with no data.
 */
import fs from 'node:fs';
import path from 'node:path';

export const ELEVATION_CACHE_PATH = path.resolve(__dirname, '..', '..', 'data', 'elevation.json');
const EPQS_URL = 'https://epqs.nationalmap.gov/v1/json';
/** EPQS is a free public service: a descriptive User-Agent (no contact details), a few requests at a time, with pauses. */
const USER_AGENT = 'bridgewatch-relay-extractor (hobby project; subway track heights; one-off runs)';
const PAUSE_MS = 150;
const CONCURRENCY = 3;
const MAX_TRIES = 6;

/** Cache key: coordinates to 5 decimals (about 1 m, the DEM's own resolution). */
export function elevationKey(lat: number, lon: number): string {
  return `${lat.toFixed(5)},${lon.toFixed(5)}`;
}

export class ElevationCache {
  private values: Record<string, number | null>;

  constructor(private readonly file = ELEVATION_CACHE_PATH) {
    this.values = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
  }

  /** The cached ground elevation, `null` where EPQS has none, undefined when never asked. */
  get(lat: number, lon: number): number | null | undefined {
    return this.values[elevationKey(lat, lon)];
  }

  set(lat: number, lon: number, value: number | null): void {
    this.values[elevationKey(lat, lon)] = value;
  }

  /**
   * Asks EPQS for each point the cache lacks, CONCURRENCY at a time (it answers in 0.5-7 s), backing off on 429, then
   * saves. Returns how many.
   */
  async fetchMissing(points: readonly (readonly [number, number])[]): Promise<number> {
    const queue = [...new Map(points.filter(([la, lo]) => this.get(la, lo) === undefined).map((p) => [elevationKey(p[0], p[1]), p])).values()];
    const total = queue.length;
    const worker = async () => {
      for (let p = queue.pop(); p; p = queue.pop()) {
        this.set(p[0], p[1], await queryEpqs(p[0], p[1]));
        if ((total - queue.length) % 25 === 0) this.save();
        await new Promise((r) => setTimeout(r, PAUSE_MS));
      }
    };
    await Promise.all(Array.from({ length: CONCURRENCY }, worker));
    this.save();
    return total;
  }

  /** Writes the file with sorted keys, one point per line, so diffs stay small. */
  save(): void {
    const keys = Object.keys(this.values).sort();
    const body = keys.map((k) => `  ${JSON.stringify(k)}: ${this.values[k]}`).join(',\n');
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    fs.writeFileSync(this.file, `{\n${body}\n}\n`);
  }
}

async function queryEpqs(lat: number, lon: number): Promise<number | null> {
  const url = `${EPQS_URL}?x=${lon.toFixed(5)}&y=${lat.toFixed(5)}&units=Meters&wkid=4326&includeDate=false`;
  let wait = 2000;
  for (let attempt = 1; ; attempt++) {
    try {
      const res = await fetch(url, { headers: { 'User-Agent': USER_AGENT }, signal: AbortSignal.timeout(30_000) });
      if (res.status === 429 || res.status >= 500) throw new Error(`HTTP ${res.status}`);
      if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
      const value = Number(((await res.json()) as { value: string | number }).value);
      // EPQS answers -1000000 where it has no data.
      return Number.isFinite(value) && value > -1000 ? Math.round(value * 100) / 100 : null;
    } catch (e) {
      if (attempt >= MAX_TRIES) throw e;
      await new Promise((r) => setTimeout(r, wait));
      wait *= 2;
    }
  }
}
