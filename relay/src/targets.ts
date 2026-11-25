import type { VesselExtras } from './types';

/** What a target is (PROTOCOL.md, "Target"). Clients skip kinds they don't know. */
export type TargetKind = 'vessel' | 'train';

/** The `vessel` object of a vessel target. */
export interface VesselDetails extends VesselExtras {
  mmsi: number;
  shipType?: number;
}

/** The `train` object of a train target. */
export interface TrainDetails {
  route: string;
  /** NYCT's railroad direction (the stop ID suffix), not a compass direction. */
  direction: 'N' | 'S';
  destination?: string;
  /** The named above-ground stretch the train is on; omitted underground. */
  stretch?: string;
  underground: boolean;
  /** True when the target's `altitude` is rule-based (a default depth), false when measured or published. */
  altitudeEstimated: boolean;
}

/** One tracked object, whatever its source (PROTOCOL.md, "Target"). Every message carries its full state. */
export interface Target {
  /** `<kind>:<id>`, the same whichever source reports the object (e.g. `vessel:<mmsi>`). */
  id: string;
  kind: TargetKind;
  /** The source plug-in that sent this state, e.g. `aisstream`. */
  source: string;
  name?: string;
  lat: number;
  lon: number;
  /** Meters above sea level. Omitted for objects on the water. */
  altitude?: number;
  /** Knots over ground. */
  speed?: number;
  /** Direction of travel, degrees true. */
  course?: number;
  /** Where the object points, degrees true. */
  heading?: number;
  /** ISO 8601 UTC with milliseconds: the time of the position. */
  timestamp: string;
  vessel?: VesselDetails;
  train?: TrainDetails;
}

/** Builds a Target with the key order PROTOCOL.md specifies; unknown keys are omitted, never null. */
export function makeTarget(f: Target): Target {
  const t: Partial<Target> = { id: f.id, kind: f.kind, source: f.source };
  if (f.name !== undefined) t.name = f.name;
  t.lat = f.lat;
  t.lon = f.lon;
  if (f.altitude !== undefined) t.altitude = f.altitude;
  if (f.speed !== undefined) t.speed = f.speed;
  if (f.course !== undefined) t.course = f.course;
  if (f.heading !== undefined) t.heading = f.heading;
  t.timestamp = f.timestamp;
  if (f.vessel !== undefined) {
    t.vessel = { mmsi: f.vessel.mmsi };
    const v = f.vessel;
    if (v.shipType !== undefined) t.vessel.shipType = v.shipType;
    if (v.imo !== undefined) t.vessel.imo = v.imo;
    if (v.callSign !== undefined) t.vessel.callSign = v.callSign;
    if (v.destination !== undefined) t.vessel.destination = v.destination;
    if (v.eta !== undefined) t.vessel.eta = { month: v.eta.month, day: v.eta.day, hour: v.eta.hour, minute: v.eta.minute };
    if (v.length !== undefined) t.vessel.length = v.length;
    if (v.beam !== undefined) t.vessel.beam = v.beam;
    if (v.draught !== undefined) t.vessel.draught = v.draught;
    if (v.navStatus !== undefined) t.vessel.navStatus = v.navStatus;
  }
  if (f.train !== undefined) {
    const { route, direction, destination, stretch, underground, altitudeEstimated } = f.train;
    t.train = {
      route,
      direction,
      ...(destination === undefined ? {} : { destination }),
      ...(stretch === undefined ? {} : { stretch }),
      underground,
      altitudeEstimated,
    };
  }
  return t as Target;
}
