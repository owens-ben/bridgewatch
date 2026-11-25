export interface VesselUpdate {
  mmsi: number;
  name?: string;
  shipType?: number;
  lat: number;
  lon: number;
  sog?: number;
  cog?: number;
  heading?: number;
  timestamp: string;
}

/**
 * Vessel details only /v2/targets carries (PROTOCOL.md, "Vessels"). The normalizer returns them next to a
 * VesselUpdate, never inside it: /v1/vessels must stay as installed builds read it. Every key is optional.
 */
export interface VesselExtras {
  /** IMO number; AIS 0 = not available is omitted. */
  imo?: number;
  callSign?: string;
  destination?: string;
  eta?: { month: number; day: number; hour: number; minute: number };
  /** Meters, from AIS dimensions A + B. */
  length?: number;
  /** Meters, from AIS dimensions C + D. */
  beam?: number;
  /** Meters, one decimal. */
  draught?: number;
  /** AIS navigational status 0-14 (15 = not defined is omitted). */
  navStatus?: number;
}

/** One normalized AIS message: the VesselUpdate, the extras it carried, and whether /v1/vessels gets the update. */
export interface Normalized {
  update: VesselUpdate;
  extras?: VesselExtras;
  /** False for a message /v1 never saw (static data with nothing but extras): it only feeds /v2. */
  legacy: boolean;
}

export type Logger = (message: string) => void;

/** Builds a VesselUpdate with the key order PROTOCOL.md specifies; unknown keys are omitted, never null. */
export function makeVesselUpdate(f: VesselUpdate): VesselUpdate {
  const v: Partial<VesselUpdate> = { mmsi: f.mmsi };
  if (f.name !== undefined) v.name = f.name;
  if (f.shipType !== undefined) v.shipType = f.shipType;
  v.lat = f.lat;
  v.lon = f.lon;
  if (f.sog !== undefined) v.sog = f.sog;
  if (f.cog !== undefined) v.cog = f.cog;
  if (f.heading !== undefined) v.heading = f.heading;
  v.timestamp = f.timestamp;
  return v as VesselUpdate;
}
