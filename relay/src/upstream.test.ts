import { EventEmitter } from 'node:events';
import { afterEach, beforeEach, describe, expect, jest, test } from '@jest/globals';
import { BOUNDING_BOXES, FILTER_MESSAGE_TYPES } from './config';
import { UpstreamClient, upstreamErrorMessage, type UpstreamSocket } from './upstream';
import type { Normalized, VesselUpdate } from './types';
import type { Normalizer } from './normalizer';

class FakeSocket extends EventEmitter implements UpstreamSocket {
  sent: { at: number; data: string }[] = [];
  closed = false;
  send(data: string) {
    this.sent.push({ at: Date.now(), data });
  }
  close() {
    this.closed = true;
  }
}

const POSITION = JSON.stringify({
  MessageType: 'PositionReport',
  MetaData: { MMSI: 5, time_utc: '2026-11-10 14:00:00.000000000 +0000 UTC' },
  Message: { PositionReport: { UserID: 5, Latitude: 40.7, Longitude: -73.99, Sog: 1, Cog: 2, TrueHeading: 3 } },
});

let sockets: FakeSocket[];
let factoryCalls: { url: string; options: unknown }[];

function makeClient(extra: Partial<ConstructorParameters<typeof UpstreamClient>[0]> = {}) {
  return new UpstreamClient({
    apiKey: 'test-key',
    random: () => 1,
    socketFactory: (url, options) => {
      factoryCalls.push({ url, options });
      const s = new FakeSocket();
      sockets.push(s);
      return s;
    },
    ...extra,
  });
}

beforeEach(() => {
  jest.useFakeTimers();
  sockets = [];
  factoryCalls = [];
});
afterEach(() => {
  jest.useRealTimers();
});

describe('UpstreamClient', () => {
  test('requests perMessageDeflate and sends the subscription on open', () => {
    makeClient().start();
    expect(factoryCalls).toEqual([{ url: 'wss://stream.aisstream.io/v0/stream', options: { perMessageDeflate: true } }]);
    expect(sockets[0].sent).toHaveLength(0);
    sockets[0].emit('open');
    expect(sockets[0].sent).toHaveLength(1);
    expect(JSON.parse(sockets[0].sent[0].data)).toEqual({
      APIKey: 'test-key',
      BoundingBoxes: [
        [
          [40.675, -74.045],
          [40.735, -73.955],
        ],
      ],
      FilterMessageTypes: ['PositionReport', 'ShipStaticData'],
    });
    expect(JSON.parse(sockets[0].sent[0].data).BoundingBoxes).toEqual(BOUNDING_BOXES);
    expect(JSON.parse(sockets[0].sent[0].data).FilterMessageTypes).toEqual(FILTER_MESSAGE_TYPES);
  });

  test('decodes Buffer, ArrayBuffer, Buffer[] and string frames', () => {
    const frames: string[] = [];
    const updates: VesselUpdate[] = [];
    makeClient({ onRawFrame: (t) => frames.push(t), onUpdate: (u) => updates.push(u) }).start();
    const buf = Buffer.from(POSITION, 'utf8');
    const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
    const half = Math.floor(buf.length / 2);
    sockets[0].emit('open');
    sockets[0].emit('message', buf, true);
    sockets[0].emit('message', ab, true);
    sockets[0].emit('message', [buf.subarray(0, half), buf.subarray(half)], true);
    sockets[0].emit('message', POSITION, false);
    expect(frames).toEqual([POSITION, POSITION, POSITION, POSITION]);
    expect(updates).toHaveLength(4);
    expect(updates[0]).toMatchObject({ mmsi: 5, lat: 40.7, timestamp: '2026-11-10T14:00:00.000Z' });
  });

  test('uses injected receive time as fallback timestamp', () => {
    const updates: VesselUpdate[] = [];
    const raw = JSON.stringify({
      MessageType: 'PositionReport',
      MetaData: { MMSI: 5 },
      Message: { PositionReport: { UserID: 5, Latitude: 40.7, Longitude: -74 } },
    });
    makeClient({ now: () => Date.parse('2026-01-02T03:04:05.678Z'), onUpdate: (u) => updates.push(u) }).start();
    sockets[0].emit('message', Buffer.from(raw));
    expect(updates[0].timestamp).toBe('2026-01-02T03:04:05.678Z');
  });

  test('reconnects after close with exponential backoff; counter resets after a delivered message', () => {
    makeClient().start();
    // Socket 1 delivers a message, so the next delay is the base (attempt 0) = 1000.
    sockets[0].emit('open');
    sockets[0].emit('message', Buffer.from(POSITION));
    sockets[0].emit('close');
    jest.advanceTimersByTime(999);
    expect(sockets).toHaveLength(1);
    jest.advanceTimersByTime(1);
    expect(sockets).toHaveLength(2);

    // Socket 2 never delivers: attempts keep growing 1000 -> 2000 -> 4000.
    sockets[1].emit('close');
    jest.advanceTimersByTime(1999);
    expect(sockets).toHaveLength(2);
    jest.advanceTimersByTime(1);
    expect(sockets).toHaveLength(3);
    sockets[2].emit('error', new Error('boom'));
    sockets[2].emit('close'); // duplicate end events must not double-schedule
    jest.advanceTimersByTime(3999);
    expect(sockets).toHaveLength(3);
    jest.advanceTimersByTime(1);
    expect(sockets).toHaveLength(4);

    // A delivered message resets the counter.
    sockets[3].emit('message', Buffer.from(POSITION));
    sockets[3].emit('close');
    jest.advanceTimersByTime(1000);
    expect(sockets).toHaveLength(5);
  });

  test('stop() cancels reconnects and closes the socket', () => {
    const c = makeClient();
    c.start();
    sockets[0].emit('close');
    c.stop();
    jest.advanceTimersByTime(120_000);
    expect(sockets).toHaveLength(1);
    const c2 = makeClient();
    c2.start();
    c2.stop();
    expect(sockets[1].closed).toBe(true);
  });

  test('never sends the subscription twice within 1000 ms across rapid reconnects', () => {
    // backoff of 0 simulates reconnects that open sooner than the guard allows.
    makeClient({ backoff: () => 0 }).start();
    sockets[0].emit('open');
    expect(sockets[0].sent).toHaveLength(1);

    sockets[0].emit('close');
    jest.advanceTimersByTime(0);
    expect(sockets).toHaveLength(2);
    sockets[1].emit('open'); // immediately after: must wait
    jest.advanceTimersByTime(999);
    expect(sockets[1].sent).toHaveLength(0);
    jest.advanceTimersByTime(1);
    expect(sockets[1].sent).toHaveLength(1);

    // A socket that dies while its send is pending never sends.
    sockets[1].emit('close');
    jest.advanceTimersByTime(0);
    sockets[2].emit('open');
    sockets[2].emit('close');
    jest.advanceTimersByTime(5000);
    expect(sockets[2].sent).toHaveLength(0);

    // Subsequent open still respects the gap relative to the last actual send.
    sockets[3].emit('open');
    jest.advanceTimersByTime(1000);
    const times = sockets.flatMap((s) => s.sent.map((m) => m.at));
    expect(times.length).toBeGreaterThanOrEqual(3);
    for (let i = 1; i < times.length; i++) expect(times[i] - times[i - 1]).toBeGreaterThanOrEqual(1000);
  });
});

describe('idle watchdog', () => {
  test('drops and reopens a socket that goes silent without closing', () => {
    const logs: string[] = [];
    makeClient({ idleTimeoutMs: 120_000, log: (m: string) => logs.push(m) }).start();
    sockets[0].emit('open');
    sockets[0].emit('message', Buffer.from(POSITION));
    // Steady data keeps it open.
    for (let i = 0; i < 10; i++) {
      jest.advanceTimersByTime(60_000);
      sockets[0].emit('message', Buffer.from(POSITION));
    }
    expect(sockets).toHaveLength(1);
    // Then silence: dropped within a quarter timeout past the limit, reopened after the base backoff.
    jest.advanceTimersByTime(150_000);
    expect(logs).toContain('upstream: nothing received for 120 s, reconnecting');
    jest.advanceTimersByTime(1000);
    expect(sockets).toHaveLength(2);
    // The dead socket's late close is ignored: no second reconnect.
    sockets[0].emit('close');
    jest.advanceTimersByTime(60_000);
    expect(sockets).toHaveLength(2);
  });

  test('a socket that never opens is dropped too', () => {
    makeClient({ idleTimeoutMs: 40_000 }).start();
    jest.advanceTimersByTime(40_000);
    jest.advanceTimersByTime(1000);
    expect(sockets).toHaveLength(2);
  });

  test('status reports the link and the newest data frame', () => {
    const c = makeClient({ now: () => 1_000 });
    expect(c.status()).toEqual({ connected: false, lastFrameAt: undefined });
    c.start();
    sockets[0].emit('open');
    expect(c.status()).toEqual({ connected: true, lastFrameAt: undefined });
    sockets[0].emit('message', Buffer.from('{"error":"nope"}'));
    expect(c.status().lastFrameAt).toBeUndefined();
    sockets[0].emit('message', Buffer.from(POSITION));
    expect(c.status()).toEqual({ connected: true, lastFrameAt: 1_000 });
    sockets[0].emit('close');
    expect(c.status()).toEqual({ connected: false, lastFrameAt: 1_000 });
    c.stop();
  });
});

describe('aisstream error frames', () => {
  beforeEach(() => {
    sockets = [];
    factoryCalls = [];
  });

  test('upstreamErrorMessage extracts the error text only', () => {
    expect(upstreamErrorMessage('{"error":"Api Key Is Not Valid"}')).toBe('Api Key Is Not Valid');
    expect(upstreamErrorMessage(POSITION)).toBeUndefined();
    expect(upstreamErrorMessage('{"error": 5}')).toBeUndefined();
    expect(upstreamErrorMessage('"error" but not json')).toBeUndefined();
  });

  test('logs the error, emits nothing and does not reset the backoff', () => {
    jest.useFakeTimers();
    try {
      const logs: string[] = [];
      const attempts: number[] = [];
      const updates: VesselUpdate[] = [];
      const client = makeClient({
        log: (m: string) => logs.push(m),
        backoff: (attempt: number) => {
          attempts.push(attempt);
          return 1000;
        },
        onUpdate: (u: VesselUpdate) => updates.push(u),
      });
      client.start();
      for (let i = 0; i < 2; i++) {
        const sock = sockets[i];
        sock.emit('open');
        sock.emit('message', Buffer.from('{"error":"Api Key Is Not Valid"}'));
        sock.emit('close');
        jest.advanceTimersByTime(1000);
      }
      client.stop();
      expect(logs).toContain('upstream: aisstream error: Api Key Is Not Valid');
      expect(updates).toEqual([]);
      expect(attempts).toEqual([0, 1]);
    } finally {
      jest.useRealTimers();
    }
  });
});

describe('UpstreamClient, a delivery that throws', () => {
  test('is logged once, the socket stays open (no reconnect) and the next frame is processed', () => {
    const logs: string[] = [];
    const seen: number[] = [];
    let calls = 0;
    const client = makeClient({
      log: (m: string) => logs.push(m),
      onMessage: (n) => {
        calls++;
        if (calls <= 2) throw new Error('listener broke');
        seen.push(n.update.mmsi);
      },
    });
    client.start();
    sockets[0].emit('open');
    expect(() => sockets[0].emit('message', Buffer.from(POSITION))).not.toThrow();
    expect(() => sockets[0].emit('message', Buffer.from(POSITION))).not.toThrow();
    sockets[0].emit('message', Buffer.from(POSITION));
    expect(seen).toEqual([5]);
    expect(client.status().connected).toBe(true);
    expect(sockets[0].closed).toBe(false);
    jest.advanceTimersByTime(10_000);
    expect(sockets).toHaveLength(1);
    expect(logs.filter((m) => m.startsWith('upstream: message'))).toEqual(['upstream: message delivery failed: listener broke']);
    expect(logs.some((m) => m.includes('reconnecting'))).toBe(false);
    client.stop();
  });

  test('one frame, two messages, the first throws: the second is still delivered', () => {
    const update = (mmsi: number): Normalized => ({
      update: { mmsi, lat: 40.7, lon: -73.99, timestamp: '2026-11-10T14:00:00.000Z' },
      legacy: true,
    });
    // As Normalizer.position() does with held static data: one frame yields the position and the static message.
    const normalizer = { normalizeAll: () => [update(1), update(2)], normalize: () => [] } as unknown as Normalizer;
    const logs: string[] = [];
    const seen: number[] = [];
    const client = makeClient({
      normalizer,
      log: (m: string) => logs.push(m),
      onMessage: (n) => {
        if (n.update.mmsi === 1) throw new Error('first broke');
        seen.push(n.update.mmsi);
      },
    });
    client.start();
    sockets[0].emit('open');
    sockets[0].emit('message', Buffer.from(POSITION));
    expect(seen).toEqual([2]);
    expect(sockets[0].closed).toBe(false);
    expect(client.status().connected).toBe(true);
    expect(logs).toContain('upstream: message delivery failed: first broke');
    client.stop();
  });

  test('the raw-frame hook throwing is a frame failure; the socket stays open', () => {
    const logs: string[] = [];
    const client = makeClient({
      log: (m: string) => logs.push(m),
      onRawFrame: () => {
        throw new Error('recorder broke');
      },
    });
    client.start();
    sockets[0].emit('open');
    expect(() => sockets[0].emit('message', Buffer.from(POSITION))).not.toThrow();
    expect(logs).toContain('upstream: frame processing failed: recorder broke');
    expect(client.status().connected).toBe(true);
    client.stop();
  });
});
