import { describe, expect, test } from '@jest/globals';
import {
  COVER_M,
  DEFAULT_STATION_DEPTH_M,
  DEFAULT_TUBE_LOW_M,
  estimatedBetween,
  interpolate,
  MAX_GRADE,
  railProfile,
  stationDepth,
  tubeLow,
  waterCrossings,
  type RangeEnd,
  type RangeSpec,
} from './depth';

const station = (altitude: number, estimated = true): RangeEnd => ({ altitude, estimated, portal: false });
const portal = (altitude: number, estimated = false): RangeEnd => ({ altitude, estimated, portal: true });
const flat = (elevation: number) => () => elevation;

const spec = (over: Partial<RangeSpec> & Pick<RangeSpec, 'start' | 'end'>): RangeSpec => ({ length: 1000, ground: flat(10), lows: [], ...over });
const altAt = (p: { knots: [number, number][] }, x: number) => interpolate(p.knots, x);

/** The steepest grade between samples 25 m apart over the whole range. */
function steepest(p: { knots: [number, number][] }, length: number): number {
  let worst = 0;
  for (let x = 25; x <= length; x += 25) worst = Math.max(worst, Math.abs(altAt(p, x) - altAt(p, x - 25)) / 25);
  return worst;
}

describe('interpolate', () => {
  test('linear between knots, flat outside', () => {
    const k: [number, number][] = [[0, 10], [100, 20], [300, 0]];
    expect(interpolate(k, -5)).toBe(10);
    expect(interpolate(k, 50)).toBe(15);
    expect(interpolate(k, 200)).toBe(10);
    expect(interpolate(k, 500)).toBe(0);
  });
});

describe('waterCrossings', () => {
  const samples = (values: number[], step = 100): [number, number][] => values.map((v, i) => [i * step, v]);

  test('a run of water samples is a crossing from halfway to the last dry sample to halfway to the next', () => {
    expect(waterCrossings(samples([3, 2, -1.6, -1.6, -1.6, -1.6, 2, 4]))).toEqual([[150, 550]]);
  });

  test('a short wet run is a slip or a dock, not a crossing', () => {
    expect(waterCrossings(samples([3, -1.6, 2, 4]))).toEqual([]);
  });

  test('a crossing at the end of the track runs to its last sample', () => {
    expect(waterCrossings(samples([3, -1.6, -1.6, -1.6]))).toEqual([[50, 300]]);
  });

  test('a sample with no data counts as water, so a gap in the data cannot hide a crossing', () => {
    expect(waterCrossings(samples([3, 2, -1.6, NaN, NaN, -1.6, 2, 4]))).toEqual([[150, 550]]);
    expect(waterCrossings(samples([3, NaN, NaN, NaN, 4]))).toEqual([[50, 350]]);
    expect(waterCrossings(samples([3, NaN, 2, 4]))).toEqual([]);
  });
});

describe('railProfile', () => {
  test('between two stations: linear in rail altitude, the station altitudes held exactly', () => {
    const p = railProfile(spec({ start: station(4), end: station(-6) }));
    expect(altAt(p, 0)).toBe(4);
    expect(altAt(p, 1000)).toBe(-6);
    expect(altAt(p, 500)).toBeCloseTo(-1, 1);
    expect(p.clamps).toEqual([]);
    expect(p.knots).toHaveLength(2);
  });

  test('never above the ground less COVER_M: a hill dip pushes the rail down', () => {
    // Ground 10 m, dipping to 2 m in the middle (a street cut): the rail has to stay 3 m under it.
    const ground = (x: number) => 10 - 8 * Math.max(0, 1 - Math.abs(x - 500) / 100);
    const p = railProfile(spec({ start: station(4), end: station(4), ground }));
    for (let x = 0; x <= 1000; x += 25) expect(altAt(p, x)).toBeLessThanOrEqual(ground(x) - COVER_M + 0.2);
    expect(altAt(p, 500)).toBeLessThan(-0.8);
    expect(p.clamps.some((c) => c.kind === 'cover')).toBe(true);
    expect(altAt(p, 0)).toBe(4);
    expect(altAt(p, 1000)).toBe(4);
  });

  test('the grade is held to MAX_GRADE after the cover clamp, and the clamp is reported', () => {
    const ground = (x: number) => (x >= 480 && x <= 520 ? -10 : 10); // a deep cut: the rail must go below -13 there
    const p = railProfile(spec({ start: station(4), end: station(4), ground }));
    expect(steepest(p, 1000)).toBeLessThanOrEqual(MAX_GRADE + 0.005);
    expect(altAt(p, 500)).toBeLessThanOrEqual(-13 + 0.2);
    expect(p.clamps.map((c) => c.kind)).toContain('grade');
    expect(altAt(p, 0)).toBe(4);
    expect(altAt(p, 1000)).toBe(4);
  });

  test('a portal ramps down to the tunnel altitude at MAX_GRADE, with no jump', () => {
    // Out of a bridge at 20 m, 1500 m of tunnel to a station at 4 m under 10 m ground... the baseline at the portal is
    // ground less the default depth, 4 m: a 16 m ramp, 400 m at 4%.
    const p = railProfile(spec({ length: 1500, start: portal(20), end: station(4) }));
    expect(altAt(p, 0)).toBe(20);
    expect(altAt(p, 1500)).toBe(4);
    expect(altAt(p, 200)).toBeCloseTo(12, 1);
    expect(altAt(p, 400)).toBeCloseTo(4, 1);
    expect(altAt(p, 900)).toBeCloseTo(4, 1);
    expect(steepest(p, 1500)).toBeLessThanOrEqual(MAX_GRADE + 0.005);
    expect(p.clamps.map((c) => c.kind)).toContain('portal');
    expect(p.clamps.map((c) => c.kind)).not.toContain('steep');
  });

  test('a portal below the tunnel altitude ramps the rail down from the portal too', () => {
    const p = railProfile(spec({ length: 1500, start: portal(-6), end: station(4) }));
    expect(altAt(p, 0)).toBe(-6);
    expect(altAt(p, 1500)).toBe(4);
    expect(steepest(p, 1500)).toBeLessThanOrEqual(MAX_GRADE + 0.005);
  });

  test('a portal too close to a station for the height difference: straight between them, reported as steep', () => {
    const p = railProfile(spec({ length: 300, start: portal(20), end: station(-4) }));
    expect(altAt(p, 0)).toBe(20);
    expect(altAt(p, 300)).toBe(-4);
    expect(altAt(p, 150)).toBeCloseTo(8, 1);
    const steep = p.clamps.find((c) => c.kind === 'steep');
    expect(steep?.amount).toBeCloseTo(24 / 300, 3);
  });

  test('the steep fallback reports any tube low point it drops', () => {
    const p = railProfile(spec({ length: 300, start: portal(20), end: station(-4), lows: [{ x: 150, altitude: -28, estimated: true }] }));
    const kinds = p.clamps.map((c) => c.kind);
    // After the steep run, the dropped low point (earlier clamps are the ones the fallback overrides).
    expect(kinds.slice(kinds.indexOf('steep'))).toEqual(['steep', 'tube']);
    // Straight from 20 to -4: 8 m at the low point, 36 m above it.
    const dropped = p.clamps[p.clamps.length - 1];
    expect(dropped).toMatchObject({ kind: 'tube', from: 150, to: 150 });
    expect(dropped.amount).toBeCloseTo(36, 1);
    expect(altAt(p, 150)).toBeCloseTo(8, 1);
  });

  test('the steep fallback with no tube low points reports only the steep run', () => {
    const p = railProfile(spec({ length: 300, start: portal(20), end: station(-4) }));
    expect(p.clamps.map((c) => c.kind)).toEqual(['steep']);
  });

  test('a river tube: the rail is lowest at the low point, and the stations keep their altitudes', () => {
    const p = railProfile(
      spec({ length: 2400, ground: flat(10), start: station(4), end: station(4), lows: [{ x: 1200, altitude: -28, estimated: true }] }),
    );
    expect(altAt(p, 1200)).toBeCloseTo(-28, 1);
    expect(Math.min(...p.knots.map((k) => k[1]))).toBeCloseTo(-28, 1);
    expect(altAt(p, 0)).toBe(4);
    expect(altAt(p, 2400)).toBe(4);
    expect(steepest(p, 2400)).toBeLessThanOrEqual(MAX_GRADE + 0.005);
    expect(p.clamps).toEqual([]);
  });

  test('a river tube too short for its low point: the low point is raised to what 4% reaches, and reported', () => {
    // 600 m from station to station: the rail can only drop 12 m from each end by the middle.
    const p = railProfile(
      spec({ length: 600, ground: flat(10), start: station(4), end: station(4), lows: [{ x: 300, altitude: -28, estimated: true }] }),
    );
    expect(altAt(p, 300)).toBeCloseTo(4 - 0.04 * 300, 1);
    expect(p.clamps.find((c) => c.kind === 'tube')?.amount).toBeCloseTo(-8 - -28, 1);
    expect(steepest(p, 600)).toBeLessThanOrEqual(MAX_GRADE + 0.005);
  });

  test('knots are simplified: a straight run is two knots', () => {
    expect(railProfile(spec({ length: 5000, start: station(0), end: station(-20) })).knots).toHaveLength(2);
  });
});

describe('estimatedBetween', () => {
  const p = railProfile(
    spec({ length: 2000, start: station(4, false), end: station(4, true), lows: [{ x: 1000, altitude: -20, estimated: false }] }),
  );

  test('a span between two published controls is not estimated; one that reaches an estimated control is', () => {
    expect(estimatedBetween(p, 100, 900)).toBe(false);
    expect(estimatedBetween(p, 1100, 1900)).toBe(true);
    expect(estimatedBetween(p, 800, 1000)).toBe(false);
    expect(estimatedBetween(p, 800, 1200)).toBe(true); // reaches past the low point to the estimated end
    expect(estimatedBetween(p, 1500, 2000)).toBe(true);
  });

  test('a portal end counts as an estimated baseline (the tunnel altitude it ramps to is a default)', () => {
    const q = railProfile(spec({ length: 1500, start: portal(20, false), end: station(4, false) }));
    expect(estimatedBetween(q, 0, 1500)).toBe(true);
    const r = railProfile(spec({ length: 1500, start: station(4, false), end: station(4, false) }));
    expect(estimatedBetween(r, 0, 1500)).toBe(false);
  });
});

describe('the depth tables', () => {
  test('published station depths, each with its source quoted', () => {
    expect(stationDepth('231')).toMatchObject({ depth: 24, source: 'published' }); // Clark St
    expect(stationDepth('A40')).toMatchObject({ depth: 21, source: 'published' }); // High St
    expect(stationDepth('F18')).toMatchObject({ depth: 24, source: 'published' }); // York St
    for (const id of ['231', 'A40', 'F18']) expect(stationDepth(id).note).toContain('Wikipedia');
  });

  test('every other station: the cut-and-cover default, estimated', () => {
    expect(stationDepth('A41')).toEqual({ depth: DEFAULT_STATION_DEPTH_M, source: 'estimated', note: expect.any(String) });
  });

  test('tubes: Joralemon (4 5) and Cranberry (A C) published, the rest the Joralemon figure, estimated', () => {
    expect(tubeLow('423', '420')).toMatchObject({ source: 'published', altitude: DEFAULT_TUBE_LOW_M });
    expect(tubeLow('A40', 'A38').source).toBe('published');
    expect(tubeLow('F16', 'F18')).toMatchObject({ source: 'estimated', altitude: DEFAULT_TUBE_LOW_M });
    expect(DEFAULT_TUBE_LOW_M).toBeCloseTo(-27.9, 1);
  });
});
