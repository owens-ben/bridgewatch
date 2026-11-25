import { inBoundingBoxes } from './config';
import { makeVesselUpdate, type Normalized, type VesselExtras, type VesselUpdate } from './types';

type Json = Record<string, unknown>;

const isObj = (v: unknown): v is Json => typeof v === 'object' && v !== null && !Array.isArray(v);
const num = (v: unknown): number | undefined => (typeof v === 'number' && Number.isFinite(v) ? v : undefined);

const TIME_RE = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})(?:\.(\d+))? \+0000(?: UTC)?$/;
const MAX_HELD = 5000;

/**
 * A `time_utc` more than this far past the relay's receive time is not believed: the receive time is used instead,
 * as for a missing one. The registry keeps a vessel's newest position (src/registry.ts), so one frame stamped 2099
 * would otherwise freeze the boat (every real position after it is "older") and keep it from expiring. Clamping,
 * rather than dropping the frame, keeps showing boats if aisstream's clock runs ahead; a clamped bogus frame holds
 * back only real positions stamped before its receive time, i.e. for about aisstream's lag (seconds).
 */
export const MAX_FUTURE_MS = 60_000;

/** Parses '2026-11-10 14:00:05.123456789 +0000 UTC' to ISO with ms (fraction truncated). */
export function parseAisTime(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const m = TIME_RE.exec(value.trim());
  if (!m) return undefined;
  const [, y, mo, d, h, mi, s, frac] = m;
  const ms = frac ? Number(frac.slice(0, 3).padEnd(3, '0')) : 0;
  const date = new Date(Date.UTC(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(s), ms));
  if (Number.isNaN(date.getTime())) return undefined;
  // Reject overflowed fields (month 13, hour 24, ...): Date.UTC silently rolls them over.
  if (date.toISOString().slice(0, 19) !== `${y}-${mo}-${d}T${h}:${mi}:${s}`) return undefined;
  return date.toISOString();
}

/** A real position inside the app's area: anything else (swapped, 0/0, another ocean) is never published. */
function validPosition(lat: number | undefined, lon: number | undefined): lat is number {
  return lat !== undefined && lon !== undefined && Math.abs(lat) <= 90 && Math.abs(lon) <= 180 && inBoundingBoxes(lat, lon);
}

export function cleanName(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const t = value.replace(/^[@\s]+|[@\s]+$/g, '');
  return t === '' ? undefined : t;
}

/** AIS field lengths: a vessel name is 20 characters (ITU-R M.1371), a call sign 7, a destination 20. */
export const NAME_MAX = 20;
const CALL_SIGN_MAX = 7;
const DESTINATION_MAX = 20;

/**
 * Text from a boat's transponder is untrusted: control characters (newlines included) become spaces, invisible
 * format characters (bidi controls, zero-width) are dropped, whitespace runs collapse, AIS '@' and space padding is
 * trimmed, and the AIS field length caps it. Undefined if nothing is left.
 */
export function cleanText(value: unknown, maxLength: number): string | undefined {
  if (typeof value !== 'string') return undefined;
  const flat = value
    .replace(/[\p{Cc}\p{Zl}\p{Zp}]/gu, ' ')
    .replace(/\p{Cf}/gu, '')
    .replace(/\s+/g, ' ');
  const capped = Array.from(flat.replace(/^[@\s]+/, '')).slice(0, maxLength).join('');
  const t = capped.replace(/[@\s]+$/, '');
  return t === '' ? undefined : t;
}

const intIn = (v: unknown, min: number, max: number): number | undefined => {
  const n = num(v);
  return n !== undefined && Number.isInteger(n) && n >= min && n <= max ? n : undefined;
};

/** The static-data extras (PROTOCOL.md, "Vessels"): each only when valid, AIS "not available" values omitted. */
function staticExtras(s: Json): VesselExtras {
  const x: VesselExtras = {};
  const imo = intIn(s.ImoNumber, 1, 999_999_999);
  if (imo !== undefined) x.imo = imo;
  const callSign = cleanText(s.CallSign, CALL_SIGN_MAX);
  if (callSign !== undefined) x.callSign = callSign;
  const destination = cleanText(s.Destination, DESTINATION_MAX);
  if (destination !== undefined) x.destination = destination;
  if (isObj(s.Eta)) {
    const month = intIn(s.Eta.Month, 1, 12);
    const day = intIn(s.Eta.Day, 1, 31);
    const hour = intIn(s.Eta.Hour, 0, 23);
    const minute = intIn(s.Eta.Minute, 0, 59);
    if (month !== undefined && day !== undefined && hour !== undefined && minute !== undefined) {
      x.eta = { month, day, hour, minute };
    }
  }
  if (isObj(s.Dimension)) {
    const a = intIn(s.Dimension.A, 0, 511);
    const b = intIn(s.Dimension.B, 0, 511);
    const c = intIn(s.Dimension.C, 0, 63);
    const d = intIn(s.Dimension.D, 0, 63);
    if (a !== undefined && b !== undefined && a + b > 0) x.length = a + b;
    if (c !== undefined && d !== undefined && c + d > 0) x.beam = c + d;
  }
  // Rounded to a tenth first, then checked: 0.04 rounds to 0, which PROTOCOL.md says is omitted.
  const raw = num(s.MaximumStaticDraught);
  const draught = raw === undefined ? undefined : Math.round(raw * 10) / 10;
  if (draught !== undefined && draught > 0 && draught <= 25.5) x.draught = draught;
  return x;
}

const hasKeys = (x: object) => Object.keys(x).length > 0;

interface HeldStatic {
  mmsi: number;
  name?: string;
  shipType?: number;
  extras: VesselExtras;
  timestamp: string;
}

/** Stateful: remembers last positions and holds static data that arrives before any position is known. */
export class Normalizer {
  private readonly lastPos = new Map<number, { lat: number; lon: number }>();
  private readonly held = new Map<number, HeldStatic>();

  /** The VesselUpdates /v1/vessels carries, exactly as before extras existed. */
  normalize(raw: string, receivedAt: Date): VesselUpdate[] {
    return this.normalizeAll(raw, receivedAt)
      .filter((n) => n.legacy)
      .map((n) => n.update);
  }

  /** Every update with the extras it carried (for /v2/targets) and whether /v1 sees it. */
  normalizeAll(raw: string, receivedAt: Date): Normalized[] {
    let msg: unknown;
    try {
      msg = JSON.parse(raw);
    } catch {
      return [];
    }
    if (!isObj(msg)) return [];
    const meta = isObj(msg.MetaData) ? msg.MetaData : {};
    const body = isObj(msg.Message) ? msg.Message : {};
    const parsed = parseAisTime(meta.time_utc);
    const timestamp =
      parsed !== undefined && Date.parse(parsed) - receivedAt.getTime() <= MAX_FUTURE_MS ? parsed : receivedAt.toISOString();

    if (msg.MessageType === 'PositionReport' && isObj(body.PositionReport)) {
      return this.position(body.PositionReport, meta, timestamp);
    }
    if (msg.MessageType === 'ShipStaticData' && isObj(body.ShipStaticData)) {
      return this.static(body.ShipStaticData, meta, timestamp);
    }
    return [];
  }

  private mmsi(meta: Json, inner: Json): number | undefined {
    const m = num(meta.MMSI) ?? num(inner.UserID);
    return m !== undefined && Number.isInteger(m) && m > 0 ? m : undefined;
  }

  private position(p: Json, meta: Json, timestamp: string): Normalized[] {
    const mmsi = this.mmsi(meta, p);
    const lat = num(p.Latitude);
    const lon = num(p.Longitude);
    if (mmsi === undefined || !validPosition(lat, lon)) return [];
    const sog = num(p.Sog);
    const cog = num(p.Cog);
    const heading = num(p.TrueHeading);
    const update = makeVesselUpdate({
      mmsi,
      lat,
      lon: lon as number,
      sog: sog !== undefined && sog >= 0 && sog < 102.3 ? sog : undefined,
      cog: cog !== undefined && cog >= 0 && cog < 360 ? cog : undefined,
      heading: heading !== undefined && heading >= 0 && heading < 360 ? heading : undefined,
      timestamp,
    });
    this.lastPos.set(mmsi, { lat, lon: lon as number });
    const navStatus = intIn(p.NavigationalStatus, 0, 14);
    const out: Normalized[] = [{ update, extras: navStatus === undefined ? undefined : { navStatus }, legacy: true }];
    const held = this.held.get(mmsi);
    if (held) {
      this.held.delete(mmsi);
      const { extras, ...fields } = held;
      out.push({
        update: makeVesselUpdate({ ...fields, lat, lon: lon as number }),
        extras: hasKeys(extras) ? extras : undefined,
        legacy: fields.name !== undefined || fields.shipType !== undefined,
      });
    }
    return out;
  }

  private static(s: Json, meta: Json, timestamp: string): Normalized[] {
    const mmsi = this.mmsi(meta, s);
    if (mmsi === undefined) return [];
    const name = cleanName(s.Name);
    const type = num(s.Type);
    const shipType = type !== undefined && Number.isInteger(type) && type >= 1 && type <= 99 ? type : undefined;
    const extras = staticExtras(s);
    const legacy = name !== undefined || shipType !== undefined;
    if (!legacy && !hasKeys(extras)) return [];

    const mLat = num(meta.latitude) ?? num(meta.Latitude);
    const mLon = num(meta.longitude) ?? num(meta.Longitude);
    let pos: { lat: number; lon: number } | undefined;
    if (validPosition(mLat, mLon)) {
      pos = { lat: mLat, lon: mLon as number };
      this.lastPos.set(mmsi, pos);
    } else {
      pos = this.lastPos.get(mmsi);
    }
    if (!pos) {
      // Held data merges: the /v1 fields (name, shipType, timestamp) are replaced as a whole only by a message that
      // has some, as before extras existed; the extras are replaced per key.
      const old = this.held.get(mmsi);
      this.held.delete(mmsi);
      this.held.set(mmsi, {
        mmsi,
        ...(legacy || !old ? { name, shipType, timestamp } : { name: old.name, shipType: old.shipType, timestamp: old.timestamp }),
        extras: { ...old?.extras, ...extras },
      });
      if (this.held.size > MAX_HELD) {
        const oldest = this.held.keys().next().value;
        if (oldest !== undefined) this.held.delete(oldest);
      }
      return [];
    }
    return [
      {
        update: makeVesselUpdate({ mmsi, name, shipType, lat: pos.lat, lon: pos.lon, timestamp }),
        extras: hasKeys(extras) ? extras : undefined,
        legacy,
      },
    ];
  }
}
