import { describe, expect, test } from '@jest/globals';
import type { FeedMessage } from './gtfsrt';
import { SUBWAY_DATA } from './subway-data';
import {
  feedName,
  feedUrl,
  MAX_RETRY_MS,
  MTA_FEED_BASE,
  POLL_INTERVAL_MS,
  SUBWAY_FEED_ROUTES,
  SUBWAY_FEEDS,
  SubwayPoller,
  type FetchFeed,
} from './subway-feed';
import { ProtoWriter } from './tools/protobuf-writer';

const feedBytes = (timestamp: number) => new ProtoWriter().message(1, (h) => h.string(1, '1.0').varint(3, timestamp)).finish();

/** Timers the test fires by hand. */
function manualTimers() {
  const pending: { fn: () => void; ms: number; cancelled: boolean }[] = [];
  return {
    pending,
    setTimer: (fn: () => void, ms: number) => {
      const t = { fn, ms, cancelled: false };
      pending.push(t);
      return t as unknown as ReturnType<typeof setTimeout>;
    },
    clearTimer: (h: ReturnType<typeof setTimeout>) => {
      (h as unknown as { cancelled: boolean }).cancelled = true;
    },
    /** Fires the oldest timer and waits for the poll round it starts. */
    async fire(poller: SubwayPoller): Promise<number> {
      const t = pending.shift()!;
      if (!t.cancelled) {
        t.fn();
        await poller.pollOnce();
      }
      return t.ms;
    },
  };
}

describe('SubwayPoller', () => {
  test('the default feeds and URLs are the MTA subway feeds, encoded', () => {
    expect(SUBWAY_FEEDS).toEqual([
      'nyct/gtfs',
      'nyct/gtfs-ace',
      'nyct/gtfs-bdfm',
      'nyct/gtfs-g',
      'nyct/gtfs-jz',
      'nyct/gtfs-l',
      'nyct/gtfs-nqrw',
    ]);
    expect(feedUrl(MTA_FEED_BASE, 'nyct/gtfs-jz')).toBe('https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-jz');
    expect(feedUrl(MTA_FEED_BASE, 'nyct/gtfs')).toBe('https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs');
  });

  test('every route with track in the extract comes from exactly one polled feed', () => {
    const feedsOf = (route: string) => SUBWAY_FEEDS.filter((f) => SUBWAY_FEED_ROUTES[f].includes(route));
    expect(SUBWAY_DATA.routes.filter((r) => feedsOf(r).length !== 1)).toEqual([]);
    expect(feedsOf('1')).toEqual(['nyct/gtfs']);
    expect(feedsOf('A')).toEqual(['nyct/gtfs-ace']);
    expect(feedsOf('F')).toEqual(['nyct/gtfs-bdfm']);
    expect(feedsOf('L')).toEqual(['nyct/gtfs-l']);
    expect(feedsOf('W')).toEqual(['nyct/gtfs-nqrw']);
  });

  test('feeds have short names for their fixture files', () => {
    expect(SUBWAY_FEEDS.map(feedName)).toEqual(['numbered', 'ace', 'bdfm', 'g', 'jz', 'l', 'nqrw']);
  });

  test('polls every feed each round, keeps the latest good message per feed, never faster than 30 s', async () => {
    const urls: string[] = [];
    let t = 1000;
    const fetchFeed: FetchFeed = async (url) => {
      urls.push(url);
      return feedBytes(t);
    };
    const timers = manualTimers();
    const polls: FeedMessage[][] = [];
    const poller = new SubwayPoller({
      feeds: ['a', 'b/c'],
      baseUrl: 'https://feeds.invalid/',
      intervalMs: 1000,
      fetchFeed,
      ...timers,
      onPoll: (f) => polls.push(f),
    });
    poller.start();
    expect(await timers.fire(poller)).toBe(0);
    expect(urls).toEqual(['https://feeds.invalid/a', 'https://feeds.invalid/b%2Fc']);
    expect(poller.latest().map((f) => f.timestamp)).toEqual([1000, 1000]);
    t = 1030;
    expect(await timers.fire(poller)).toBe(POLL_INTERVAL_MS);
    expect(polls.map((p) => p.map((f) => f.timestamp))).toEqual([
      [1000, 1000],
      [1030, 1030],
    ]);
    poller.stop();
    expect(timers.pending.every((p) => p.cancelled)).toBe(true);
  });

  test('lastRoundAt marks each finished round, whether or not its fetches worked', async () => {
    let now = 7_000;
    let fail = false;
    const poller = new SubwayPoller({
      feeds: ['a'],
      now: () => now,
      fetchFeed: async () => {
        if (fail) throw new Error('down');
        return feedBytes(1);
      },
    });
    expect(poller.lastRoundAt()).toBeUndefined();
    await poller.pollOnce();
    expect(poller.lastRoundAt()).toBe(7_000);
    now = 9_000;
    fail = true;
    await poller.pollOnce();
    expect(poller.lastRoundAt()).toBe(9_000);
  });

  test('a failing feed keeps its last good message; failures and recovery are logged once each', async () => {
    const logs: string[] = [];
    let failB = false;
    const fetchFeed: FetchFeed = async (url) => {
      if (url.endsWith('b') && failB) throw new Error('HTTP 503');
      return feedBytes(url.endsWith('a') ? 2000 : 1000);
    };
    const timers = manualTimers();
    const poller = new SubwayPoller({ feeds: ['a', 'b'], baseUrl: '', fetchFeed, ...timers, log: (m) => logs.push(m) });
    poller.start();
    await timers.fire(poller);
    failB = true;
    await timers.fire(poller);
    await timers.fire(poller);
    expect(poller.latest().map((f) => f.timestamp)).toEqual([2000, 1000]);
    expect(logs).toEqual(['subway: b failed: HTTP 503']);
    failB = false;
    await timers.fire(poller);
    expect(logs).toEqual(['subway: b failed: HTTP 503', 'subway: b recovered']);
    // One good feed is enough to keep the normal interval.
    expect(timers.pending.map((p) => p.ms)).toEqual([POLL_INTERVAL_MS]);
    poller.stop();
  });

  test('undecodable bytes count as a failure', async () => {
    const logs: string[] = [];
    const timers = manualTimers();
    const poller = new SubwayPoller({
      feeds: ['a'],
      baseUrl: '',
      fetchFeed: async () => Buffer.from('<html>Service Unavailable</html>'),
      ...timers,
      log: (m) => logs.push(m),
    });
    poller.start();
    await timers.fire(poller);
    expect(poller.latest()).toEqual([]);
    expect(logs[0]).toMatch(/^subway: a failed: /);
    poller.stop();
  });

  test('when every feed fails, the wait doubles up to MAX_RETRY_MS, then resets on success', async () => {
    let fail = true;
    const timers = manualTimers();
    const poller = new SubwayPoller({
      feeds: ['a', 'b'],
      baseUrl: '',
      fetchFeed: async () => {
        if (fail) throw new Error('offline');
        return feedBytes(1);
      },
      ...timers,
    });
    poller.start();
    const waits: number[] = [];
    for (let i = 0; i < 7; i++) waits.push(await timers.fire(poller));
    expect(waits).toEqual([0, 60_000, 120_000, 240_000, 480_000, MAX_RETRY_MS, MAX_RETRY_MS]);
    fail = false;
    await timers.fire(poller);
    expect(timers.pending.map((p) => p.ms)).toEqual([POLL_INTERVAL_MS]);
    poller.stop();
  });

  test('stop() before the first round: nothing is fetched', async () => {
    const timers = manualTimers();
    let calls = 0;
    const poller = new SubwayPoller({ fetchFeed: async () => (calls++, feedBytes(1)), ...timers });
    poller.start();
    poller.stop();
    await timers.fire(poller);
    expect(calls).toBe(0);
  });

  test('onPoll throwing: pollOnce still resolves, the failure is logged (rate limited), the loop goes on', async () => {
    const timers = manualTimers();
    const logs: string[] = [];
    let broken = true;
    let polls = 0;
    const poller = new SubwayPoller({
      feeds: ['a'],
      fetchFeed: async () => feedBytes(1),
      log: (m) => logs.push(m),
      ...timers,
      onPoll: () => {
        polls++;
        if (broken) throw new Error('publish broke');
      },
    });
    await expect(poller.pollOnce()).resolves.toBeUndefined();
    poller.start();
    await timers.fire(poller);
    // The next round is still scheduled, at the normal interval: the fetches worked.
    expect(timers.pending.map((p) => p.ms)).toEqual([POLL_INTERVAL_MS]);
    await timers.fire(poller);
    expect(polls).toBe(3);
    expect(logs).toEqual(['subway: publish failed: publish broke']);
    broken = false;
    await timers.fire(poller);
    expect(polls).toBe(4);
    expect(logs).toEqual(['subway: publish failed: publish broke']);
    expect(timers.pending.map((p) => p.ms)).toEqual([POLL_INTERVAL_MS]);
    poller.stop();
  });
});
