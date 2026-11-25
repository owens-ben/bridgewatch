import { createHash, timingSafeEqual } from 'node:crypto';
import type { IncomingMessage } from 'node:http';
import { isIP } from 'node:net';

/**
 * Who may open a WebSocket, and how many (PROTOCOL.md, "Access"). Built for the public edge: the relay reached
 * through a Cloudflare Tunnel by a small TestFlight group. The token is a speed bump (it ships inside the app, so
 * anyone who unpacks a build has it), not real authentication; the caps keep one buggy or hostile client from
 * taking the relay down.
 *
 * The relay has two listeners. The main one (`PORT`, published on the host for the local network) asks no token,
 * as it always has. The public one (`PUBLIC_PORT`) is never published on a host port: only cloudflared reaches it,
 * over a Docker network. It always asks the token and serves only the WebSocket paths.
 */

/**
 * Headers a proxy or CDN adds. A request on the main listener that carries any of them came through something other
 * than a plain local-network client (which send none), so it is treated as public: token required, no /healthz or
 * /metrics. That way a misrouted tunnel or a forwarder in front of the main port can't skip the token.
 */
export const FORWARDING_HEADERS = [
  'cf-connecting-ip',
  'cf-ray',
  'cdn-loop',
  'cf-ipcountry',
  'x-forwarded-for',
  'x-forwarded-host',
  'x-real-ip',
  'forwarded',
  'true-client-ip',
] as const;

type Request = Pick<IncomingMessage, 'headers' | 'socket'>;

/** True if the request carries any forwarding header, even an empty one. */
export function isForwarded(req: Request): boolean {
  return FORWARDING_HEADERS.some((h) => req.headers[h] !== undefined);
}

/** Default caps on open WebSockets (README, "Environment"). The main listener has only a total cap. */
export const DEFAULT_MAX_CLIENTS = 200;
export const DEFAULT_PUBLIC_MAX_CLIENTS = 200;
export const DEFAULT_PUBLIC_MAX_CLIENTS_PER_IP = 10;

/** A token shorter than this is refused: the public address is known, and a short one can be guessed. */
export const MIN_TOKEN_LENGTH = 16;

/**
 * Parses `APP_TOKEN`: comma-separated (several during a rotation), blanks ignored. Any token shorter than
 * `MIN_TOKEN_LENGTH` makes the whole setting invalid, so a placeholder never goes live: `tokens` is then empty (every
 * public request is refused) and `error` says why. Never throws: a crash here would restart-loop the live relay.
 */
export function parseTokens(raw: string | undefined): { tokens: string[]; error?: string } {
  const tokens = [
    ...new Set(
      (raw ?? '')
        .split(',')
        .map((t) => t.trim())
        .filter((t) => t !== ''),
    ),
  ];
  if (tokens.some((t) => t.length < MIN_TOKEN_LENGTH)) {
    return { tokens: [], error: `each APP_TOKEN must be at least ${MIN_TOKEN_LENGTH} characters` };
  }
  return { tokens };
}

const digest = (s: string) => createHash('sha256').update(s).digest();

/** Checks `Authorization: Bearer <token>` against the accepted tokens, in constant time. */
export class TokenCheck {
  private readonly digests: Buffer[];

  constructor(tokens: readonly string[]) {
    this.digests = tokens.map(digest);
  }

  /** True when there is at least one token to accept. Without one, every request is refused. */
  get configured(): boolean {
    return this.digests.length > 0;
  }

  authorized(req: Request): boolean {
    const match = /^Bearer +(.+)$/i.exec(req.headers.authorization ?? '');
    if (!match) return false;
    const given = digest(match[1]!.trim());
    // Compare every token, so the time taken doesn't say which one (or how much of it) matched.
    let ok = false;
    for (const expected of this.digests) ok = timingSafeEqual(given, expected) || ok;
    return ok;
  }
}

/**
 * Expands an IPv6 address to its 8 groups, or undefined if it isn't one. Handles `::`, an embedded IPv4 tail and a
 * zone (`%eth0`).
 */
function ipv6Groups(ip: string): number[] | undefined {
  let s = ip.split('%')[0]!;
  if (isIP(s) !== 6) return undefined;
  const v4 = /(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(s);
  if (v4) {
    const [a, b, c, d] = v4.slice(1).map(Number) as [number, number, number, number];
    s = `${s.slice(0, v4.index)}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
  }
  const [head, tail] = s.split('::') as [string, string?];
  const parse = (part: string) => (part === '' ? [] : part.split(':').map((g) => parseInt(g, 16)));
  const front = parse(head);
  const back = tail === undefined ? [] : parse(tail);
  return [...front, ...new Array<number>(8 - front.length - back.length).fill(0), ...back];
}

/**
 * The key a client's connections are counted under for the per-address cap: an IPv4 address as is (IPv4-mapped IPv6
 * too), an IPv6 address by its /64, since one phone or home gets a whole /64 and can pick any address in it.
 */
export function addressKey(ip: string): string {
  const groups = ipv6Groups(ip);
  if (!groups) return ip;
  const mapped = groups.slice(0, 5).every((g) => g === 0) && groups[5] === 0xffff;
  if (mapped) return [groups[6]! >> 8, groups[6]! & 255, groups[7]! >> 8, groups[7]! & 255].join('.');
  return `${groups
    .slice(0, 4)
    .map((g) => g.toString(16))
    .join(':')}::/64`;
}

/**
 * The client's address on the public listener: `CF-Connecting-IP` when it's a valid IP (trusted there, since only
 * cloudflared can reach that listener), else the socket's. Keyed by `addressKey`. Never logged.
 */
export function publicClientKey(req: Request): string {
  const raw = req.headers['cf-connecting-ip'];
  const header = (Array.isArray(raw) ? raw[0] : raw)?.trim();
  const ip = header && isIP(header) ? header : (req.socket.remoteAddress ?? 'unknown');
  return addressKey(ip);
}

/** Why an upgrade was refused, with the HTTP status and headers the client gets (PROTOCOL.md, "Access"). */
export const REJECTIONS = {
  unauthorized: { status: 401, text: 'Unauthorized', headers: { 'WWW-Authenticate': 'Bearer' } },
  capacity: { status: 503, text: 'Service Unavailable', headers: { 'Retry-After': '10' } },
  per_ip_limit: { status: 429, text: 'Too Many Requests', headers: { 'Retry-After': '30' } },
} as const;
export type Rejection = keyof typeof REJECTIONS;

export type Admission = { ok: true; release: () => void } | { ok: false; reason: Rejection };

/** Counts open connections against a total cap and, optionally, a cap per key (the client's address). */
export class Slots {
  private readonly perKey = new Map<string, number>();
  private open = 0;

  constructor(
    private readonly maxClients: number,
    private readonly maxPerKey = Infinity,
  ) {}

  /** Connections let in and not yet released. */
  get active(): number {
    return this.open;
  }

  /**
   * Takes a slot for `key`. When it lets the client in, the slot is held until `release` is called (once the socket
   * closes; calling it again does nothing). A refused client uses up nothing.
   */
  admit(key = ''): Admission {
    if (this.open >= this.maxClients) return { ok: false, reason: 'capacity' };
    const fromKey = this.perKey.get(key) ?? 0;
    if (fromKey >= this.maxPerKey) return { ok: false, reason: 'per_ip_limit' };

    this.open++;
    // Only tracked when there is a per-key cap, so the main listener keeps no per-address state at all.
    if (this.maxPerKey !== Infinity) this.perKey.set(key, fromKey + 1);
    let released = false;
    return {
      ok: true,
      release: () => {
        if (released) return;
        released = true;
        this.open--;
        if (this.maxPerKey === Infinity) return;
        const left = (this.perKey.get(key) ?? 1) - 1;
        if (left > 0) this.perKey.set(key, left);
        else this.perKey.delete(key);
      },
    };
  }

  /** Keys with a connection open; for tests. */
  get keys(): number {
    return this.perKey.size;
  }
}
