/**
 * Generates src/subway-data.ts: the track between every pair of consecutive stations (of any route's scheduled trips)
 * that runs inside the app's area (BOUNDING_BOXES) or on an above-ground stretch, in parts: the stretches below whole,
 * with their track heights, and everything else underground at the rail altitude of the depth model (depth.ts: each
 * station's depth below the street, the river tubes' low points, ramps at the portals), clipped to the area. Run
 * after downloading and unzipping MTA's static subway GTFS (https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip):
 *
 *   npm run subway-extract -- /path/to/unzipped/gtfs_subway [--fetch-elevation]
 *
 * Ground elevations come from data/elevation.json (committed; elevation.ts). The run is offline and deterministic; a
 * point the file lacks (a new station or track) stops it, and --fetch-elevation asks USGS for the missing points.
 * The stretches below are hand-made: which shapes run above ground, between which tunnel portals, at what heights.
 */
import fs from 'node:fs';
import path from 'node:path';
import { BOUNDING_BOXES } from '../config';
import { type Approach, type SubwayData, type TrackPart, type TrackSegment } from '../subway';
import {
  estimatedBetween,
  interpolate,
  MIN_CROSSING_M,
  railProfile,
  stationDepth,
  tubeLow,
  waterCrossings,
  type Clamp,
  type RangeEnd,
  type RangeLow,
  type RangeProfile,
} from './depth';
import { ELEVATION_CACHE_PATH, ElevationCache } from './elevation';
import { Polyline, simplify, toLatLon, toXY, type LatLon, type XY } from './geometry';

interface TrackDef {
  /** A static GTFS shape_id that runs along this track. */
  shape: string;
  /** Where the stretch's track starts and ends on the shape: tunnel portals, or the edge of the area. */
  from: LatLon;
  to: LatLon;
}

interface StretchDef {
  id: string;
  name: string;
  /** Routes expected on the stretch; the extractor warns about any other route that runs on it. */
  routes: string[];
  tracks: TrackDef[];
  /** Track height along the stretch, [lat, lon, meters above sea level], in track order; linear in between. */
  heights: (readonly [number, number, number])[];
  /** True when the heights are rule-based, not measured: trains there get `altitudeEstimated`. */
  heightsEstimated?: boolean;
}

/**
 * Portals: OpenStreetMap (railway=subway ways tagged tunnel=yes vs bridge/viaduct), checked against the GTFS shapes
 * and the lidar below (a "portal" with street surface over the track is still tunnel).
 * Heights: rail height in meters above sea level (NAVD88), measured 2026-11-10 from the USGS 3DEP / NYC 2017 airborne
 * lidar (https://usgs-lidar-public.s3.amazonaws.com/NY_NewYorkCity/ept.json) along each track: the deck or track bed,
 * plus about 0.3 m to the rail head. Good to about 1 m except where noted. Checks against published figures: both
 * bridges have 135 ft (41.1 m) clearance above mean high water at midspan, which is 0.6 m above NAVD88 at the Battery
 * (NOAA 8518750), so 41.75 m to the underside, and the rails measure about 2.5-3 m above it; Smith-9 Sts is 87.5 ft
 * (26.7 m) above a 2.2 m street, 28.9 m against 29.6 m measured.
 */
export const STRETCHES: StretchDef[] = [
  {
    id: 'manhattan-bridge',
    name: 'Manhattan Bridge',
    routes: ['B', 'D', 'N', 'Q'],
    tracks: [
      // North side, B/D: Chrystie St tunnel (Grand St) to where the bridge structure ends in Brooklyn; past it the
      // tracks run under Flatbush Av Extension (OSM tunnel, street surface in the lidar) to DeKalb Av.
      { shape: 'B..S65R', from: [40.714897, -73.994713], to: [40.699748, -73.986432] },
      // South side, N/Q: Canal St tunnel to the same end.
      { shape: 'Q..S16R', from: [40.714878, -73.99501], to: [40.699748, -73.986432] },
    ],
    // On the bridge centerline (the tracks run 10-15 m either side, at the same height). Lower deck: the rails are
    // already about 20 m up at the Manhattan portal, climb at 3.1% past the anchorage, crest 2.5 m above the towers at
    // midspan and come down at 3.1% to the end of the structure (OSM way 46346751). Towers: OSM 1255353996, 317352033.
    heights: [
      [40.714841, -73.994878, 20.3], // Manhattan portal (±2 m)
      [40.714361, -73.994609, 21.3], // bridge structure starts
      [40.711053, -73.992758, 33.9], // Manhattan anchorage
      [40.709068, -73.991648, 41.2],
      [40.708804, -73.991499, 42.2], // Manhattan tower
      [40.708382, -73.991263, 43.3],
      [40.70772, -73.990893, 44.3],
      [40.707083, -73.990537, 44.7],
      [40.706877, -73.990421, 44.8], // midspan
      [40.706389, -73.990148, 44.6],
      [40.705727, -73.989778, 43.7],
      [40.705396, -73.989593, 43.1],
      [40.705115, -73.989435, 42.3], // Brooklyn tower
      [40.704727, -73.989218, 40.8],
      [40.702783, -73.98813, 33.4], // Brooklyn anchorage
      [40.699748, -73.986432, 22.2], // bridge structure ends
    ],
  },
  {
    id: 'williamsburg-bridge',
    name: 'Williamsburg Bridge',
    routes: ['J', 'Z', 'M'],
    tracks: [
      // Delancey St tunnel (Essex St) over the bridge and along the Broadway el past Marcy Av to the area's edge.
      { shape: 'J..N40R', from: [40.717289, -73.984387], to: [40.70741, -73.955] },
    ],
    // Center tracks: above the roadways on the approaches and side spans, level with them at midspan. Towers: OSM
    // 1016434034, 1016434035. Across the Manhattan anchorage the lidar dips 4-5 m with nothing to explain it; the
    // plateau there is taken from the Brooklyn anchorage's (±3 m). The Broadway el runs 6.5-7.5 m above the street.
    heights: [
      [40.71729, -73.984393, 14.5], // portal
      [40.716959, -73.983303, 19.3],
      [40.715626, -73.978901, 34.7],
      [40.715532, -73.978593, 36.0],
      [40.714959, -73.9767, 36.4], // Manhattan anchorage (±3 m)
      [40.714692, -73.97582, 38.4],
      [40.714372, -73.974763, 40.5], // Manhattan tower
      [40.714159, -73.974059, 41.5],
      [40.713959, -73.973399, 42.6],
      [40.713759, -73.972738, 43.8],
      [40.713558, -73.972078, 44.3], // midspan
      [40.713358, -73.971418, 43.6],
      [40.713158, -73.970757, 42.5],
      [40.712958, -73.970097, 41.5],
      [40.712745, -73.969393, 40.3], // Brooklyn tower
      [40.712558, -73.968776, 39.0],
      [40.712358, -73.968116, 37.7],
      [40.712158, -73.967456, 36.3],
      [40.711905, -73.966619, 36.2], // Brooklyn anchorage
      [40.710824, -73.963053, 27.0],
      [40.710624, -73.962393, 26.5],
      [40.710418, -73.961711, 26.4],
      [40.710127, -73.960926, 24.9], // Broadway el begins
      [40.709293, -73.959852, 21.2],
      [40.708974, -73.959458, 20.5],
      [40.708408, -73.95802, 20.1], // Marcy Av
      [40.707931, -73.956631, 19.0],
      [40.707621, -73.955722, 18.1],
      [40.707265, -73.954681, 17.8],
    ],
  },
  {
    id: 'culver-viaduct',
    name: 'Culver Viaduct',
    routes: ['F', 'FX', 'G'],
    tracks: [
      // Out of the tunnel south of Carroll St (OSM way 813282238), up the viaduct over the Gowanus Canal at
      // Smith-9 Sts, back into the tunnel past 4 Av-9 St.
      { shape: 'F..S69R', from: [40.678762, -73.996017], to: [40.669421, -73.987623] },
    ],
    heights: [
      [40.678762, -73.996017, 11.9], // portal (open cut)
      [40.677627, -73.996577, 15.9], // viaduct starts
      [40.676438, -73.997223, 21.1],
      [40.674927, -73.997225, 25.9],
      [40.674324, -73.996758, 28.4],
      [40.673873, -73.996215, 29.7], // Smith-9 Sts
      [40.673564, -73.995781, 29.2],
      [40.673041, -73.994916, 27.8],
      [40.672324, -73.993682, 24.3],
      [40.671614, -73.992337, 20.2],
      [40.671184, -73.991475, 19.3],
      [40.67029, -73.989658, 18.6], // 4 Av-9 St
      [40.669798, -73.988641, 18.0], // viaduct ends
      [40.669421, -73.987623, 15.4], // portal (open cut; ±2 m)
    ],
  },
  {
    id: 'franklin-av',
    name: 'Franklin Av shuttle',
    routes: ['FS'],
    tracks: [
      // The BMT Franklin Avenue Line from its terminal at Franklin Av (the shape's first point, the station) on a raised
      // embankment (Wikipedia, "BMT Franklin Avenue Line": "In 1905 and 1906, the line was elevated near Park Place to
      // eliminate the last remaining grade crossings." and "some of the elevated trackage was placed on
      // concrete-retained embankment."; no tunnel in the area) with short street bridges, south to Park Pl, where
      // it leaves the area (its edge is at 40.675, 25 m north of the station); it goes down into an open cut after Park
      // Pl, which isn't kept. The ends are the two stations, from the GTFS shape (OSM ways 97047841/2 and 46774564/5
      // show no tunnel tags and were used only to hand-pick them).
      { shape: 'FS.S01R', from: [40.680596, -73.955827], to: [40.674772, -73.957624] },
    ],
    // ESTIMATED, not measured (±3 m): the lidar could not be read here (no LAZ tools), so the ground comes from the
    // USGS Elevation Point Query Service (bare-earth 3DEP DEM, 1 m, https://epqs.nationalmap.gov/v1/json): the mean of
    // three points across the track (on it and 15 m either side), every 50 m (the DEM has no embankment here: the
    // structure is not ground, so it reads the street level, 22 m at Franklin Av rising 1.7% to 33.5 m at Park Pl), plus
    // 5.5 m to the rail: a street bridge's clearance (about 4.1 m) and deck (about 1 m) less the street's dip under it
    // (up to 0.9 m, Wikipedia), and the rail head. The embankment between the streets is taken at the same height.
    // The side samples (15 m either side of the track) are not in data/elevation.json, which holds only the points the
    // extractor asks for, so these heights can't be re-derived from committed data alone: they are hand-entered here.
    heights: [
      [40.680596, -73.955827, 27.6], // Franklin Av, 22.1 m ground
      [40.680147, -73.955843, 28.2],
      [40.679698, -73.95588, 28.8],
      [40.679259, -73.956006, 29.4],
      [40.678825, -73.956162, 30.7],
      [40.678392, -73.956319, 31.3],
      [40.677958, -73.956475, 32.8],
      [40.677524, -73.956632, 33.5],
      [40.67709, -73.956788, 34.3],
      [40.676657, -73.956944, 35.1],
      [40.676223, -73.957101, 36.2],
      [40.675789, -73.957257, 37.5],
      [40.675355, -73.957414, 38.3],
      [40.674922, -73.95757, 39.0],
      [40.674772, -73.957624, 39.0], // Park Pl, 33.5 m ground
    ],
    heightsEstimated: true,
  },
];

const SAMPLE_M = 5;
/** A path point this close to a stretch's track, running the same way, is on the stretch. */
const NEAR_M = 15;
const PARALLEL_COS = Math.cos((25 * Math.PI) / 180);
/** Shorter matches are crossings over or under the stretch, not shared track. */
const MIN_PART_M = 40;
const SIMPLIFY_M = 2;
/** Less track than this inside the area is a segment that only clips its edge. */
const MIN_IN_AREA_M = 2;
/** Pairs of stations at least this far from the area aren't reported when no shape runs between them. */
const WARN_WITHIN_M = 3000;

type Row = Record<string, string>;

function readCsv(file: string, onRow: (row: Row) => void): void {
  const text = fs.readFileSync(file, 'utf8');
  const lines = text.split(/\r?\n/);
  const cols = lines[0].replace(/^﻿/, '').split(',');
  for (let i = 1; i < lines.length; i++) {
    if (!lines[i]) continue;
    // MTA's files have no quoted commas in the columns used here (route descriptions are in routes.txt, not read).
    const cells = lines[i].split(',');
    const row: Row = {};
    cols.forEach((c, j) => (row[c] = cells[j] ?? ''));
    onRow(row);
  }
}

const stationOf = (stopId: string) => stopId.replace(/[NS]$/, '');

/** Seconds since the start of the service day from a GTFS time (which runs past 24:00:00 after midnight). */
function gtfsSeconds(time: string): number {
  const [h, m, s] = time.split(':').map(Number);
  return h * 3600 + m * 60 + s;
}

const median = (values: number[]) => {
  const sorted = [...values].sort((x, y) => x - y);
  return sorted[Math.floor(sorted.length / 2)];
};
const round = (v: number, places: number) => Math.round(v * 10 ** places) / 10 ** places;

interface Station {
  name: string;
  xy: XY;
}

interface StretchRef {
  def: StretchDef;
  tracks: Polyline[];
  profile: Polyline;
  profileHeights: number[];
}

function buildStretch(def: StretchDef, shapes: Map<string, Polyline>): StretchRef {
  const tracks = def.tracks.map((t) => {
    const shape = shapes.get(t.shape);
    if (!shape) throw new Error(`${def.id}: shape ${t.shape} not in shapes.txt`);
    const a = shape.project(toXY(t.from));
    const b = shape.project(toXY(t.to));
    for (const [end, p] of [
      ['from', a],
      ['to', b],
    ] as const) {
      if (p.offset > 30) throw new Error(`${def.id}: ${t.shape} ${end} point is ${p.offset.toFixed(0)} m off the shape`);
    }
    return a.along < b.along ? shape.slice(a.along, b.along) : shape.slice(b.along, a.along).reversed();
  });
  const profile = new Polyline(def.heights.map(([lat, lon]) => toXY([lat, lon])));
  return { def, tracks, profile, profileHeights: def.heights.map((h) => h[2]) };
}

function heightAt(s: StretchRef, p: XY): number {
  if (s.profileHeights.length === 1) return s.profileHeights[0];
  const { along } = s.profile.project(p);
  const c = s.profile.cumulative;
  let i = 1;
  while (i < c.length - 1 && c[i] < along) i++;
  const f = c[i] > c[i - 1] ? Math.min(Math.max((along - c[i - 1]) / (c[i] - c[i - 1]), 0), 1) : 0;
  return s.profileHeights[i - 1] + f * (s.profileHeights[i] - s.profileHeights[i - 1]);
}

/** The stretch that the path is on at `d`, if any. */
function stretchAt(pathLine: Polyline, d: number, stretches: StretchRef[]): StretchRef | undefined {
  const p = pathLine.at(d);
  const dir = pathLine.direction(d);
  for (const s of stretches) {
    for (const track of s.tracks) {
      const { along, offset } = track.project(p);
      if (offset > NEAR_M) continue;
      const tdir = track.direction(along);
      if (Math.abs(dir[0] * tdir[0] + dir[1] * tdir[1]) >= PARALLEL_COS) return s;
    }
  }
  return undefined;
}

/** The path between two stations along a shape, or undefined if the shape doesn't pass close to both. */
function pathBetween(shape: Polyline, a: XY, b: XY): Polyline | undefined {
  const candidates: Polyline[] = [];
  const pa = shape.project(a);
  const pb = shape.project(b, pa.along);
  if (pa.offset < 60 && pb.offset < 60 && pb.along > pa.along) candidates.push(shape.slice(pa.along, pb.along));
  const qb = shape.project(b);
  const qa = shape.project(a, qb.along);
  if (qb.offset < 60 && qa.offset < 60 && qa.along > qb.along) candidates.push(shape.slice(qb.along, qa.along).reversed());
  candidates.sort((x, y) => x.length - y.length);
  return candidates[0];
}

/** Inserts a vertex at each of `alongs` (meters along `line`); returns the points and the inserted indices. */
function withVertices(line: Polyline, alongs: number[]): { points: XY[]; inserted: Set<number> } {
  const marks = alongs.filter((d) => d > 0.5 && d < line.length - 0.5).sort((x, y) => x - y);
  const points: XY[] = [];
  const inserted = new Set<number>();
  let m = 0;
  for (let i = 0; i < line.points.length; i++) {
    while (m < marks.length && marks[m] < line.cumulative[i] - 0.5) {
      inserted.add(points.length);
      points.push(line.at(marks[m++]));
    }
    if (m < marks.length && Math.abs(marks[m] - line.cumulative[i]) <= 0.5) {
      inserted.add(points.length);
      m++;
    }
    points.push(line.points[i]);
  }
  return { points, inserted };
}

/** [minX, minY, maxX, maxY] in local meters. */
type Box = readonly [number, number, number, number];

/** BOUNDING_BOXES (corners in either order) in local meters; the plane is linear in lat/lon, so they stay boxes. */
const AREA: Box[] = BOUNDING_BOXES.map(([c1, c2]) => {
  const [x1, y1] = toXY(c1);
  const [x2, y2] = toXY(c2);
  return [Math.min(x1, x2), Math.min(y1, y2), Math.max(x1, x2), Math.max(y1, y2)] as const;
});

/** Meters from a point to the nearest box (0 inside). */
function metersToArea(p: XY): number {
  return Math.min(...AREA.map((b) => Math.hypot(Math.max(b[0] - p[0], 0, p[0] - b[2]), Math.max(b[1] - p[1], 0, p[1] - b[3]))));
}

/** The part of the segment a -> b inside the box as fractions of its length (Liang-Barsky), if any. */
function clipToBox(a: XY, b: XY, box: Box): [number, number] | undefined {
  let t0 = 0;
  let t1 = 1;
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  for (const [p, q] of [
    [-dx, a[0] - box[0]],
    [dx, box[2] - a[0]],
    [-dy, a[1] - box[1]],
    [dy, box[3] - a[1]],
  ] as const) {
    if (p === 0) {
      if (q < 0) return undefined;
    } else if (p < 0) {
      t0 = Math.max(t0, q / p);
    } else {
      t1 = Math.min(t1, q / p);
    }
  }
  return t0 < t1 ? [t0, t1] : undefined;
}

/** `pieces` ([from, to] meters along a line) sorted, with overlapping and touching ones joined. */
function joinSpans(pieces: [number, number][]): [number, number][] {
  const sorted = [...pieces].sort((x, y) => x[0] - y[0]);
  const joined: [number, number][] = [];
  for (const p of sorted) {
    const last = joined[joined.length - 1];
    if (last && p[0] <= last[1] + 1e-6) last[1] = Math.max(last[1], p[1]);
    else joined.push([...p]);
  }
  return joined;
}

/** Where the line is inside the area, as [from, to] meters along it, in order, with touching pieces joined. */
function insideArea(line: Polyline): [number, number][] {
  const pieces: [number, number][] = [];
  for (const box of AREA) {
    for (let i = 1; i < line.points.length; i++) {
      const t = clipToBox(line.points[i - 1], line.points[i], box);
      if (!t) continue;
      const len = line.cumulative[i] - line.cumulative[i - 1];
      pieces.push([line.cumulative[i - 1] + t[0] * len, line.cumulative[i - 1] + t[1] * len]);
    }
  }
  return joinSpans(pieces);
}

interface StretchRun {
  stretch: StretchRef;
  from: number;
  to: number;
}

/** The runs of the whole path (inside the area or not) that lie on a stretch, in order. */
function stretchRuns(pathLine: Polyline, stretches: StretchRef[]): StretchRun[] {
  const samples: number[] = [];
  for (let d = 0; d < pathLine.length; d += SAMPLE_M) samples.push(d);
  samples.push(pathLine.length);
  const runs: StretchRun[] = [];
  for (const d of samples) {
    const s = stretchAt(pathLine, d, stretches);
    const last = runs[runs.length - 1];
    if (s && last && last.stretch === s && d - last.to <= SAMPLE_M + 1e-6) last.to = d;
    else if (s) runs.push({ stretch: s, from: d, to: d });
  }
  return runs.filter((r) => r.to - r.from >= MIN_PART_M);
}

function stretchPart(pathLine: Polyline, from: number, to: number, stretch: StretchRef): TrackPart {
  const sub = pathLine.slice(from, to);
  const controls = stretch.def.heights
    .map(([lat, lon]) => sub.project(toXY([lat, lon])))
    .filter((p) => p.offset < 60)
    .map((p) => p.along);
  const { points, inserted } = withVertices(sub, controls);
  const keep = simplify(points, SIMPLIFY_M, inserted);
  return {
    underground: false,
    stretch: stretch.def.id,
    from: round(from, 0),
    to: round(to, 0),
    points: keep.map((i) => {
      const [lat, lon] = toLatLon(points[i]);
      return [round(lat, 6), round(lon, 6), round(heightAt(stretch, points[i]), 1)] as const;
    }),
    altitudeEstimated: stretch.def.heightsEstimated ?? false,
  };
}

/** What the depth model needs to know about one segment's track. */
interface SegmentDepth {
  /** The station IDs at the start and end of the path, and the rail altitudes there (ground less depth). */
  a: { id: string; altitude: number; estimated: boolean };
  b: { id: string; altitude: number; estimated: boolean };
  /** Ground elevation, meters, `along` meters from the start of the whole path. */
  ground: (along: number) => number;
  /** Where the path runs over water, [from, to] along. */
  water: [number, number][];
  /** Reports a clamp of the model (a range of the path, meters along it). */
  onClamp: (kind: Clamp['kind'], from: number, to: number, amount: number) => void;
  /** Reports a river tube's low point placed at `along` meters, over water for `water` meters. */
  onTube: (along: number, altitude: number, source: string, water: number) => void;
}

/** A stretch of the path between stretch runs (or its ends), underground whole, also where it leaves the area. */
interface UndergroundRange {
  from: number;
  to: number;
  profile: RangeProfile;
}

function undergroundRange(pathLine: Polyline, from: number, to: number, before: StretchRun | undefined, after: StretchRun | undefined, depth: SegmentDepth): UndergroundRange {
  const portal = (run: StretchRun, along: number): RangeEnd => ({
    altitude: round(heightAt(run.stretch, pathLine.at(along)), 1),
    estimated: run.stretch.def.heightsEstimated ?? false,
    portal: true,
  });
  const start: RangeEnd = before ? portal(before, from) : { altitude: depth.a.altitude, estimated: depth.a.estimated, portal: false };
  const end: RangeEnd = after ? portal(after, to) : { altitude: depth.b.altitude, estimated: depth.b.estimated, portal: false };
  // The river tubes: the rail is lowest in the middle of the water.
  const lows: RangeLow[] = [];
  const tube = tubeLow(depth.a.id, depth.b.id);
  for (const [w0, w1] of depth.water) {
    const lo = Math.max(w0, from);
    const hi = Math.min(w1, to);
    if (hi - lo < MIN_CROSSING_M) continue;
    lows.push({ x: (lo + hi) / 2 - from, altitude: tube.altitude, estimated: tube.source === 'estimated' });
    depth.onTube((lo + hi) / 2, tube.altitude, tube.source, hi - lo);
  }
  const profile = railProfile({ length: to - from, start, end, ground: (x) => depth.ground(from + x), lows });
  for (const c of profile.clamps) depth.onClamp(c.kind, from + c.from, from + c.to, c.amount);
  return { from, to, profile };
}

function undergroundPart(pathLine: Polyline, from: number, to: number, range: UndergroundRange): TrackPart {
  const sub = pathLine.slice(from, to);
  const knots = range.profile.knots;
  const { points, inserted } = withVertices(
    sub,
    knots.map(([x]) => range.from + x - from),
  );
  const keep = simplify(points, SIMPLIFY_M, inserted);
  const line = new Polyline(points);
  return {
    underground: true,
    from: round(from, 0),
    to: round(to, 0),
    points: keep.map((i) => {
      const [lat, lon] = toLatLon(points[i]);
      return [round(lat, 6), round(lon, 6), round(interpolate(knots, from + line.cumulative[i] - range.from), 1)] as const;
    }),
    altitudeEstimated: estimatedBetween(range.profile, from - range.from, to - range.from),
  };
}

/**
 * The path's parts, in order, with no gaps: underground track inside the area, and the stretches whole, also where
 * they run outside it (the Culver Viaduct's crest at Smith-9 Sts lies just south of it): a viaduct or bridge is seen
 * from inside the area, a tunnel isn't. A path that leaves and comes back has parts on both visits.
 */
function trackParts(pathLine: Polyline, stretches: StretchRef[], depth: SegmentDepth): TrackPart[] {
  const runs = stretchRuns(pathLine, stretches);
  // The rail altitude is modelled over each whole underground range between stretches, inside the area or not, so
  // that it joins the stations and portals at its ends.
  const ranges: UndergroundRange[] = [];
  let edge = 0;
  for (let i = 0; i <= runs.length; i++) {
    const to = i < runs.length ? runs[i].from : pathLine.length;
    if (to - edge > 1e-3) ranges.push(undergroundRange(pathLine, edge, to, runs[i - 1], runs[i], depth));
    if (i < runs.length) edge = runs[i].to;
  }
  const rangeOf = (d: number) => ranges.find((r) => d >= r.from - 1e-3 && d <= r.to + 1e-3)!;
  const parts: TrackPart[] = [];
  const spans = joinSpans([
    ...insideArea(pathLine).filter(([lo, hi]) => hi - lo >= MIN_IN_AREA_M),
    ...runs.map((r): [number, number] => [r.from, r.to]),
  ]);
  for (const [lo, hi] of spans) {
    let at = lo;
    for (const r of runs) {
      const from = Math.max(r.from, lo);
      const to = Math.min(r.to, hi);
      if (to - from < 1) continue; // a sliver where a run just touches the area's edge
      if (from - at > 1e-3) parts.push(undergroundPart(pathLine, at, from, rangeOf((at + from) / 2)));
      parts.push(stretchPart(pathLine, from, to, r.stretch));
      at = to;
    }
    if (hi - at > 1e-3) parts.push(undergroundPart(pathLine, at, hi, rangeOf((at + hi) / 2)));
  }
  return parts;
}

/** Ground elevations from the cache; remembers the points it lacks. */
class Ground {
  readonly missing = new Map<string, [number, number]>();
  constructor(private readonly cache: ElevationCache) {}

  /** The elevation at a point, 0 (and noted as missing) when the cache doesn't have it; NaN where USGS has no data. */
  at(lat: number, lon: number): number {
    const v = this.cache.get(lat, lon);
    if (v === undefined) {
      this.missing.set(`${lat.toFixed(5)},${lon.toFixed(5)}`, [lat, lon]);
      return 0;
    }
    return v === null ? NaN : v;
  }
}

/** Meters between ground elevation samples along a path. */
const GROUND_SAMPLE_M = 150;

/**
 * Ground elevation along `line`: a sample every GROUND_SAMPLE_M. `samples` keeps the ones with no data (NaN), which
 * waterCrossings counts as water; `at` interpolates linearly between the samples that have data.
 */
function groundAlong(line: Polyline, ground: Ground): { at: (along: number) => number; samples: [number, number][] } {
  const alongs: number[] = [];
  for (let d = 0; d < line.length; d += GROUND_SAMPLE_M) alongs.push(d);
  alongs.push(line.length);
  const samples = alongs.map((d): [number, number] => {
    const [lat, lon] = toLatLon(line.at(d));
    return [d, ground.at(lat, lon)];
  });
  const known = samples.filter((s) => Number.isFinite(s[1]));
  return { at: (along) => interpolate(known.length > 0 ? known : [[0, 0]], along), samples };
}

async function main(): Promise<void> {
  const dir = process.argv[2];
  if (!dir || !fs.existsSync(path.join(dir, 'stop_times.txt'))) {
    console.error('usage: npm run subway-extract -- <directory with the unzipped static GTFS>');
    process.exit(1);
  }
  const out = path.resolve(__dirname, '..', '..', 'src', 'subway-data.ts');

  let feedVersion = 'unknown';
  readCsv(path.join(dir, 'feed_info.txt'), (r) => (feedVersion = r.feed_version || feedVersion));

  const stations = new Map<string, Station>();
  readCsv(path.join(dir, 'stops.txt'), (r) => {
    if (r.location_type === '1') stations.set(r.stop_id, { name: r.stop_name, xy: toXY([Number(r.stop_lat), Number(r.stop_lon)]) });
  });

  const trips = new Map<string, { route: string; shape: string }>();
  readCsv(path.join(dir, 'trips.txt'), (r) => trips.set(r.trip_id, { route: r.route_id, shape: r.shape_id }));

  const wantedShapes = new Set([...trips.values()].map((t) => t.shape));
  for (const s of STRETCHES) for (const t of s.tracks) wantedShapes.add(t.shape);
  const shapePoints = new Map<string, { seq: number; xy: XY }[]>();
  readCsv(path.join(dir, 'shapes.txt'), (r) => {
    if (!wantedShapes.has(r.shape_id)) return;
    let list = shapePoints.get(r.shape_id);
    if (!list) shapePoints.set(r.shape_id, (list = []));
    list.push({ seq: Number(r.shape_pt_sequence), xy: toXY([Number(r.shape_pt_lat), Number(r.shape_pt_lon)]) });
  });
  const shapes = new Map<string, Polyline>();
  for (const [id, list] of shapePoints) shapes.set(id, new Polyline(list.sort((a, b) => a.seq - b.seq).map((p) => p.xy)));

  const sequences = new Map<string, { seq: number; station: string; dir: string; arrival: number; departure: number }[]>();
  readCsv(path.join(dir, 'stop_times.txt'), (r) => {
    let list = sequences.get(r.trip_id);
    if (!list) sequences.set(r.trip_id, (list = []));
    list.push({
      seq: Number(r.stop_sequence),
      station: stationOf(r.stop_id),
      dir: r.stop_id.slice(-1),
      arrival: gtfsSeconds(r.arrival_time),
      departure: gtfsSeconds(r.departure_time),
    });
  });

  // Consecutive station pairs, undirected, with how often each shape (in each direction) runs them.
  const pairs = new Map<string, Map<string, { a: string; b: string; shape: string; trips: number; routes: Set<string> }>>();
  const terminalsByRoute = new Map<string, Set<string>>();
  // Where trains come from into a station: "shape|station" and "route|N|station" to the stations before it.
  const arrivals = new Map<string, Map<string, { trips: number; seconds: number[] }>>();
  for (const [tripId, list] of sequences) {
    const trip = trips.get(tripId);
    if (!trip) continue;
    const { route, shape } = trip;
    list.sort((x, y) => x.seq - y.seq);
    let terminals = terminalsByRoute.get(route);
    if (!terminals) terminalsByRoute.set(route, (terminals = new Set()));
    terminals.add(list[list.length - 1].station);
    for (let i = 1; i < list.length; i++) {
      const a = list[i - 1].station;
      const b = list[i].station;
      if (a === b) continue;
      const dir = list[i].dir;
      if (dir === 'N' || dir === 'S') {
        // Under the trip's shape (a stopping pattern: realtime trip IDs end in it) and under its route and direction.
        for (const into of [`${shape}|${b}`, `${route}|${dir}|${b}`]) {
          let from = arrivals.get(into);
          if (!from) arrivals.set(into, (from = new Map()));
          const seen = from.get(a) ?? { trips: 0, seconds: [] };
          seen.trips++;
          seen.seconds.push(list[i].arrival - list[i - 1].departure);
          from.set(a, seen);
        }
      }
      const key = a < b ? `${a}|${b}` : `${b}|${a}`;
      let byShape = pairs.get(key);
      if (!byShape) pairs.set(key, (byShape = new Map()));
      const k = `${shape}|${a}|${b}`;
      const entry = byShape.get(k) ?? { a, b, shape, trips: 0, routes: new Set<string>() };
      entry.trips++;
      entry.routes.add(route);
      byShape.set(k, entry);
    }
  }

  const refs = STRETCHES.map((s) => buildStretch(s, shapes));
  const segments: TrackSegment[] = [];
  const summary: string[] = [];
  const routesInArea = new Set<string>();
  const routesOnStretch = new Map<string, Set<string>>();
  const depthTable = new Map<string, string>();
  const tubeTable = new Map<string, string>();
  const clampLog: string[] = [];
  const cache = new ElevationCache();
  const fetchElevation = process.argv.includes('--fetch-elevation');
  for (;;) {
    const ground = new Ground(cache);
    segments.length = 0;
    summary.length = 0;
    routesInArea.clear();
    routesOnStretch.clear();
    depthTable.clear();
    tubeTable.clear();
    clampLog.length = 0;
    for (const byShape of pairs.values()) {
      const options = [...byShape.values()].sort((x, y) => y.trips - x.trips);
      const best = options[0];
      const sa = stations.get(best.a);
      const sb = stations.get(best.b);
      const shape = shapes.get(best.shape);
      if (!sa || !sb || !shape) continue;
      const line = pathBetween(shape, sa.xy, sb.xy);
      if (!line) {
        if (Math.min(metersToArea(sa.xy), metersToArea(sb.xy)) < WARN_WITHIN_M) {
          console.warn(`warning: ${best.shape} doesn't run between ${best.a} and ${best.b}; skipped`);
        }
        continue;
      }
      // Only track that has parts needs ground elevations (every other pair of stations in the system is skipped here).
      if (!insideArea(line).some(([lo, hi]) => hi - lo >= MIN_IN_AREA_M) && stretchRuns(line, refs).length === 0) continue;
      const g = groundAlong(line, ground);
      const station = (id: string, st: Station) => {
        const [lat, lon] = toLatLon(st.xy);
        const elevation = ground.at(lat, lon);
        if (Number.isNaN(elevation)) throw new Error(`no ground elevation at station ${id} ${st.name}`);
        const d = stationDepth(id);
        const altitude = round(elevation - d.depth, 1);
        depthTable.set(id, `${id} ${st.name}: depth ${d.depth} m ${d.source}, ground ${elevation} m, rail ${altitude} m`);
        return { id, altitude, estimated: d.source === 'estimated' };
      };
      const where = `${best.a}-${best.b}`;
      const water = waterCrossings(g.samples);
      const parts = trackParts(line, refs, {
        a: station(best.a, sa),
        b: station(best.b, sb),
        ground: g.at,
        water,
        onClamp: (kind, from, to, amount) => clampLog.push(`${where} ${kind} ${round(from, 0)}-${round(to, 0)} m by ${round(amount, 2)}`),
        onTube: (along, altitude, source, wet) =>
          tubeTable.set(where, `${where} ${sa.name} - ${sb.name}: ${round(wet, 0)} m over water, low point at ${round(along, 0)} m of ${round(line.length, 0)} m: ${round(altitude, 1)} m ${source}`),
      });
      if (parts.length === 0) continue;
      segments.push({ a: best.a, b: best.b, length: round(line.length, 0), parts });
      const routesHere = new Set(options.flatMap((o) => [...o.routes]));
      for (const route of routesHere) routesInArea.add(route);
      for (const p of parts) {
        if (!p.stretch) continue;
        let seen = routesOnStretch.get(p.stretch);
        if (!seen) routesOnStretch.set(p.stretch, (seen = new Set()));
        for (const route of routesHere) seen.add(route);
      }
      const trips = options.reduce((n, o) => n + o.trips, 0);
      summary.push(
        `${best.a} ${sa.name} <-> ${best.b} ${sb.name}: ${round(line.length, 0)} m, ` +
          parts.map((p) => `${p.stretch ?? 'underground'} ${p.from}-${p.to} m (${p.points.length} pts)`).join(', ') +
          `; ${[...routesHere].sort().join('')} ${trips} trips; shape ${best.shape}`,
      );
    }
    if (ground.missing.size === 0) break;
    if (!fetchElevation) {
      console.error(`${ground.missing.size} ground elevations are missing from ${ELEVATION_CACHE_PATH}; run again with --fetch-elevation`);
      process.exit(1);
    }
    console.log(`fetching ${ground.missing.size} ground elevations from USGS EPQS...`);
    await cache.fetchMissing([...ground.missing.values()]);
  }
  segments.sort((x, y) => (x.a + x.b < y.a + y.b ? -1 : 1));
  for (const s of STRETCHES) {
    const others = [...(routesOnStretch.get(s.id) ?? [])].filter((r) => !s.routes.includes(r));
    if (others.length > 0) console.warn(`warning: routes ${others.sort().join(' ')} also run on ${s.id}; not in its routes`);
  }

  // Approaches into every station a segment touches: where a train reported on its way there came from, and how long
  // that run takes on the schedule (median over the day's trips: arrival there less departure from the station before).
  const inSegments = new Set(segments.flatMap((s) => [s.a, s.b]));
  const approaches: Record<string, Approach[]> = {};
  for (const [into, from] of [...arrivals].sort(([x], [y]) => (x < y ? -1 : 1))) {
    if (!inSegments.has(into.split('|').pop()!)) continue;
    const list = [...from]
      .map(([station, v]) => ({ from: station, seconds: Math.max(1, median(v.seconds)), trips: v.trips }))
      .sort((x, y) => y.trips - x.trips || (x.from < y.from ? -1 : 1));
    approaches[into] = list;
  }

  const terminals = new Set([...routesInArea].flatMap((r) => [...(terminalsByRoute.get(r) ?? [])]));
  const data: SubwayData = {
    stretches: STRETCHES.map((s) => ({ id: s.id, name: s.name })),
    routes: [...routesInArea].sort(),
    terminals: Object.fromEntries(
      [...terminals]
        .filter((t) => stations.has(t))
        .sort()
        .map((t) => [t, stations.get(t)!.name]),
    ),
    segments,
    approaches,
  };
  fs.writeFileSync(out, render(data, feedVersion));
  console.log(summary.sort().join('\n'));
  console.log('\nstation depths:\n' + [...depthTable].sort(([x], [y]) => (x < y ? -1 : 1)).map(([, v]) => v).join('\n'));
  console.log('\nriver tubes:\n' + [...tubeTable.values()].sort().join('\n'));
  console.log('\nclamps:\n' + clampLog.sort().join('\n'));
  console.log(
    `wrote ${out}: ${segments.length} segments, ${segments.reduce((n, s) => n + s.parts.length, 0)} parts, ` +
      `routes ${data.routes.join(' ')}, ${Object.keys(data.terminals).length} terminals`,
  );
}

function render(data: SubwayData, feedVersion: string): string {
  const lines: string[] = [];
  lines.push(
    `// Generated by \`npm run subway-extract\` (src/tools/subway-extract.ts) from MTA New York City Transit's static`,
    `// subway GTFS, https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip,`,
    `// feed_version ${feedVersion}:`,
    `// stations from stops.txt, track geometry from shapes.txt, station pairs, approaches and run times from trips.txt and`,
    `// stop_times.txt.`,
    `// Every pair of consecutive stations whose track runs inside BOUNDING_BOXES (src/config.ts) or on a stretch. Stretch`,
    `// ends (tunnel portals) and track heights are hand-made: see STRETCHES in the generator; stretches are kept whole.`,
    `// Everything else is underground, clipped to the area, at the rail altitude of the depth model (src/tools/depth.ts:`,
    `// station depths below the street, river tube low points, ramps at the portals; ground elevations from USGS 3DEP via`,
    `// EPQS, data/elevation.json). altitudeEstimated: the part's altitudes follow rule-based figures. Do not edit by hand.`,
    ``,
    `import type { SubwayData } from './subway';`,
    ``,
    `export const SUBWAY_DATA: SubwayData = {`,
    `  stretches: ${JSON.stringify(data.stretches)},`,
    `  routes: ${JSON.stringify(data.routes)},`,
    `  terminals: {`,
    ...Object.entries(data.terminals).map(([id, name]) => `    ${JSON.stringify(id)}: ${JSON.stringify(name)},`),
    `  },`,
    `  segments: [`,
  );
  for (const s of data.segments) {
    lines.push(`    {`, `      a: ${JSON.stringify(s.a)},`, `      b: ${JSON.stringify(s.b)},`, `      length: ${s.length},`, `      parts: [`);
    for (const p of s.parts) {
      lines.push(
        `        {`,
        `          underground: ${p.underground},`,
        ...(p.stretch === undefined ? [] : [`          stretch: ${JSON.stringify(p.stretch)},`]),
        `          from: ${p.from},`,
        `          to: ${p.to},`,
        `          points: [`,
        ...p.points.map((q) => `            [${q[0]}, ${q[1]}, ${q[2]}],`),
        `          ],`,
        `          altitudeEstimated: ${p.altitudeEstimated ?? false},`,
        `        },`,
      );
    }
    lines.push(`      ],`, `    },`);
  }
  lines.push(
    `  ],`,
    `  approaches: {`,
    ...Object.entries(data.approaches).map(([into, list]) => `    ${JSON.stringify(into)}: ${JSON.stringify(list)},`),
    `  },`,
    `};`,
    ``,
  );
  return lines.join('\n');
}

if (require.main === module) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
