import { EventEmitter } from 'node:events';
import { describe, expect, test } from '@jest/globals';
import { TargetHub, type HubEvent, type TargetSink } from '../hub';
import type { UpstreamSocket } from '../upstream';
import { AisstreamSource } from './aisstream';
import { MtaSubwaySource } from './mta-subway';
import type { Source } from './source';
import { startSources } from './start-sources';

class FakeSocket extends EventEmitter implements UpstreamSocket {
  send() {}
  close() {}
}

const POSITION = JSON.stringify({
  MessageType: 'PositionReport',
  MetaData: { MMSI: 367000001, time_utc: '2026-11-10 14:00:00.000000000 +0000 UTC' },
  Message: { PositionReport: { UserID: 367000001, Latitude: 40.7, Longitude: -73.99, Sog: 1, Cog: 2, TrueHeading: 3 } },
});
const NOW = Date.parse('2026-11-10T14:00:05.000Z');

/** Timers that never fire (the upstream watchdog); nothing real is scheduled. */
const idleTimers = {
  setTimer: () => 0 as unknown as ReturnType<typeof setTimeout>,
  clearTimer: () => {},
};

/** The real AIS source on `sink`, its socket a fake the test drives. */
function aisSource(sink: TargetSink, log: (m: string) => void) {
  const sockets: FakeSocket[] = [];
  const source = new AisstreamSource({
    apiKey: 'k',
    sink,
    log,
    upstream: {
      ...idleTimers,
      socketFactory: () => {
        const s = new FakeSocket();
        sockets.push(s);
        return s;
      },
    },
  });
  return { source, sockets };
}

/** The real MTA source; its poller's timer throws, so start() throws. */
function brokenMtaSource(sink: TargetSink, log: (m: string) => void) {
  return new MtaSubwaySource({
    sink,
    log,
    now: () => NOW,
    poller: {
      fetchFeed: async () => {
        throw new Error('no network in tests');
      },
      setTimer: () => {
        throw new Error('no timers left');
      },
      clearTimer: () => {},
    },
  });
}

describe('source isolation (real sources, one hub)', () => {
  test('the MTA source failing to start doesn\'t stop AIS starting or publishing', () => {
    const hub = new TargetHub(() => NOW);
    const events: HubEvent[] = [];
    hub.subscribe((e) => events.push(e));
    const logs: string[] = [];
    const log = (m: string) => logs.push(m);
    const mta = brokenMtaSource(hub.sink('mta-subway'), log);
    const ais = aisSource(hub.sink('aisstream'), log);

    const started = startSources(
      [
        { id: 'mta-subway', source: mta },
        { id: 'aisstream', source: ais.source },
      ],
      log,
    );
    expect(started).toEqual(['aisstream']);
    expect(logs).toContain('source mta-subway: failed to start: no timers left');
    expect(ais.sockets).toHaveLength(1); // AIS really started: it opened its socket

    ais.sockets[0].emit('open');
    ais.sockets[0].emit('message', Buffer.from(POSITION));
    expect(hub.snapshot().map((t) => [t.id, t.source])).toEqual([['vessel:367000001', 'aisstream']]);
    expect(events).toEqual([{ type: 'update', target: hub.snapshot()[0] }]);
    ais.source.stop();
    mta.stop();
  });

  test('the MTA source publishing into a sink that throws doesn\'t throw, and AIS publishing is unaffected', () => {
    const hub = new TargetHub(() => NOW);
    const events: HubEvent[] = [];
    hub.subscribe((e) => events.push(e));
    const logs: string[] = [];
    const log = (m: string) => logs.push(m);
    const real = hub.sink('mta-subway');
    const mta = brokenMtaSource(
      {
        ...real,
        replaceAll: () => {
          throw new Error('sink broke');
        },
      },
      log,
    );
    const ais = aisSource(hub.sink('aisstream'), log);
    expect(startSources([{ id: 'aisstream', source: ais.source }], log)).toEqual(['aisstream']);
    ais.sockets[0].emit('open');

    expect(() => mta.publish()).not.toThrow();
    ais.sockets[0].emit('message', Buffer.from(POSITION));
    expect(() => mta.publish()).not.toThrow();
    expect(hub.snapshot().map((t) => t.id)).toEqual(['vessel:367000001']);
    expect(events.map((e) => e.type)).toEqual(['update']);
    expect(logs.filter((m) => m.startsWith('mta-subway:'))).toEqual(['mta-subway: publish failed: sink broke']);
    ais.source.stop();
  });
});

describe('startSources', () => {
  test('starts every source in order and returns the ids that started', () => {
    const order: string[] = [];
    const source = (id: string, fail = false): Source => ({
      start: () => {
        order.push(id);
        if (fail) throw new Error(`${id} broke`);
      },
      stop: () => {},
    });
    const logs: string[] = [];
    const running = [
      { id: 'one', source: source('one') },
      { id: 'two', source: source('two', true) },
      { id: 'three', source: source('three') },
    ];
    expect(startSources(running, (m) => logs.push(m))).toEqual(['one', 'three']);
    expect(order).toEqual(['one', 'two', 'three']);
    expect(logs).toEqual(['source two: failed to start: two broke']);
  });
});
