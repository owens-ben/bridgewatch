import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, test } from '@jest/globals';
import { BOUNDING_BOXES } from './config';
import { INCOMING_AT, IN_TRANSIT_TO, STOPPED_AT, type FeedMessage, type TripUpdate, type VehiclePosition } from './gtfsrt';
import { ProtoReader } from './protobuf';
import {
  bearingBetween,
  MAX_CLOCK_SKEW_SECONDS,
  MAX_FEED_AGE_SECONDS,
  MAX_REPORT_AGE_SECONDS,
  MIN_APPROACH_SHARE,
  metersBetween,
  TrainEstimator,
  type TrackPart,
  type TrainEstimate,
} from './subway';
import { SUBWAY_DATA } from './subway-data';
import { feedName, SUBWAY_FEED_ROUTES, SUBWAY_FEEDS } from './subway-feed';
import { expectedTargetsPath, generatedSubwayFixtures, subwayRounds, SUBWAY_FIXTURES_DIR, trainsFixture } from './subway-fixtures';
import { STRETCHES } from './tools/subway-extract';
import { expectIn, HEADER_AGE, ROUND_0, ROUND_COUNT, SCENARIO, STALE_FEEDS, tripAt, type ScenarioTrip } from './tools/subway-scenario';

const rounds = subwayRounds();
const estimates = rounds.map((r) => trainsFixture(r, SUBWAY_DATA));
const allTrains = estimates.flatMap((e) => e.trains);

const M_PER_DEG_LAT = 111_195;

/** Inside BOUNDING_BOXES; `slackDegrees` forgives the rounding of coordinates to 1e-6 degrees. */
function inArea(lat: number, lon: number, slackDegrees = 1e-9): boolean {
  return BOUNDING_BOXES.some(([[la1, lo1], [la2, lo2]]) =>
    lat >= Math.min(la1, la2) - slackDegrees && lat <= Math.max(la1, la2) + slackDegrees &&
    lon >= Math.min(lo1, lo2) - slackDegrees && lon <= Math.max(lo1, lo2) + slackDegrees,
  );
}

/** Meters from a point to the nearest part of the extract that `keep` accepts (equirectangular, fine at this scale). */
function metersToTrack(lat: number, lon: number, keep: (part: TrackPart, a: string, b: string) => boolean = () => true): number {
  let best = Infinity;
  const k = Math.cos((lat * Math.PI) / 180);
  for (const s of SUBWAY_DATA.segments) {
    for (const part of s.parts) {
      if (!keep(part, s.a, s.b)) continue;
      for (let i = 1; i < part.points.length; i++) {
        const [la1, lo1] = part.points[i - 1];
        const [la2, lo2] = part.points[i];
        const ax = (lo1 - lon) * k, ay = la1 - lat, bx = (lo2 - lon) * k, by = la2 - lat;
        const vx = bx - ax, vy = by - ay;
        const len2 = vx * vx + vy * vy;
        const t = len2 > 0 ? Math.min(Math.max(-(ax * vx + ay * vy) / len2, 0), 1) : 0;
        best = Math.min(best, Math.hypot(ax + t * vx, ay + t * vy) * M_PER_DEG_LAT);
      }
    }
  }
  return best;
}

/** The altitude of the track (parts `keep` accepts) at the point nearest to (lat, lon), interpolated along the part. */
function trackAltitudeAt(lat: number, lon: number, keep: (part: TrackPart, a: string, b: string) => boolean = () => true): number {
  let best = Infinity;
  let altitude = NaN;
  const k = Math.cos((lat * Math.PI) / 180);
  for (const s of SUBWAY_DATA.segments) {
    for (const part of s.parts) {
      if (!keep(part, s.a, s.b)) continue;
      for (let i = 1; i < part.points.length; i++) {
        const [la1, lo1, h1] = part.points[i - 1];
        const [la2, lo2, h2] = part.points[i];
        const ax = (lo1 - lon) * k, ay = la1 - lat, bx = (lo2 - lon) * k, by = la2 - lat;
        const vx = bx - ax, vy = by - ay;
        const len2 = vx * vx + vy * vy;
        const t = len2 > 0 ? Math.min(Math.max(-(ax * vx + ay * vy) / len2, 0), 1) : 0;
        const d = Math.hypot(ax + t * vx, ay + t * vy) * M_PER_DEG_LAT;
        if (d < best) {
          best = d;
          altitude = h1 + t * (h2 - h1);
        }
      }
    }
  }
  return altitude;
}

const polylineMeters = (points: TrackPart['points']) =>
  points.slice(1).reduce((n, p, i) => n + metersBetween(points[i][0], points[i][1], p[0], p[1]), 0);

const ROUTES_BY_STRETCH: Record<string, string[]> = {
  'manhattan-bridge': ['B', 'D', 'N', 'Q'],
  'williamsburg-bridge': ['J', 'M', 'Z'],
  'culver-viaduct': ['F', 'FX', 'G'],
  'franklin-av': ['FS'],
};

describe('the extract (subway-data.ts)', () => {
  test('has track for every route that runs through the area, and the three stretches', () => {
    expect(SUBWAY_DATA.routes).toEqual(
      expect.arrayContaining(['1', '2', '3', '4', '5', '6', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'J', 'L', 'M', 'N', 'Q', 'R', 'W', 'Z']),
    );
    expect(SUBWAY_DATA.stretches.map((s) => s.id).sort()).toEqual(STRETCHES.map((s) => s.id).sort());
  });

  test('every segment is a pair of stations once, with ordered parts that run from the stations along the track', () => {
    const pairs = SUBWAY_DATA.segments.map((s) => [s.a, s.b].sort().join('|'));
    expect(new Set(pairs).size).toBe(pairs.length);
    expect(SUBWAY_DATA.segments.length).toBeGreaterThan(80);
    for (const s of SUBWAY_DATA.segments) {
      expect(s.parts.length).toBeGreaterThan(0);
      s.parts.forEach((p, i) => {
        const where = `${s.a}-${s.b} part ${i}`;
        expect([where, p.from >= 0 && p.to <= s.length + 1 && p.to > p.from]).toEqual([where, true]);
        if (i > 0) expect([where, p.from >= s.parts[i - 1].to]).toEqual([where, true]);
        // The geometry is as long as the stretch of track it stands for (the parts' ends are rounded to meters).
        expect([where, Math.abs(polylineMeters(p.points) - (p.to - p.from)) <= 2 + 0.02 * (p.to - p.from)]).toEqual([where, true]);
        // Parts that touch share their end point.
        if (i > 0 && p.from === s.parts[i - 1].to) {
          const before = s.parts[i - 1].points.at(-1)!;
          expect(metersBetween(before[0], before[1], p.points[0][0], p.points[0][1])).toBeLessThan(0.5);
        }
      });
    }
  });

  test('underground track is clipped to BOUNDING_BOXES; the stretches are kept whole, also outside it', () => {
    for (const s of SUBWAY_DATA.segments) {
      for (const p of s.parts.filter((q) => q.underground)) {
        for (const [lat, lon] of p.points) expect([`${s.a}-${s.b}`, lat, lon, inArea(lat, lon)]).toEqual([`${s.a}-${s.b}`, lat, lon, true]);
      }
    }
    // Underground track that leaves the area is cut at its edge.
    const leaving = SUBWAY_DATA.segments.flatMap((s) => s.parts.filter((p) => p.underground && p.to < s.length - 100));
    expect(leaving.length).toBeGreaterThan(0);
    // The Culver Viaduct runs south of the area's edge (lat 40.675) to its crest at Smith-9 Sts and past 4 Av-9 St, and
    // all of it is there: Carroll St to Smith-9 Sts reaches the station, and the next two segments are viaduct.
    const toSmith9 = SUBWAY_DATA.segments.find((s) => s.a === 'F21' && s.b === 'F22')!;
    expect(toSmith9.parts.at(-1)).toMatchObject({ stretch: 'culver-viaduct', to: toSmith9.length });
    expect(toSmith9.parts.at(-1)!.points.at(-1)![0]).toBeLessThan(BOUNDING_BOXES[0][0][0]);
    for (const [a, b] of [['F22', 'F23'], ['F23', 'F24']]) {
      const s = SUBWAY_DATA.segments.find((x) => x.a === a && x.b === b)!;
      expect(s.parts.map((p) => [p.stretch, p.from])).toEqual([['culver-viaduct', 0]]);
    }
  });

  test('part by part: underground ones carry the modelled altitude (finite, sane), stretch ones keep their heights', () => {
    const parts = SUBWAY_DATA.segments.flatMap((s) => s.parts);
    expect(parts.filter((p) => p.underground).length).toBeGreaterThan(80);
    for (const p of parts) {
      if (p.underground) {
        expect(p.stretch).toBeUndefined();
        for (const point of p.points) {
          expect(point[2]).toBeGreaterThan(-45);
          expect(point[2]).toBeLessThan(35); // Grand Army Plaza: street at 36.7 m
        }
      } else {
        expect(SUBWAY_DATA.stretches.map((s) => s.id)).toContain(p.stretch);
      }
    }
    for (const def of STRETCHES) {
      const mine = parts.filter((p) => p.stretch === def.id);
      expect(mine.length).toBeGreaterThan(0);
      const heights = def.heights.map((h) => h[2]);
      for (const point of mine.flatMap((p) => p.points)) {
        expect(point[2]).toBeGreaterThanOrEqual(Math.min(...heights) - 0.1);
        expect(point[2]).toBeLessThanOrEqual(Math.max(...heights) + 0.1);
      }
      // Every control point is a vertex of the track (heights are read at the track, up to 15 m to either side of it)
      // with its height; the stretches are whole, so outside the area too.
      for (const [lat, lon, height] of def.heights) {
        const near = mine
          .flatMap((p) => p.points)
          .filter((q) => metersBetween(lat, lon, q[0], q[1]) < 25)
          .map((q) => Math.abs(q[2] - height));
        expect([def.id, lat, lon, near.length > 0 && Math.min(...near) < 0.5]).toEqual([def.id, lat, lon, true]);
      }
    }
    // The bridges' crests, by their known figures.
    const crest = (id: string) => Math.max(...parts.filter((p) => p.stretch === id).flatMap((p) => p.points.map((q) => q[2])));
    expect(crest('manhattan-bridge')).toBeCloseTo(44.8, 0);
    expect(crest('williamsburg-bridge')).toBeCloseTo(44.3, 0);
    expect(crest('culver-viaduct')).toBeCloseTo(29.7, 0); // Smith-9 Sts
  });

  test('East Broadway to York St (F16-F18, the Rutgers St tunnel under the East River) is one underground part', () => {
    const s = SUBWAY_DATA.segments.find((x) => x.a === 'F16' && x.b === 'F18')!;
    expect(s.length).toBeGreaterThan(1300);
    expect(s.length).toBeLessThan(1600);
    expect(s.parts).toHaveLength(1);
    expect(s.parts[0]).toMatchObject({ underground: true, from: 0, to: s.length, altitudeEstimated: true });
    // From East Broadway (40.7137, -73.9902) to York St (40.7014, -73.9868), out under the river.
    const lats = s.parts[0].points.map((p) => p[0]);
    expect(Math.max(...lats)).toBeCloseTo(40.7137, 3);
    expect(Math.min(...lats)).toBeCloseTo(40.7014, 3);
    const mid = s.parts[0].points.find((p) => p[0] < 40.7075)!;
    expect(mid[1]).toBeGreaterThan(-73.9905);
    expect(mid[1]).toBeLessThan(-73.9865);
  });
});

describe('an F train in the East River tunnel, from synthetic feed entries', () => {
  const estimator = new TrainEstimator(SUBWAY_DATA);
  const T0 = Date.parse('2026-11-11T02:52:39Z') / 1000;
  const trip = (tripId: string, stops: [string, number][]): TripUpdate => ({
    trip: { tripId, routeId: 'F' },
    stopTimeUpdates: stops.map(([stopId, t]) => ({ stopId, arrival: t, departure: t })),
  });
  const stopped = (tripId: string, stopId: string, timestamp: number): VehiclePosition => ({
    trip: { tripId },
    currentStatus: STOPPED_AT,
    stopId,
    timestamp,
  });
  const inTunnel = (a: string, b: string) => (part: TrackPart, sa: string, sb: string) => part.underground && [sa, sb].sort().join() === [a, b].sort().join();

  test('Brooklyn-bound: left East Broadway (F16S) 60 s ago, due at York St (F18S) in 80 s', () => {
    const t = estimator.estimate(trip('f-south', [['F18S', T0 + 80], ['A41S', T0 + 200]]), stopped('f-south', 'F16S', T0 - 60), T0);
    expect(t).toMatchObject({ route: 'F', direction: 'S', underground: true, altitudeEstimated: true });
    expect(t).not.toHaveProperty('stretch');
    // 60/140 of the 1.4 km tunnel from East Broadway, heading south-south-east (Brooklyn).
    const s = SUBWAY_DATA.segments.find((x) => x.a === 'F16' && x.b === 'F18')!;
    expect(metersBetween(t!.lat, t!.lon, 40.713715, -73.990173)).toBeGreaterThan(0.4 * s.length);
    expect(metersBetween(t!.lat, t!.lon, 40.713715, -73.990173)).toBeLessThan((60 / 140) * s.length + 1);
    expect(t!.lat).toBeLessThan(40.7137);
    expect(t!.lat).toBeGreaterThan(40.7014);
    expect(metersToTrack(t!.lat, t!.lon, inTunnel('F16', 'F18'))).toBeLessThan(1);
    expect(Math.abs(((t!.bearing - 170 + 540) % 360) - 180)).toBeLessThan(25);
    expect(t!.speed).toBeCloseTo((s.length / 140) * (3600 / 1852), 1);
  });

  test('Manhattan-bound: left York St (F18N) 30 s ago, due at East Broadway (F16N) in 90 s', () => {
    const t = estimator.estimate(trip('f-north', [['F16N', T0 + 90], ['F15N', T0 + 160]]), stopped('f-north', 'F18N', T0 - 30), T0);
    expect(t).toMatchObject({ route: 'F', direction: 'N', underground: true, altitudeEstimated: true });
    expect(metersToTrack(t!.lat, t!.lon, inTunnel('F16', 'F18'))).toBeLessThan(1);
    expect(Math.abs(((t!.bearing - 350 + 540) % 360) - 180)).toBeLessThan(25);
  });

  const inTransit = (tripId: string, stopId: string, timestamp: number): VehiclePosition => ({
    trip: { tripId },
    currentStatus: IN_TRANSIT_TO,
    stopId,
    timestamp,
  });

  test('Brooklyn-bound, reported in transit to York St (F18S): placed by the scheduled East Broadway run time', () => {
    const [approach] = SUBWAY_DATA.approaches['F|S|F18'];
    expect(approach.from).toBe('F16');
    expect(approach.seconds).toBeGreaterThan(60);
    // Due at York St in 80 s, reported 10 s ago: left (run time - 80) s ago, (run time - 80) / run time of the tunnel.
    const t = estimator.estimate(trip('f-transit', [['F18S', T0 + 80], ['A41S', T0 + 200]]), inTransit('f-transit', 'F18S', T0 - 10), T0);
    const s = SUBWAY_DATA.segments.find((x) => x.a === 'F16' && x.b === 'F18')!;
    const along = (1 - 80 / approach.seconds) * s.length;
    expect(t).toMatchObject({ route: 'F', direction: 'S', underground: true, altitudeEstimated: true });
    expect(t).not.toHaveProperty('stretch');
    // The tunnel bends a little: the straight line from East Broadway is a bit shorter than the track.
    expect(metersBetween(t!.lat, t!.lon, 40.713715, -73.990173)).toBeGreaterThan(0.95 * along);
    expect(metersBetween(t!.lat, t!.lon, 40.713715, -73.990173)).toBeLessThan(along + 1);
    expect(metersToTrack(t!.lat, t!.lon, inTunnel('F16', 'F18'))).toBeLessThan(1);
    expect(Math.abs(((t!.bearing - 165 + 540) % 360) - 180)).toBeLessThan(30);
    expect(t!.speed).toBeGreaterThan(0);
  });

  test('standing at either end of the tunnel: placed at the station, underground', () => {
    const at = estimator.estimate(trip('f-stand', [['F16S', T0 - 5], ['F18S', T0 + 140]]), stopped('f-stand', 'F16S', T0 - 5), T0);
    expect(at).toMatchObject({ speed: 0, underground: true, altitudeEstimated: true });
    expect(metersBetween(at!.lat, at!.lon, 40.713715, -73.990173)).toBeLessThan(40);
  });
});

describe('the modelled altitude of a train in the Rutgers St tunnel (F16-F18)', () => {
  const estimator = new TrainEstimator(SUBWAY_DATA);
  const T0 = Date.parse('2026-11-11T02:52:39Z') / 1000;
  const segment = SUBWAY_DATA.segments.find((x) => x.a === 'F16' && x.b === 'F18')!;
  const pointsAlt = segment.parts[0].points.map((q) => q[2]);

  test('mid-tunnel it is the tube\'s low part, far below both stations; at either end the station\'s own altitude', () => {
    const trip = { trip: { tripId: 'f-mid', routeId: 'F' }, stopTimeUpdates: [{ stopId: 'F18S', arrival: T0 + 70, departure: T0 + 70 }] };
    const vehicle: VehiclePosition = { trip: { tripId: 'f-mid' }, currentStatus: STOPPED_AT, stopId: 'F16S', timestamp: T0 - 70 };
    const mid = estimator.estimate(trip, vehicle, T0)!;
    expect(mid).toMatchObject({ underground: true, altitudeEstimated: true });
    expect(mid.altitude).toBeCloseTo(trackAltitudeAt(mid.lat, mid.lon, (p, a, b) => p.underground && a === 'F16' && b === 'F18'), 1);
    expect(mid.altitude).toBeLessThan(Math.max(...pointsAlt) - 15);
    expect(mid.altitude).toBeGreaterThan(Math.min(...pointsAlt) - 0.2);
    const lowPoint = Math.min(...pointsAlt);
    expect(lowPoint).toBeLessThan(-20);
    expect(lowPoint).toBeGreaterThan(-35);
    // Standing at York St (the published 24 m below the street).
    const york = estimator.estimate(
      { trip: { tripId: 'f-york', routeId: 'F' }, stopTimeUpdates: [{ stopId: 'F18S', arrival: T0 + 20, departure: T0 + 20 }, { stopId: 'A41S', arrival: T0 + 140, departure: T0 + 140 }] },
      { trip: { tripId: 'f-york' }, currentStatus: STOPPED_AT, stopId: 'F18S', timestamp: T0 },
      T0,
    )!;
    expect(york.speed).toBe(0);
    expect(york.altitude).toBeCloseTo(pointsAlt.at(-1)!, 1);
  });
});


// ------------------------------------------------------------------------------------------- the synthetic feeds

const stationOf = (stopId: string) => stopId.replace(/[NS]$/, '');
const epoch = (relative: number) => ROUND_0 + relative;
const tripsOf = (feed: FeedMessage) => feed.entities.flatMap((e) => (e.tripUpdate ? [e.tripUpdate] : []));
const vehiclesOf = (feed: FeedMessage) => feed.entities.flatMap((e) => (e.vehicle ? [e.vehicle] : []));
const allFeeds = (r: number) => [...rounds[r].feeds.values()];
const placedIn = (r: number) => SCENARIO.filter((trip) => expectIn(trip, r) !== 'none');
const trainFor = (trip: ScenarioTrip, r: number): TrainEstimate | undefined => estimates[r].trains.find((t) => t.tripId === trip.id);

/** The approach the estimator should use for a train reported on its way to `stopId` (shape first, then route). */
function approachFor(trip: ScenarioTrip, stopId: string) {
  const shape = trip.id!.slice(trip.id!.indexOf('_') + 1);
  for (const key of [`${shape}|${stationOf(stopId)}`, `${trip.route}|${stopId.slice(-1)}|${stationOf(stopId)}`]) {
    const list = SUBWAY_DATA.approaches[key];
    if (!list?.length) continue;
    const total = list.reduce((n, a) => n + a.trips, 0);
    return list[0].trips >= MIN_APPROACH_SHARE * total ? list[0] : undefined;
  }
  return undefined;
}

/**
 * Where a train in motion should be, from the scenario's own numbers and nothing the estimator computes: the two
 * stations it is between and how far along the track (0 at `from`, 1 at `to`). A train that left its station is that
 * far along as the time since its report is of the time from the report to the predicted arrival; one reported on its
 * way to a station left the station before about `approach.seconds` before its predicted arrival (no later than the
 * report).
 */
function expectedLeg(trip: ScenarioTrip, r: number): { from: string; to: string; fraction: number } | undefined {
  const { at, stops, shift } = tripAt(trip, r);
  if (!Array.isArray(at)) return undefined;
  const [stop, status, ts] = at;
  const now = epoch(30 * r);
  const reportedAt = Math.min(epoch(ts + shift), now);
  const listed = stops.findIndex((s) => stationOf(s.stopId) === stationOf(stop));
  if (status === 'stopped') {
    const next = stops[listed + 1] ?? stops[0];
    if (listed >= 0 || next?.arrival == null) return undefined;
    const arrival = epoch(next.arrival + shift);
    return { from: stationOf(stop), to: stationOf(next.stopId), fraction: (now - reportedAt) / (arrival - reportedAt) };
  }
  const approach = approachFor(trip, stop);
  if (!approach || listed < 0 || stops[listed].arrival == null) return undefined;
  const arrival = epoch(stops[listed].arrival! + shift);
  const departure = Math.min(arrival - approach.seconds, reportedAt);
  return { from: approach.from, to: stationOf(stop), fraction: (now - departure) / (arrival - departure) };
}

/** How far along the segment's track (meters from its first station) the point nearest to (lat, lon) is. */
function alongSegment(lat: number, lon: number, a: string, b: string): number {
  const segment = SUBWAY_DATA.segments.find((s) => (s.a === a && s.b === b) || (s.a === b && s.b === a))!;
  const k = Math.cos((lat * Math.PI) / 180);
  let best = Infinity;
  let along = NaN;
  for (const part of segment.parts) {
    const total = polylineMeters(part.points);
    let walked = 0;
    for (let i = 1; i < part.points.length; i++) {
      const [la1, lo1] = part.points[i - 1];
      const [la2, lo2] = part.points[i];
      const ax = (lo1 - lon) * k, ay = la1 - lat, bx = (lo2 - lon) * k, by = la2 - lat;
      const vx = bx - ax, vy = by - ay;
      const len2 = vx * vx + vy * vy;
      const t = len2 > 0 ? Math.min(Math.max(-(ax * vx + ay * vy) / len2, 0), 1) : 0;
      const d = Math.hypot(ax + t * vx, ay + t * vy) * M_PER_DEG_LAT;
      const legMeters = metersBetween(la1, lo1, la2, lo2);
      if (d < best) {
        best = d;
        // The estimator spreads the part's span over the polyline's length.
        along = part.from + ((walked + t * legMeters) / total) * (part.to - part.from);
      }
      walked += legMeters;
    }
  }
  return segment.a === a ? along : segment.length - along;
}

describe('synthetic MTA feeds (fixtures/subway)', () => {
  const fixtures = generatedSubwayFixtures(SUBWAY_DATA);

  test('the committed files are exactly what the scenario generates (run `npm run fixtures`)', () => {
    expect(fs.readdirSync(SUBWAY_FIXTURES_DIR).sort()).toEqual([...fixtures.keys()].sort());
    for (const [name, content] of fixtures) {
      const committed = fs.readFileSync(path.join(SUBWAY_FIXTURES_DIR, name));
      if (!Buffer.from(content).equals(committed)) {
        throw new Error(`${name} is out of date with tools/subway-scenario.ts. Run \`npm run fixtures\` and commit the result.`);
      }
    }
  });

  test('three rounds of every subway feed, 30 s apart, decoded with NYCT extensions skipped', () => {
    expect(rounds).toHaveLength(ROUND_COUNT);
    const names = SUBWAY_FEEDS.map(feedName).sort();
    expect(names).toEqual(['ace', 'bdfm', 'g', 'jz', 'l', 'nqrw', 'numbered']);
    for (const r of rounds) {
      expect([...r.feeds.keys()].sort()).toEqual(names);
      for (const feed of r.feeds.values()) {
        expect(r.at / 1000 - feed.timestamp!).toBeLessThan(MAX_FEED_AGE_SECONDS + 30);
        expect(feed.entities.filter((e) => e.tripUpdate).length).toBeGreaterThan(2);
        for (const e of feed.entities) {
          if (e.tripUpdate?.trip.routeId) expect(e.tripUpdate.trip.routeId).toMatch(/^[A-Z0-9]+$/);
        }
      }
    }
    expect(rounds.map((r) => r.at / 1000)).toEqual([0, 1, 2].map((i) => ROUND_0 + 30 * i));
    // The round's clock is its newest header (a feed is refreshed at its own moment, so the others are a little older).
    for (const [i, r] of rounds.entries()) {
      const ages = [...r.feeds.entries()].map(([name, f]) => [name, r.at / 1000 - f.timestamp!] as const);
      expect(Math.min(...ages.map((a) => a[1]))).toBe(0);
      expect(new Set(ages.map((a) => a[1])).size).toBeGreaterThan(2);
      for (const [name, age] of ages) expect([i, name, age]).toEqual([i, name, HEADER_AGE[name][i]]);
    }
  });

  test('each feed only carries the routes SUBWAY_FEED_ROUTES says it does', () => {
    for (const r of rounds) {
      for (const feed of SUBWAY_FEEDS) {
        const message = r.feeds.get(feedName(feed))!;
        const routes = new Set(message.entities.flatMap((e) => (e.tripUpdate?.trip.routeId ? [e.tripUpdate.trip.routeId] : [])));
        expect([feed, [...routes].filter((x) => !SUBWAY_FEED_ROUTES[feed].includes(x))]).toEqual([feed, []]);
      }
    }
  });

  test('the feeds carry NYCT extension fields (1001) on the header, trip descriptors and stop time updates, so skipping them is exercised', () => {
    /** Counts field 1001 inside a message, at the depth a path of field numbers names. */
    const count = (bytes: Uint8Array, path: number[]): number => {
      const reader = new ProtoReader(bytes);
      let n = 0;
      while (!reader.done) {
        const t = reader.tag();
        if (t.wire === 2 && path.length > 0 && t.field === path[0]) n += count(reader.bytes(), path.slice(1));
        else if (t.wire === 2 && path.length === 0 && t.field === 1001) {
          reader.bytes();
          n++;
        } else reader.skip(t.wire, t.field);
      }
      return n;
    };
    for (const r of rounds) {
      for (const name of r.feeds.keys()) {
        const bytes = fixtures.get(`${r.stamp}-${name}.pb`) as Uint8Array;
        expect([name, count(bytes, [1])]).toEqual([name, 1]);
        expect([name, count(bytes, [2, 3, 1]) > 2]).toEqual([name, true]);
        expect([name, count(bytes, [2, 3, 2]) > 5]).toEqual([name, true]);
      }
    }
    const top = new ProtoReader(fixtures.get(`${rounds[0].stamp}-numbered.pb`) as Uint8Array);
    expect(top.tag().field).toBe(1); // FeedHeader comes first
    const header = top.message();
    const fields: number[] = [];
    while (!header.done) {
      const t = header.tag();
      fields.push(t.field);
      header.skip(t.wire, t.field);
    }
    expect(fields).toContain(1001);
  });

  /** The odd and edge cases of real feeds, each there on purpose; the scenario's `why` says what each one is for. */
  test('the scenario covers the properties the recordings had, and the edge cases they only had by luck', () => {
    const feeds = allFeeds(0);
    const trips = feeds.flatMap(tripsOf);
    const vehicles = feeds.flatMap(vehiclesOf);
    const stops = trips.flatMap((t) => t.stopTimeUpdates);
    // Vehicle statuses, and a report either at a stop that is listed or at one that is not.
    expect(new Set(vehicles.map((v) => v.currentStatus))).toEqual(new Set([INCOMING_AT, STOPPED_AT, IN_TRANSIT_TO]));
    // Stop time updates: both times, arrival only, departure only, a dwell, and no time at all.
    expect(stops.some((s) => s.arrival !== undefined && s.departure !== undefined && s.arrival === s.departure)).toBe(true);
    expect(stops.some((s) => s.arrival !== undefined && s.departure !== undefined && s.departure > s.arrival)).toBe(true);
    expect(stops.some((s) => s.arrival !== undefined && s.departure === undefined)).toBe(true);
    expect(stops.some((s) => s.arrival === undefined && s.departure !== undefined)).toBe(true);
    expect(stops.some((s) => s.arrival === undefined && s.departure === undefined && s.stopId)).toBe(true);
    expect(stops.some((s) => s.stopId === undefined)).toBe(true);
    // Trips: with and without a vehicle, with no route ID, no trip ID, a vehicle that names no trip, an orphan vehicle,
    // a deleted entity, other entities (alerts), a trip ID without a shape suffix and an express one, a route whose
    // trip ID carries another route's shape (a W as an N), and the short trips (one, two, three and four stops).
    const vehicleIds = new Set(vehicles.map((v) => v.trip.tripId));
    expect(trips.some((t) => t.trip.tripId && !vehicleIds.has(t.trip.tripId))).toBe(true);
    expect(trips.some((t) => t.trip.routeId === undefined)).toBe(true);
    expect(trips.some((t) => t.trip.tripId === undefined)).toBe(true);
    expect(vehicles.some((v) => v.trip.tripId === undefined)).toBe(true);
    const tripIds = new Set(trips.map((t) => t.trip.tripId));
    expect(vehicles.some((v) => v.trip.tripId && !tripIds.has(v.trip.tripId))).toBe(true);
    expect(trips.some((t) => /^\d+_[A-Z0-9]+\.\.[NS]$/.test(t.trip.tripId ?? ''))).toBe(true);
    expect(trips.some((t) => /X\d+$/.test(t.trip.tripId ?? ''))).toBe(true);
    expect(trips.some((t) => t.trip.routeId === 'W' && t.trip.tripId?.includes('_N..'))).toBe(true);
    for (const n of [1, 2, 3, 4]) expect(trips.some((t) => t.stopTimeUpdates.length === n)).toBe(true);
    expect(feeds.some((f) => f.entities.some((e) => !e.tripUpdate && !e.vehicle))).toBe(true);
    expect(SCENARIO.some((t) => t.odd?.deleted)).toBe(true);
    // Vehicle report times: past the report age limit, in the future (not started), standing with an arrival still ahead.
    const clock = ROUND_0;
    expect(vehicles.some((v) => v.timestamp !== undefined && clock - v.timestamp > MAX_REPORT_AGE_SECONDS)).toBe(true);
    expect(vehicles.some((v) => v.timestamp !== undefined && v.timestamp - clock > MAX_CLOCK_SKEW_SECONDS)).toBe(true);
    expect(vehicles.some((v) => v.timestamp === undefined)).toBe(true);
    expect(vehicles.some((v) => v.stopId === undefined)).toBe(true);
    expect(vehicles.some((v) => v.currentStatus === STOPPED_AT && trips.some((t) => t.trip.tripId === v.trip.tripId && t.stopTimeUpdates.some((s) => stationOf(s.stopId ?? '') === stationOf(v.stopId ?? '') && (s.arrival ?? 0) > clock)))).toBe(true);
    // Stops with no direction letter, stations outside the extract, a route with no track in the extract.
    expect(stops.some((s) => s.stopId && !/[NS]$/.test(s.stopId))).toBe(true);
    expect(trips.some((t) => !SUBWAY_DATA.routes.includes(t.trip.routeId ?? ''))).toBe(true);
    // A feed too old to use in one round, and the same feed fine in the next.
    expect(rounds[1].at / 1000 - rounds[1].feeds.get('jz')!.timestamp!).toBeGreaterThan(MAX_FEED_AGE_SECONDS);
    expect(rounds[2].at / 1000 - rounds[2].feeds.get('jz')!.timestamp!).toBeLessThan(MAX_FEED_AGE_SECONDS);
    // Every route of the extract has a train somewhere in the scenario that is placed.
    const placedRoutes = new Set(SCENARIO.filter((t) => [0, 1, 2].some((r) => expectIn(t, r) !== 'none')).map((t) => t.route));
    for (const route of ['1', '2', '3', '4', '5', '6', 'A', 'B', 'C', 'D', 'E', 'F', 'FS', 'G', 'J', 'L', 'M', 'N', 'Q', 'R', 'W', 'Z']) {
      expect([route, placedRoutes.has(route)]).toEqual([route, true]);
    }
    // Every stretch has a train on it, and the bridges' trains are there in both directions.
    for (const stretch of Object.keys(ROUTES_BY_STRETCH)) expect(SCENARIO.some((t) => expectIn(t, 2) === stretch || expectIn(t, 0) === stretch)).toBe(true);
    const onBridge = SCENARIO.filter((t) => expectIn(t, 0) === 'manhattan-bridge');
    expect(onBridge.some((t) => t.stops.startsWith('D22N') || t.stops.endsWith('N'))).toBe(true);
    expect(onBridge.some((t) => t.id!.includes('..S'))).toBe(true);
    // A train that moves from underground onto a stretch, and one from a stretch back underground, between rounds.
    expect(SCENARIO.some((t) => expectIn(t, 0) === 'ug' && expectIn(t, 2) === 'manhattan-bridge')).toBe(true);
    expect(SCENARIO.some((t) => expectIn(t, 0) === 'manhattan-bridge' && expectIn(t, 2) === 'ug')).toBe(true);
  });
});

describe('trains estimated from the synthetic feeds', () => {
  const ugCount = (r: number) => placedIn(r).filter((t) => expectIn(t, r) === 'ug').length;

  test('every trip is placed as its scenario entry says, in every round, and nothing else is placed', () => {
    for (const r of rounds.keys()) {
      for (const trip of SCENARIO) {
        const train = trainFor(trip, r);
        const got = train === undefined ? 'none' : train.underground ? 'ug' : train.stretch;
        expect([r, trip.id, trip.why, got]).toEqual([r, trip.id, trip.why, expectIn(trip, r)]);
      }
      expect(estimates[r].trains).toHaveLength(placedIn(r).length);
      expect(new Set(estimates[r].trains.map((t) => t.tripId)).size).toBe(placedIn(r).length);
    }
  });

  test('counts per round follow from the scenario: underground, above ground, and on each stretch', () => {
    const counts = rounds.map((_, r) => ({
      total: placedIn(r).length,
      below: ugCount(r),
      above: placedIn(r).length - ugCount(r),
      byStretch: Object.fromEntries(Object.keys(ROUTES_BY_STRETCH).map((s) => [s, placedIn(r).filter((t) => expectIn(t, r) === s).length])),
    }));
    rounds.forEach((_, r) => {
      const trains = estimates[r].trains;
      expect(trains.length).toBe(counts[r].total);
      expect(trains.filter((t) => t.underground).length).toBe(counts[r].below);
      expect(trains.filter((t) => !t.underground).length).toBe(counts[r].above);
      for (const [stretch, n] of Object.entries(counts[r].byStretch)) expect([r, stretch, trains.filter((t) => t.stretch === stretch).length]).toEqual([r, stretch, n]);
    });
    // The committed /v2 snapshot holds the last round's trains (and Swift's RelayFixtureTests pins these numbers).
    const targets = JSON.parse(fs.readFileSync(expectedTargetsPath(rounds[2].stamp), 'utf8')).targets;
    expect(targets).toHaveLength(counts[2].total);
  });

  test('trains are placed above ground and underground, on many routes', () => {
    const allTrains = estimates.flatMap((e) => e.trains);
    expect(allTrains.length).toBeGreaterThan(100);
    expect(allTrains.filter((t) => !t.underground).length).toBeGreaterThan(3);
    expect(allTrains.filter((t) => t.underground).length).toBeGreaterThan(50);
    expect(new Set(allTrains.map((t) => t.route)).size).toBeGreaterThanOrEqual(12);
    // Every feed has trains in the area, except the one that was too old in round 1.
    for (const [i, round] of rounds.entries()) {
      for (const name of round.feeds.keys()) {
        const routes = new Set(SUBWAY_FEEDS.filter((f) => feedName(f) === name).flatMap((f) => SUBWAY_FEED_ROUTES[f]));
        const expected = !STALE_FEEDS[i]?.includes(name);
        expect([round.stamp, name, estimates[i].trains.some((t) => routes.has(t.route))]).toEqual([round.stamp, name, expected]);
      }
    }
  });

  test('every train is on the extract\'s track, inside BOUNDING_BOXES unless on a stretch, with sane values', () => {
    for (const t of estimates.flatMap((e) => e.trains)) {
      const placedOk = inArea(t.lat, t.lon) || t.stretch !== undefined;
      expect([t.tripId, t.lat, t.lon, placedOk]).toEqual([t.tripId, t.lat, t.lon, true]);
      expect(metersToTrack(t.lat, t.lon)).toBeLessThan(2);
      expect(SUBWAY_DATA.routes).toContain(t.route);
      expect(['N', 'S']).toContain(t.direction);
      expect(t.speed).toBeGreaterThanOrEqual(0);
      expect(t.speed).toBeLessThan(45);
      expect(t.bearing).toBeGreaterThanOrEqual(0);
      expect(t.bearing).toBeLessThan(360);
    }
  });

  test('underground trains: no stretch, a modelled altitude in range. Above ground: a stretch of their route, its heights', () => {
    for (const t of estimates.flatMap((e) => e.trains)) {
      if (t.underground) {
        expect(t.stretch).toBeUndefined();
        expect(t.altitude).toBeGreaterThan(-45);
        expect(t.altitude).toBeLessThan(35);
        expect(metersToTrack(t.lat, t.lon, (p) => p.underground)).toBeLessThan(2);
      } else {
        expect(ROUTES_BY_STRETCH[t.stretch!]).toContain(t.route);
        expect(metersToTrack(t.lat, t.lon, (p) => p.stretch === t.stretch)).toBeLessThan(2);
        const heights = STRETCHES.find((s) => s.id === t.stretch)!.heights.map((h) => h[2]);
        expect(t.altitude).toBeGreaterThanOrEqual(Math.min(...heights) - 0.1);
        expect(t.altitude).toBeLessThanOrEqual(Math.max(...heights) + 0.1);
        expect(t.altitudeEstimated).toBe(STRETCHES.find((s) => s.id === t.stretch)!.heightsEstimated ?? false);
      }
    }
  });

  test('trains in motion are as far along the track as the scenario\'s times say; trains standing at a station do not move', () => {
    let legs = 0;
    for (const r of rounds.keys()) {
      for (const trip of SCENARIO.filter((x) => x.track && expectIn(x, r) !== 'none')) {
        const train = trainFor(trip, r)!;
        const leg = expectedLeg(trip, r);
        expect([r, trip.id, 'leg known', leg !== undefined]).toEqual([r, trip.id, 'leg known', true]);
        const segment = SUBWAY_DATA.segments.find((s) => [s.a, s.b].sort().join() === [leg!.from, leg!.to].sort().join())!;
        // Past the end of its leg (it stands its dwell, then runs on) the scenario's times say no more than `expect`.
        if (leg!.fraction >= 1) continue;
        // Meters from the leg's first station, measured on the track from where the train is.
        const measured = alongSegment(train.lat, train.lon, leg!.from, leg!.to);
        const wanted = leg!.fraction * segment.length;
        expect([r, trip.id, Math.abs(measured - wanted) <= 5 + 0.03 * segment.length, Math.round(measured), Math.round(wanted)]).toEqual([
          r, trip.id, true, Math.round(measured), Math.round(wanted),
        ]);
        expect(train.speed).toBeGreaterThan(0);
        legs++;
      }
      // Standing trains (their times shift with the clock): speed 0, and the same place in every round.
      for (const trip of SCENARIO.filter((x) => x.hold && expectIn(x, r) !== 'none')) {
        const train = trainFor(trip, r)!;
        const first = trainFor(trip, 0)!;
        expect([r, trip.id, train.speed, train.lat, train.lon]).toEqual([r, trip.id, 0, first.lat, first.lon]);
      }
    }
    expect(legs).toBeGreaterThan(60);
  });

  // Trains reported IN_TRANSIT_TO or INCOMING_AT a station are placed from the schedule's approach to it. (The F tests
  // above cover the East River tunnel one by one.)
  test('trains reported in transit to a station are placed too, from the approach; without the approaches they are not', () => {
    const inTransit = (r: number) => SCENARIO.filter((t) => Array.isArray(t.at) && t.at[1] !== 'stopped' && expectIn(t, r) !== 'none');
    for (const i of rounds.keys()) {
      expect([rounds[i].stamp, inTransit(i).length >= 8]).toEqual([rounds[i].stamp, true]);
      // Moving while the predicted arrival is ahead; it may be standing at the station once the clock passes it.
      for (const trip of inTransit(i)) {
        const { at, stops, shift } = tripAt(trip, i);
        const arrival = epoch(stops.find((s) => stationOf(s.stopId) === stationOf((at as string[])[0]))!.arrival! + shift);
        if (epoch(30 * i) < arrival) expect([trip.id, trainFor(trip, i)!.speed > 0]).toEqual([trip.id, true]);
      }
      // Without the schedule's approaches they are all unplaced: nothing else changes.
      const without = new TrainEstimator({ ...SUBWAY_DATA, approaches: {} }).estimateAll(rounds[i].feeds.values(), rounds[i].at);
      expect([rounds[i].stamp, without.length]).toEqual([rounds[i].stamp, estimates[i].trains.length - inTransit(i).length]);
    }
    // Both statuses are covered, and the app gets them as trains like any other.
    expect(SCENARIO.some((t) => Array.isArray(t.at) && t.at[1] === 'transit' && expectIn(t, 0) === 'ug')).toBe(true);
    expect(SCENARIO.some((t) => Array.isArray(t.at) && t.at[1] === 'incoming' && expectIn(t, 0) === 'ug')).toBe(true);
    const trip = inTransit(0)[0];
    const train = trainFor(trip, 0)!;
    const target = JSON.parse(fs.readFileSync(expectedTargetsPath(rounds[0].stamp), 'utf8')).targets.find(
      (x: { id: string }) => x.id === `train:nyct:${train.tripId}`,
    );
    expect(target).toMatchObject({ kind: 'train', train: { route: train.route, direction: train.direction, underground: train.underground } });
  });

  test('a train in transit moves with its predicted arrival: revising the prediction moves it by the time revised', () => {
    // The same trip reported twice, 30 s apart, with the arrival 20 s later in the second: it has gone 10 s of the way.
    const estimator = new TrainEstimator(SUBWAY_DATA);
    const feed = (arrival: number): FeedMessage => ({
      timestamp: ROUND_0,
      entities: [
        { id: '1', tripUpdate: { trip: { tripId: 'x_F..S54R', routeId: 'F' }, stopTimeUpdates: [{ stopId: 'F18S', arrival, departure: arrival }, { stopId: 'A41S', arrival: arrival + 120 }] } },
        { id: '2', vehicle: { trip: { tripId: 'x_F..S54R' }, currentStatus: IN_TRANSIT_TO, stopId: 'F18S', timestamp: ROUND_0 - 10 } },
      ],
    });
    const seconds = approachFor({ ...SCENARIO[0], id: 'x_F..S54R', route: 'F' }, 'F18S')!.seconds;
    const before = estimator.estimateAll([feed(ROUND_0 + 80)], ROUND_0 * 1000)[0];
    const later = estimator.estimateAll([{ ...feed(ROUND_0 + 100), timestamp: ROUND_0 + 30 }], (ROUND_0 + 30) * 1000)[0];
    const along = (t: TrainEstimate) => alongSegment(t.lat, t.lon, 'F16', 'F18');
    const segment = SUBWAY_DATA.segments.find((s) => s.a === 'F16' && s.b === 'F18')!;
    // Fractions of the run: (seconds - 80) / seconds, then (seconds + 30 - 100) / seconds.
    expect(along(before)).toBeCloseTo(((seconds - 80) / seconds) * segment.length, -1);
    expect(along(later)).toBeCloseTo(((seconds + 30 - 100) / seconds) * segment.length, -1);
  });

  // The scenario revises no prediction, so a train in motion covers its speed times the time between rounds; on a
  // bend in a tunnel the track can turn between two placements, so its direction is judged against the bearing at
  // either end of the move.
  test('a moving train advances along its bearing between rounds, as far as its speed says', () => {
    let compared = 0;
    for (const r of [1, 2]) {
      for (const trip of SCENARIO.filter((x) => x.track && !x.hold)) {
        const [p, t] = [trainFor(trip, r - 1), trainFor(trip, r)];
        if (!p || !t || expectedLeg(trip, r - 1)!.fraction >= 1 || expectedLeg(trip, r)!.fraction >= 1) continue;
        if (p.stretch !== t.stretch || p.underground !== t.underground) continue;
        const moved = metersBetween(p.lat, p.lon, t.lat, t.lon);
        const expected = ((p.speed + t.speed) / 2) * (1852 / 3600) * 30;
        // The straight line between two placements is never longer than the track between them, and on a bend a bit shorter.
        expect([trip.id, r, moved <= expected * 1.02 + 5 && moved >= expected * 0.6]).toEqual([trip.id, r, true]);
        const heading = bearingBetween(p.lat, p.lon, t.lat, t.lon);
        const off = (bearing: number) => Math.abs(((heading - bearing + 540) % 360) - 180);
        if (moved >= 30) expect([trip.id, r, Math.min(off(p.bearing), off(t.bearing)) < 40]).toEqual([trip.id, r, true]);
        compared++;
      }
    }
    expect(compared).toBeGreaterThan(30);
  });

  test('each round is estimated for its newest feed time', () => {
    rounds.forEach((r, i) => {
      for (const t of estimates[i].trains) expect(Date.parse(t.timestamp)).toBe(r.at);
    });
  });

  test('a feed past MAX_FEED_AGE_SECONDS drops all its trains for that round, and they come back with the next', () => {
    const jz = SCENARIO.filter((t) => t.feed === 'jz' && expectIn(t, 0) !== 'none');
    expect(jz.length).toBeGreaterThan(2);
    expect(estimates[0].trains.filter((t) => ['J', 'Z'].includes(t.route))).toHaveLength(jz.length);
    expect(estimates[1].trains.filter((t) => ['J', 'Z'].includes(t.route))).toHaveLength(0);
    expect(estimates[2].trains.filter((t) => ['J', 'Z'].includes(t.route))).toHaveLength(jz.length);
  });

  test.each(rounds.map((r, i) => [r.stamp, i] as const))(
    '%s-targets.json is in sync with the estimator (run `npm run fixtures`)',
    (stamp, i) => {
      const file = expectedTargetsPath(stamp);
      const committed = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
      if (committed !== estimates[i].text) {
        throw new Error(`${file} is out of date with the estimator. Run \`npm run fixtures\` and commit the result.`);
      }
    },
  );
});
