import { forEachField, ProtoError, ProtoReader, WIRE_LEN, WIRE_VARINT, type Tag } from './protobuf';

/**
 * The few GTFS-realtime fields the subway estimator uses, decoded from the wire format. Field numbers are from
 * gtfs-realtime.proto (https://gtfs.org/documentation/realtime/proto/). Everything else is skipped, including
 * alerts and NYCT's extensions (field 1001 on the header, trip descriptor and stop time update; nyct-subway.proto).
 */

export interface TripDescriptor {
  tripId?: string;
  routeId?: string;
  startTime?: string;
  startDate?: string;
}

export interface StopTimeUpdate {
  stopId?: string;
  /** Predicted arrival, seconds since the Unix epoch. */
  arrival?: number;
  /** Predicted departure, seconds since the Unix epoch. */
  departure?: number;
}

export interface TripUpdate {
  trip: TripDescriptor;
  /** Remaining stops in order; NYCT drops a stop once the train has left it. */
  stopTimeUpdates: StopTimeUpdate[];
}

/** VehiclePosition.VehicleStopStatus. */
export const INCOMING_AT = 0;
export const STOPPED_AT = 1;
export const IN_TRANSIT_TO = 2;

export interface VehiclePosition {
  trip: TripDescriptor;
  /** INCOMING_AT, STOPPED_AT or IN_TRANSIT_TO; the proto's default is IN_TRANSIT_TO. */
  currentStatus: number;
  stopId?: string;
  /** Seconds since the Unix epoch. */
  timestamp?: number;
}

export interface FeedEntity {
  id: string;
  tripUpdate?: TripUpdate;
  vehicle?: VehiclePosition;
}

export interface FeedMessage {
  /** Seconds since the Unix epoch. */
  timestamp?: number;
  entities: FeedEntity[];
}

export { ProtoError as GtfsRtError };

const isLen = (t: Tag) => t.wire === WIRE_LEN;
const isVarint = (t: Tag) => t.wire === WIRE_VARINT;

function decodeTrip(r: ProtoReader): TripDescriptor {
  const trip: TripDescriptor = {};
  forEachField(r, (t, r) => {
    if (!isLen(t)) return false;
    if (t.field === 1) trip.tripId = r.string();
    else if (t.field === 2) trip.startTime = r.string();
    else if (t.field === 3) trip.startDate = r.string();
    else if (t.field === 5) trip.routeId = r.string();
    else return false;
    return true;
  });
  return trip;
}

/** StopTimeEvent.time (field 2, int64). Zero means not set. */
function decodeEventTime(r: ProtoReader): number | undefined {
  let time: number | undefined;
  forEachField(r, (t, r) => {
    if (t.field !== 2 || !isVarint(t)) return false;
    time = r.uint();
    return true;
  });
  return time ? time : undefined;
}

function decodeStopTimeUpdate(r: ProtoReader): StopTimeUpdate {
  const u: StopTimeUpdate = {};
  forEachField(r, (t, r) => {
    if (!isLen(t)) return false;
    if (t.field === 2) u.arrival = decodeEventTime(r.message());
    else if (t.field === 3) u.departure = decodeEventTime(r.message());
    else if (t.field === 4) u.stopId = r.string();
    else return false;
    return true;
  });
  return u;
}

function decodeTripUpdate(r: ProtoReader): TripUpdate {
  const u: TripUpdate = { trip: {}, stopTimeUpdates: [] };
  forEachField(r, (t, r) => {
    if (!isLen(t)) return false;
    if (t.field === 1) u.trip = decodeTrip(r.message());
    else if (t.field === 2) u.stopTimeUpdates.push(decodeStopTimeUpdate(r.message()));
    else return false;
    return true;
  });
  return u;
}

function decodeVehicle(r: ProtoReader): VehiclePosition {
  const v: VehiclePosition = { trip: {}, currentStatus: IN_TRANSIT_TO };
  forEachField(r, (t, r) => {
    if (t.field === 1 && isLen(t)) v.trip = decodeTrip(r.message());
    else if (t.field === 4 && isVarint(t)) v.currentStatus = r.uint();
    else if (t.field === 5 && isVarint(t)) v.timestamp = r.uint();
    else if (t.field === 7 && isLen(t)) v.stopId = r.string();
    else return false;
    return true;
  });
  return v;
}

function decodeEntity(r: ProtoReader): FeedEntity | undefined {
  const e: FeedEntity = { id: '' };
  let deleted = false;
  forEachField(r, (t, r) => {
    if (t.field === 1 && isLen(t)) e.id = r.string();
    else if (t.field === 2 && isVarint(t)) deleted = r.bool();
    else if (t.field === 3 && isLen(t)) e.tripUpdate = decodeTripUpdate(r.message());
    else if (t.field === 4 && isLen(t)) e.vehicle = decodeVehicle(r.message());
    else return false;
    return true;
  });
  return deleted ? undefined : e;
}

/** Decodes a GTFS-realtime FeedMessage. Throws GtfsRtError (ProtoError) on malformed input. */
export function decodeFeedMessage(buf: Uint8Array): FeedMessage {
  const feed: FeedMessage = { entities: [] };
  forEachField(new ProtoReader(buf), (t, r) => {
    if (t.field === 1 && isLen(t)) {
      forEachField(r.message(), (h, hr) => {
        if (h.field !== 3 || !isVarint(h)) return false;
        feed.timestamp = hr.uint();
        return true;
      });
    } else if (t.field === 2 && isLen(t)) {
      const entity = decodeEntity(r.message());
      if (entity) feed.entities.push(entity);
    } else {
      return false;
    }
    return true;
  });
  return feed;
}
