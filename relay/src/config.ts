import { DEFAULT_MAX_CLIENTS, DEFAULT_PUBLIC_MAX_CLIENTS, DEFAULT_PUBLIC_MAX_CLIENTS_PER_IP, parseTokens } from './access';
import type { Source, SourceContext, SourcePlugin } from './sources/source';

export const UPSTREAM_URL = 'wss://stream.aisstream.io/v0/stream';

/** [[lat, lon], [lat, lon]] corners: Upper Bay and lower East River (Statue of Liberty to Williamsburg Bridge). Matches BoatCore's devBoundingBox. */
export const BOUNDING_BOXES: readonly (readonly [readonly [number, number], readonly [number, number]])[] = [
  [
    [40.675, -74.045],
    [40.735, -73.955],
  ],
];

/**
 * Whether a position is inside any of `BOUNDING_BOXES` (edges included; corners in either order). Boats outside are
 * never published (PROTOCOL.md, "Vessels"): aisstream is asked for the boxes only, but a bad frame can carry any
 * position.
 *
 * Trains don't go through this. The subway source can only place a train on the extracted track (src/subway-data.ts,
 * clipped to the boxes by the extract), except on the named above-ground stretches, which are kept whole and run on
 * past the edge on purpose (PROTOCOL.md, "Levels"): the Franklin Av shuttle's Park Pl end is about 25 m south of it,
 * the Culver Viaduct about 630 m. A box with a margin wide enough for those would add nothing the track doesn't
 * already bound.
 */
export function inBoundingBoxes(lat: number, lon: number): boolean {
  return BOUNDING_BOXES.some(([[lat1, lon1], [lat2, lon2]]) =>
    lat >= Math.min(lat1, lat2) && lat <= Math.max(lat1, lat2) && lon >= Math.min(lon1, lon2) && lon <= Math.max(lon1, lon2));
}

export const FILTER_MESSAGE_TYPES: readonly string[] = ['PositionReport', 'ShipStaticData'];

export const DEFAULT_SOURCES = 'aisstream,mta-subway';

export interface ConfiguredSource {
  id: string;
  create: (context: SourceContext) => Source;
}

export interface Config {
  port: number;
  host: string;
  /** The sources SOURCES names, in its order, each with its settings checked. */
  sources: ConfiguredSource[];
  /** Tokens, client caps and the public listener (README, "Environment"; PROTOCOL.md, "Access"). */
  access: AccessConfig;
}

export interface PublicListenerConfig {
  port: number;
  /** Open WebSockets at once on the public listener. */
  maxClients: number;
  /** Open WebSockets at once on the public listener from one address (an IPv6 /64). */
  maxClientsPerIp: number;
}

export interface AccessConfig {
  /**
   * Accepted app tokens. Asked of everything on the public listener, and of requests on the main one that carry a
   * forwarding header. Empty when `APP_TOKEN` is unset or invalid: those requests are then all refused.
   */
  tokens: string[];
  /** Open WebSockets at once on the main listener. It has no per-address cap. */
  maxClients: number;
  /** The public listener, when `PUBLIC_PORT` is set and everything it needs is valid. */
  public?: PublicListenerConfig;
  /**
   * Problems with the public settings, to log loudly at startup. They never stop the relay: the main listener keeps
   * running, and a public listener with any problem is not started (fail closed).
   */
  errors: string[];
}

export class ConfigError extends Error {}

/** A positive integer setting, `fallback` when unset; else the error. */
function positiveInt(env: NodeJS.ProcessEnv, name: string, fallback: number): number | string {
  const raw = env[name]?.trim();
  if (!raw) return fallback;
  const n = Number(raw);
  return Number.isInteger(n) && n >= 1 ? n : `${name} must be a positive integer, got "${raw}"`;
}

/**
 * Reads the access settings. Never throws: a bad setting must not stop the live relay (it restarts on exit, so a typo
 * in relay.env would crash-loop the main listener). Anything wrong on the public side lands in `errors` and leaves the
 * public listener off; a bad `MAX_CLIENTS` keeps the default and is reported in `errors` too.
 */
export function loadAccessConfig(env: NodeJS.ProcessEnv, mainPort: number): AccessConfig {
  const rawMax = positiveInt(env, 'MAX_CLIENTS', DEFAULT_MAX_CLIENTS);
  const maxClients = typeof rawMax === 'string' ? DEFAULT_MAX_CLIENTS : rawMax;
  const { tokens, error } = parseTokens(env.APP_TOKEN);
  const errors = error ? [error] : [];
  if (typeof rawMax === 'string') errors.push(`${rawMax}; using the default ${DEFAULT_MAX_CLIENTS}`);

  const rawPort = env.PUBLIC_PORT?.trim();
  if (!rawPort) return { tokens, maxClients, errors };
  const port = Number(rawPort);
  const publicMax = positiveInt(env, 'PUBLIC_MAX_CLIENTS', DEFAULT_PUBLIC_MAX_CLIENTS);
  const perIp = positiveInt(env, 'PUBLIC_MAX_CLIENTS_PER_IP', DEFAULT_PUBLIC_MAX_CLIENTS_PER_IP);
  if (!Number.isInteger(port) || port < 1 || port > 65535 || port === mainPort) {
    errors.push(`PUBLIC_PORT must be an integer 1-65535 other than PORT, got "${rawPort}"`);
  }
  if (typeof publicMax === 'string') errors.push(publicMax);
  if (typeof perIp === 'string') errors.push(perIp);
  if (!error && tokens.length === 0) errors.push('PUBLIC_PORT is set but APP_TOKEN is not');
  if (errors.length > 0 || typeof publicMax === 'string' || typeof perIp === 'string') {
    return { tokens, maxClients, errors: errors.map((e) => (e.startsWith('MAX_CLIENTS') ? e : `public listener not started: ${e}`)) };
  }
  return { tokens, maxClients, public: { port, maxClients: publicMax, maxClientsPerIp: perIp }, errors };
}

export function loadConfig(env: NodeJS.ProcessEnv, plugins: readonly SourcePlugin[]): Config {
  const port = env.PORT ? Number(env.PORT) : 8080;
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new ConfigError(`PORT must be an integer 0-65535, got "${env.PORT}"`);
  }
  const names = [
    ...new Set(
      (env.SOURCES?.trim() || DEFAULT_SOURCES)
        .split(',')
        .map((n) => n.trim().toLowerCase())
        .filter((n) => n !== ''),
    ),
  ];
  if (names.length === 0) throw new ConfigError('SOURCES names no source');
  const sources = names.map((name) => {
    const plugin = plugins.find((p) => p.id === name);
    if (!plugin) {
      throw new ConfigError(`unknown source "${name}" in SOURCES (known: ${plugins.map((p) => p.id).join(', ')})`);
    }
    return { id: plugin.id, create: plugin.configure(env) };
  });
  return { port, host: env.HOST || '0.0.0.0', sources, access: loadAccessConfig(env, port) };
}
