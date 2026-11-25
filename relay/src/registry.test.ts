import { describe, expect, test } from '@jest/globals';
import { Registry } from './registry';
import type { VesselUpdate } from './types';

const T0 = Date.parse('2026-11-10T14:00:00.000Z');
const iso = (ms: number) => new Date(ms).toISOString();
const u = (o: Partial<VesselUpdate> & { mmsi: number }, ms = T0): VesselUpdate => ({
  lat: 40.7,
  lon: -73.99,
  timestamp: iso(ms),
  ...o,
});

describe('Registry', () => {
  test('merges name/shipType and per-field position values', () => {
    const r = new Registry();
    r.apply(u({ mmsi: 1, sog: 5, cog: 10, heading: 20 }, T0));
    r.apply(u({ mmsi: 1, name: 'X', shipType: 60, lat: 40.71, lon: -73.98 }, T0 + 1000));
    r.apply(u({ mmsi: 1, lat: 40.72, lon: -73.97, sog: 6 }, T0 + 2000));
    expect(r.snapshot(T0 + 2000)).toEqual([
      { mmsi: 1, name: 'X', shipType: 60, lat: 40.72, lon: -73.97, sog: 6, cog: 10, heading: 20, timestamp: iso(T0 + 2000) },
    ]);
  });

  test('equal timestamp counts as not older', () => {
    const r = new Registry();
    r.apply(u({ mmsi: 1, lat: 1, lon: 1 }));
    r.apply(u({ mmsi: 1, lat: 2, lon: 2 }));
    expect(r.snapshot(T0)[0]).toMatchObject({ lat: 2, lon: 2 });
  });

  test('out-of-order update does not move vessel or change lastSeen, but still merges static fields', () => {
    const r = new Registry();
    r.apply(u({ mmsi: 1, lat: 1, lon: 1, sog: 9 }, T0 + 60_000));
    r.apply(u({ mmsi: 1, name: 'OLD', lat: 2, lon: 2, sog: 3 }, T0));
    expect(r.snapshot(T0 + 60_000)).toEqual([
      { mmsi: 1, name: 'OLD', lat: 1, lon: 1, sog: 9, timestamp: iso(T0 + 60_000) },
    ]);
  });

  test('lastSeen is the newest timestamp, even from an older-position static update', () => {
    const r = new Registry();
    r.apply(u({ mmsi: 1 }, T0));
    r.apply(u({ mmsi: 1, name: 'N' }, T0 + 5000));
    expect(r.snapshot(T0)[0].timestamp).toBe(iso(T0 + 5000));
  });

  test('expiry boundary: exactly 600 s kept, 600.001 s dropped', () => {
    const r = new Registry();
    r.apply(u({ mmsi: 1 }));
    expect(r.snapshot(T0 + 600_000)).toHaveLength(1);
    expect(r.snapshot(T0 + 600_001)).toHaveLength(0);
    expect(r.prune(T0 + 600_000)).toBe(0);
    expect(r.size).toBe(1);
    expect(r.prune(T0 + 600_001)).toBe(1);
    expect(r.size).toBe(0);
  });

  test('snapshot sorted by mmsi and omits unknown keys', () => {
    const r = new Registry();
    r.apply(u({ mmsi: 30 }));
    r.apply(u({ mmsi: 10 }));
    r.apply(u({ mmsi: 20 }));
    const s = r.snapshot(T0);
    expect(s.map((v) => v.mmsi)).toEqual([10, 20, 30]);
    expect(Object.keys(s[0])).toEqual(['mmsi', 'lat', 'lon', 'timestamp']);
  });

  test('ignores updates with unparseable timestamps', () => {
    const r = new Registry();
    r.apply({ mmsi: 1, lat: 0, lon: 0, timestamp: 'nope' });
    expect(r.size).toBe(0);
  });
});

describe('Registry extras (v2 only)', () => {
  test('static extras replace per key and are kept when a later message omits them', () => {
    const r = new Registry();
    r.apply(u({ mmsi: 1 }), { imo: 7, destination: 'A', length: 30 });
    r.apply(u({ mmsi: 1 }, T0 + 1000), { destination: 'B' });
    r.apply(u({ mmsi: 1, sog: 3 }, T0 + 2000));
    r.apply(u({ mmsi: 1 }, T0 + 3000), {});
    expect(r.get(1)?.extras).toEqual({ imo: 7, destination: 'B', length: 30 });
  });
  test('navStatus comes with positions: replaced when a position has it, kept otherwise', () => {
    const r = new Registry();
    r.apply(u({ mmsi: 1 }), { navStatus: 0 });
    r.apply(u({ mmsi: 1 }, T0 + 1000));
    expect(r.get(1)?.extras.navStatus).toBe(0);
    r.apply(u({ mmsi: 1 }, T0 + 2000), { navStatus: 5 });
    expect(r.get(1)?.extras.navStatus).toBe(5);
    r.apply(u({ mmsi: 1 }, T0 + 3000), { destination: 'X' });
    expect(r.get(1)?.extras).toEqual({ navStatus: 5, destination: 'X' });
  });
  test('an older position report does not replace navStatus', () => {
    const r = new Registry();
    r.apply(u({ mmsi: 1 }, T0 + 5000), { navStatus: 5 });
    r.apply(u({ mmsi: 1 }, T0), { navStatus: 1 });
    expect(r.get(1)?.extras.navStatus).toBe(5);
  });
  test('extras never reach a /v1 snapshot', () => {
    const r = new Registry();
    r.apply(u({ mmsi: 1 }), { imo: 7, navStatus: 5 });
    expect(r.snapshot(T0)).toEqual([{ mmsi: 1, lat: 40.7, lon: -73.99, timestamp: iso(T0) }]);
  });
  test('expiry is unchanged: extras go with the vessel', () => {
    const r = new Registry();
    r.apply(u({ mmsi: 1 }), { imo: 7 });
    expect(r.prune(T0 + 600_001)).toBe(1);
    expect(r.get(1)).toBeUndefined();
  });
});
