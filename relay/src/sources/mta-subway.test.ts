import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, test } from '@jest/globals';
import { TargetHub, type HubEvent, type TargetSink } from '../hub';
import type { TrainEstimate } from '../subway';
import { SUBWAY_DATA } from '../subway-data';
import { feedName, MTA_FEED_BASE } from '../subway-feed';
import {
  expectedTargetsPath,
  subwayRounds,
  SUBWAY_FIXTURES_DIR,
  trainsFixture,
  type SubwayRound,
} from '../subway-fixtures';
import { mtaSubway, MtaSubwaySource, STALLED_AFTER_MS, TRAIN_EXPIRY_MS, trainTarget } from './mta-subway';

const rounds = subwayRounds();

/** The synthetic response of `round` for a feed URL like .../nyct%2Fgtfs-jz. */
function recorded(round: SubwayRound, url: string): Uint8Array {
  const feed = feedName(decodeURIComponent(url).slice(MTA_FEED_BASE.length));
  return fs.readFileSync(path.join(SUBWAY_FIXTURES_DIR, `${round.stamp}-${feed}.pb`));
}

const fixtureTargets = (round: SubwayRound) => JSON.parse(fs.readFileSync(expectedTargetsPath(round.stamp), 'utf8')).targets;

/** Lets pending promise callbacks (a poll round) run. */
const settle = () => new Promise((resolve) => setImmediate(resolve));

describe('mta-subway source', () => {
  test('each poll publishes the trains of the rounds; trains that left are removed', async () => {
    let now = rounds[0].at;
    let serving = rounds[0];
    const hub = new TargetHub(() => now);
    const events: HubEvent[] = [];
    hub.subscribe((e) => events.push(e));
    const timers: (() => void)[] = [];
    const source = new MtaSubwaySource({
      sink: hub.sink('mta-subway'),
      log: () => {},
      now: () => now,
      poller: {
        fetchFeed: async (url) => recorded(serving, url),
        setTimer: (fn) => {
          timers.push(fn);
          return 0 as unknown as ReturnType<typeof setTimeout>;
        },
        clearTimer: () => {},
      },
    });
    source.start();
    timers.shift()!();
    await settle();
    expect(hub.snapshot()).toEqual(fixtureTargets(rounds[0]));

    // A minute after round 2, still on round 2's feeds: 90 s after round 1, some of round 1's trains have run out of
    // the area (or their predictions did) and are removed, and others, reported since, appear.
    serving = rounds[1];
    now = rounds[1].at + 60_000;
    events.length = 0;
    timers.shift()!();
    await settle();
    source.stop();
    const after = JSON.parse(trainsFixture({ ...rounds[1], at: now }, SUBWAY_DATA).text).targets;
    expect(after.length).toBeGreaterThan(0);
    expect(hub.snapshot()).toEqual(after);
    const gone = fixtureTargets(rounds[0])
      .map((t: { id: string }) => t.id)
      .filter((id: string) => !after.some((t: { id: string }) => t.id === id));
    expect(gone.length).toBeGreaterThan(0);
    expect(events.filter((e) => e.type === 'remove')).toEqual(gone.map((id: string) => ({ type: 'remove', id })));

    // Nothing re-estimates them after the source stops: they expire.
    now += TRAIN_EXPIRY_MS;
    expect(hub.sweep()).toBe(0);
    now += 1;
    expect(hub.sweep()).toBe(after.length);
  });

  test('feeds gone stale publish an empty list, removing every train; health stays ok until the loop stalls', async () => {
    let now = rounds[0].at;
    const hub = new TargetHub(() => now);
    const timers: (() => void)[] = [];
    const source = new MtaSubwaySource({
      sink: hub.sink('mta-subway'),
      log: () => {},
      now: () => now,
      poller: {
        fetchFeed: async (url) => recorded(rounds[0], url),
        setTimer: (fn) => {
          timers.push(fn);
          return 0 as unknown as ReturnType<typeof setTimeout>;
        },
        clearTimer: () => {},
      },
    });
    source.start();
    timers.shift()!();
    await settle();
    source.stop();
    expect(hub.size).toBeGreaterThan(0);
    const newest = Math.max(...[...rounds[0].feeds.values()].map((f) => f.timestamp!));
    const polledAt = now;
    expect(source.health(now)).toEqual({ ok: true, lastDataAgeSeconds: Math.round(now / 1000 - newest) });
    now += 181_000; // past MAX_FEED_AGE_SECONDS
    source.publish();
    expect(hub.size).toBe(0);
    // Old MTA data is reported, not failed: a restart can't fix it.
    expect(source.health(now)).toEqual({ ok: true, lastDataAgeSeconds: Math.round(now / 1000 - newest) });
    // No round finished for STALLED_AFTER_MS: the poll loop died.
    expect(source.health(polledAt + STALLED_AFTER_MS).ok).toBe(true);
    expect(source.health(polledAt + STALLED_AFTER_MS + 1).ok).toBe(false);
  });

  test('health before the first round counts from start, with no data age', () => {
    const source = new MtaSubwaySource({
      sink: new TargetHub(() => 0).sink('mta-subway'),
      log: () => {},
      now: () => 5_000,
      poller: { setTimer: () => 0 as unknown as ReturnType<typeof setTimeout>, clearTimer: () => {} },
    });
    source.start();
    expect(source.health(5_000 + STALLED_AFTER_MS)).toEqual({ ok: true, lastDataAgeSeconds: undefined });
    expect(source.health(5_001 + STALLED_AFTER_MS).ok).toBe(false);
    source.stop();
  });

  const estimate: TrainEstimate = {
    tripId: '101100_Q..S36R',
    route: 'Q',
    direction: 'S',
    destination: 'Coney Island-Stillwell Av',
    stretch: 'manhattan-bridge',
    underground: false,
    lat: 40.7071,
    lon: -73.9905,
    altitude: 42,
    altitudeEstimated: false,
    bearing: 157.1,
    speed: 16.4,
    timestamp: '2026-11-10T14:11:50.000Z',
  };

  test('a train as a target: shared keys first, then the train object; destination omitted when unknown', () => {
    const t = trainTarget(estimate);
    expect(t).toEqual({
      id: 'train:nyct:101100_Q..S36R',
      kind: 'train',
      source: 'mta-subway',
      lat: 40.7071,
      lon: -73.9905,
      altitude: 42,
      speed: 16.4,
      course: 157.1,
      timestamp: '2026-11-10T14:11:50.000Z',
      train: { route: 'Q', direction: 'S', destination: 'Coney Island-Stillwell Av', stretch: 'manhattan-bridge', underground: false, altitudeEstimated: false },
    });
    expect(Object.keys(t)).toEqual(['id', 'kind', 'source', 'lat', 'lon', 'altitude', 'speed', 'course', 'timestamp', 'train']);
    expect(Object.keys(t.train!)).toEqual(['route', 'direction', 'destination', 'stretch', 'underground', 'altitudeEstimated']);
    const unknown = trainTarget({ ...estimate, destination: undefined });
    expect(Object.keys(unknown.train!)).toEqual(['route', 'direction', 'stretch', 'underground', 'altitudeEstimated']);
  });

  test('an underground train as a target: no stretch key, underground and altitudeEstimated always present', () => {
    const { stretch: _stretch, ...onStretch } = estimate;
    const t = trainTarget({ ...onStretch, underground: true, altitude: -17.3, altitudeEstimated: true });
    expect(t.altitude).toBe(-17.3);
    expect(t.train).toEqual({ route: 'Q', direction: 'S', destination: 'Coney Island-Stillwell Av', underground: true, altitudeEstimated: true });
    expect(Object.keys(t.train!)).toEqual(['route', 'direction', 'destination', 'underground', 'altitudeEstimated']);
    expect(JSON.stringify(t)).not.toContain('stretch');
    expect(JSON.stringify(t)).toContain('"underground":true');
    expect(Object.keys(trainTarget({ ...onStretch, underground: true, destination: undefined }).train!)).toEqual([
      'route',
      'direction',
      'underground',
      'altitudeEstimated',
    ]);
  });

  test('needs no settings', () => {
    expect(typeof mtaSubway.configure({})).toBe('function');
  });

  test('a sink that throws: publish() never throws, logs once, and delivers again once the sink recovers', async () => {
    const now = rounds[0].at;
    const hub = new TargetHub(() => now);
    const real = hub.sink('mta-subway');
    let broken = true;
    const sink: TargetSink = {
      upsert: real.upsert,
      remove: real.remove,
      replaceAll: (targets, expiresAt) => {
        if (broken) throw new Error('sink broke');
        real.replaceAll(targets, expiresAt);
      },
    };
    const logs: string[] = [];
    const timers: (() => void)[] = [];
    const source = new MtaSubwaySource({
      sink,
      log: (m) => logs.push(m),
      now: () => now,
      poller: {
        fetchFeed: async (url) => recorded(rounds[0], url),
        setTimer: (fn) => {
          timers.push(fn);
          return 0 as unknown as ReturnType<typeof setTimeout>;
        },
        clearTimer: () => {},
      },
    });
    source.start();
    timers.shift()!(); // the first poll round publishes, into the broken sink
    await settle();
    expect(() => source.publish()).not.toThrow(); // as the 10 s ticker would
    expect(hub.size).toBe(0);
    expect(logs.filter((m) => m.startsWith('mta-subway:'))).toEqual(['mta-subway: publish failed: sink broke']);
    // The poll loop survived: its next round is scheduled.
    expect(timers).toHaveLength(1);

    broken = false;
    source.publish();
    source.stop();
    expect(hub.snapshot()).toEqual(fixtureTargets(rounds[0]));
    expect(logs.filter((m) => m.startsWith('mta-subway:'))).toEqual(['mta-subway: publish failed: sink broke']);
  });

  test('trips whose estimate throws log one rate-limited line, not one per trip, and only new failures log again', () => {
    let now = rounds[0].at;
    const logs: string[] = [];
    const source = new MtaSubwaySource({
      sink: new TargetHub(() => now).sink('mta-subway'),
      log: (m) => logs.push(m),
      now: () => now,
    });
    // The estimator is private: stand in for one that throws on some trips (its own per-trip guard is tested in
    // subway.test.ts), so what's tested here is how the source logs them.
    let failing = ['A', 'B', 'C'];
    (source as unknown as { estimator: { estimateAll: unknown } }).estimator.estimateAll = (
      _feeds: unknown,
      _now: number,
      onError: (tripId: string, err: unknown) => void,
    ) => {
      for (const id of failing) onError(id, new Error('boom'));
      return [];
    };
    const tripLogs = () => logs.filter((m) => m.startsWith('mta-subway: trip'));

    source.publish();
    expect(tripLogs()).toEqual(['mta-subway: trip A skipped: boom']); // three trips failed, one line
    source.publish(); // the same three again: nothing new
    expect(tripLogs()).toHaveLength(1);

    now += 61_000; // a window later, with two trips that are new
    failing = ['A', 'B', 'C', 'D', 'E'];
    source.publish();
    expect(tripLogs()).toEqual([
      'mta-subway: trip A skipped: boom',
      'mta-subway: trip D skipped: boom (and 2 more since the last line)',
    ]);
  });
});
