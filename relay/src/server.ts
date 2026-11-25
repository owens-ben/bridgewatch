import http from 'node:http';
import type { Duplex } from 'node:stream';
import { WebSocket, WebSocketServer } from 'ws';
import {
  DEFAULT_MAX_CLIENTS,
  DEFAULT_PUBLIC_MAX_CLIENTS,
  DEFAULT_PUBLIC_MAX_CLIENTS_PER_IP,
  isForwarded,
  publicClientKey,
  REJECTIONS,
  Slots,
  TokenCheck,
  type Rejection,
} from './access';
import { DEFAULT_CENSUS_LIMIT, type Census } from './census';
import type { TargetHub } from './hub';
import { METRICS_CONTENT_TYPE, type RelayMetrics } from './metrics';
import type { Registry } from './registry';
import type { Logger, VesselUpdate } from './types';

/** Legacy: AIS vessels only, for app builds from before /v2/targets (PROTOCOL.md, "/v1/vessels"). */
export const VESSELS_PATH = '/v1/vessels';
export const TARGETS_PATH = '/v2/targets';
const PING_INTERVAL_MS = 30_000;
/**
 * A client with more than this unsent is not reading: it is dropped (it reconnects to a fresh snapshot). A snapshot is
 * about 32 KiB today (Packages/BoatCore/Tests/BoatCoreTests/Fixtures/relay-v2-snapshot.json), so a client that reads
 * never comes near it.
 */
export const MAX_BUFFERED_BYTES = 256 * 1024;
/**
 * Unsent bytes across all clients at which every client with a backlog is dropped, so many slow clients together
 * can't run the container (256 MiB) out of memory. Worst case: each kept client is at most one message past its
 * check, so unsent data stays under this plus (clients x the largest message): 32 MiB + 400 x ~32 KiB = ~45 MiB, next to
 * a relay of about 80 MiB. Without the budget it would be 400 x 256 KiB = 100 MiB. (The kernel's socket buffers come on
 * top, as for any server.)
 */
export const MAX_TOTAL_BUFFERED_BYTES = 32 * 1024 * 1024;
/**
 * A snapshot larger than this is logged as a warning (at most once a minute per path). The app accepts messages up
 * to 8 MiB (URLSessionWebSocketConnector.maximumMessageSize; URLSession's default was 1 MiB) and a bigger snapshot
 * would fail every connection before its first message, so this is the early sign to act on: about 1,300 targets at
 * ~400 bytes each. Note that a snapshot past `MAX_BUFFERED_BYTES` that the kernel doesn't take at once already gets a
 * client dropped as not keeping up.
 */
export const SNAPSHOT_WARN_BYTES = 512 * 1024;
/** Refusals are logged at most this often per reason; the count is in /metrics. */
const REJECTION_LOG_INTERVAL_MS = 60_000;

/** Which listener a request came in on. */
export type Listener = 'main' | 'public';

export interface RelayServer {
  /** Starts the main listener: local network, no token, /healthz, /metrics and /census. Resolves with its port. */
  listen(port: number, host: string): Promise<number>;
  /**
   * Starts the public listener: token always, WebSocket paths only, per-address cap. Rejects if no token is
   * configured, so it can't be opened by mistake.
   */
  listenPublic(port: number, host: string): Promise<number>;
  /** True while the public listener is open. */
  publicListening(): boolean;
  /** Sends a /v1/vessels update. /v2/targets clients get the hub's changes without being told. */
  broadcast(update: VesselUpdate): void;
  clientCount(): number;
  /** Connected clients by path. */
  clientCounts(): Record<string, number>;
  close(): Promise<void>;
}

function pathOf(url: string | undefined): string {
  try {
    return new URL(url ?? '/', 'http://relay.invalid').pathname;
  } catch {
    return '';
  }
}

/** `?limit=N` of /census; a missing or bad one gives the default (the census caps a large one). */
function censusLimit(url: string | undefined): number {
  try {
    const raw = new URL(url ?? '/', 'http://relay.invalid').searchParams.get('limit');
    const n = raw !== null && /^\d+$/.test(raw) ? Number(raw) : NaN;
    return Number.isSafeInteger(n) && n >= 1 ? n : DEFAULT_CENSUS_LIMIT;
  } catch {
    return DEFAULT_CENSUS_LIMIT;
  }
}

function refuse(socket: Duplex, status: number, text: string, headers: Record<string, string> = {}): void {
  const extra = Object.entries(headers)
    .map(([k, v]) => `${k}: ${v}\r\n`)
    .join('');
  socket.end(`HTTP/1.1 ${status} ${text}\r\n${extra}Connection: close\r\nContent-Length: 0\r\n\r\n`);
}

export function createRelayServer(opts: {
  /** /v1/vessels state. */
  registry: Registry;
  hub: TargetHub;
  now?: () => number;
  log?: Logger;
  /** Backs /healthz: 200 with the report as JSON when `ok`, 503 otherwise. Without it /healthz is a plain 200 "ok". */
  health?: () => { ok: boolean };
  /** Backs GET /metrics and counts client traffic. Without it /metrics is 404. */
  metrics?: Pick<RelayMetrics, 'render' | 'connections' | 'messages' | 'rejections' | 'drops'>;
  /** Backs GET /census on the main listener, never forwarded requests. Without it /census is 404. */
  census?: Pick<Census, 'report'>;
  /** Accepted app tokens (src/access.ts). Without any, every public request is refused. */
  tokens?: readonly string[];
  /** Open WebSockets at once on the main listener. Default `DEFAULT_MAX_CLIENTS`. */
  maxClients?: number;
  /** Caps on the public listener. Defaults: `DEFAULT_PUBLIC_MAX_CLIENTS`, `DEFAULT_PUBLIC_MAX_CLIENTS_PER_IP`. */
  publicLimits?: { maxClients: number; maxClientsPerIp: number };
  /** Unsent bytes at which a client is dropped. Default `MAX_BUFFERED_BYTES`. */
  maxBufferedBytes?: number;
  /** Unsent bytes across all clients at which those with a backlog are dropped. Default `MAX_TOTAL_BUFFERED_BYTES`. */
  maxTotalBufferedBytes?: number;
  /** Snapshot size, bytes, past which a warning is logged. Default `SNAPSHOT_WARN_BYTES`. */
  snapshotWarnBytes?: number;
}): RelayServer {
  const now = opts.now ?? Date.now;
  const log = opts.log ?? (() => {});
  const v1 = new WebSocketServer({ noServer: true, maxPayload: 1024 });
  const v2 = new WebSocketServer({ noServer: true, maxPayload: 1024 });
  const servers = new Map([
    [VESSELS_PATH, v1],
    [TARGETS_PATH, v2],
  ]);
  const tokens = new TokenCheck(opts.tokens ?? []);
  const slots: Record<Listener, Slots> = {
    main: new Slots(opts.maxClients ?? DEFAULT_MAX_CLIENTS),
    public: new Slots(
      opts.publicLimits?.maxClients ?? DEFAULT_PUBLIC_MAX_CLIENTS,
      opts.publicLimits?.maxClientsPerIp ?? DEFAULT_PUBLIC_MAX_CLIENTS_PER_IP,
    ),
  };
  const maxBuffered = opts.maxBufferedBytes ?? MAX_BUFFERED_BYTES;
  const maxTotalBuffered = opts.maxTotalBufferedBytes ?? MAX_TOTAL_BUFFERED_BYTES;
  const lastRejectionLog = new Map<Rejection, number>();
  const snapshotWarnBytes = opts.snapshotWarnBytes ?? SNAPSHOT_WARN_BYTES;
  const lastSnapshotWarning = new Map<string, number>();
  const alive = new WeakSet<WebSocket>();
  const clientCount = () => v1.clients.size + v2.clients.size;
  const allClients = () => [...v1.clients, ...v2.clients];

  // Main listener: /healthz, /metrics and /census for the operator, unless the request came through a proxy.
  const main = http.createServer((req, res) => {
    const internal = !isForwarded(req);
    if (internal && req.method === 'GET' && pathOf(req.url) === '/healthz') {
      if (opts.health) {
        const report = opts.health();
        res.writeHead(report.ok ? 200 : 503, { 'Content-Type': 'application/json' }).end(JSON.stringify(report));
      } else {
        res.writeHead(200, { 'Content-Type': 'text/plain' }).end('ok');
      }
    } else if (internal && req.method === 'GET' && pathOf(req.url) === '/metrics' && opts.metrics) {
      res.writeHead(200, { 'Content-Type': METRICS_CONTENT_TYPE }).end(opts.metrics.render());
    } else if (internal && req.method === 'GET' && pathOf(req.url) === '/census' && opts.census) {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(opts.census.report(censusLimit(req.url))));
    } else {
      res.writeHead(404, { 'Content-Type': 'text/plain' }).end('not found');
    }
  });
  // Public listener: nothing but the WebSocket upgrades.
  const pub = http.createServer((_req, res) => {
    res.writeHead(404, { 'Content-Type': 'text/plain' }).end('not found');
  });
  let publicOpen = false;

  function reject(listener: Listener, socket: Duplex, reason: Rejection): void {
    const { status, text, headers } = REJECTIONS[reason];
    opts.metrics?.rejections.inc({ listener, reason });
    const t = now();
    if (t - (lastRejectionLog.get(reason) ?? -Infinity) >= REJECTION_LOG_INTERVAL_MS) {
      lastRejectionLog.set(reason, t);
      log(`server: refused an upgrade on the ${listener} listener (${reason}); further ones are only counted`);
    }
    refuse(socket, status, text, headers);
  }

  function upgrade(listener: Listener, req: http.IncomingMessage, socket: Duplex, head: Buffer): void {
    // A client that resets the connection while we refuse it would otherwise emit an unhandled 'error' on this raw
    // socket and kill the process (found by the adversarial run; it is also in the relay before the edge work).
    socket.on('error', () => {});
    const wss = servers.get(pathOf(req.url));
    if (!wss) {
      refuse(socket, 404, 'Not Found');
      return;
    }
    // Everything on the public listener is public. On the main one, so is anything a proxy forwarded.
    if ((listener === 'public' || isForwarded(req)) && !tokens.authorized(req)) {
      reject(listener, socket, 'unauthorized');
      return;
    }
    const admission = listener === 'public' ? slots.public.admit(publicClientKey(req)) : slots.main.admit();
    if (!admission.ok) {
      reject(listener, socket, admission.reason);
      return;
    }
    // The socket's close is the one event every connection ends with, even one that fails during the handshake.
    socket.once('close', admission.release);
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req, listener));
  }
  main.on('upgrade', (req, socket, head) => upgrade('main', req, socket, head));
  pub.on('upgrade', (req, socket, head) => upgrade('public', req, socket, head));

  let totalBuffered = 0;
  /**
   * Drops `ws` if it isn't keeping up: more than its own limit unsent, or any backlog while all clients together are
   * over the budget. A queue that only grows would eat the relay's memory; the client reconnects to a fresh snapshot.
   */
  function dropIfBehind(ws: WebSocket, path: string): boolean {
    const behind = ws.bufferedAmount;
    if (behind <= maxBuffered && !(behind > 0 && totalBuffered > maxTotalBuffered)) return false;
    ws.terminate();
    totalBuffered -= behind;
    opts.metrics?.drops.inc({ path });
    log(`server: dropped a client on ${path} that was not keeping up (${behind} bytes unsent)`);
    return true;
  }
  const sumBuffered = () => allClients().reduce((sum, ws) => sum + ws.bufferedAmount, 0);

  /** Logs a snapshot over `snapshotWarnBytes`, at most once a minute per path. */
  function warnIfLarge(path: string, bytes: number): void {
    if (bytes <= snapshotWarnBytes) return;
    const t = now();
    if (t - (lastSnapshotWarning.get(path) ?? -Infinity) < REJECTION_LOG_INTERVAL_MS) return;
    lastSnapshotWarning.set(path, t);
    log(
      `server: WARNING snapshot on ${path} is ${bytes} bytes, over ${snapshotWarnBytes}; the app refuses messages ` +
        'over 8 MiB (PROTOCOL.md, "Message size")',
    );
  }

  function accept(ws: WebSocket, path: string, listener: Listener, snapshot: () => object): void {
    alive.add(ws);
    ws.on('error', () => {});
    ws.on('pong', () => alive.add(ws));
    const text = JSON.stringify(snapshot());
    ws.send(text);
    warnIfLarge(path, Buffer.byteLength(text));
    opts.metrics?.connections.inc({ path });
    opts.metrics?.messages.inc({ path });
    // A client that can't take even its snapshot goes at once, not at the next broadcast.
    totalBuffered = sumBuffered();
    if (dropIfBehind(ws, path)) return;
    log(`server: client connected to ${path} on the ${listener} listener (${clientCount()} total)`);
    ws.on('close', () => log(`server: client disconnected from ${path} on the ${listener} listener (${clientCount()} total)`));
  }
  v1.on('connection', (ws: WebSocket, _req: http.IncomingMessage, listener: Listener) =>
    accept(ws, VESSELS_PATH, listener, () => ({ type: 'snapshot', vessels: opts.registry.snapshot(now()) })),
  );
  v2.on('connection', (ws: WebSocket, _req: http.IncomingMessage, listener: Listener) =>
    accept(ws, TARGETS_PATH, listener, () => ({ type: 'snapshot', targets: opts.hub.snapshot() })),
  );

  function send(path: string, clients: Iterable<WebSocket>, msg: string): void {
    totalBuffered = sumBuffered();
    let sent = 0;
    for (const ws of clients) {
      if (ws.readyState !== WebSocket.OPEN) continue;
      if (dropIfBehind(ws, path)) continue;
      const before = ws.bufferedAmount;
      ws.send(msg);
      totalBuffered += ws.bufferedAmount - before;
      sent++;
    }
    if (sent > 0) opts.metrics?.messages.inc({ path }, sent);
  }
  const unsubscribe = opts.hub.subscribe((event) => send(TARGETS_PATH, v2.clients, JSON.stringify(event)));

  const pinger = setInterval(() => {
    for (const ws of allClients()) {
      if (!alive.has(ws)) {
        ws.terminate();
        continue;
      }
      alive.delete(ws);
      ws.ping();
    }
  }, PING_INTERVAL_MS);
  pinger.unref();

  function listenOn(server: http.Server, port: number, host: string): Promise<number> {
    return new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(port, host, () => {
        server.off('error', reject);
        const addr = server.address();
        resolve(typeof addr === 'object' && addr ? addr.port : port);
      });
    });
  }
  const closeServer = (server: http.Server) =>
    new Promise<void>((resolve) => {
      if (!server.listening) return resolve();
      server.close(() => resolve());
      server.closeAllConnections();
    });

  return {
    listen: (port, host) => listenOn(main, port, host),
    async listenPublic(port, host) {
      if (!tokens.configured) throw new Error('the public listener needs at least one app token');
      const bound = await listenOn(pub, port, host);
      publicOpen = true;
      pub.once('close', () => (publicOpen = false));
      return bound;
    },
    publicListening: () => publicOpen,
    broadcast(update) {
      send(VESSELS_PATH, v1.clients, JSON.stringify({ type: 'update', vessel: update }));
    },
    clientCount,
    clientCounts: () => ({ [VESSELS_PATH]: v1.clients.size, [TARGETS_PATH]: v2.clients.size }),
    async close() {
      clearInterval(pinger);
      unsubscribe();
      for (const ws of allClients()) ws.terminate();
      v1.close();
      v2.close();
      await Promise.all([closeServer(main), closeServer(pub)]);
    },
  };
}
