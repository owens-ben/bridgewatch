import type { UpstreamStatus } from './upstream';

/**
 * A streaming source with no data for this long is unhealthy, so /healthz fails and the container is restarted
 * (autoheal on the host). Matches the vessel expiry: by then the app shows nothing. The upstream watchdog reconnects long
 * before this; this is the backstop.
 */
export const STALE_AFTER_MS = 600_000;

/**
 * One source's part of /healthz. `ok` is false only when restarting the relay could help (a stuck stream), not for an
 * outage on the feed's side: a restart can't fix that and would drop every client. The data's age is reported either
 * way, for monitoring.
 */
export interface SourceHealth {
  ok: boolean;
  /** Streaming sources: whether the upstream socket is open. */
  connected?: boolean;
  /** Seconds since the source last got data; omitted before the first. */
  lastDataAgeSeconds?: number;
}

export interface HealthReport {
  ok: boolean;
  sources: Record<string, SourceHealth>;
  targets: number;
  clients: number;
}

/** A streaming source: healthy while data arrived within STALE_AFTER_MS (counting from start until the first). */
export function streamHealth(now: number, startedAt: number, upstream: UpstreamStatus): SourceHealth {
  const freshest = upstream.lastFrameAt ?? startedAt;
  return {
    ok: now - freshest <= STALE_AFTER_MS,
    connected: upstream.connected,
    lastDataAgeSeconds: ageSeconds(now, upstream.lastFrameAt),
  };
}

export function ageSeconds(now: number, at: number | undefined): number | undefined {
  return at === undefined ? undefined : Math.round((now - at) / 1000);
}

/** The relay is healthy when every source is. */
export function relayHealth(sources: Record<string, SourceHealth>, targets: number, clients: number): HealthReport {
  return { ok: Object.values(sources).every((s) => s.ok), sources, targets, clients };
}
