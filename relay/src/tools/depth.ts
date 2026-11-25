/**
 * The depth model of the subway extract: rail height (meters above sea level, NAVD88) of underground track, from the
 * depth of each station below the street and the low points of the river tubes. Pure functions; the extractor
 * (subway-extract.ts) feeds them ground elevations from data/elevation.json and bakes the result into subway-data.ts,
 * so the relay itself does no lookups.
 */

/** Steepest grade of underground track (NYCT's own tubes: Joralemon St 3.1%, the Manhattan Bridge approaches 3-4%). */
export const MAX_GRADE = 0.04;
/** The rail never lies closer than this to the street above (tunnel roof and cover). Estimate. */
export const COVER_M = 3;
/**
 * Rail depth below the street at a station with no better figure: a cut-and-cover subway (most of the extract's
 * lines) has its roof just under the street, and its rail about a car and a half lower. Estimate.
 */
export const DEFAULT_STATION_DEPTH_M = 6;
/**
 * Ground elevation at or below this is open water (EPQS answers the hydro-flattened river, -1.62 m, over the East River).
 * A sample with no data (EPQS answers nothing, stored as null) counts as water too: it is open water far more often
 * than not, and dropping it could make a river crossing too short to find, so its tube would silently vanish.
 */
export const WATER_M = 0.5;
/** A run of water samples shorter than this along the track is a slip or a dock, not a river crossing. */
export const MIN_CROSSING_M = 200;
/**
 * Mean high water at the Battery in NAVD88, the datum of the published tube depths: NOAA CO-OPS station 8518750, datums
 * for the 1983-2001 epoch (checked 2026-11-16): MHW 2.445 m less NAVD88 1.848 m above station datum, 0.597 m. Sea level
 * has risen since that epoch (about 0.1 m), and the articles don't say which epoch their "mean high water" is, so take
 * it as good to about 0.1 m.
 */
export const MEAN_HIGH_WATER_M = 0.6;
/**
 * Rail low point of a river tube with no published figure: Joralemon Street Tunnel's, 28 to 29 m below mean high water
 * (Wikipedia, "Joralemon Street Tunnel": "The lowest points on the tubes are about 91 to 95 feet (28 to 29 m) below the
 * mean high water level of the East River."), 28.5 m. Estimate for the other tubes: riverbed depth varies along the
 * river, but the tubes all had to clear the same channel with the same shield-driven cast-iron or concrete rings.
 */
export const DEFAULT_TUBE_LOW_M = MEAN_HIGH_WATER_M - 28.5;

export type Source = 'published' | 'estimated';

export interface StationDepth {
  /** Rail depth below the street, meters. */
  depth: number;
  source: Source;
  /** Where the figure comes from: the sentence quoted, or the rule. */
  note: string;
}

/**
 * Stations with a depth of their own, by parent station ID (stops.txt). Every other station gets
 * DEFAULT_STATION_DEPTH_M. Published figures are Wikipedia's station articles (2026-11-16); where an article says
 * "below street level" for the platform that is taken as the rail.
 */
export const STATION_DEPTHS: Record<string, StationDepth> = {
  // https://en.wikipedia.org/wiki/Clark_Street_station: "At approximately 80 feet (24 m) deep, the Clark Street station
  // contains one island platform and two tracks."
  '231': { depth: 24, source: 'published', note: 'Clark St (2 3): "approximately 80 feet (24 m) deep" (Wikipedia, Clark Street station)' },
  // https://en.wikipedia.org/wiki/High_Street%E2%80%93Brooklyn_Bridge_station: "the station site was constructed 70 feet
  // (21 m) below the street (the tunnel is 90 feet (27 m) below the surface at its lowest point) using mining techniques."
  A40: { depth: 21, source: 'published', note: 'High St (A C): "70 feet (21 m) below the street" (Wikipedia, High Street station)' },
  // https://en.wikipedia.org/wiki/York_Street_station_(IND_Sixth_Avenue_Line): "The station is about 80 feet (24 m) deep."
  F18: { depth: 24, source: 'published', note: 'York St (F): "about 80 feet (24 m) deep" (Wikipedia, York Street station)' },
  // https://en.wikipedia.org/wiki/Whitehall_Street%E2%80%93South_Ferry_station, on the new station (opened 2009): "The new
  // 76,820-square-foot (7,137 m2) station, located at a depth of 50 feet (15 m), would contain a 600-by-25-foot platform".
  // That is the planned depth (the article's account of the plans, "would contain"); it gives no as-built figure.
  '142': { depth: 15, source: 'published', note: 'South Ferry (1): "located at a depth of 50 feet (15 m)", the planned depth (Wikipedia, South Ferry/Whitehall Street station)' },
};

export interface TubeLow {
  /** Rail altitude at the tube's lowest point, meters above sea level. */
  altitude: number;
  source: Source;
  note: string;
}

/**
 * Low point of a river tube, by the two stations it runs between ("A|B", sorted). Every crossing the extract finds
 * (the track runs over water for MIN_CROSSING_M or more) and has no entry here gets DEFAULT_TUBE_LOW_M, estimated.
 */
export const TUBE_LOWS: Record<string, TubeLow> = {
  // Joralemon Street Tunnel (4 5), Bowling Green to Borough Hall.
  '420|423': {
    altitude: DEFAULT_TUBE_LOW_M,
    source: 'published',
    note: 'Wikipedia, Joralemon Street Tunnel: "The tubes descend 91 to 95 feet (28 to 29 m) below the mean high water level of the East River, with a maximum gradient of 3.1 percent." 28.5 m below 0.6 m, taken as the rail (the article does not say tube or rail: about 1 m apart)',
  },
  // Cranberry Street Tunnel (A C), Fulton St to High St.
  'A38|A40': {
    altitude: MEAN_HIGH_WATER_M - 27,
    source: 'published',
    note: 'Wikipedia, High Street station: "the tunnel is 90 feet (27 m) below the surface at its lowest point", read as the river surface (mean high water); the article does not say which surface',
  },
};

/** The depth rule for a station: its own entry, else the default. */
export function stationDepth(id: string): StationDepth {
  return STATION_DEPTHS[id] ?? { depth: DEFAULT_STATION_DEPTH_M, source: 'estimated', note: 'cut-and-cover default' };
}

/** The tube's low point for the station pair `a`, `b` (either order). */
export function tubeLow(a: string, b: string): TubeLow {
  return (
    TUBE_LOWS[[a, b].sort().join('|')] ?? {
      altitude: DEFAULT_TUBE_LOW_M,
      source: 'estimated',
      note: "Joralemon Street Tunnel's low point, the only river tube with a published figure besides Cranberry St",
    }
  );
}

/** Linear interpolation of [x, value] knots sorted by x; flat beyond the first and last. */
export function interpolate(knots: readonly (readonly [number, number])[], x: number): number {
  if (x <= knots[0][0]) return knots[0][1];
  for (let i = 1; i < knots.length; i++) {
    if (x <= knots[i][0]) {
      const span = knots[i][0] - knots[i - 1][0];
      return span > 0 ? knots[i - 1][1] + ((x - knots[i - 1][0]) / span) * (knots[i][1] - knots[i - 1][1]) : knots[i][1];
    }
  }
  return knots[knots.length - 1][1];
}

/**
 * A run of `samples` ([along, ground elevation]) at or below WATER_M, or with no data (a non-finite elevation), for
 * at least MIN_CROSSING_M: [from, to] along.
 */
export function waterCrossings(samples: readonly (readonly [number, number])[]): [number, number][] {
  const found: [number, number][] = [];
  let start: number | undefined;
  for (let i = 0; i <= samples.length; i++) {
    const wet = i < samples.length && !(samples[i][1] > WATER_M);
    if (wet && start === undefined) start = i;
    if (!wet && start !== undefined) {
      // The crossing runs from the last dry sample to the first dry one after it: halfway to each.
      const from = start > 0 ? (samples[start - 1][0] + samples[start][0]) / 2 : samples[start][0];
      const to = i < samples.length ? (samples[i - 1][0] + samples[i][0]) / 2 : samples[i - 1][0];
      if (to - from >= MIN_CROSSING_M) found.push([from, to]);
      start = undefined;
    }
  }
  return found;
}

/** One end of an underground range: a station (rail altitude from its depth) or a portal (the stretch's end height). */
export interface RangeEnd {
  altitude: number;
  /** True when the altitude is rule-based. */
  estimated: boolean;
  portal: boolean;
}

export interface RangeLow {
  /** Meters from the range's start. */
  x: number;
  altitude: number;
  estimated: boolean;
}

export interface RangeSpec {
  /** Meters of track. */
  length: number;
  start: RangeEnd;
  end: RangeEnd;
  /** Ground elevation, meters, `x` meters from the start. */
  ground: (x: number) => number;
  /** Low points of river tubes inside the range. */
  lows: RangeLow[];
}

export interface Clamp {
  kind: 'cover' | 'grade' | 'tube' | 'portal' | 'steep';
  /** Meters from the range's start, first and last affected. */
  from: number;
  to: number;
  /** The largest change to the altitude (meters); for `steep` the grade that could not be held (as a fraction). */
  amount: number;
}

export interface RangeProfile {
  /** [x, rail altitude] knots, linear in between, simplified to KNOT_TOLERANCE_M. */
  knots: [number, number][];
  /** [x, estimated] of every control the profile follows: the ends, tube lows, and the baseline at a portal. */
  controls: { x: number; estimated: boolean }[];
  clamps: Clamp[];
}

export const PROFILE_STEP_M = 25;
export const KNOT_TOLERANCE_M = 0.15;
/** A clamp that moves the altitude by less than this isn't worth reporting. */
const CLAMP_MIN_M = 0.05;

/**
 * Rail altitude along an underground range:
 * 1. Baseline: linear between the controls: the range's ends (a station's altitude, or at a portal the ground less
 *    DEFAULT_STATION_DEPTH_M, the tunnel altitude the ramp below meets) and the low points of any river tubes. A low
 *    point is raised if either end would need more than MAX_GRADE to reach it.
 * 2. Never above the ground less COVER_M, and then no steeper than MAX_GRADE (only ever lowering, so the cover holds).
 * 3. Both ends are pinned (a station's altitude, a portal's stretch height): the baseline is held inside the cone
 *    of +-MAX_GRADE around each pin, which is the ramp from a portal and keeps stations at their altitude. If the two
 *    pins are too close for their heights (a portal near a station), the range runs straight between them, steeper
 *    than MAX_GRADE, and says so; any tube low point in it is dropped, and reported as a `tube` clamp.
 */
export function railProfile(spec: RangeSpec): RangeProfile {
  const { length, start, end } = spec;
  const clamps: Clamp[] = [];
  const g = MAX_GRADE;

  const baseAt = (end_: RangeEnd, x: number): { altitude: number; estimated: boolean } =>
    end_.portal ? { altitude: spec.ground(x) - DEFAULT_STATION_DEPTH_M, estimated: true } : { altitude: end_.altitude, estimated: end_.estimated };
  const s0 = baseAt(start, 0);
  const s1 = baseAt(end, length);
  const controls = [{ x: 0, altitude: s0.altitude, estimated: s0.estimated }];
  for (const low of [...spec.lows].sort((a, b) => a.x - b.x)) {
    const needed = Math.max(start.altitude - g * low.x, end.altitude - g * (length - low.x));
    const altitude = Math.max(low.altitude, needed);
    if (altitude > low.altitude + CLAMP_MIN_M) clamps.push({ kind: 'tube', from: low.x, to: low.x, amount: altitude - low.altitude });
    controls.push({ x: low.x, altitude, estimated: low.estimated });
  }
  controls.push({ x: length, altitude: s1.altitude, estimated: s1.estimated });
  const knots = controls.map((c) => [c.x, c.altitude] as const);

  const n = Math.max(1, Math.ceil(length / PROFILE_STEP_M));
  const xs = Array.from({ length: n + 1 }, (_, i) => (i === n ? length : i * PROFILE_STEP_M));
  const alt = xs.map((x) => interpolate(knots, x));
  const note = (kind: Clamp['kind'], i: number, amount: number) => {
    if (amount < CLAMP_MIN_M) return;
    const last = clamps[clamps.length - 1];
    if (last && last.kind === kind && xs[i] - last.to <= PROFILE_STEP_M + 1e-6) {
      last.to = xs[i];
      last.amount = Math.max(last.amount, amount);
    } else clamps.push({ kind, from: xs[i], to: xs[i], amount });
  };

  for (let i = 0; i < xs.length; i++) {
    const cap = spec.ground(xs[i]) - COVER_M;
    if (alt[i] > cap) {
      note('cover', i, alt[i] - cap);
      alt[i] = cap;
    }
  }
  for (let i = 1; i < xs.length; i++) {
    const limit = alt[i - 1] + g * (xs[i] - xs[i - 1]);
    if (alt[i] > limit) {
      note('grade', i, alt[i] - limit);
      alt[i] = limit;
    }
  }
  for (let i = xs.length - 2; i >= 0; i--) {
    const limit = alt[i + 1] + g * (xs[i + 1] - xs[i]);
    if (alt[i] > limit) {
      note('grade', i, alt[i] - limit);
      alt[i] = limit;
    }
  }

  const pins: [number, number][] = [
    [0, start.altitude],
    [length, end.altitude],
  ];
  const feasible = xs.every((x) => Math.max(...pins.map(([px, pa]) => pa - g * Math.abs(x - px))) <= Math.min(...pins.map(([px, pa]) => pa + g * Math.abs(x - px))) + 1e-9);
  if (!feasible) {
    clamps.push({ kind: 'steep', from: 0, to: length, amount: Math.abs(start.altitude - end.altitude) / Math.max(length, 1) });
    for (let i = 0; i < xs.length; i++) alt[i] = start.altitude + (xs[i] / Math.max(length, 1e-9)) * (end.altitude - start.altitude);
    // The straight line drops any river tube's low point: report each one (by how far the rail now runs above it).
    for (const low of spec.lows) {
      const straight = start.altitude + (low.x / Math.max(length, 1e-9)) * (end.altitude - start.altitude);
      clamps.push({ kind: 'tube', from: low.x, to: low.x, amount: Math.max(0, straight - low.altitude) });
    }
  } else {
    for (let i = 0; i < xs.length; i++) {
      const lo = Math.max(...pins.map(([px, pa]) => pa - g * Math.abs(xs[i] - px)));
      const hi = Math.min(...pins.map(([px, pa]) => pa + g * Math.abs(xs[i] - px)));
      const held = Math.min(Math.max(alt[i], lo), hi);
      note('portal', i, Math.abs(held - alt[i]));
      alt[i] = held;
    }
  }

  const kept = simplifyProfile(xs, alt, KNOT_TOLERANCE_M);
  return {
    knots: kept.map((i) => [xs[i], Math.round(alt[i] * 100) / 100]),
    controls: controls.map((c) => ({ x: c.x, estimated: c.estimated })),
    clamps,
  };
}

/** Douglas-Peucker on (x, altitude) with a vertical tolerance; indices of the kept samples. */
export function simplifyProfile(xs: readonly number[], alt: readonly number[], tolerance: number): number[] {
  const kept = new Set<number>([0, xs.length - 1]);
  const stack: [number, number][] = [[0, xs.length - 1]];
  while (stack.length > 0) {
    const [s, e] = stack.pop()!;
    let worst = -1;
    let worstD = tolerance;
    for (let i = s + 1; i < e; i++) {
      const f = (xs[i] - xs[s]) / (xs[e] - xs[s]);
      const d = Math.abs(alt[i] - (alt[s] + f * (alt[e] - alt[s])));
      if (d > worstD) {
        worst = i;
        worstD = d;
      }
    }
    if (worst >= 0) {
      kept.add(worst);
      stack.push([s, worst], [worst, e]);
    }
  }
  return [...kept].sort((a, b) => a - b);
}

/** True when any control the profile follows between `from` and `to` (and the ones bracketing them) is rule-based. */
export function estimatedBetween(profile: RangeProfile, from: number, to: number): boolean {
  const cs = profile.controls;
  let lo = 0;
  for (let i = 0; i < cs.length; i++) if (cs[i].x <= from + 1e-6) lo = i;
  let hi = cs.length - 1;
  for (let i = cs.length - 1; i >= 0; i--) if (cs[i].x >= to - 1e-6) hi = i;
  return cs.slice(lo, hi + 1).some((c) => c.estimated);
}
