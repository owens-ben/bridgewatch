import WebSocket from 'ws';
import { backoffDelay } from './backoff';
import { BOUNDING_BOXES, FILTER_MESSAGE_TYPES, UPSTREAM_URL } from './config';
import { guarded, safeText } from './guard';
import { Normalizer } from './normalizer';
import type { Logger, Normalized, VesselUpdate } from './types';

export const MIN_SUBSCRIPTION_GAP_MS = 1000;
/**
 * No frame (or no open) for this long and the socket is dropped and reopened. aisstream can stop sending without
 * closing the socket; the relay then served nothing for 15 hours (2026-11-11). The harbor normally sends several
 * frames a second.
 */
export const IDLE_TIMEOUT_MS = 120_000;

/** What the upstream link looks like right now, for /healthz. */
export interface UpstreamStatus {
  connected: boolean;
  /** When the newest vessel data frame arrived (ms since epoch), if any since start. */
  lastFrameAt?: number;
}

/** The slice of ws.WebSocket the client uses; tests inject a fake. */
export interface UpstreamSocket {
  on(event: string, listener: (...args: any[]) => void): unknown;
  send(data: string): void;
  close(): void;
  terminate?(): void;
}

export type SocketFactory = (url: string, options: { perMessageDeflate: boolean }) => UpstreamSocket;

type TimerHandle = ReturnType<typeof setTimeout>;

export interface UpstreamOptions {
  apiKey: string;
  url?: string;
  boundingBoxes?: unknown;
  filterMessageTypes?: readonly string[];
  socketFactory?: SocketFactory;
  now?: () => number;
  random?: () => number;
  setTimer?: (fn: () => void, ms: number) => TimerHandle;
  clearTimer?: (handle: TimerHandle) => void;
  /** Defaults to IDLE_TIMEOUT_MS. */
  idleTimeoutMs?: number;
  /** Overrides the reconnect delay (tests). Defaults to backoffDelay with `random`. */
  backoff?: (attempt: number) => number;
  normalizer?: Normalizer;
  onRawFrame?: (text: string, receivedAt: Date) => void;
  onUpdate?: (update: VesselUpdate) => void;
  /** Like onUpdate, but every message with its v2-only extras (and whether /v1 sees it). */
  onMessage?: (message: Normalized) => void;
  log?: Logger;
}

export function decodeFrame(data: unknown): string | undefined {
  if (typeof data === 'string') return data;
  if (Buffer.isBuffer(data)) return data.toString('utf8');
  if (data instanceof ArrayBuffer) return Buffer.from(data).toString('utf8');
  if (Array.isArray(data) && data.every((c) => Buffer.isBuffer(c))) return Buffer.concat(data).toString('utf8');
  if (ArrayBuffer.isView(data)) return Buffer.from(data.buffer, data.byteOffset, data.byteLength).toString('utf8');
  return undefined;
}

/** aisstream reports problems (bad API key, bad subscription) as {"error": "..."} before closing. */
export function upstreamErrorMessage(text: string): string | undefined {
  if (!text.includes('"error"')) return undefined;
  try {
    const parsed: unknown = JSON.parse(text);
    if (typeof parsed === 'object' && parsed !== null && typeof (parsed as { error?: unknown }).error === 'string') {
      return (parsed as { error: string }).error;
    }
  } catch {
    /* not JSON */
  }
  return undefined;
}

const defaultFactory: SocketFactory = (url, options) => new WebSocket(url, options) as unknown as UpstreamSocket;

export class UpstreamClient {
  private readonly o: UpstreamOptions;
  private readonly normalizer: Normalizer;
  /**
   * A data frame's processing (raw-frame hook and normalizer), guarded: a throw is logged (rate limited), the socket
   * stays open and the next frame is processed as usual. Each message it yields is delivered under its own guard: one
   * frame can carry two (a position plus the static data held for it), and a throw on the first must not lose the second.
   */
  private readonly processFrame: (text: string, receivedAt: Date) => void;
  private readonly deliverMessage: (message: Normalized) => void;
  private readonly deliverUpdate: (update: VesselUpdate) => void;
  private socket?: UpstreamSocket;
  private attempt = 0;
  private lastSubscriptionAt = -Infinity;
  private reconnectTimer?: TimerHandle;
  private subscribeTimer?: TimerHandle;
  private watchdogTimer?: TimerHandle;
  private lastActivityAt = 0;
  private open = false;
  private lastFrameAt?: number;
  private stopped = true;

  constructor(options: UpstreamOptions) {
    this.o = options;
    this.normalizer = options.normalizer ?? new Normalizer();
    const log = (m: string) => this.log(m);
    this.deliverMessage = guarded('upstream: message delivery failed', log, (n: Normalized) => this.o.onMessage?.(n));
    this.deliverUpdate = guarded('upstream: update delivery failed', log, (u: VesselUpdate) => this.o.onUpdate?.(u));
    this.processFrame = guarded('upstream: frame processing failed', log, (text: string, receivedAt: Date) => {
      this.o.onRawFrame?.(text, receivedAt);
      if (this.o.onMessage) {
        for (const n of this.normalizer.normalizeAll(text, receivedAt)) this.deliverMessage(n);
      } else if (this.o.onUpdate) {
        for (const u of this.normalizer.normalize(text, receivedAt)) this.deliverUpdate(u);
      }
    });
  }

  private now(): number {
    return (this.o.now ?? Date.now)();
  }
  private setTimer(fn: () => void, ms: number): TimerHandle {
    return (this.o.setTimer ?? ((f, m) => setTimeout(f, m)))(fn, ms);
  }
  private clearTimer(h: TimerHandle): void {
    (this.o.clearTimer ?? ((x) => clearTimeout(x)))(h);
  }
  private log(msg: string): void {
    this.o.log?.(msg);
  }

  status(): UpstreamStatus {
    return { connected: this.open, lastFrameAt: this.lastFrameAt };
  }

  start(): void {
    this.stopped = false;
    this.connect();
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer) this.clearTimer(this.reconnectTimer);
    if (this.subscribeTimer) this.clearTimer(this.subscribeTimer);
    if (this.watchdogTimer) this.clearTimer(this.watchdogTimer);
    this.reconnectTimer = this.subscribeTimer = this.watchdogTimer = undefined;
    this.open = false;
    const sock = this.socket;
    this.socket = undefined;
    try {
      sock?.close();
    } catch {
      /* already closed */
    }
  }

  private connect(): void {
    if (this.stopped) return;
    this.reconnectTimer = undefined;
    const url = this.o.url ?? UPSTREAM_URL;
    this.log('upstream: connecting');
    const sock = (this.o.socketFactory ?? defaultFactory)(url, { perMessageDeflate: true });
    this.socket = sock;
    this.lastActivityAt = this.now();
    this.armWatchdog(sock);

    sock.on('open', () => {
      if (this.socket !== sock) return;
      this.open = true;
      this.lastActivityAt = this.now();
      this.log('upstream: connected');
      this.sendSubscription(sock);
    });
    sock.on('message', (data: unknown) => {
      if (this.socket !== sock) return;
      const text = decodeFrame(data);
      if (text === undefined) return;
      this.lastActivityAt = this.now();
      const upstreamError = upstreamErrorMessage(text);
      if (upstreamError !== undefined) {
        // e.g. a rejected API key; aisstream closes the socket next. Not a sign of a healthy link, so no backoff reset.
        // Upstream text: one line, capped (a newline in it would forge log lines).
        this.log(`upstream: aisstream error: ${safeText(upstreamError)}`);
        return;
      }
      this.attempt = 0;
      this.lastFrameAt = this.now();
      this.processFrame(text, new Date(this.lastFrameAt));
    });
    sock.on('error', (err: unknown) => {
      this.log(`upstream: error: ${err instanceof Error ? err.message : String(err)}`);
      this.ended(sock, true);
    });
    sock.on('close', () => this.ended(sock, false));
  }

  private ended(sock: UpstreamSocket, terminate: boolean): void {
    if (this.socket !== sock) return;
    this.socket = undefined;
    this.open = false;
    if (this.subscribeTimer) this.clearTimer(this.subscribeTimer);
    if (this.watchdogTimer) this.clearTimer(this.watchdogTimer);
    this.subscribeTimer = this.watchdogTimer = undefined;
    if (terminate) {
      try {
        sock.terminate?.();
      } catch {
        /* ignore */
      }
    }
    if (this.stopped) return;
    const delay = (this.o.backoff ?? ((a) => backoffDelay(a, this.o.random)))(this.attempt++);
    this.log(`upstream: disconnected, reconnecting in ${Math.round(delay)} ms`);
    this.reconnectTimer = this.setTimer(() => this.connect(), delay);
  }

  /** Drops `sock` once it has been silent (or unopened) for idleTimeoutMs; checks every quarter of that. */
  private armWatchdog(sock: UpstreamSocket): void {
    const timeout = this.o.idleTimeoutMs ?? IDLE_TIMEOUT_MS;
    this.watchdogTimer = this.setTimer(() => {
      this.watchdogTimer = undefined;
      if (this.socket !== sock) return;
      const idle = this.now() - this.lastActivityAt;
      if (idle >= timeout) {
        this.log(`upstream: nothing received for ${Math.round(idle / 1000)} s, reconnecting`);
        this.ended(sock, true);
      } else {
        this.armWatchdog(sock);
      }
    }, timeout / 4);
  }

  /** Sends the subscription immediately, or after enough delay to keep >= 1000 ms between sends. */
  private sendSubscription(sock: UpstreamSocket): void {
    const send = () => {
      this.subscribeTimer = undefined;
      if (this.socket !== sock) return;
      this.lastSubscriptionAt = this.now();
      sock.send(
        JSON.stringify({
          APIKey: this.o.apiKey,
          BoundingBoxes: this.o.boundingBoxes ?? BOUNDING_BOXES,
          FilterMessageTypes: this.o.filterMessageTypes ?? FILTER_MESSAGE_TYPES,
        }),
      );
    };
    const wait = this.lastSubscriptionAt + MIN_SUBSCRIPTION_GAP_MS - this.now();
    if (wait > 0) {
      this.log(`upstream: delaying subscription ${Math.ceil(wait)} ms`);
      this.subscribeTimer = this.setTimer(send, wait);
    } else {
      send();
    }
  }
}
