import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, test } from '@jest/globals';
import type { CensusRecord } from '../census';
import { formatReport, loadVessels, summarize } from './census-report';

const rec = (mmsi: number, positions: number, over: Partial<CensusRecord> = {}): CensusRecord => ({
  mmsi,
  firstSeen: '2026-11-10T00:00:00.000Z',
  lastSeen: '2026-11-11T00:00:00.000Z',
  daysSeen: 1,
  positions,
  lastDates: ['2026-11-10'],
  ...over,
});

describe('summarize', () => {
  test('how many vessels, how many named, and the fewest vessels that cover 50/80/95% of position reports', () => {
    // 100 reports: 50, 30, 10, 5, 3, 2.
    const vessels = [50, 30, 10, 5, 3, 2].map((n, i) => ({ name: i < 4 ? `B${i}` : undefined, positions: n }));
    expect(summarize(vessels)).toEqual({
      total: 6,
      named: 4,
      totalPositions: 100,
      cover: [
        { share: 0.5, vessels: 1 }, // exactly 50%
        { share: 0.8, vessels: 2 }, // exactly 80%
        { share: 0.95, vessels: 4 }, // 95 of 100
      ],
    });
  });

  test('order does not matter, a share needing one more vessel takes it, and empty input is zeros', () => {
    expect(summarize([{ positions: 1 }, { positions: 1 }, { positions: 1 }, { positions: 1 }]).cover.map((c) => c.vessels)).toEqual([2, 4, 4]);
    expect(summarize([{ positions: 1 }, { positions: 9 }]).cover.map((c) => c.vessels)).toEqual([1, 1, 2]);
    expect(summarize([])).toEqual({ total: 0, named: 0, totalPositions: 0, cover: [0.5, 0.8, 0.95].map((share) => ({ share, vessels: 0 })) });
    expect(summarize([{ positions: 0 }]).cover.map((c) => c.vessels)).toEqual([0, 0, 0]);
  });

  test('an empty name does not count as named', () => {
    expect(summarize([{ name: '', positions: 1 }, { name: 'A', positions: 1 }]).named).toBe(1);
  });
});

describe('formatReport', () => {
  test('a table with rank, mmsi, name, type, length, days, positions, lastSeen, then the summary', () => {
    const text = formatReport([rec(367000001, 9, { name: 'HARBOR LARK', shipType: 60, length: 30, daysSeen: 3 }), rec(5, 1)]);
    const lines = text.split('\n');
    expect(lines[0].split(/\s+/)).toEqual(['rank', 'mmsi', 'name', 'type', 'length', 'days', 'positions', 'lastSeen']);
    expect(lines[1]).toMatch(/^\s*1\s+367000001\s+HARBOR LARK\s+60\s+30\s+3\s+9\s+2026-11-11T00:00:00.000Z$/);
    expect(lines[2]).toMatch(/^\s*2\s+5\s+-\s+-\s+-\s+1\s+1\s+2026-11-11/);
    expect(text).toContain('vessels: 2\nnamed: 1\n');
    expect(text).toContain('1 vessel(s) cover 50% of position reports');
    expect(text).toContain('2 vessel(s) cover 95% of position reports');
  });
});

describe('loadVessels', () => {
  let dir: string;
  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'census-report-'));
  });
  afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

  test('reads a census file; refuses something else', async () => {
    const file = path.join(dir, 'census.json');
    fs.writeFileSync(file, JSON.stringify({ version: 1, generatedAt: 'x', vessels: [rec(1, 2)] }));
    expect(await loadVessels(file)).toEqual([rec(1, 2)]);
    fs.writeFileSync(file, '{"nope":1}');
    await expect(loadVessels(file)).rejects.toThrow('not a census');
  });

  test('reads a URL, asking for the most it gives unless the URL has a query; a non-200 is an error', async () => {
    const seen: string[] = [];
    let status = 200;
    const server = http.createServer((req, res) => {
      seen.push(req.url ?? '');
      res.writeHead(status).end(JSON.stringify({ version: 1, generatedAt: 'x', vessels: [rec(1, 2)] }));
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    const { port } = server.address() as { port: number };
    try {
      expect(await loadVessels(`http://127.0.0.1:${port}/census`)).toHaveLength(1);
      expect(await loadVessels(`http://127.0.0.1:${port}/census?limit=10`)).toHaveLength(1);
      expect(seen).toEqual(['/census?limit=5000', '/census?limit=10']);
      status = 404;
      await expect(loadVessels(`http://127.0.0.1:${port}/census`)).rejects.toThrow('404');
    } finally {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    }
  });
});
