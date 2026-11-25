import { describeError, guarded, rateLimited, safeText } from '../guard';
import { ageSeconds, type SourceHealth } from '../health';
import { TRAINS_INTERVAL_MS, TrainEstimator, type SubwayData, type TrainEstimate } from '../subway';
import { SUBWAY_DATA } from '../subway-data';
import { FETCH_TIMEOUT_MS, MAX_RETRY_MS, SubwayPoller, type SubwayPollerOptions } from '../subway-feed';
import { makeTarget, type Target } from '../targets';
import type { Source, SourceContext, SourcePlugin } from './source';

export const MTA_SUBWAY_SOURCE_ID = 'mta-subway';
/** A train not re-estimated for this long is dropped: the source stopped, or lost MTA. */
export const TRAIN_EXPIRY_MS = 30_000;
/**
 * No poll round finished for this long means the poll loop itself died (rounds always finish: each fetch times out,
 * and failures back off to MAX_RETRY_MS at most), which a restart fixes. MTA being down is not that.
 */
export const STALLED_AFTER_MS = MAX_RETRY_MS + FETCH_TIMEOUT_MS + 60_000;

/** NYC subway trains inside the app's area, above ground and underground, estimated from MTA's feeds (no key). */
export const mtaSubway: SourcePlugin = {
  id: MTA_SUBWAY_SOURCE_ID,
  configure() {
    return (context) => new MtaSubwaySource(context);
  },
};

/** An estimated train as a target (PROTOCOL.md, "Trains"). */
export function trainTarget(t: TrainEstimate): Target {
  return makeTarget({
    id: `train:nyct:${t.tripId}`,
    kind: 'train',
    source: MTA_SUBWAY_SOURCE_ID,
    lat: t.lat,
    lon: t.lon,
    altitude: t.altitude,
    speed: t.speed,
    course: t.bearing,
    timestamp: t.timestamp,
    train: {
      route: t.route,
      direction: t.direction,
      destination: t.destination,
      stretch: t.stretch,
      underground: t.underground,
      altitudeEstimated: t.altitudeEstimated,
    },
  });
}

export interface MtaSubwaySourceOptions extends SourceContext {
  data?: SubwayData;
  /** Overrides for the poller (tests inject a fake fetch). */
  poller?: Partial<SubwayPollerOptions>;
  now?: () => number;
}

/** Polls MTA every 30 s and publishes the trains inside the area, re-estimated every 10 s. */
export class MtaSubwaySource implements Source {
  private readonly estimator: TrainEstimator;
  private readonly poller: SubwayPoller;
  private ticker?: ReturnType<typeof setInterval>;
  private startedAt = 0;
  /** publish() under a guard: a throw is logged (rate limited) and never reaches the poller, the ticker or the hub. */
  private readonly safePublish: () => void;
  /** Trips whose estimate failed in the last publish, so each odd trip is logged once, not every 10 s. */
  private badTrips = new Set<string>();
  /** The "trip skipped" lines, rate limited too: a bug that breaks every trip logs one line and a count, not hundreds. */
  private readonly tripErrors: (message: string) => void;

  constructor(private readonly o: MtaSubwaySourceOptions) {
    this.estimator = new TrainEstimator(o.data ?? SUBWAY_DATA);
    this.tripErrors = rateLimited(o.log, { now: o.now });
    this.safePublish = guarded('mta-subway: publish failed', o.log, () => this.estimateAndPublish(), { now: o.now });
    this.poller = new SubwayPoller({ log: o.log, now: o.now, onPoll: () => this.publish(), ...o.poller });
  }

  start(): void {
    this.startedAt = (this.o.now ?? Date.now)();
    this.poller.start();
    this.ticker = setInterval(() => this.publish(), TRAINS_INTERVAL_MS);
    this.ticker.unref();
  }

  stop(): void {
    clearInterval(this.ticker);
    this.poller.stop();
  }

  /** Not ok only when the poll loop has stalled; the data's age is how old MTA's newest feed is. */
  health(now: number): SourceHealth {
    const lastRound = this.poller.lastRoundAt() ?? this.startedAt;
    const stamps = this.poller.latest().flatMap((f) => (f.timestamp === undefined ? [] : [f.timestamp * 1000]));
    return {
      ok: now - lastRound <= STALLED_AFTER_MS,
      lastDataAgeSeconds: ageSeconds(now, stamps.length > 0 ? Math.max(...stamps) : undefined),
    };
  }

  /**
   * Estimates every train from the latest feeds and makes them the source's complete set of targets. Never throws: a
   * failure is logged (rate limited) and the next tick tries again. A trip whose estimate throws is left out.
   */
  publish(): void {
    this.safePublish();
  }

  private estimateAndPublish(): void {
    const now = (this.o.now ?? Date.now)();
    const bad = new Set<string>();
    const trains = this.estimator.estimateAll(this.poller.latest(), now, (tripId, err) => {
      bad.add(tripId);
      if (!this.badTrips.has(tripId)) {
        this.tripErrors(`mta-subway: trip ${safeText(tripId, 100)} skipped: ${describeError(err)}`);
      }
    });
    this.badTrips = bad;
    this.o.sink.replaceAll(trains.map(trainTarget), now + TRAIN_EXPIRY_MS);
  }
}
