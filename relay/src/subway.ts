import { STOPPED_AT, type FeedEntity, type FeedMessage, type TripUpdate, type VehiclePosition } from './gtfsrt';

/**
 * Estimates where subway trains are inside the app's area (PROTOCOL.md, "Trains"), above ground and underground.
 * NYCT's realtime feeds have no GPS: a train reports the station it last stood at, or is heading to, and when, plus
 * predicted times at the stations ahead. A train between two stations is placed along the track between them in
 * proportion to time, from its departure to its predicted arrival; for a train reported on its way to a station the
 * departure is derived from the static schedule (SubwayData.approaches).
 */

/**
 * A piece of a segment inside the app's area: `points` run from `from` to `to`, meters from the segment's station
 * `a`. A segment has several when its track leaves the area and comes back, or changes level.
 */
export interface TrackPart {
  /** True for every part that is not on a named above-ground stretch. */
  underground: boolean;
  /** The named above-ground stretch (a `SubwayStretch` ID); set exactly when the part is not underground. */
  stretch?: string;
  from: number;
  to: number;
  /**
   * [lat, lon, track height in meters above sea level]. Underground the height is the extract's depth model (rail below
   * the street at each station, river tubes, ramps at portals: src/tools/depth.ts), so it can be negative.
   */
  points: (readonly [number, number, number])[];
  /**
   * True when the heights of this part follow rule-based figures (a default station depth, a tube's estimated low
   * point, hand-estimated stretch heights), false when published or measured. Absent counts as false.
   */
  altitudeEstimated?: boolean;
}

/**
 * The track between two consecutive stations (of any route's scheduled trips), in either direction. Only segments
 * with a part inside the area are kept; `length` is the whole track between the stations, also outside the area.
 */
export interface TrackSegment {
  a: string;
  b: string;
  /** Meters along the track from `a` to `b`. */
  length: number;
  parts: TrackPart[];
}

export interface SubwayStretch {
  id: string;
  name: string;
}

/** Where a route's trains in one direction come from into a station, per the static schedule. */
export interface Approach {
  /** The station before it. */
  from: string;
  /** Typical seconds from leaving `from` to arriving (median of the schedule's trips). */
  seconds: number;
  /** Scheduled trips that run it, to tell the usual approach from a rare one. */
  trips: number;
}

export interface SubwayData {
  stretches: SubwayStretch[];
  /** IDs of the routes whose scheduled trips run on track inside the area. */
  routes: string[];
  /** Parent station ID (e.g. "D43") to name, for every station where a scheduled trip of these routes ends. */
  terminals: Record<string, string>;
  segments: TrackSegment[];
  /**
   * For each station a segment touches, the stations trains come from into it, most trips first, under two keys:
   * "shape|station" (the stopping pattern: realtime trip IDs end in the static shape ID, e.g. 101450_F..S54R) and
   * "route|N|station" (or S). The realtime feeds drop a station once the train has left it, so this is where a train
   * reported on its way to a station was before.
   */
  approaches: Record<string, Approach[]>;
}

/** One estimated train; the mta-subway source publishes it as a target (PROTOCOL.md, "Trains"). */
export interface TrainEstimate {
  tripId: string;
  route: string;
  direction: 'N' | 'S';
  destination?: string;
  /** The named above-ground stretch the train is on; absent underground. */
  stretch?: string;
  underground: boolean;
  lat: number;
  lon: number;
  /** Track height, meters above sea level; underground it is the modelled rail altitude, below sea level in places. */
  altitude: number;
  /** True when `altitude` is rule-based rather than measured or published (TrackPart.altitudeEstimated). */
  altitudeEstimated: boolean;
  /** Direction of travel along the track, degrees true. */
  bearing: number;
  /** Knots, like VesselUpdate.sog; 0 while stopped at a station. */
  speed: number;
  timestamp: string;
}

/** How often the relay re-estimates and sends trains, from the latest feeds (polled every 30 s). */
export const TRAINS_INTERVAL_MS = 10_000;
/** Assumed stop at each predicted station: NYCT predicts arrival = departure, and its run times include the dwell. */
export const DWELL_SECONDS = 30;
/** A train whose last station report is older than this is not trusted (stalled data, or a trip that ended). */
export const MAX_REPORT_AGE_SECONDS = 20 * 60;
/** A feed older than this is ignored: its predictions have drifted too far to place trains. */
export const MAX_FEED_AGE_SECONDS = 180;
/**
 * Share of the scheduled trips into a station a single previous station must have for a route (or stopping pattern) to
 * go by it: where trips come from two different ways about equally often, a train reported on its way there is
 * placed on neither.
 */
export const MIN_APPROACH_SHARE = 0.75;
/** How far a station report may lie in the relay's future and still count as clock skew rather than a prediction. */
export const MAX_CLOCK_SKEW_SECONDS = 30;

const KNOTS_PER_MPS = 3600 / 1852;
const EARTH_RADIUS_M = 6_371_008.8;
const RAD = Math.PI / 180;

/** Meters between two points (equirectangular; exact enough over a few kilometers). */
export function metersBetween(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const x = (lon2 - lon1) * RAD * Math.cos(((lat1 + lat2) / 2) * RAD);
  const y = (lat2 - lat1) * RAD;
  return Math.hypot(x, y) * EARTH_RADIUS_M;
}

/** Initial bearing from one point to another, degrees true in [0, 360). */
export function bearingBetween(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const p1 = lat1 * RAD;
  const p2 = lat2 * RAD;
  const dl = (lon2 - lon1) * RAD;
  const y = Math.sin(dl) * Math.cos(p2);
  const x = Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dl);
  const deg = (Math.atan2(y, x) / RAD + 360) % 360;
  return deg >= 360 ? 0 : deg;
}

const round = (v: number, places: number) => Math.round(v * 10 ** places) / 10 ** places;

/** A point on the track. */
interface TrackPoint {
  lat: number;
  lon: number;
  altitude: number;
  /** Degrees true, in the segment's a -> b direction. */
  bearing: number;
}

interface IndexedPart extends TrackPart {
  /** Cumulative polyline distance at each point, scaled so the last equals `to - from`. */
  cumulative: number[];
}

interface IndexedSegment extends TrackSegment {
  parts: IndexedPart[];
}

interface Located {
  segment: IndexedSegment;
  reversed: boolean;
}

/** Where a train is: at `point` on `part`. */
interface Placed {
  point: TrackPoint;
  part: IndexedPart;
  speedMps: number;
}

function indexPart(part: TrackPart): IndexedPart {
  const cumulative = [0];
  for (let i = 1; i < part.points.length; i++) {
    const [la1, lo1] = part.points[i - 1];
    const [la2, lo2] = part.points[i];
    cumulative.push(cumulative[i - 1] + metersBetween(la1, lo1, la2, lo2));
  }
  const total = cumulative[cumulative.length - 1];
  const span = part.to - part.from;
  return { ...part, cumulative: cumulative.map((c) => (total > 0 ? (c / total) * span : 0)) };
}

/** The point `along` meters from the part's start (clamped to the part). */
function pointOnPart(part: IndexedPart, along: number): TrackPoint {
  const c = part.cumulative;
  const pts = part.points;
  if (pts.length === 1) return { lat: pts[0][0], lon: pts[0][1], altitude: pts[0][2], bearing: 0 };
  const u = Math.min(Math.max(along, 0), c[c.length - 1]);
  let i = 1;
  while (i < c.length - 1 && c[i] < u) i++;
  const [la1, lo1, h1] = pts[i - 1];
  const [la2, lo2, h2] = pts[i];
  const f = c[i] > c[i - 1] ? (u - c[i - 1]) / (c[i] - c[i - 1]) : 0;
  return {
    lat: la1 + f * (la2 - la1),
    lon: lo1 + f * (lo2 - lo1),
    altitude: h1 + f * (h2 - h1),
    bearing: bearingBetween(la1, lo1, la2, lo2),
  };
}

/** One stop of a trip's timeline, seconds since the epoch. */
interface TimelineStop {
  station: string;
  arrival: number;
  departure: number;
}

const stationOf = (stopId: string) => stopId.replace(/[NS]$/, '');

function directionOf(stopId: string | undefined): 'N' | 'S' | undefined {
  const c = stopId?.slice(-1);
  return c === 'N' || c === 'S' ? c : undefined;
}

/**
 * The trip's stops from the station it last reported onward. NYCT reports a running train as STOPPED_AT the last
 * station it stood at: while it stands there the report's time is refreshed every half minute or so, and once it
 * leaves, the station drops out of the trip update and the time stops changing, so it is about the departure time.
 *
 * - Reported at a station still listed (the first one left, after dropping stale ones before it): it's standing there,
 *   and stays until a newer feed says it left. NYCT can't predict departures either (it keeps predicting "leaves
 *   now"), so guessing a dwell only makes held trains wander onto bridges and jump back.
 * - Reported at a station no longer listed: it left at the report's time for the first listed stop.
 * - Later stops are predictions with arrival = departure; each gets a dwell of DWELL_SECONDS, at most a third of the
 *   run to the next one, so a train that's due somewhere doesn't skip the stop.
 *
 * A train reported IN_TRANSIT_TO (or INCOMING_AT) a station is on its way there from the station before it, which
 * the trip update no longer lists, so `approach` says which it is (from the static schedule: SubwayData.approaches) and
 * how long the run takes there. The report's time is when the report was made, not the departure; the train left
 * the station before at about the predicted arrival less the scheduled run time, but no later than the report:
 * a train in transit has left. The listed stop it's heading to (the first at or after it, earlier ones are stale)
 * is the arrival, and the later stops go as above. Position is linear in time from there to the arrival, so it
 * only advances as `now` does and never passes the station before the predicted arrival.
 *
 * Undefined when the train's place can't be known: no report, a trip that hasn't left its terminal yet (reported
 * IN_TRANSIT_TO with a time in the future), a report older than MAX_REPORT_AGE_SECONDS, or a train in transit whose
 * target isn't listed or whose previous station is unknown.
 */
function timeline(
  trip: TripUpdate,
  vehicle: VehiclePosition | undefined,
  now: number,
  approach: Approach | undefined,
): TimelineStop[] | undefined {
  if (!vehicle?.stopId || vehicle.timestamp === undefined) return undefined;
  const inTransit = vehicle.currentStatus !== STOPPED_AT;
  if (inTransit && !approach) return undefined;
  // A report from the future is a prediction, unless it's only clock skew.
  if (vehicle.timestamp > now + MAX_CLOCK_SKEW_SECONDS) return undefined;
  const reportedAt = Math.min(vehicle.timestamp, now);
  if (now - reportedAt > MAX_REPORT_AGE_SECONDS) return undefined;
  const stops: TimelineStop[] = [];
  for (const u of trip.stopTimeUpdates) {
    const arrival = u.arrival ?? u.departure;
    if (!u.stopId || arrival === undefined) continue;
    stops.push({ station: stationOf(u.stopId), arrival, departure: Math.max(arrival, u.departure ?? arrival) });
  }
  if (stops.length === 0) return undefined;

  const reported = stationOf(vehicle.stopId);
  const k = stops.findIndex((s) => s.station === reported);
  if (inTransit) {
    if (k < 0) return undefined; // heading to a station with no predicted arrival: nothing to place it by
    stops.splice(0, k);
    const departure = Math.min(stops[0].arrival - approach!.seconds, reportedAt);
    stops.unshift({ station: approach!.from, arrival: departure, departure });
  } else if (k >= 0) {
    stops.splice(0, k); // stops listed before the reported one are stale: it has passed them
    stops[0].arrival = Math.min(stops[0].arrival, reportedAt);
    stops[0].departure = Infinity;
    return stops;
  } else {
    stops.unshift({ station: reported, arrival: reportedAt, departure: reportedAt });
  }
  // Predicted stops: times never run backwards, and each gets a short dwell.
  for (let i = 1; i < stops.length; i++) {
    const s = stops[i];
    s.arrival = Math.max(s.arrival, stops[i - 1].departure);
    const next = stops[i + 1]?.arrival;
    const dwell = next === undefined ? DWELL_SECONDS : Math.min(DWELL_SECONDS, Math.max(0, next - s.arrival) / 3);
    s.departure = Math.max(s.departure, s.arrival + dwell);
  }
  return stops;
}

/** Train positions from decoded NYCT feeds. Reusable across calls: it indexes the static data once. */
export class TrainEstimator {
  /** "A>B" to the segment between stations A and B; `reversed` when it's stored as B -> A. */
  private readonly segments = new Map<string, Located>();
  /** Stations that lie at the end of a part, for trains standing at them. */
  private readonly areaStations = new Map<string, Located>();

  constructor(private readonly data: SubwayData) {
    for (const s of data.segments) {
      const segment: IndexedSegment = { ...s, parts: s.parts.map(indexPart) };
      this.segments.set(`${s.a}>${s.b}`, { segment, reversed: false });
      this.segments.set(`${s.b}>${s.a}`, { segment, reversed: true });
      for (const part of segment.parts) {
        if (part.from <= 1 && !this.areaStations.has(s.a)) this.areaStations.set(s.a, { segment, reversed: false });
        if (part.to >= s.length - 1 && !this.areaStations.has(s.b)) this.areaStations.set(s.b, { segment, reversed: false });
      }
    }
  }

  /** Where `trip` is at `now` (seconds since the epoch), if it's on track inside the area. */
  estimate(trip: TripUpdate, vehicle: VehiclePosition | undefined, now: number): TrainEstimate | undefined {
    const route = trip.trip.routeId;
    const tripId = trip.trip.tripId;
    if (!route || !tripId) return undefined;
    const stops = timeline(trip, vehicle, now, this.approach(tripId, route, vehicle?.stopId));
    if (!stops) return undefined;
    const direction = directionOf(vehicle?.stopId) ?? directionOf(trip.stopTimeUpdates[0]?.stopId);
    if (!direction) return undefined;

    let placed: Placed | undefined;
    for (let i = 0; i < stops.length && !placed; i++) {
      const here = stops[i];
      if (now < here.arrival) return undefined; // before the first known stop: nowhere to place it
      if (now < here.departure) {
        placed = this.atStation(here.station, stops[i + 1]?.station, stops[i - 1]?.station);
        if (!placed) return undefined;
        break;
      }
      const next = stops[i + 1];
      if (next && now < next.arrival) {
        placed = this.between(here, next, now);
        if (!placed) return undefined;
      }
    }
    if (!placed) return undefined;

    const last = stops[stops.length - 1].station;
    const update: TrainEstimate = {
      tripId,
      route,
      direction,
      destination: this.data.terminals[last],
      stretch: placed.part.stretch,
      underground: placed.part.underground,
      lat: round(placed.point.lat, 6),
      lon: round(placed.point.lon, 6),
      altitude: round(placed.point.altitude, 1),
      altitudeEstimated: placed.part.altitudeEstimated ?? false,
      bearing: round(placed.point.bearing, 1) % 360,
      speed: round(placed.speedMps * KNOTS_PER_MPS, 1),
      timestamp: new Date(now * 1000).toISOString(),
    };
    if (update.destination === undefined) delete update.destination;
    if (update.stretch === undefined) delete update.stretch;
    return update;
  }

  /**
   * Every train inside the area at `nowMs`, sorted by trip ID. Feeds older than MAX_FEED_AGE_SECONDS are skipped. An
   * entity whose estimate throws is skipped and reported to `onError` with its trip ID (or `entity <id>` without one).
   */
  estimateAll(
    feeds: Iterable<FeedMessage>,
    nowMs: number,
    onError?: (tripId: string, err: unknown) => void,
  ): TrainEstimate[] {
    const now = nowMs / 1000;
    const trains: TrainEstimate[] = [];
    // One odd entity is skipped (and reported), never the whole set: the other trains still publish.
    const report = (e: FeedEntity, id: () => string | undefined, err: unknown) => {
      let name: string | undefined;
      try {
        name = id() || `entity ${e.id}`;
      } catch {
        name = 'unknown trip'; // too broken to name
      }
      onError?.(name, err);
    };
    for (const feed of feeds) {
      if (feed.timestamp === undefined || now - feed.timestamp > MAX_FEED_AGE_SECONDS) continue;
      const vehicles = new Map<string, VehiclePosition>();
      for (const e of feed.entities) {
        try {
          if (e.vehicle?.trip.tripId) vehicles.set(e.vehicle.trip.tripId, e.vehicle);
        } catch (err) {
          report(e, () => e.vehicle?.trip.tripId, err);
        }
      }
      for (const e of feed.entities) {
        try {
          if (!e.tripUpdate) continue;
          const train = this.estimate(e.tripUpdate, vehicles.get(e.tripUpdate.trip.tripId ?? ''), now);
          if (train) trains.push(train);
        } catch (err) {
          report(e, () => e.tripUpdate?.trip.tripId, err);
        }
      }
    }
    return trains.sort((a, b) => (a.tripId < b.tripId ? -1 : a.tripId > b.tripId ? 1 : 0));
  }

  /**
   * The station before `stopId` for a train heading there, and the scheduled run time: by the trip's stopping pattern
   * (the static shape ID ends the realtime trip ID) if the extract has it, else by its route and direction; undefined
   * when there is none or the schedule's trips come from two ways about equally often (MIN_APPROACH_SHARE).
   */
  private approach(tripId: string, route: string, stopId: string | undefined): Approach | undefined {
    const direction = directionOf(stopId);
    if (!stopId || !direction) return undefined;
    const station = stationOf(stopId);
    const shape = tripId.includes('_') ? tripId.slice(tripId.indexOf('_') + 1) : undefined;
    for (const key of [shape === undefined ? '' : `${shape}|${station}`, `${route}|${direction}|${station}`]) {
      const list = this.data.approaches[key];
      if (!list?.length) continue;
      const total = list.reduce((n, a) => n + a.trips, 0);
      return list[0].trips >= MIN_APPROACH_SHARE * total ? list[0] : undefined;
    }
    return undefined;
  }

  private between(from: TimelineStop, to: TimelineStop, now: number): Placed | undefined {
    const found = this.segments.get(`${from.station}>${to.station}`);
    if (!found) return undefined;
    const { segment, reversed } = found;
    const seconds = to.arrival - from.departure;
    if (seconds <= 0) return undefined;
    const traveled = ((now - from.departure) / seconds) * segment.length;
    const along = reversed ? segment.length - traveled : traveled;
    for (const part of segment.parts) {
      if (along < part.from || along > part.to) continue;
      const point = pointOnPart(part, along - part.from);
      if (reversed) point.bearing = (point.bearing + 180) % 360;
      return { point, part, speedMps: segment.length / seconds };
    }
    return undefined;
  }

  /**
   * A train standing at `station`, if the station is on a part. It faces along the segment it's about to
   * run, else the one it came in on; with neither known, along whichever segment ends there.
   */
  private atStation(station: string, next: string | undefined, previous: string | undefined): Placed | undefined {
    const options = [
      next === undefined ? undefined : this.segments.get(`${station}>${next}`),
      previous === undefined ? undefined : this.segments.get(`${previous}>${station}`),
      this.areaStations.get(station),
    ];
    for (const option of options) {
      if (!option) continue;
      const { segment, reversed } = option;
      const along = station === segment.a ? 0 : segment.length;
      const part = segment.parts.find((p) => along >= p.from - 1 && along <= p.to + 1);
      if (!part) continue;
      const point = pointOnPart(part, along - part.from);
      if (reversed) point.bearing = (point.bearing + 180) % 360;
      return { point, part, speedMps: 0 };
    }
    return undefined;
  }
}
