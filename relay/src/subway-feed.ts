import { decodeFeedMessage, type FeedMessage } from './gtfsrt';
import { describeError, guarded } from './guard';
import type { Logger } from './types';

/** MTA's GTFS-realtime subway feeds. No API key needed (checked 2026-11-10). */
export const MTA_FEED_BASE = 'https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/';
/**
 * NYCT's subway feeds and the routes each carries (the Staten Island Railway's `nyct/gtfs-si` is nowhere near the
 * area). A route that gets track in the extract (`SubwayData.routes`) must be listed here, or its trains never show.
 */
export const SUBWAY_FEED_ROUTES: Readonly<Record<string, readonly string[]>> = {
  'nyct/gtfs': ['1', '2', '3', '4', '5', '6', '6X', '7', '7X', 'GS'],
  'nyct/gtfs-ace': ['A', 'C', 'E', 'H'],
  'nyct/gtfs-bdfm': ['B', 'D', 'F', 'FS', 'FX', 'M'],
  'nyct/gtfs-g': ['G'],
  'nyct/gtfs-jz': ['J', 'Z'],
  'nyct/gtfs-l': ['L'],
  'nyct/gtfs-nqrw': ['N', 'Q', 'R', 'W'],
};
/** The feeds the poller fetches by default: every one of SUBWAY_FEED_ROUTES. */
export const SUBWAY_FEEDS: readonly string[] = Object.keys(SUBWAY_FEED_ROUTES);

/** A feed's short name, for the fixture files: `nyct/gtfs-ace` is `ace`, the numbered routes' `nyct/gtfs` is `numbered`. */
export function feedName(feed: string): string {
  return feed.replace(/^nyct\/gtfs-?/, '') || 'numbered';
}
/** MTA refreshes the feeds about every 30 s; polling faster only repeats data. Also the floor for `intervalMs`. */
export const POLL_INTERVAL_MS = 30_000;
export const FETCH_TIMEOUT_MS = 15_000;
/** After failures the wait doubles, up to this. */
export const MAX_RETRY_MS = 10 * 60_000;

export type FetchFeed = (url: string, signal: AbortSignal) => Promise<Uint8Array>;

type TimerHandle = ReturnType<typeof setTimeout>;

export interface SubwayPollerOptions {
  feeds?: readonly string[];
  baseUrl?: string;
  intervalMs?: number;
  fetchFeed?: FetchFeed;
  setTimer?: (fn: () => void, ms: number) => TimerHandle;
  clearTimer?: (handle: TimerHandle) => void;
  log?: Logger;
  /** ms since the epoch; for lastRoundAt. */
  now?: () => number;
  /** Called after each poll round with the latest good message of every feed. A throw is logged, at most once a minute. */
  onPoll?: (feeds: FeedMessage[]) => void;
}

export function feedUrl(baseUrl: string, feed: string): string {
  return baseUrl + encodeURIComponent(feed);
}

/** Fetches one feed over HTTPS (the poller's default). */
export const fetchFeedBytes: FetchFeed = async (url, signal) => {
  const res = await fetch(url, { signal, headers: { 'User-Agent': 'boat-ar-relay (hobby AR app; polls every 30 s)' } });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return new Uint8Array(await res.arrayBuffer());
};

/** Polls the subway feeds, one round at a time, and keeps the latest good message per feed. */
export class SubwayPoller {
  private readonly o: SubwayPollerOptions;
  private readonly latestByFeed = new Map<string, FeedMessage>();
  private readonly failing = new Set<string>();
  private failedRounds = 0;
  private timer?: TimerHandle;
  private stopped = true;
  private round?: Promise<void>;
  private finishedAt?: number;

  private readonly publish: (feeds: FeedMessage[]) => void;

  constructor(options: SubwayPollerOptions = {}) {
    this.o = options;
    this.publish = guarded('subway: publish failed', (m) => this.o.log?.(m), (feeds: FeedMessage[]) => this.o.onPoll?.(feeds));
  }

  private get intervalMs(): number {
    return Math.max(POLL_INTERVAL_MS, this.o.intervalMs ?? POLL_INTERVAL_MS);
  }

  /** When the last poll round finished (ms since the epoch), whether or not its fetches worked. */
  lastRoundAt(): number | undefined {
    return this.finishedAt;
  }

  /** The latest good message of each feed (possibly old: callers check `timestamp`). */
  latest(): FeedMessage[] {
    return [...this.latestByFeed.values()];
  }

  start(): void {
    if (!this.stopped) return;
    this.stopped = false;
    this.schedule(0);
  }

  stop(): void {
    this.stopped = true;
    if (this.timer) (this.o.clearTimer ?? clearTimeout)(this.timer);
    this.timer = undefined;
  }

  /** Runs one round now (tests, and the scheduled loop). Never rejects. */
  pollOnce(): Promise<void> {
    // poll() catches its own failures; the catch here makes "never rejects" hold even if its logging throws.
    this.round ??= this.poll()
      .catch(() => {})
      .finally(() => (this.round = undefined));
    return this.round;
  }

  private schedule(ms: number): void {
    if (this.stopped) return;
    this.timer = (this.o.setTimer ?? setTimeout)(() => {
      this.timer = undefined;
      void this.pollOnce().finally(() => {
        // Always the next round, whatever this one did: the loop must not die.
        const wait = this.failedRounds === 0 ? this.intervalMs : Math.min(MAX_RETRY_MS, this.intervalMs * 2 ** this.failedRounds);
        this.schedule(wait);
      });
    }, ms);
  }

  /** One round, never rejecting: anything the round itself throws is logged and counts as a failed round. */
  private async poll(): Promise<void> {
    try {
      await this.fetchAll();
    } catch (err) {
      this.failedRounds++;
      this.finishedAt = (this.o.now ?? Date.now)();
      this.o.log?.(`subway: poll round failed: ${describeError(err)}`);
      return;
    }
    this.publish(this.latest());
  }

  private async fetchAll(): Promise<void> {
    const feeds = this.o.feeds ?? SUBWAY_FEEDS;
    const fetchFeed = this.o.fetchFeed ?? fetchFeedBytes;
    const base = this.o.baseUrl ?? MTA_FEED_BASE;
    const results = await Promise.all(
      feeds.map(async (feed) => {
        try {
          const bytes = await fetchFeed(feedUrl(base, feed), AbortSignal.timeout(FETCH_TIMEOUT_MS));
          const message = decodeFeedMessage(bytes);
          this.latestByFeed.set(feed, message);
          if (this.failing.delete(feed)) this.o.log?.(`subway: ${feed} recovered`);
          return true;
        } catch (err) {
          // Log a feed's failure once, not every 30 s.
          if (!this.failing.has(feed)) {
            this.failing.add(feed);
            this.o.log?.(`subway: ${feed} failed: ${err instanceof Error ? err.message : String(err)}`);
          }
          return false;
        }
      }),
    );
    this.failedRounds = results.some(Boolean) ? 0 : this.failedRounds + 1;
    this.finishedAt = (this.o.now ?? Date.now)();
  }
}
