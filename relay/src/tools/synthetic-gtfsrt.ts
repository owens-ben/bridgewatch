import { IN_TRANSIT_TO, INCOMING_AT, STOPPED_AT } from '../gtfsrt';
import { ProtoWriter } from './protobuf-writer';

/**
 * Encodes synthetic GTFS-realtime feeds from a readable description, byte-compatible with the shape of NYCT's subway
 * feeds: the standard fields the relay reads, the fields it skips (stop sequences, delays, schedule relationships) and
 * NYCT's extensions (field 1001 on the header, the trip descriptor and the stop time update; nyct-subway.proto).
 * Field numbers are from gtfs-realtime.proto (https://gtfs.org/documentation/realtime/proto/). Nothing is copied from
 * a provider's feed: the scenario (subway-scenario.ts) invents every trip, time and train.
 */

export type VehicleStatus = 'incoming' | 'stopped' | 'transit';

const STATUS_CODE: Record<VehicleStatus, number> = { incoming: INCOMING_AT, stopped: STOPPED_AT, transit: IN_TRANSIT_TO };

export interface StopSpec {
  /** Omitted from the encoding when undefined (an odd update the parser must skip). */
  stopId?: string;
  /** Seconds since the epoch; undefined leaves the arrival event out, `null` writes an event with no time. */
  arrival?: number | null;
  departure?: number | null;
  /** StopTimeEvent.delay and .uncertainty, as the L feed sends them (the relay skips both). */
  delay?: number;
  uncertainty?: number;
  /** StopTimeUpdate.stop_sequence (field 1) and schedule_relationship (field 5), as the L feed sends them. */
  sequence?: number;
  /** NYCT's stop time update extension: scheduled and actual track. */
  tracks?: [scheduled: string, actual?: string];
}

export interface VehicleSpec {
  /** VehiclePosition.stop_id; undefined leaves it out. */
  stopId?: string;
  /** Undefined leaves current_status out (the proto's default is IN_TRANSIT_TO). */
  status?: VehicleStatus;
  /** Seconds since the epoch; undefined leaves it out. */
  timestamp?: number;
  /** current_stop_sequence (field 3), which the relay skips. */
  sequence?: number;
  entityId: string;
  /** Leave the trip descriptor's trip_id out of the vehicle (an orphan vehicle). */
  noTripId?: boolean;
}

export interface TripSpec {
  tripId?: string;
  routeId?: string;
  /** TripDescriptor.start_time and start_date (fields 2 and 3). */
  startTime?: string;
  startDate?: string;
  /** NYCT's trip descriptor extension: train id, is_assigned, direction (1 north, 3 south). */
  nyct?: { trainId: string; assigned?: boolean; direction?: 1 | 3 };
  /** TripDescriptor.direction_id and schedule_relationship, as the L feed sends them (skipped by the relay). */
  lStyle?: boolean;
  entityId: string;
  stops: StopSpec[];
  /** No trip update entity at all: only the vehicle (an orphan the relay must ignore). */
  noTripUpdate?: boolean;
  /** FeedEntity.is_deleted: the relay drops such an entity. */
  deleted?: boolean;
  vehicle?: VehicleSpec;
}

export interface FeedSpec {
  /** Header timestamp, seconds since the epoch; undefined leaves it out. */
  timestamp?: number;
  /** Header.incrementality: sent by the L and G feeds, absent from the others. */
  incrementality?: number;
  /** NYCT's header extension: replacement periods per route, ending at the given time. */
  replacement?: { routes: string[]; start?: number; end: number };
  trips: TripSpec[];
  /** Entities of kinds the relay doesn't read (alerts, field 5), by entity ID. */
  alerts?: string[];
  /** Trailing unknown top-level field, to prove a parser skips it. */
  trailer?: boolean;
}

function writeEvent(w: ProtoWriter, field: number, time: number | null | undefined, delay?: number, uncertainty?: number) {
  if (time === undefined) return;
  w.message(field, (e) => {
    if (delay !== undefined) e.int32(1, delay);
    if (time !== null) e.varint(2, time);
    if (uncertainty !== undefined) e.int32(3, uncertainty);
  });
}

function writeTrip(w: ProtoWriter, t: TripSpec, noTripId = false) {
  w.message(1, (d) => {
    if (t.tripId !== undefined && !noTripId) d.string(1, t.tripId);
    if (t.startTime !== undefined) d.string(2, t.startTime);
    if (t.startDate !== undefined) d.string(3, t.startDate);
    if (t.lStyle) d.int32(4, 0);
    if (t.routeId !== undefined) d.string(5, t.routeId);
    if (t.lStyle) d.int32(6, 0);
    if (t.nyct) {
      const n = t.nyct;
      d.message(1001, (x) => {
        x.string(1, n.trainId).bool(2, n.assigned ?? true);
        if (n.direction !== undefined) x.varint(3, n.direction);
      });
    }
  });
}

function writeTripUpdate(t: TripSpec): Uint8Array {
  return new ProtoWriter().message(3, (tu) => {
    writeTrip(tu, t);
    for (const s of t.stops) {
      tu.message(2, (u) => {
        if (s.sequence !== undefined) u.varint(1, s.sequence);
        writeEvent(u, 2, s.arrival, s.delay, s.uncertainty);
        writeEvent(u, 3, s.departure, s.delay, s.uncertainty);
        if (s.stopId !== undefined) u.string(4, s.stopId);
        if (s.sequence !== undefined) u.varint(5, 0);
        if (s.tracks) {
          const [scheduled, actual] = s.tracks;
          u.message(1001, (x) => {
            x.string(1, scheduled);
            if (actual !== undefined) x.string(2, actual);
          });
        }
      });
    }
  }).finish();
}

function writeVehicle(t: TripSpec, v: VehicleSpec): Uint8Array {
  return new ProtoWriter().message(4, (vp) => {
    writeTrip(vp, t, v.noTripId);
    if (v.sequence !== undefined) vp.varint(3, v.sequence);
    if (v.status !== undefined) vp.varint(4, STATUS_CODE[v.status]);
    if (v.timestamp !== undefined) vp.varint(5, v.timestamp);
    if (t.lStyle) vp.varint(6, 0);
    if (v.stopId !== undefined) vp.string(7, v.stopId);
  }).finish();
}

/** One feed as the wire format: header, then a trip update and a vehicle position entity per trip. */
export function encodeFeed(feed: FeedSpec): Uint8Array {
  const w = new ProtoWriter();
  w.message(1, (h) => {
    h.string(1, '1.0');
    if (feed.incrementality !== undefined) h.varint(2, feed.incrementality);
    if (feed.timestamp !== undefined) h.varint(3, feed.timestamp);
    const r = feed.replacement;
    if (r) {
      h.message(1001, (x) => {
        x.string(1, '1.0');
        for (const route of r.routes) {
          x.message(2, (p) =>
            p.string(1, route).message(2, (range) => {
              if (r.start !== undefined) range.varint(1, r.start);
              range.varint(2, r.end);
            }),
          );
        }
      });
    }
  });
  for (const t of feed.trips) {
    if (!t.noTripUpdate) {
      w.message(2, (e) => {
        e.string(1, t.entityId);
        if (t.lStyle) e.varint(2, 0);
        if (t.deleted) e.varint(2, 1);
        e.raw(writeTripUpdate(t));
      });
    }
    if (t.vehicle) {
      const v = t.vehicle;
      w.message(2, (e) => {
        e.string(1, v.entityId);
        if (t.lStyle) e.varint(2, 0);
        e.raw(writeVehicle(t, v));
      });
    }
  }
  for (const id of feed.alerts ?? []) w.message(2, (e) => e.string(1, id).message(5, (a) => a.string(1, 'synthetic alert')));
  if (feed.trailer) w.varint(15, 1);
  return w.finish();
}
