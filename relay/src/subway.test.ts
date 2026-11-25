import { describe, expect, test } from '@jest/globals';
import { INCOMING_AT, IN_TRANSIT_TO, STOPPED_AT, type FeedMessage, type TripUpdate, type VehiclePosition } from './gtfsrt';
import {
  bearingBetween,
  DWELL_SECONDS,
  MAX_FEED_AGE_SECONDS,
  MAX_REPORT_AGE_SECONDS,
  metersBetween,
  TrainEstimator,
  type SubwayData,
} from './subway';

const T0 = Date.parse('2026-11-11T02:52:39Z') / 1000;
const KNOTS_PER_MPS = 3600 / 1852;

// A straight track running due north: station A1 at 40.700, B1 1000 m north, C1 500 m further, D1 500 m beyond that.
const M_PER_DEG_LAT = 111_195;
const latAt = (meters: number) => 40.7 + meters / M_PER_DEG_LAT;
const LON = -73.99;
/** The rail altitude of the test tunnels (the extract's own is modelled per point, see depth.ts). */
const UG = -10;

/** An underground part running north from `from` to `to` meters north of A1. */
const tunnel = (from: number, to: number) => [
  [latAt(from), LON, UG] as const,
  [latAt(to), LON, UG] as const,
];

/**
 * A -> B (1000 m): underground for 200 m, then on the "bridge" (10 m up to 40 m at 500 m, down to 15 m at B).
 * C -> B (500 m): elevated all the way, so B and C are elevated stations.
 * C -> D (500 m): elevated for 100 m, then down into a tunnel: D is an underground station.
 * I -> J (500 m): underground all the way.
 * E -> F (1000 m), both stations outside the area: only the 400 m from 300 to 700 m are inside.
 * G -> H (1000 m): inside for the first 100 m and the last 400 m (two parts).
 */
const DATA: SubwayData = {
  stretches: [{ id: 'test-bridge', name: 'Test Bridge' }],
  routes: ['Q'],
  // Run A1 -> B1 takes 100 s on the schedule, as do B1 -> A1 and C1 -> D1; trains reach C1 from B1 or from X1, about
  // equally often; the stopping pattern "Q..N01R" is a train that comes into B1 from A1 in 200 s; Y1 -> B1 has no
  // stored track.
  approaches: {
    'Q|N|B1': [{ from: 'A1', seconds: 100, trips: 40 }],
    'Q..N01R|B1': [{ from: 'A1', seconds: 200, trips: 4 }],
    'Q|S|A1': [{ from: 'B1', seconds: 100, trips: 40 }],
    'Q|N|D1': [{ from: 'C1', seconds: 100, trips: 40 }],
    'Q|N|C1': [
      { from: 'B1', seconds: 100, trips: 6 },
      { from: 'X1', seconds: 100, trips: 5 },
    ],
    'Q|N|F1': [{ from: 'E1', seconds: 100, trips: 40 }],
    'Q|S|B1': [{ from: 'Y1', seconds: 100, trips: 40 }],
  },
  terminals: { C1: 'Terminal C', D1: 'Terminal D', J1: 'Terminal J' },
  segments: [
    {
      a: 'A1',
      b: 'B1',
      length: 1000,
      parts: [
        { underground: true, from: 0, to: 200, points: tunnel(0, 200) },
        {
          underground: false,
          stretch: 'test-bridge',
          from: 200,
          to: 1000,
          points: [
            [latAt(200), LON, 10],
            [latAt(500), LON, 40],
            [latAt(1000), LON, 15],
          ],
        },
      ],
    },
    {
      a: 'C1',
      b: 'B1',
      length: 500,
      parts: [
        {
          underground: false,
          stretch: 'test-bridge',
          from: 0,
          to: 500,
          points: [
            [latAt(1500), LON, 20],
            [latAt(1000), LON, 15],
          ],
        },
      ],
    },
    {
      a: 'C1',
      b: 'D1',
      length: 500,
      parts: [
        {
          underground: false,
          stretch: 'test-bridge',
          from: 0,
          to: 100,
          points: [
            [latAt(1500), LON, 20],
            [latAt(1600), LON, 20],
          ],
        },
        { underground: true, from: 100, to: 500, points: tunnel(1600, 2000) },
      ],
    },
    {
      // A tunnel that descends and has rule-based heights.
      a: 'I1',
      b: 'J1',
      length: 500,
      parts: [
        {
          underground: true,
          from: 0,
          to: 500,
          points: [
            [latAt(7000), LON, -12],
            [latAt(7500), LON, -20],
          ],
          altitudeEstimated: true,
        },
      ],
    },
    { a: 'E1', b: 'F1', length: 1000, parts: [{ underground: true, from: 300, to: 700, points: tunnel(3300, 3700) }] },
    {
      a: 'G1',
      b: 'H1',
      length: 1000,
      parts: [
        { underground: true, from: 0, to: 100, points: tunnel(5000, 5100) },
        { underground: true, from: 600, to: 1000, points: tunnel(5600, 6000) },
      ],
    },
  ],
};

const estimator = new TrainEstimator(DATA);

function trip(tripId: string, stops: [string, number][], route = 'Q'): TripUpdate {
  return { trip: { tripId, routeId: route }, stopTimeUpdates: stops.map(([stopId, t]) => ({ stopId, arrival: t, departure: t })) };
}

const stopped = (tripId: string, stopId: string, timestamp: number): VehiclePosition => ({
  trip: { tripId },
  currentStatus: STOPPED_AT,
  stopId,
  timestamp,
});

describe('TrainEstimator, between stations', () => {
  test('placed along the track in proportion to time from its last report (its departure) to the predicted arrival', () => {
    // Reported at A1 (no longer listed) 70 s ago; due at B1 in 100 s: 70/170 of 1000 m.
    const t = estimator.estimate(trip('t1', [['B1N', T0 + 100], ['C1N', T0 + 300]]), stopped('t1', 'A1N', T0 - 70), T0);
    const along = (70 / 170) * 1000;
    expect(t).toMatchObject({
      tripId: 't1',
      route: 'Q',
      direction: 'N',
      destination: 'Terminal C',
      stretch: 'test-bridge',
      underground: false,
      lon: LON,
      bearing: 0,
      speed: Math.round((1000 / 170) * KNOTS_PER_MPS * 10) / 10,
      timestamp: '2026-11-11T02:52:39.000Z',
    });
    expect(metersBetween(t!.lat, t!.lon, latAt(along), LON)).toBeLessThan(0.5);
    // Height interpolated along the profile: 10 m at 200 m, 40 m at 500 m.
    expect(t!.altitude).toBeCloseTo(10 + ((along - 200) / 300) * 30, 0);
    expect(Object.keys(t!)).toEqual([
      'tripId', 'route', 'direction', 'destination', 'stretch', 'underground', 'lat', 'lon', 'altitude', 'altitudeEstimated', 'bearing', 'speed', 'timestamp',
    ]);
    expect(t!.altitudeEstimated).toBe(false);
  });

  test('the underground parts of the run are placed too: no stretch, the part\'s altitude', () => {
    // Left A1 only 20 s ago: 20/170 of 1000 m = 118 m, still in the tunnel.
    const t = estimator.estimate(trip('t1', [['B1N', T0 + 150]]), stopped('t1', 'A1N', T0 - 20), T0);
    expect(t).toMatchObject({ underground: true, altitude: UG, bearing: 0, lon: LON });
    expect(metersBetween(t!.lat, t!.lon, latAt((20 / 170) * 1000), LON)).toBeLessThan(0.5);
    expect(t!.speed).toBeCloseTo((1000 / 170) * KNOTS_PER_MPS, 1);
    // B1 is no terminal: no destination either.
    expect(Object.keys(t!)).toEqual([
      'tripId', 'route', 'direction', 'underground', 'lat', 'lon', 'altitude', 'altitudeEstimated', 'bearing', 'speed', 'timestamp',
    ]);
  });

  test('a run that goes down into a tunnel: on the stretch first, then underground', () => {
    // C1 -> D1 takes 100 s; the tunnel starts 100 m in.
    const at = (seconds: number) => estimator.estimate(trip('t3', [['D1N', T0 + 100 - seconds]]), stopped('t3', 'C1N', T0 - seconds), T0);
    expect(at(10)).toMatchObject({ stretch: 'test-bridge', underground: false, altitude: 20 });
    const inside = at(50);
    expect(inside).toMatchObject({ underground: true, altitude: UG, bearing: 0, destination: 'Terminal D' });
    expect(Object.keys(inside!)).not.toContain('stretch');
    expect(metersBetween(inside!.lat, inside!.lon, latAt(1750), LON)).toBeLessThan(0.5);
    // Coming out the other way, the same places.
    const out = estimator.estimate(trip('t4', [['C1S', T0 + 80]]), stopped('t4', 'D1S', T0 - 20), T0);
    expect(out).toMatchObject({ underground: true, altitude: UG, bearing: 180, direction: 'S', destination: 'Terminal C' });
    expect(metersBetween(out!.lat, out!.lon, latAt(1900), LON)).toBeLessThan(0.5);
  });

  test('a run that is underground all the way', () => {
    const t = estimator.estimate(trip('t5', [['J1N', T0 + 60]]), stopped('t5', 'I1N', T0 - 40), T0);
    expect(t).toMatchObject({ underground: true, bearing: 0, destination: 'Terminal J', altitudeEstimated: true });
    expect(metersBetween(t!.lat, t!.lon, latAt(7200), LON)).toBeLessThan(0.5);
    // The modelled altitude, interpolated along the part (-12 m to -20 m): 200 m of 500.
    expect(t!.altitude).toBeCloseTo(-12 - (200 / 500) * 8, 1);
  });

  test('track outside the area is not placed: only what a segment has inside it, in one part or in several', () => {
    // E1 -> F1 runs 100 s; the area holds 300-700 m of it.
    const e = (seconds: number) => estimator.estimate(trip('e', [['F1N', T0 + 100 - seconds]]), stopped('e', 'E1N', T0 - seconds), T0);
    expect(e(0)).toBeUndefined();
    expect(e(25)).toBeUndefined(); // 250 m: not in yet
    expect(e(35)).toMatchObject({ underground: true });
    expect(metersBetween(e(50)!.lat, LON, latAt(3500), LON)).toBeLessThan(0.5);
    expect(e(65)).toMatchObject({ underground: true });
    expect(e(75)).toBeUndefined(); // 750 m: out again
    // G1 -> H1 is inside for 0-100 m and 600-1000 m.
    const g = (seconds: number) => estimator.estimate(trip('g', [['H1N', T0 + 100 - seconds]]), stopped('g', 'G1N', T0 - seconds), T0);
    expect(metersBetween(g(5)!.lat, LON, latAt(5050), LON)).toBeLessThan(0.5);
    expect(g(30)).toBeUndefined();
    expect(metersBetween(g(80)!.lat, LON, latAt(5800), LON)).toBeLessThan(0.5);
  });

  test('the other way along the same segment: reversed position and bearing', () => {
    // B1 -> A1, halfway: 500 m from A1, at the top of the bridge.
    const t = estimator.estimate(trip('t2', [['A1S', T0 + 100]]), stopped('t2', 'B1S', T0 - 100), T0);
    expect(t).toMatchObject({ direction: 'S', bearing: 180, altitude: 40 });
    expect(metersBetween(t!.lat, t!.lon, latAt(500), LON)).toBeLessThan(0.5);
    expect(t!.destination).toBeUndefined();
    expect(Object.keys(t!)).not.toContain('destination');
  });

  test('a train whose next stop is overdue waits there briefly, then moves on to the following segment', () => {
    // Left A1 at T0 - 400, due at B1 at T0 - 100, then C1 at T0 + 130: dwell 30 s, so it left B1 at T0 - 70 and is
    // 70/200 of the way to C1.
    const t = estimator.estimate(trip('t4', [['B1N', T0 - 100], ['C1N', T0 + 130]]), stopped('t4', 'A1N', T0 - 400), T0);
    expect(t).toMatchObject({ stretch: 'test-bridge', bearing: 0 });
    expect(metersBetween(t!.lat, t!.lon, latAt(1000 + 0.35 * 500), LON)).toBeLessThan(0.5);
    expect(t!.speed).toBeCloseTo((500 / 200) * KNOTS_PER_MPS, 1);
  });

  test('the dwell at a predicted stop is at most a third of the run that follows it', () => {
    // Due at B1 at T0 - 45, then C1 at T0 + 15: a 60 s run, so the dwell is 20 s and it left B1 at T0 - 25,
    // 25/40 of the way to C1.
    const t = estimator.estimate(trip('t3', [['B1N', T0 - 45], ['C1N', T0 + 15]]), stopped('t3', 'A1N', T0 - 300), T0);
    expect(metersBetween(t!.lat, t!.lon, latAt(1000 + (25 / 40) * 500), LON)).toBeLessThan(0.5);
    expect(t!.speed).toBeCloseTo((500 / 40) * KNOTS_PER_MPS, 1);
  });

  test('stale stops listed before the one the train reported are dropped', () => {
    // NYCT sometimes still lists stops the train has passed, ahead of the one it reports.
    const t = estimator.estimate(trip('t5', [['A1N', T0 - 300], ['B1N', T0 - 10], ['C1N', T0 + 300]]), stopped('t5', 'B1N', T0 - 10), T0);
    expect(t).toMatchObject({ speed: 0, bearing: 0 });
    expect(metersBetween(t!.lat, t!.lon, latAt(1000), LON)).toBeLessThan(0.5);
  });
});

const transit = (tripId: string, stopId: string, timestamp: number, currentStatus = IN_TRANSIT_TO): VehiclePosition => ({
  trip: { tripId },
  currentStatus,
  stopId,
  timestamp,
});

describe('TrainEstimator, in transit to a station', () => {
  // The station before is no longer in the trip update: it comes from the schedule's approaches (A1 -> B1, 100 s).
  test('left A1 at the predicted arrival less the scheduled run time: placed in proportion to time', () => {
    // Due at B1 in 40 s, a run of 100 s: left 60 s ago (the report, 20 s ago, is later than that), 60% of 1000 m.
    const t = estimator.estimate(trip('i1', [['B1N', T0 + 40], ['C1N', T0 + 300]]), transit('i1', 'B1N', T0 - 20), T0);
    expect(t).toMatchObject({
      tripId: 'i1',
      route: 'Q',
      direction: 'N',
      destination: 'Terminal C',
      stretch: 'test-bridge',
      underground: false,
      lon: LON,
      bearing: 0,
      speed: Math.round((1000 / 100) * KNOTS_PER_MPS * 10) / 10,
    });
    expect(metersBetween(t!.lat, t!.lon, latAt(600), LON)).toBeLessThan(0.5);
    expect(t!.altitude).toBeCloseTo(40 - ((600 - 500) / 500) * 25, 0); // 40 m at 500 m, 15 m at B1
  });

  test('a train that is late (arrival further off than the run time): it left no later than its report', () => {
    // Due in 150 s: by the run time it would leave in 50 s, but it's in transit, so it left at the report, 20 s ago.
    const t = estimator.estimate(trip('i2', [['B1N', T0 + 150]]), transit('i2', 'B1N', T0 - 20), T0);
    expect(metersBetween(t!.lat, t!.lon, latAt((20 / 170) * 1000), LON)).toBeLessThan(0.5);
    expect(t!.underground).toBe(true);
    expect(t!.speed).toBeCloseTo((1000 / 170) * KNOTS_PER_MPS, 1);
  });

  test('INCOMING_AT is placed the same way', () => {
    const t = estimator.estimate(trip('i3', [['B1N', T0 + 10]]), transit('i3', 'B1N', T0 - 5, INCOMING_AT), T0);
    expect(metersBetween(t!.lat, t!.lon, latAt(900), LON)).toBeLessThan(0.5);
  });

  test('moves forward as time passes, never past the station before the predicted arrival', () => {
    const stops: [string, number][] = [['B1N', T0 + 40], ['C1N', T0 + 300]];
    const at = (now: number) => estimator.estimate(trip('i4', stops), transit('i4', 'B1N', T0 - 20), now);
    let last = -1;
    for (let now = T0; now < T0 + 40; now += 0.5) {
      const along = metersBetween(latAt(0), LON, at(now)!.lat, LON);
      expect(along).toBeGreaterThanOrEqual(last);
      expect(along).toBeLessThan(1000);
      last = along;
    }
    expect(last).toBeGreaterThan(990);
    // Due now: it's at B1, standing for its dwell, then on toward C1.
    expect(at(T0 + 40)).toMatchObject({ speed: 0 });
    expect(metersBetween(at(T0 + 40)!.lat, LON, latAt(1000), LON)).toBeLessThan(0.5);
    expect(at(T0 + 40 + DWELL_SECONDS + 10)!.speed).toBeGreaterThan(0);
  });

  test('the position follows the predicted arrival, not the report time, for a train that is not late', () => {
    // Same report, arrival 10 s sooner: 10 s further along (speed unchanged).
    const a = estimator.estimate(trip('i5', [['B1N', T0 + 40]]), transit('i5', 'B1N', T0 - 50), T0)!;
    const b = estimator.estimate(trip('i5', [['B1N', T0 + 30]]), transit('i5', 'B1N', T0 - 50), T0)!;
    expect(metersBetween(a.lat, LON, b.lat, LON)).toBeCloseTo(100, 0);
    expect(b.speed).toBe(a.speed);
  });

  test('the other direction runs the same segment reversed', () => {
    // B1 -> A1: due at A1 in 50 s, a run of 100 s: halfway, 500 m from A1, at the top of the bridge.
    const t = estimator.estimate(trip('i6', [['A1S', T0 + 50]]), transit('i6', 'A1S', T0 - 10), T0);
    expect(t).toMatchObject({ direction: 'S', bearing: 180, altitude: 40 });
    expect(metersBetween(t!.lat, t!.lon, latAt(500), LON)).toBeLessThan(0.5);
  });

  test('a stopping pattern (the shape ending the trip ID) is preferred to the route and direction', () => {
    // "Q..N01R" runs into B1 from A1 in 200 s, the route as a whole in 100 s.
    const t = estimator.estimate(trip('116450_Q..N01R', [['B1N', T0 + 100]]), transit('116450_Q..N01R', 'B1N', T0 - 20), T0);
    expect(metersBetween(t!.lat, t!.lon, latAt(500), LON)).toBeLessThan(0.5);
    const u = estimator.estimate(trip('116450_Q..N99R', [['B1N', T0 + 100]]), transit('116450_Q..N99R', 'B1N', T0 - 20), T0);
    // An unknown shape goes by the route: a 100 s run would have left at the arrival less 100 s = now, but the report
    // (20 s ago) says it left by then: 20/120 of the way.
    expect(metersBetween(u!.lat, u!.lon, latAt((20 / 120) * 1000), LON)).toBeLessThan(0.5);
  });

  test('past its predicted arrival: waits the dwell at the station, then on along the next run', () => {
    // Due at B1 at T0 - 50, then C1 at T0 + 130 (a 180 s run, so a 30 s dwell): left B1 at T0 - 20, 20/150 of the way.
    const t = estimator.estimate(trip('i7', [['B1N', T0 - 50], ['C1N', T0 + 130]]), transit('i7', 'B1N', T0 - 80), T0);
    expect(metersBetween(t!.lat, t!.lon, latAt(1000 + (20 / 150) * 500), LON)).toBeLessThan(0.5);
  });

  test('a trip that has not left its terminal (reported in transit with a future time) stays unplaced', () => {
    expect(estimator.estimate(trip('i8', [['B1N', T0 + 300]]), transit('i8', 'B1N', T0 + 300), T0)).toBeUndefined();
    // Clock skew is tolerated, as for stopped trains.
    expect(estimator.estimate(trip('i8', [['B1N', T0 + 60]]), transit('i8', 'B1N', T0 + 5), T0)).toBeDefined();
  });

  test('a train in transit that is not yet inside the area (track outside) is not placed', () => {
    // E1 -> F1 runs 100 s; the area holds 300-700 m of it. Due in 90 s: 100 m along.
    expect(estimator.estimate(trip('i9', [['F1N', T0 + 90]]), transit('i9', 'F1N', T0 - 10), T0)).toBeUndefined();
    expect(estimator.estimate(trip('i9', [['F1N', T0 + 50]]), transit('i9', 'F1N', T0 - 10), T0)).toMatchObject({ underground: true });
  });
});

describe('TrainEstimator, at stations', () => {
  test('standing at an elevated station: speed 0, facing the next stop', () => {
    const t = estimator.estimate(trip('t6', [['B1S', T0 - 10], ['A1S', T0 + 300]]), stopped('t6', 'B1S', T0 - 10), T0);
    expect(t).toMatchObject({ speed: 0, bearing: 180, altitude: 15, stretch: 'test-bridge', underground: false });
    expect(metersBetween(t!.lat, t!.lon, latAt(1000), LON)).toBeLessThan(0.5);
    // Toward C1 instead: faces north.
    const u = estimator.estimate(trip('t7', [['B1N', T0 - 10], ['C1N', T0 + 300]]), stopped('t7', 'B1N', T0 - 10), T0);
    expect(u).toMatchObject({ speed: 0, bearing: 0 });
  });

  test('standing at an underground station: placed there, underground, speed 0', () => {
    const t = estimator.estimate(trip('t8', [['A1N', T0 - 10], ['B1N', T0 + 300]]), stopped('t8', 'A1N', T0 - 10), T0);
    expect(t).toMatchObject({ speed: 0, bearing: 0, underground: true, altitude: UG });
    expect(Object.keys(t!)).not.toContain('stretch');
    expect(metersBetween(t!.lat, t!.lon, latAt(0), LON)).toBeLessThan(0.5);
    // Nothing known about where it goes next: it faces along the segment that ends at the station.
    const u = estimator.estimate(trip('t8', [['D1N', T0 - 10]]), stopped('t8', 'D1N', T0 - 10), T0);
    expect(u).toMatchObject({ speed: 0, bearing: 0, underground: true, altitude: UG });
    expect(metersBetween(u!.lat, u!.lon, latAt(2000), LON)).toBeLessThan(0.5);
  });

  test('standing at a station outside the area: not placed', () => {
    expect(estimator.estimate(trip('t8', [['E1N', T0 - 10], ['F1N', T0 + 300]]), stopped('t8', 'E1N', T0 - 10), T0)).toBeUndefined();
    expect(estimator.estimate(trip('t8', [['F1S', T0 - 10], ['E1S', T0 + 300]]), stopped('t8', 'F1S', T0 - 10), T0)).toBeUndefined();
  });

  test('reported at a station still listed: it stays there until a newer feed says it left, even when overdue', () => {
    // Held: reported at B1 4 minutes ago, and C1 was predicted a minute ago.
    const t = estimator.estimate(trip('t9', [['B1N', T0 - 240], ['C1N', T0 - 60]]), stopped('t9', 'B1N', T0 - 240), T0);
    expect(t).toMatchObject({ speed: 0, bearing: 0 });
    expect(metersBetween(t!.lat, t!.lon, latAt(1000), LON)).toBeLessThan(0.5);
  });

  test('predicted stops get DWELL_SECONDS when the next run is long enough', () => {
    // Due at B1 DWELL_SECONDS - 1 s ago, then a long run to C1: still standing at B1.
    const stops: [string, number][] = [['B1N', T0 - (DWELL_SECONDS - 1)], ['C1N', T0 + 300]];
    expect(estimator.estimate(trip('t10', stops), stopped('t10', 'A1N', T0 - 400), T0)?.speed).toBe(0);
    stops[0][1] = T0 - (DWELL_SECONDS + 1);
    expect(estimator.estimate(trip('t10', stops), stopped('t10', 'A1N', T0 - 400), T0)?.speed).toBeGreaterThan(0);
  });
});

describe('TrainEstimator, trains it cannot place', () => {
  test('a trip that has not left its terminal: report in the future, IN_TRANSIT_TO', () => {
    const v: VehiclePosition = { trip: { tripId: 'n1' }, currentStatus: IN_TRANSIT_TO, stopId: 'A1N', timestamp: T0 + 300 };
    expect(estimator.estimate(trip('n1', [['A1N', T0 + 300], ['B1N', T0 + 500]]), v, T0)).toBeUndefined();
  });

  test('IN_TRANSIT_TO or INCOMING_AT a station: where it comes from is unknown (no scheduled approach)', () => {
    const v: VehiclePosition = { trip: { tripId: 'n2' }, currentStatus: IN_TRANSIT_TO, stopId: 'J1N', timestamp: T0 - 20 };
    expect(estimator.estimate(trip('n2', [['J1N', T0 + 30]]), v, T0)).toBeUndefined();
    const w: VehiclePosition = { trip: { tripId: 'n2' }, currentStatus: INCOMING_AT, stopId: 'A1N', timestamp: T0 - 20 };
    expect(estimator.estimate(trip('n2', [['A1N', T0 + 30]]), w, T0)).toBeUndefined();
  });

  test('in transit, but the station before it is ambiguous (trips come from two ways about equally often): not placed', () => {
    const v: VehiclePosition = { trip: { tripId: 'n9' }, currentStatus: IN_TRANSIT_TO, stopId: 'C1N', timestamp: T0 - 20 };
    expect(estimator.estimate(trip('n9', [['C1N', T0 + 30]]), v, T0)).toBeUndefined();
  });

  test('in transit, but there is no stored track from the station before it: not placed', () => {
    const v: VehiclePosition = { trip: { tripId: 'n10' }, currentStatus: IN_TRANSIT_TO, stopId: 'B1S', timestamp: T0 - 20 };
    expect(estimator.estimate(trip('n10', [['B1S', T0 + 30]]), v, T0)).toBeUndefined();
  });

  test('in transit to a station the trip update no longer (or not yet) predicts: nothing to place it by', () => {
    const v: VehiclePosition = { trip: { tripId: 'n11' }, currentStatus: IN_TRANSIT_TO, stopId: 'B1N', timestamp: T0 - 20 };
    expect(estimator.estimate(trip('n11', [['C1N', T0 + 130]]), v, T0)).toBeUndefined();
  });

  test('in transit with a report older than MAX_REPORT_AGE_SECONDS: not placed', () => {
    const v: VehiclePosition = { trip: { tripId: 'n12' }, currentStatus: IN_TRANSIT_TO, stopId: 'B1N', timestamp: T0 - MAX_REPORT_AGE_SECONDS - 1 };
    expect(estimator.estimate(trip('n12', [['B1N', T0 + 30]]), v, T0)).toBeUndefined();
  });

  test('no vehicle report, no stops left, or a report older than MAX_REPORT_AGE_SECONDS', () => {
    expect(estimator.estimate(trip('n3', [['B1N', T0 + 100]]), undefined, T0)).toBeUndefined();
    expect(estimator.estimate(trip('n4', []), stopped('n4', 'B1N', T0 - 7859), T0)).toBeUndefined();
    const old = T0 - MAX_REPORT_AGE_SECONDS - 1;
    expect(estimator.estimate(trip('n5', [['B1N', T0 + 100]]), stopped('n5', 'A1N', old), T0)).toBeUndefined();
  });

  test('a station pair with no stored track (entirely outside the area, or an unusual reroute)', () => {
    expect(estimator.estimate(trip('n6', [['Z9N', T0 + 100]]), stopped('n6', 'A1N', T0 - 100), T0)).toBeUndefined();
  });

  test('a trip without a route or trip ID', () => {
    const t = trip('n7', [['B1N', T0 + 100]]);
    delete t.trip.routeId;
    expect(estimator.estimate(t, stopped('n7', 'A1N', T0 - 100), T0)).toBeUndefined();
  });

  test('a report slightly in the future is clock skew, not a prediction', () => {
    const t = estimator.estimate(trip('n8', [['B1S', T0 + 5], ['A1S', T0 + 300]]), stopped('n8', 'B1S', T0 + 5), T0);
    expect(t?.speed).toBe(0);
  });
});

describe('TrainEstimator.estimateAll', () => {
  const feed = (timestamp: number, ...trips: [TripUpdate, VehiclePosition][]): FeedMessage => ({
    timestamp,
    entities: trips.flatMap(([tu, v], i) => [
      { id: `${i}`, tripUpdate: tu },
      { id: `${i}v`, vehicle: v },
    ]),
  });

  test('matches vehicles to trips by trip ID, across feeds, sorted by trip ID', () => {
    const a = feed(T0, [trip('b-trip', [['B1N', T0 + 100]]), stopped('b-trip', 'A1N', T0 - 100)]);
    const b = feed(
      T0 - 20,
      [trip('a-trip', [['A1S', T0 + 100]]), stopped('a-trip', 'B1S', T0 - 130)],
      [trip('c-trip', [['B1N', T0 + 100]]), stopped('someone-else', 'A1N', T0 - 100)],
    );
    expect(estimator.estimateAll([a, b], T0 * 1000).map((t) => t.tripId)).toEqual(['a-trip', 'b-trip']);
  });

  test('feeds older than MAX_FEED_AGE_SECONDS, or without a timestamp, are skipped', () => {
    const entry: [TripUpdate, VehiclePosition] = [trip('x', [['B1N', T0 + 100]]), stopped('x', 'A1N', T0 - 100)];
    expect(estimator.estimateAll([feed(T0 - MAX_FEED_AGE_SECONDS, entry)], T0 * 1000)).toHaveLength(1);
    expect(estimator.estimateAll([feed(T0 - MAX_FEED_AGE_SECONDS - 1, entry)], T0 * 1000)).toHaveLength(0);
    expect(estimator.estimateAll([{ entities: feed(T0, entry).entities }], T0 * 1000)).toHaveLength(0);
  });

  test('a trip whose estimate throws is skipped and reported; the other trips still come back', () => {
    const poisoned = trip('poison-trip', [['B1N', T0 + 100]]);
    Object.defineProperty(poisoned, 'stopTimeUpdates', {
      get() {
        throw new Error('odd MTA entity');
      },
    });
    const good = feed(
      T0,
      [trip('a-trip', [['A1S', T0 + 100]]), stopped('a-trip', 'B1S', T0 - 130)],
      [poisoned, stopped('poison-trip', 'A1N', T0 - 100)],
      [trip('b-trip', [['B1N', T0 + 100]]), stopped('b-trip', 'A1N', T0 - 100)],
    );
    const errors: [string, unknown][] = [];
    const trains = estimator.estimateAll([good], T0 * 1000, (tripId, err) => errors.push([tripId, err]));
    expect(trains.map((t) => t.tripId)).toEqual(['a-trip', 'b-trip']);
    expect(errors.map(([id]) => id)).toEqual(['poison-trip']);
    expect((errors[0][1] as Error).message).toBe('odd MTA entity');
    // Without onError, still no throw.
    expect(estimator.estimateAll([good], T0 * 1000).map((t) => t.tripId)).toEqual(['a-trip', 'b-trip']);
  });
});

describe('geo helpers', () => {
  test('bearings and distances', () => {
    expect(bearingBetween(40.7, -73.99, 40.71, -73.99)).toBe(0);
    expect(bearingBetween(40.7, -73.99, 40.7, -73.98)).toBeCloseTo(90, 1);
    expect(bearingBetween(40.71, -73.99, 40.7, -73.99)).toBe(180);
    expect(bearingBetween(40.7, -73.98, 40.7, -73.99)).toBeCloseTo(270, 1);
    expect(metersBetween(40.7, -73.99, latAt(1000), -73.99)).toBeCloseTo(1000, 0);
  });
});
