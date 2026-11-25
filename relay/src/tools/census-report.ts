/**
 * Prints the vessel census as a table with a summary, to see which boats recur in the harbor:
 *
 *   npm run census -- census.json
 *   npm run census -- http://relay-box:8095/census          (or: curl -s localhost:8095/census > census.json, on the host)
 *
 * It reads either the census file (CENSUS_FILE) or an http(s) URL to /census; for a URL without a query it asks for
 * the most /census gives (limit=5000). Read only. See README, "Census".
 */
import fs from 'node:fs';
import { MAX_CENSUS_LIMIT, type CensusRecord } from '../census';

export interface CensusSummary {
  total: number;
  named: number;
  totalPositions: number;
  /** The fewest vessels (busiest first, by position reports) that make up 50%, 80% and 95% of all position reports. */
  cover: { share: number; vessels: number }[];
}

export const COVERAGE_SHARES = [0.5, 0.8, 0.95];

export function summarize(vessels: readonly Pick<CensusRecord, 'name' | 'positions'>[]): CensusSummary {
  const counts = vessels.map((v) => v.positions).sort((a, b) => b - a);
  const totalPositions = counts.reduce((sum, n) => sum + n, 0);
  const cover = COVERAGE_SHARES.map((share) => {
    if (totalPositions === 0) return { share, vessels: 0 };
    let sum = 0;
    let n = 0;
    // Integer compare (sum * 100 >= share * 100 * total) to avoid float edge cases at exactly 50%.
    while (n < counts.length && sum * 100 < Math.round(share * 100) * totalPositions) sum += counts[n++];
    return { share, vessels: n };
  });
  return { total: vessels.length, named: vessels.filter((v) => v.name !== undefined && v.name !== '').length, totalPositions, cover };
}

/** The table and summary as text, vessels in the order given. */
export function formatReport(vessels: readonly CensusRecord[]): string {
  const rows = [
    ['rank', 'mmsi', 'name', 'type', 'length', 'days', 'positions', 'lastSeen'],
    ...vessels.map((v, i) => [
      String(i + 1),
      String(v.mmsi),
      v.name ?? '-',
      v.shipType === undefined ? '-' : String(v.shipType),
      v.length === undefined ? '-' : String(v.length),
      String(v.daysSeen),
      String(v.positions),
      v.lastSeen,
    ]),
  ];
  const widths = rows[0].map((_, c) => Math.max(...rows.map((r) => r[c].length)));
  const textColumns = new Set([2, 7]);
  const lines = rows.map((r) => r.map((cell, c) => (textColumns.has(c) ? cell.padEnd(widths[c]) : cell.padStart(widths[c]))).join('  ').trimEnd());
  const s = summarize(vessels);
  lines.push(
    '',
    `vessels: ${s.total}`,
    `named: ${s.named}`,
    `position reports: ${s.totalPositions}`,
    ...s.cover.map((c) => `${s.total === 0 ? 0 : c.vessels} vessel(s) cover ${Math.round(c.share * 100)}% of position reports`),
  );
  return lines.join('\n');
}

/** The census's vessels from a file path or an http(s) URL. Throws with a readable message on anything else. */
export async function loadVessels(source: string, fetchFn: typeof fetch = fetch): Promise<CensusRecord[]> {
  let text: string;
  if (/^https?:\/\//i.test(source)) {
    const url = new URL(source);
    if (!url.search) url.searchParams.set('limit', String(MAX_CENSUS_LIMIT));
    const res = await fetchFn(url, { signal: AbortSignal.timeout(15_000) });
    if (!res.ok) throw new Error(`${url.origin}${url.pathname} answered ${res.status}`);
    text = await res.text();
  } else {
    text = fs.readFileSync(source, 'utf8');
  }
  const data: unknown = JSON.parse(text);
  const vessels = typeof data === 'object' && data !== null ? (data as { vessels?: unknown }).vessels : undefined;
  if (!Array.isArray(vessels)) throw new Error('not a census: no "vessels" list');
  return vessels as CensusRecord[];
}

async function main(): Promise<void> {
  const source = process.argv[2];
  if (!source) {
    console.error('usage: npm run census -- <census.json | http(s)://host/census>');
    process.exit(2);
  }
  try {
    console.log(formatReport(await loadVessels(source)));
  } catch (err) {
    console.error(`error: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  }
}

if (require.main === module) void main();
