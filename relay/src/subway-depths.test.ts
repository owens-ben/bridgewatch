import { describe, expect, test } from '@jest/globals';
import { metersBetween, type TrackPart, type TrackSegment } from './subway';
import { SUBWAY_DATA } from './subway-data';
import { DEFAULT_TUBE_LOW_M, MAX_GRADE, MEAN_HIGH_WATER_M, COVER_M, stationDepth, tubeLow } from './tools/depth';
import { ElevationCache } from './tools/elevation';

/**
 * Integrity of the depth model as baked into subway-data.ts (src/tools/depth.ts, the extractor): every altitude is
 * sane, the rail joins up everywhere, and the figures the model was given come out at the stations and tubes.
 */

const cache = new ElevationCache();
const ground = (lat: number, lon: number) => cache.get(lat, lon);

const segments = SUBWAY_DATA.segments;
const parts = segments.flatMap((s) => s.parts);
const underground = parts.filter((p) => p.underground);

/** Stations by parent ID: [lat, lon] from MTA's stops.txt (2026 fall pick). */
const STATIONS: Record<string, [number, number]> = {
  '231': [40.697466, -73.993086], // Clark St (2 3)
  A40: [40.699337, -73.990531], // High St (A C)
  F18: [40.701397, -73.986751], // York St (F)
  '142': [40.702068, -74.013664], // South Ferry (1)
};

/** The rail altitude where a segment meets `station`: its first or last point, wherever a part of it touches. */
function altitudesAt(station: string): number[] {
  const out: number[] = [];
  for (const s of segments) {
    if (s.a === station) for (const p of s.parts) if (p.from <= 1) out.push(p.points[0][2]);
    if (s.b === station) for (const p of s.parts) if (p.to >= s.length - 1) out.push(p.points[p.points.length - 1][2]);
  }
  return out;
}

const segment = (a: string, b: string): TrackSegment => segments.find((s) => (s.a === a && s.b === b) || (s.a === b && s.b === a))!;

describe('underground altitudes', () => {
  test('every point of every underground part has a finite altitude in a sane range', () => {
    expect(underground.length).toBeGreaterThan(80);
    for (const p of underground) {
      for (const [lat, lon, alt] of p.points) {
        expect([lat, lon, Number.isFinite(alt) && alt > -45 && alt < 35]).toEqual([lat, lon, true]);
      }
    }
  });

  test('a good part of the extract is below sea level, and some of it well down', () => {
    const alts = underground.flatMap((p) => p.points.map((q) => q[2]));
    expect(Math.min(...alts)).toBeLessThan(-20);
    expect(alts.filter((a) => a < 0).length).toBeGreaterThan(alts.length / 5);
  });

  test('no jump anywhere: consecutive parts of a segment (portals included) differ by at most 2 m where they meet', () => {
    let portals = 0;
    for (const s of segments) {
      for (let i = 1; i < s.parts.length; i++) {
        const before = s.parts[i - 1];
        const after = s.parts[i];
        if (after.from - before.to > 1) continue; // the track left the area between them
        portals++;
        const jump = Math.abs(before.points[before.points.length - 1][2] - after.points[0][2]);
        expect([`${s.a}-${s.b}`, before.to, jump <= 2]).toEqual([`${s.a}-${s.b}`, before.to, true]);
      }
    }
    expect(portals).toBeGreaterThan(4);
  });

  test('no grade over about 4% within a part (vertices 20 m or more apart; the Manhattan Bridge approach is the only steeper run)', () => {
    for (const s of segments) {
      for (const p of s.parts.filter((q) => q.underground)) {
        for (let i = 1; i < p.points.length; i++) {
          const [la1, lo1, h1] = p.points[i - 1];
          const [la2, lo2, h2] = p.points[i];
          const d = metersBetween(la1, lo1, la2, lo2);
          if (d < 20) continue;
          const grade = Math.abs(h2 - h1) / d;
          // The rounding to 0.1 m and the 0.15 m knot tolerance allow a little more than 4%.
          expect([`${s.a}-${s.b}`, p.from, grade < MAX_GRADE + 0.012]).toEqual([`${s.a}-${s.b}`, p.from, true]);
        }
      }
    }
  });

  test('the rail meets itself at every station: all segments that end at one agree on its altitude', () => {
    const stations = new Set(segments.flatMap((s) => [s.a, s.b]));
    let checked = 0;
    for (const id of stations) {
      const alts = altitudesAt(id);
      if (alts.length < 2) continue;
      checked++;
      expect([id, Math.max(...alts) - Math.min(...alts) <= 0.15]).toEqual([id, true]);
    }
    expect(checked).toBeGreaterThan(30);
  });

  test('stations are at their ground elevation less their depth, and never within COVER_M of the street', () => {
    for (const [id, [lat, lon]] of Object.entries(STATIONS)) {
      const g = ground(lat, lon);
      expect(typeof g).toBe('number');
      const alts = altitudesAt(id);
      expect(alts.length).toBeGreaterThan(0);
      for (const a of alts) {
        expect(a).toBeCloseTo((g as number) - stationDepth(id).depth, 1);
        expect(a).toBeLessThanOrEqual((g as number) - COVER_M);
      }
    }
  });

  test('the published depths: Clark St and York St 24 m, High St 21 m, South Ferry 15 m, below the street', () => {
    for (const [id, depth] of [['231', 24], ['F18', 24], ['A40', 21], ['142', 15]] as const) {
      const [lat, lon] = STATIONS[id];
      expect(stationDepth(id)).toMatchObject({ depth, source: 'published' });
      expect(altitudesAt(id)[0]).toBeCloseTo((ground(lat, lon) as number) - depth, 1);
    }
  });
});

describe('river tubes', () => {
  /** The tubes the extract has: [a, b], the segment's stations. */
  const TUBES: [string, string][] = [
    ['F16', 'F18'], // Rutgers St (F)
    ['A38', 'A40'], // Cranberry St (A C)
    ['230', '231'], // Clark St (2 3)
    ['420', '423'], // Joralemon St (4 5)
    ['R27', 'R28'], // Montague St (R)
    ['L06', 'L08'], // 14th St - Canarsie (L)
  ];

  test.each(TUBES)('%s - %s: the rail is lowest in the middle, at the tube\'s low point', (a, b) => {
    const s = segment(a, b);
    expect(s).toBeDefined();
    const part = s.parts.find((p) => p.underground && p.from <= 1 && p.to >= s.length - 1)!;
    expect(part).toBeDefined();
    const low = tubeLow(a, b).altitude;
    const lowest = part.points.reduce((m, q) => (q[2] < m[2] ? q : m));
    // At the low point, or above it where 4% from the stations could not reach it (the model raises it).
    expect(lowest[2]).toBeGreaterThanOrEqual(low - 0.3);
    expect(lowest[2]).toBeLessThan(-8);
    // In the middle of the run, not by a station.
    const along =
      part.points.slice(0, part.points.indexOf(lowest)).reduce((n, q, i) => n + metersBetween(part.points[i][0], part.points[i][1], part.points[i + 1][0], part.points[i + 1][1]), 0);
    expect(along / s.length).toBeGreaterThan(0.2);
    expect(along / s.length).toBeLessThan(0.8);
    // Both ends are stations, well above it.
    expect(part.points[0][2]).toBeGreaterThan(lowest[2] + 5);
    expect(part.points[part.points.length - 1][2]).toBeGreaterThan(lowest[2] + 5);
  });

  test('exactly these six tubes have a low point, each below -20 m: no tube lost, none made up', () => {
    const key = (a: string, b: string) => [a, b].sort().join('|');
    const deep = segments
      .filter((s) => s.parts.some((p) => p.underground && p.points.some((q) => q[2] < -20)))
      .map((s) => key(s.a, s.b))
      .sort();
    expect(deep).toEqual(TUBES.map(([a, b]) => key(a, b)).sort());
    for (const [a, b] of TUBES) {
      const lowest = Math.min(...segment(a, b).parts.filter((p) => p.underground).flatMap((p) => p.points.map((q) => q[2])));
      expect([a, b, lowest < -20]).toEqual([a, b, true]);
    }
  });

  test('the published low points: Joralemon 28.5 m below mean high water, Cranberry 27 m', () => {
    expect(tubeLow('420', '423')).toMatchObject({ source: 'published', altitude: MEAN_HIGH_WATER_M - 28.5 });
    expect(tubeLow('A38', 'A40')).toMatchObject({ source: 'published', altitude: MEAN_HIGH_WATER_M - 27 });
    for (const [a, b] of [['F16', 'F18'], ['230', '231'], ['R27', 'R28'], ['L06', 'L08']]) {
      expect(tubeLow(a, b)).toMatchObject({ source: 'estimated', altitude: DEFAULT_TUBE_LOW_M });
    }
  });

  test('an underground part is estimated unless every figure under it is published: tube parts with an estimated end are', () => {
    for (const [a, b] of TUBES) {
      const part = segment(a, b).parts.find((p) => p.underground)!;
      expect(part.altitudeEstimated).toBe(true);
    }
  });
});

describe('the Franklin Av shuttle', () => {
  const s = segment('S01', 'S03');

  test('open air on the embankment: not underground, on the franklin-av stretch, whole, with heights', () => {
    expect(SUBWAY_DATA.stretches).toContainEqual({ id: 'franklin-av', name: 'Franklin Av shuttle' });
    expect(s.length).toBeGreaterThan(640);
    expect(s.length).toBeLessThan(700);
    expect(s.parts).toHaveLength(1);
    expect(s.parts[0]).toMatchObject({ underground: false, stretch: 'franklin-av', from: 0, to: s.length, altitudeEstimated: true });
    const alts = s.parts[0].points.map((q) => q[2]);
    expect(Math.min(...alts)).toBeGreaterThan(25);
    expect(Math.max(...alts)).toBeLessThan(42);
    // Franklin Av (street at about 22 m) is the low end, Park Pl (about 33.5 m) the high one.
    expect(alts[0]).toBeCloseTo(27.6, 0);
    expect(alts[alts.length - 1]).toBeCloseTo(39, 0);
  });

  test('no underground part on the line: the whole of it is the stretch', () => {
    const franklin = parts.filter((p: TrackPart) => p.stretch === 'franklin-av');
    expect(franklin).toHaveLength(1);
    expect(underground.every((p) => p !== s.parts[0])).toBe(true);
  });
});
