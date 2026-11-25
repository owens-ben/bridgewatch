import { makeVesselUpdate, type VesselExtras, type VesselUpdate } from './types';

export const EXPIRY_MS = 600_000;

/** One vessel's merged state. `posTs` is the time of its newest accepted position, `lastSeen` of its newest message. */
export interface VesselState {
  mmsi: number;
  name?: string;
  shipType?: number;
  lat: number;
  lon: number;
  sog?: number;
  cog?: number;
  heading?: number;
  /** Details for /v2/targets only; never in a /v1 snapshot. */
  extras: VesselExtras;
  posTs: number;
  lastSeen: number;
}

/** Merge + expiry per PROTOCOL.md "Merge rules". */
export class Registry {
  private readonly vessels = new Map<number, VesselState>();

  /**
   * `extras` are the update's vessel details (v2 only): each held key is replaced when the update carries it and
   * kept otherwise, never cleared. `navStatus` comes with positions, so it follows the position's age rule.
   */
  apply(u: VesselUpdate, extras?: VesselExtras): void {
    const ts = Date.parse(u.timestamp);
    if (Number.isNaN(ts)) return;
    let e = this.vessels.get(u.mmsi);
    if (!e) {
      e = { mmsi: u.mmsi, lat: u.lat, lon: u.lon, extras: {}, posTs: -Infinity, lastSeen: ts };
      this.vessels.set(u.mmsi, e);
    }
    if (u.name !== undefined) e.name = u.name;
    if (u.shipType !== undefined) e.shipType = u.shipType;
    if (extras) {
      const { navStatus, ...details } = extras;
      Object.assign(e.extras, details);
      if (navStatus !== undefined && ts >= e.posTs) e.extras.navStatus = navStatus;
    }
    if (ts >= e.posTs) {
      e.lat = u.lat;
      e.lon = u.lon;
      if (u.sog !== undefined) e.sog = u.sog;
      if (u.cog !== undefined) e.cog = u.cog;
      if (u.heading !== undefined) e.heading = u.heading;
      e.posTs = ts;
    }
    if (ts > e.lastSeen) e.lastSeen = ts;
  }

  /** The merged state of one vessel, or undefined if it has none. */
  get(mmsi: number): Readonly<VesselState> | undefined {
    return this.vessels.get(mmsi);
  }

  get size(): number {
    return this.vessels.size;
  }

  snapshot(nowMs: number): VesselUpdate[] {
    return [...this.vessels.values()]
      .filter((e) => nowMs - e.lastSeen <= EXPIRY_MS)
      .sort((a, b) => a.mmsi - b.mmsi)
      .map((e) => makeVesselUpdate({ ...e, timestamp: new Date(e.lastSeen).toISOString() }));
  }

  prune(nowMs: number): number {
    let removed = 0;
    for (const [mmsi, e] of this.vessels) {
      if (nowMs - e.lastSeen > EXPIRY_MS) {
        this.vessels.delete(mmsi);
        removed++;
      }
    }
    return removed;
  }
}
