/**
 * Chaos tests: hostile upstream frames and hostile clients, from a seeded RNG (fixtures and localhost only).
 *
 * Seed: fixed by default, `RELAY_CHAOS_SEED=<int>` to try another one. Every failure message here carries the seed.
 * A case that documents a real bug is `test.failing` with a `CHAOS-FINDING` comment: it passes while the bug exists and
 * turns red once it is fixed (then change it to a plain `test`).
 */
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, test } from '@jest/globals';
import WebSocket from 'ws';
import { BOUNDING_BOXES } from './config';
import { decodeFeedMessage, GtfsRtError } from './gtfsrt';
import { TargetHub } from './hub';
import { Normalizer } from './normalizer';
import { Registry } from './registry';
import { createRelayServer, type RelayServer } from './server';
import { AisstreamSource } from './sources/aisstream';
import { MtaSubwaySource, trainTarget } from './sources/mta-subway';
import { SUBWAY_DATA } from './subway-data';
import { SUBWAY_FIXTURES_DIR } from './subway-fixtures';
import type { Target } from './targets';
import type { VesselUpdate } from './types';
import type { UpstreamSocket } from './upstream';

// ---------------------------------------------------------------------------------------------------- seeded RNG

const SEED = (() => {
  const raw = process.env.RELAY_CHAOS_SEED;
  const n = raw === undefined || raw.trim() === '' ? NaN : Number(raw);
  return Number.isInteger(n) ? n >>> 0 : 0xc0ffee;
})();

/** mulberry32: a tiny seeded generator, uniform in [0, 1). */
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** A generator for one test: the same seed and label always give the same stream. */
function rngFor(label: string) {
  let h = SEED;
  for (const ch of label) h = Math.imul(h ^ ch.charCodeAt(0), 0x01000193) >>> 0;
  const next = mulberry32(h);
  return {
    next,
    int: (lo: number, hi: number) => lo + Math.floor(next() * (hi - lo + 1)),
    pick: <T>(xs: readonly T[]): T => xs[Math.floor(next() * xs.length)],
    chance: (p: number) => next() < p,
  };
}

/** Throws with the seed in the message (expect() has no custom message). */
function check(ok: boolean, what: string): asserts ok {
  if (!ok) throw new Error(`[RELAY_CHAOS_SEED=${SEED}] ${what}`);
}

// ------------------------------------------------------------------------------------------------ hostile frames

const NOW = Date.parse('2026-11-10T14:12:00.000Z');
const BOX = BOUNDING_BOXES[0];
const [[LAT_MIN, LON_MIN], [LAT_MAX, LON_MAX]] = BOX;
const inBox = (lat: number, lon: number) => lat >= LAT_MIN && lat <= LAT_MAX && lon >= LON_MIN && lon <= LON_MAX;

/** JSON.stringify turns Infinity into null, so a number that parses to Infinity is a placeholder swapped in after. */
const INF = '__INF__';
const toWire = (value: unknown): string => JSON.stringify(value).replaceAll(`"${INF}"`, '1e999').replaceAll(`"-${INF}"`, '-1e999');

const HOSTILE_NUMBERS: readonly unknown[] = [
  'NaN', 'Infinity', '-Infinity', '1e999', '', ' ', '40.7', '0x10', null, true, false, [], {}, [40.7],
  INF, `-${INF}`, 1e308, -1e308, 5e-324, -0, 0, -1, 91, -91, 181, -181, 90, -90, 180, -180, 2 ** 53, -(2 ** 53), 4294967296, 1e21,
];
const HOSTILE_NAMES: readonly unknown[] = [
  '', ' ', '@@@@@@@@@@', '   PADDED   @@@', 'A'.repeat(10_000), '\u{1F6A2}'.repeat(5_000), 'BOAT \u{1F6A2}\u{1F6A2}\u{1F6A2}\u{1F6A2}\u{1F6A2}\u{1F6A2} WITH EMOJI',
  '‮evil‬', '‭ltr⁦x⁩', 'zero​width‍﻿', 'line1\nline2\r\nline3', 'tab\tsep', '\u0000\u0001\u0007\u001B[31mred',
  'a b c', '\u0085next', 'x'.repeat(19) + '\u{1F6A2}tail', '<script>alert(1)</script>', '"; DROP TABLE vessels;--', '\uD800 lone surrogate',
  null, 7, true, [], {}, ['A'], { a: 1 },
];
const NEWLINEY = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u;

interface Frame {
  wire: string | Buffer;
}

/** A plausible frame with every field pulled from the hostile pools at random. */
function hostileFrame(rng: ReturnType<typeof rngFor>): string {
  const lat = rng.chance(0.6) ? rng.pick([40.7, 40.71, 40.72]) : rng.pick(HOSTILE_NUMBERS);
  const lon = rng.chance(0.6) ? rng.pick([-73.99, -74.01, -73.97]) : rng.pick(HOSTILE_NUMBERS);
  const mmsi = rng.chance(0.5) ? rng.int(1, 40) : rng.pick(HOSTILE_NUMBERS);
  const time = rng.pick([
    '2026-11-10 14:00:00.123456789 +0000 UTC', '2026-11-10 14:11:59.000000000 +0000 UTC', '2026-13-45 99:99:99 +0000 UTC', '', 'yesterday', 12345, null,
  ]);
  const meta = { MMSI: mmsi, time_utc: time, latitude: rng.pick(HOSTILE_NUMBERS), longitude: rng.pick(HOSTILE_NUMBERS), ShipName: rng.pick(HOSTILE_NAMES) };
  const kind = rng.int(0, 9);
  if (kind <= 4) {
    return toWire({
      MessageType: 'PositionReport',
      MetaData: meta,
      Message: {
        PositionReport: {
          UserID: rng.pick(HOSTILE_NUMBERS), Latitude: lat, Longitude: lon, Sog: rng.pick(HOSTILE_NUMBERS), Cog: rng.pick(HOSTILE_NUMBERS),
          TrueHeading: rng.pick(HOSTILE_NUMBERS), NavigationalStatus: rng.pick(HOSTILE_NUMBERS),
        },
      },
    });
  }
  if (kind <= 7) {
    return toWire({
      MessageType: 'ShipStaticData',
      MetaData: meta,
      Message: {
        ShipStaticData: {
          UserID: rng.pick(HOSTILE_NUMBERS), Name: rng.pick(HOSTILE_NAMES), CallSign: rng.pick(HOSTILE_NAMES), Destination: rng.pick(HOSTILE_NAMES),
          Type: rng.pick(HOSTILE_NUMBERS), ImoNumber: rng.pick(HOSTILE_NUMBERS), MaximumStaticDraught: rng.pick(HOSTILE_NUMBERS),
          Dimension: rng.chance(0.8) ? { A: rng.pick(HOSTILE_NUMBERS), B: rng.pick(HOSTILE_NUMBERS), C: rng.pick(HOSTILE_NUMBERS), D: rng.pick(HOSTILE_NUMBERS) } : rng.pick(HOSTILE_NAMES),
          Eta: rng.chance(0.8) ? { Month: rng.pick(HOSTILE_NUMBERS), Day: rng.pick(HOSTILE_NUMBERS), Hour: rng.pick(HOSTILE_NUMBERS), Minute: rng.pick(HOSTILE_NUMBERS) } : rng.pick(HOSTILE_NUMBERS),
        },
      },
    });
  }
  // Unknown message types, wrong containers, and v1/v2 relay shapes sent upstream by mistake.
  return toWire(
    rng.pick<unknown>([
      { MessageType: 'BaseStationReport', MetaData: meta, Message: { BaseStationReport: { Latitude: 40.7, Longitude: -73.99 } } },
      { MessageType: 'PositionReport', MetaData: meta, Message: { PositionReport: 'nope' } },
      { MessageType: 'PositionReport', MetaData: 'x', Message: 5 },
      { MessageType: 7, MetaData: meta, Message: null },
      { MessageType: 'ShipStaticData', Message: { ShipStaticData: [] } },
      { type: 'snapshot', vessels: [{ mmsi: 1, lat: 40.7, lon: -73.99, timestamp: '2026-11-10T14:00:00.000Z' }] },
      { type: 'update', target: { id: 'vessel:1', kind: 'vessel', source: 'x', lat: 40.7, lon: -73.99, timestamp: '2026-11-10T14:00:00.000Z' } },
      { type: 'remove', id: 'vessel:1' },
      { error: 'Api Key Is Not Valid' },
      [], [[]], 'string', 42, null, true, {},
    ]),
  );
}

/** Frames of every broken shape: cut JSON, binary garbage, huge, deeply nested, not text at all. */
function brokenFrames(rng: ReturnType<typeof rngFor>): unknown[] {
  const good = toWire({
    MessageType: 'PositionReport',
    MetaData: { MMSI: 9, time_utc: '2026-11-10 14:00:00.000000000 +0000 UTC' },
    Message: { PositionReport: { UserID: 9, Latitude: 40.7, Longitude: -73.99, Sog: 1, Cog: 2, TrueHeading: 3 } },
  });
  const out: unknown[] = [];
  for (let i = 0; i < 100; i++) out.push(good.slice(0, rng.int(0, good.length - 1)));
  for (let i = 0; i < 100; i++) {
    const chars = good.split('');
    chars[rng.int(0, chars.length - 1)] = String.fromCharCode(rng.int(0, 0x2ff));
    out.push(chars.join(''));
  }
  for (let i = 0; i < 60; i++) out.push(Buffer.from(Array.from({ length: rng.int(0, 400) }, () => rng.int(0, 255))));
  out.push(Buffer.from(good), [Buffer.from(good.slice(0, 20)), Buffer.from(good.slice(20))], new Uint8Array(Buffer.from(good)), new Uint8Array(0).buffer);
  out.push(new Uint16Array([1, 2, 3]), 'x'.repeat(5 * 1024 * 1024), '['.repeat(100_000), '{"a":'.repeat(50_000), '\u0000'.repeat(1000), 'null', '', ' ');
  out.push(undefined, null, 42, true, { MessageType: 'PositionReport' });
  return out;
}

class FakeSocket extends EventEmitter implements UpstreamSocket {
  send() {}
  close() {}
}

/** A source wired to a fake upstream socket: `feed(x)` is a frame arriving, as `ws` would deliver it. */
function rig() {
  const logs: string[] = [];
  const hub = new TargetHub(() => NOW);
  const legacy: VesselUpdate[] = [];
  const sockets: FakeSocket[] = [];
  const source = new AisstreamSource({
    apiKey: 'k',
    sink: hub.sink('aisstream'),
    log: (m) => logs.push(m),
    legacyVesselUpdate: (u) => legacy.push(u),
    upstream: {
      now: () => NOW,
      setTimer: () => 0 as unknown as ReturnType<typeof setTimeout>,
      clearTimer: () => {},
      socketFactory: () => {
        const s = new FakeSocket();
        sockets.push(s);
        return s;
      },
    },
  });
  source.start();
  sockets[0].emit('open');
  const feed = (data: unknown) => sockets[0].emit('message', data);
  return { hub, legacy, logs, source, feed };
}

const GOOD_FRAME = (mmsi: number, lat = 40.7, lon = -73.99, time = '2026-11-10 14:11:00.000000000 +0000 UTC') =>
  toWire({
    MessageType: 'PositionReport',
    MetaData: { MMSI: mmsi, time_utc: time },
    Message: { PositionReport: { UserID: mmsi, Latitude: lat, Longitude: lon, Sog: 1, Cog: 2, TrueHeading: 3 } },
  });

/** Every number in `value` is finite, and no `null` or `undefined` is carried as a value. */
function wellFormed(value: unknown, where: string): void {
  if (typeof value === 'number') check(Number.isFinite(value), `${where}: non-finite number ${value}`);
  else if (value === null || value === undefined) check(false, `${where}: null/undefined value`);
  else if (typeof value === 'object') for (const [k, v] of Object.entries(value)) wellFormed(v, `${where}.${k}`);
}

const cleanTextOk = (s: unknown, max: number, where: string) => {
  if (s === undefined) return;
  check(typeof s === 'string', `${where}: not a string`);
  check(Array.from(s).length <= max, `${where}: longer than ${max} characters (${Array.from(s).length})`);
  check(!NEWLINEY.test(s), `${where}: control or invisible format character left in ${JSON.stringify(s.slice(0, 40))}`);
  check(s === s.trim() && !/^@|@$/.test(s) && !/\s{2}/.test(s) && s !== '', `${where}: padding or whitespace run left in ${JSON.stringify(s.slice(0, 40))}`);
};

/** What PROTOCOL.md promises of every published vessel target, whatever came in. */
function checkTarget(t: Target): void {
  const where = `target ${t.id}`;
  wellFormed(t, where);
  check(t.id === `vessel:${t.vessel?.mmsi}` && Number.isInteger(t.vessel?.mmsi) && (t.vessel?.mmsi ?? 0) > 0, `${where}: id and mmsi disagree`);
  check(Math.abs(t.lat) <= 90 && Math.abs(t.lon) <= 180, `${where}: lat/lon out of range (${t.lat}, ${t.lon})`);
  check(!Number.isNaN(Date.parse(t.timestamp)), `${where}: bad timestamp ${t.timestamp}`);
  for (const key of ['course', 'heading'] as const) {
    const v = t[key];
    check(v === undefined || (v >= 0 && v < 360), `${where}: ${key} ${v} outside [0, 360)`);
  }
  check(t.speed === undefined || (t.speed >= 0 && t.speed < 102.3), `${where}: speed ${t.speed}`);
  cleanTextOk(t.name, 20, `${where}.name`);
  cleanTextOk(t.vessel?.callSign, 7, `${where}.callSign`);
  cleanTextOk(t.vessel?.destination, 20, `${where}.destination`);
  const v = t.vessel!;
  check(v.shipType === undefined || (Number.isInteger(v.shipType) && v.shipType >= 1 && v.shipType <= 99), `${where}: shipType ${v.shipType}`);
  check(v.navStatus === undefined || (Number.isInteger(v.navStatus) && v.navStatus >= 0 && v.navStatus <= 14), `${where}: navStatus ${v.navStatus}`);
  check(v.draught === undefined || (v.draught >= 0 && v.draught <= 25.5) /* 0: see the draught finding */, `${where}: draught ${v.draught}`);
  check(v.length === undefined || (Number.isInteger(v.length) && v.length > 0), `${where}: length ${v.length}`);
  check(v.beam === undefined || (Number.isInteger(v.beam) && v.beam > 0), `${where}: beam ${v.beam}`);
  if (v.eta) {
    const { month, day, hour, minute } = v.eta;
    check(month >= 1 && month <= 12 && day >= 1 && day <= 31 && hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59, `${where}: eta ${JSON.stringify(v.eta)}`);
  }
}

describe('chaos: hostile AIS frames', () => {
  test(`a storm of random hostile frames (seed ${SEED}): nothing throws, nothing is logged as a failure, everything published is well formed`, () => {
    const rng = rngFor('storm');
    const { hub, legacy, logs, feed } = rig();
    const events: unknown[] = [];
    hub.subscribe((e) => events.push(e));
    for (let i = 0; i < 4000; i++) {
      const frame = hostileFrame(rng);
      try {
        feed(rng.chance(0.2) ? Buffer.from(frame) : frame);
      } catch (err) {
        check(false, `frame #${i} threw out of the upstream handler: ${String(err)}\n${frame.slice(0, 300)}`);
      }
    }
    // A throw inside the pipeline is swallowed by the guards but logged: that is still a bug in the relay.
    const failures = logs.filter((l) => /failed|ERROR|FATAL/.test(l));
    check(failures.length === 0, `guarded failure logged: ${failures[0]}`);
    const targets = hub.snapshot();
    check(targets.length > 0, 'the storm should still have let some valid-looking frames through');
    targets.forEach(checkTarget);
    for (const u of legacy) {
      wellFormed(u, `v1 update ${u.mmsi}`);
      check(Math.abs(u.lat) <= 90 && Math.abs(u.lon) <= 180, `v1 update ${u.mmsi} out of range`);
    }
    for (const e of events) wellFormed(e, 'hub event');
    // Everything survived a JSON round trip, as it must to reach a client.
    expect(JSON.parse(JSON.stringify(targets))).toEqual(targets);
  });

  test('broken shapes: cut JSON, byte garbage, binary buffers, 5 MB and 100k-deep frames, non-frames', () => {
    const rng = rngFor('broken');
    const { hub, logs, feed } = rig();
    const started = Date.now();
    for (const [i, frame] of brokenFrames(rng).entries()) {
      try {
        feed(frame);
      } catch (err) {
        check(false, `broken frame #${i} threw out of the upstream handler: ${String(err)}`);
      }
    }
    check(Date.now() - started < 5000, `broken frames took ${Date.now() - started} ms`);
    const failures = logs.filter((l) => /failed|FATAL/.test(l));
    check(failures.length === 0, `guarded failure logged: ${failures[0]}`);
    hub.snapshot().forEach(checkTarget);
    // The process keeps serving: a good frame afterwards still publishes.
    feed(GOOD_FRAME(777));
    expect(hub.snapshot().map((t) => t.id)).toContain('vessel:777');
  });

  test('names are cleaned as PROTOCOL.md says: control, bidi and zero-width characters out, 20 characters, no padding', () => {
    const { hub, feed } = rig();
    const names = HOSTILE_NAMES.filter((n): n is string => typeof n === 'string');
    names.forEach((name, i) => {
      const mmsi = 1000 + i;
      feed(GOOD_FRAME(mmsi));
      feed(
        toWire({
          MessageType: 'ShipStaticData',
          MetaData: { MMSI: mmsi, time_utc: '2026-11-10 14:11:01.000000000 +0000 UTC' },
          Message: { ShipStaticData: { UserID: mmsi, Name: name, CallSign: name, Destination: name, Type: 60 } },
        }),
      );
    });
    const targets = hub.snapshot().filter((t) => t.id !== 'vessel:777');
    expect(targets).toHaveLength(names.length);
    targets.forEach(checkTarget);
    const byName = (i: number) => hub.snapshot().find((t) => t.id === `vessel:${1000 + i}`)!;
    expect(byName(names.indexOf('A'.repeat(10_000))).name).toBe('A'.repeat(20));
    expect(byName(names.indexOf('‮evil‬')).name).toBe('evil');
    expect(byName(names.indexOf('line1\nline2\r\nline3')).name).toBe('line1 line2 line3');
    expect(byName(names.indexOf('@@@@@@@@@@')).name).toBeUndefined();
    expect(byName(names.indexOf('\u{1F6A2}'.repeat(5_000))).name).toBe('\u{1F6A2}'.repeat(20)); // 20 characters, not 20 UTF-16 units
  });

  test('duplicate MMSIs: one target per vessel, the newest position wins whatever the arrival order', () => {
    const rng = rngFor('dupes');
    const { hub, feed } = rig();
    const stamps = Array.from({ length: 30 }, (_, i) => i);
    for (let i = stamps.length - 1; i > 0; i--) {
      const j = rng.int(0, i);
      [stamps[i], stamps[j]] = [stamps[j], stamps[i]];
    }
    // The second at which each position is stamped is also its latitude offset, so the winner is known.
    for (const s of stamps) feed(GOOD_FRAME(55, 40.7 + s / 10000, -73.99, `2026-11-10 14:10:${String(s).padStart(2, '0')}.000000000 +0000 UTC`));
    for (const mmsi of [55, 55, 56, 55, 56]) feed(GOOD_FRAME(mmsi, 40.7, -73.99, '2026-11-10 14:05:00.000000000 +0000 UTC'));
    const t = hub.snapshot().filter((x) => x.id === 'vessel:55');
    expect(t).toHaveLength(1);
    expect(t[0].lat).toBeCloseTo(40.7029, 6);
    expect(hub.snapshot().filter((x) => x.id === 'vessel:56')).toHaveLength(1);
  });

  // D7: a frame at (0, 0), in Europe, or with lat and lon swapped (-73.99, 40.7 is a valid pair) used to be published
  // to every client: only |lat| <= 90 and |lon| <= 180 were checked. Positions outside BOUNDING_BOXES are dropped now,
  // on both endpoints, and a static message's out-of-box MetaData position doesn't place a boat either.
  test('nothing outside the bounding box is published (swapped, null island, Europe)', () => {
    const { hub, feed, legacy } = rig();
    for (const [i, [lat, lon]] of [[-73.99, 40.7], [0, 0], [51.5, 0.1], [40.7, 73.99], [-40.7, -73.99], [89.9, 179.9], [40.6749, -73.99], [40.7, -73.9549]].entries()) feed(GOOD_FRAME(2000 + i, lat, lon));
    feed(toWire({ MessageType: 'ShipStaticData', MetaData: { MMSI: 2050, latitude: 0, longitude: 0 }, Message: { ShipStaticData: { UserID: 2050, Name: 'AWAY', Type: 60 } } }));
    feed(GOOD_FRAME(2100)); // inside
    feed(GOOD_FRAME(2101, LAT_MIN, LON_MAX)); // on the edge: inside
    const out = hub.snapshot().filter((t) => !inBox(t.lat, t.lon));
    check(out.length === 0, `published outside the box: ${out.map((t) => `${t.id} (${t.lat}, ${t.lon})`).join(', ')}`);
    expect(hub.snapshot().map((t) => t.id).sort()).toEqual(['vessel:2100', 'vessel:2101']);
    expect(legacy.map((u) => u.mmsi).sort()).toEqual([2100, 2101]);
  });

  // D7, trains: the box is not applied to them (inBoundingBoxes in config.ts says why). The subway source places
  // trains only on the extracted track, and the named stretches are kept whole past the box on purpose.
  test('trains on a stretch past the box edge are still published (Franklin Av shuttle at Park Pl)', () => {
    const parkPl = SUBWAY_DATA.segments.flatMap((s) => s.parts).filter((p) => p.stretch === 'franklin-av')
      .flatMap((p) => p.points).reduce((a, b) => (b[0] < a[0] ? b : a));
    expect(inBox(parkPl[0], parkPl[1])).toBe(false);
    const culverFarthest = Math.min(...SUBWAY_DATA.segments.flatMap((s) => s.parts).filter((p) => p.stretch === 'culver-viaduct').flatMap((p) => p.points.map((x) => x[0])));
    expect((LAT_MIN - culverFarthest) * 111_195).toBeGreaterThan(500);
    const hub = new TargetHub(() => NOW);
    const train = trainTarget({
      tripId: '000000_FS..S', route: 'FS', direction: 'S', stretch: 'franklin-av', underground: false,
      lat: parkPl[0], lon: parkPl[1], altitude: parkPl[2], altitudeEstimated: true, bearing: 180, speed: 0,
      timestamp: new Date(NOW).toISOString(),
    });
    hub.sink('mta-subway').replaceAll([train], NOW + 30_000);
    expect(hub.snapshot()).toEqual([train]);
    // Underground track is clipped to the box by the extract: nothing off a stretch lies outside it.
    const offStretch = SUBWAY_DATA.segments.flatMap((s) => s.parts).filter((p) => p.stretch === undefined)
      .flatMap((p) => p.points).filter(([lat, lon]) => !inBox(lat, lon));
    expect(offStretch).toEqual([]);
  });

  test('AIS "not available" and out-of-range positions are rejected (91 / 181, 90.0001, NaN-ish strings, Infinity)', () => {
    const { hub, feed } = rig();
    const bad: [unknown, unknown][] = [[91, 181], [90.0001, -73.99], [40.7, 180.0001], ['40.7', '-73.99'], ['NaN', 'NaN'], [INF, -73.99], [40.7, `-${INF}`], [null, null], [1e308, 1e308]];
    for (const [i, [lat, lon]] of bad.entries()) {
      feed(toWire({ MessageType: 'PositionReport', MetaData: { MMSI: 3000 + i }, Message: { PositionReport: { UserID: 3000 + i, Latitude: lat, Longitude: lon } } }));
    }
    expect(hub.snapshot()).toEqual([]);
  });

  // D8: parseAisTime() accepts any year to 9999, and the registry keeps a vessel's newest position, so one frame with
  // a far-future time_utc used to freeze the vessel (every genuine position after it is older) and keep it until 2099.
  // A time more than MAX_FUTURE_MS past the receive time falls back to the receive time.
  test('a bogus far-future time_utc must not freeze a vessel: the next real position still moves it', () => {
    const { hub, feed, legacy } = rig();
    feed(GOOD_FRAME(66, 40.7, -73.99, '2099-01-01 00:00:00.000000000 +0000 UTC'));
    expect(legacy[0].timestamp).toBe(new Date(NOW).toISOString());
    expect(hub.snapshot().find((x) => x.id === 'vessel:66')?.timestamp).toBe(new Date(NOW).toISOString());
    // The next real report, stamped a few seconds after the bogus frame arrived.
    feed(GOOD_FRAME(66, 40.71, -73.98, '2026-11-10 14:12:03.000000000 +0000 UTC'));
    const t = hub.snapshot().find((x) => x.id === 'vessel:66');
    check(t === undefined || t.lat === 40.71, `vessel 66 stuck at lat ${t?.lat} after a real position`);
    expect(t?.timestamp).toBe('2026-11-10T14:12:03.000Z');
  });

  test('a time_utc up to a minute ahead of the receive time is kept as sent (clocks differ)', () => {
    const { legacy, feed } = rig();
    feed(GOOD_FRAME(67, 40.7, -73.99, '2026-11-10 14:12:59.000000000 +0000 UTC'));
    feed(GOOD_FRAME(68, 40.7, -73.99, '2026-11-10 14:13:00.001000000 +0000 UTC'));
    expect(legacy.map((u) => u.timestamp)).toEqual(['2026-11-10T14:12:59.000Z', new Date(NOW).toISOString()]);
  });

  // X2: aisstream's {"error": "..."} text used to be logged as received, so a newline in it forged log lines. It goes
  // through guard.ts safeText() now, like other feeds' text.
  test('an upstream {"error"} frame cannot forge or flood the log', () => {
    const { logs, feed } = rig();
    feed(JSON.stringify({ error: 'bad key\nrelay: FORGED LINE\n' + 'x'.repeat(100_000) }));
    const line = logs.find((l) => l.includes('aisstream error'));
    check(line !== undefined && !/[\r\n]/.test(line) && line.length < 1000, `logged ${line?.length} chars, newline: ${/[\r\n]/.test(line ?? '')}`);
  });

  // X3: MaximumStaticDraught 0.04 used to pass `draught > 0` and then round to 0, sending `draught: 0`; PROTOCOL.md says
  // draught is omitted when 0. It is rounded first now. 25.54 rounds to 25.5, still in range; 25.56 to 25.6, not.
  test('a draught that rounds to 0 is omitted, not sent as 0', () => {
    const { hub, feed } = rig();
    feed(GOOD_FRAME(88));
    feed(toWire({ MessageType: 'ShipStaticData', MetaData: { MMSI: 88 }, Message: { ShipStaticData: { UserID: 88, Name: 'X', MaximumStaticDraught: 0.04 } } }));
    check(hub.snapshot()[0].vessel?.draught === undefined, `draught ${hub.snapshot()[0].vessel?.draught}`);
    const draughtOf = (mmsi: number, value: number) => {
      feed(GOOD_FRAME(mmsi));
      feed(toWire({ MessageType: 'ShipStaticData', MetaData: { MMSI: mmsi }, Message: { ShipStaticData: { UserID: mmsi, Name: 'X', MaximumStaticDraught: value } } }));
      return hub.snapshot().find((t) => t.id === `vessel:${mmsi}`)?.vessel?.draught;
    };
    expect(draughtOf(89, 0.05)).toBe(0.1);
    expect(draughtOf(90, 25.54)).toBe(25.5);
    expect(draughtOf(91, 25.56)).toBeUndefined();
  });

  test('the normalizer alone: hostile input never throws and statics held without a position stay bounded', () => {
    const rng = rngFor('normalizer');
    const n = new Normalizer();
    const received = new Date(NOW);
    for (let i = 0; i < 3000; i++) {
      const frame = hostileFrame(rng);
      expect(() => n.normalizeAll(frame, received)).not.toThrow();
    }
    // 20,000 distinct MMSIs with only static data: held data is capped (MAX_HELD), so memory does not grow without bound.
    for (let i = 1; i <= 20_000; i++) {
      n.normalizeAll(toWire({ MessageType: 'ShipStaticData', MetaData: { MMSI: i }, Message: { ShipStaticData: { UserID: i, Name: `B${i}` } } }), received);
    }
    // Only the newest 5000 are held: the oldest one lost its name, the newest keeps it.
    const first = n.normalizeAll(GOOD_FRAME(1), received).find((x) => x.update.name !== undefined);
    const last = n.normalizeAll(GOOD_FRAME(20_000), received).find((x) => x.update.name !== undefined);
    expect(first).toBeUndefined();
    expect(last?.update.name).toBe('B20000');
  });
});

describe('chaos: hostile subway feeds', () => {
  const feeds = fs.readdirSync(SUBWAY_FIXTURES_DIR).filter((f) => f.endsWith('.pb')).sort();

  test('mutated and truncated synthetic feeds: the decoder only throws GtfsRtError, and the source keeps serving', async () => {
    const rng = rngFor('subway');
    const originals = feeds.slice(0, 4).map((f) => new Uint8Array(fs.readFileSync(path.join(SUBWAY_FIXTURES_DIR, f))));
    const mutate = (src: Uint8Array): Uint8Array => {
      const b = rng.chance(0.3) ? src.slice(0, rng.int(0, src.length)) : src.slice();
      const flips = rng.int(0, 12);
      for (let i = 0; i < flips && b.length > 0; i++) b[rng.int(0, b.length - 1)] = rng.chance(0.3) ? 0xff : rng.int(0, 255);
      return b;
    };
    let decoded = 0;
    let rejected = 0;
    for (let i = 0; i < 300; i++) {
      const bytes = mutate(rng.pick(originals));
      try {
        decodeFeedMessage(bytes);
        decoded++;
      } catch (err) {
        check(err instanceof GtfsRtError, `decodeFeedMessage threw a ${(err as Error)?.constructor?.name} (${String(err)}), not GtfsRtError, on mutation #${i}`);
        rejected++;
      }
    }
    expect(decoded + rejected).toBe(300);
    expect(rejected).toBeGreaterThan(0);

    // Through the source: mutated feeds in, finite targets out, no failure logged by a guard, a clean feed afterwards works.
    const logs: string[] = [];
    const hub = new TargetHub(() => NOW);
    let serve: () => Uint8Array = () => originals[0];
    const timers: (() => void)[] = [];
    const source = new MtaSubwaySource({
      sink: hub.sink('mta-subway'),
      log: (m) => logs.push(m),
      now: () => NOW,
      poller: {
        fetchFeed: async () => serve(),
        setTimer: (fn) => (timers.push(fn), 0 as unknown as ReturnType<typeof setTimeout>),
        clearTimer: () => {},
      },
    });
    source.start();
    for (let round = 0; round < 25; round++) {
      serve = () => mutate(rng.pick(originals));
      timers.shift()?.();
      await new Promise((resolve) => setImmediate(resolve));
      for (const t of hub.snapshot()) {
        wellFormed(t, `train ${t.id}`);
        check(Math.abs(t.lat) <= 90 && Math.abs(t.lon) <= 180, `train ${t.id} out of range`);
      }
    }
    source.stop();
    const guardFailures = logs.filter((l) => /publish failed|skipped/.test(l));
    check(guardFailures.length === 0, `guarded failure logged: ${guardFailures[0]}`);
  });
});

// ---------------------------------------------------------------------------------------------------- server side

let server: RelayServer;
let port: number;
let hub: TargetHub;
let registry: Registry;
const opened = new Set<WebSocket>();

async function start(over: Partial<Parameters<typeof createRelayServer>[0]> = {}) {
  await server?.close();
  registry = new Registry();
  hub = new TargetHub(() => NOW);
  server = createRelayServer({ registry, hub, now: () => NOW, ...over });
  port = await server.listen(0, '127.0.0.1');
}
beforeEach(() => start());
afterEach(async () => {
  for (const ws of opened) ws.terminate();
  opened.clear();
  await server.close();
});

const target = (id: string, extra: Partial<Target> = {}): Target => ({
  id,
  kind: 'vessel',
  source: 'test',
  lat: 40.7,
  lon: -73.99,
  timestamp: '2026-11-10T14:11:00.000Z',
  vessel: { mmsi: Number(id.split(':')[1]) || 1 },
  ...extra,
});

interface Client {
  ws: WebSocket;
  messages: any[];
}
/** Opens a client and resolves at the upgrade; messages are collected as they come. */
function open(p: string): Promise<Client> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}${p}`);
  opened.add(ws);
  const messages: any[] = [];
  ws.on('message', (d) => messages.push(JSON.parse(d.toString())));
  return new Promise((resolve, reject) => {
    ws.once('open', () => resolve({ ws, messages }));
    ws.once('unexpected-response', (_req, res) => {
      res.resume();
      reject(new Error(`HTTP ${res.statusCode}`));
    });
    ws.once('error', reject);
  });
}

async function waitFor(cond: () => boolean, what: string, timeoutMs = 8000): Promise<void> {
  const until = Date.now() + timeoutMs;
  while (!cond()) {
    check(Date.now() < until, `timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

/** The HTTP status a WebSocket upgrade or plain request to `p` gets (raw socket, so odd paths go out as written). */
function rawStatus(request: string | Buffer): Promise<number | 'closed'> {
  return new Promise((resolve) => {
    const s = net.connect(port, '127.0.0.1', () => s.write(request));
    let data = '';
    s.on('data', (c) => (data += c.toString('latin1')));
    s.on('error', () => resolve('closed'));
    s.on('close', () => resolve(Number(/^HTTP\/1\.[01] (\d{3})/.exec(data)?.[1]) || 'closed'));
    setTimeout(() => s.destroy(), 3000).unref();
  });
}

describe('chaos: hostile clients', () => {
  test('a client that connects and never reads is dropped once it is behind; the others carry on', async () => {
    const slow = await open('/v2/targets');
    const fast = await open('/v2/targets');
    (slow.ws as unknown as { _socket: { pause(): void } })._socket.pause();
    await waitFor(() => server.clientCount() === 2, 'two clients');

    const sink = hub.sink('test');
    const big = target('vessel:1', { name: 'x'.repeat(100 * 1024) });
    let sent = 0;
    for (; sent < 600 && server.clientCount() > 1; sent++) {
      sink.upsert({ ...big, lat: 40.7 + sent / 1e6 });
      await new Promise((resolve) => setImmediate(resolve));
    }
    await waitFor(() => server.clientCount() === 1, `the slow client to be dropped (after ${sent} x 100 KiB)`);
    // The kernel's socket buffers take a few MB before the relay's own queue (256 KiB) grows; it is bounded: far below the 60 MB sent.
    expect(sent).toBeLessThan(600);
    expect(fast.ws.readyState).toBe(WebSocket.OPEN);
    expect(fast.messages.length).toBeGreaterThan(5);
    // And the survivor still gets news.
    const before = fast.messages.length;
    sink.upsert(target('vessel:2'));
    await waitFor(() => fast.messages.length > before, 'the survivor to get the next update');
  });

  test('500 clients at once: all get a snapshot, the relay stays up, and all of them close', async () => {
    await start({ maxClients: 1000 });
    const sink = hub.sink('test');
    for (let i = 1; i <= 60; i++) sink.upsert(target(`vessel:${i}`));
    const started = Date.now();
    const clients: Client[] = [];
    const paths = ['/v2/targets', '/v1/vessels'];
    // In waves of 100: a single burst of 500 connects overflows the OS listen backlog (macOS caps it at 128) and some
    // are reset before the relay ever sees them. That is the kernel, not the relay (it accepts at once in a loop).
    for (let wave = 0; wave < 5; wave++) {
      clients.push(...(await Promise.all(Array.from({ length: 100 }, (_, i) => open(paths[(wave * 100 + i) % 5 === 0 ? 1 : 0])))));
    }
    await waitFor(() => clients.every((c) => c.messages.length >= 1), 'every client to get its snapshot', 15_000);
    expect(server.clientCount()).toBe(500);
    for (const [i, c] of clients.entries()) {
      check(c.messages[0].type === 'snapshot', `client ${i}: first message ${c.messages[0].type}`);
      if (i % 5 !== 0) check(c.messages[0].targets.length === 60, `client ${i}: ${c.messages[0].targets.length} targets in its snapshot`);
    }
    // A broadcast reaches every /v2 client once.
    sink.upsert(target('vessel:999'));
    await waitFor(() => clients.filter((_, i) => i % 5 !== 0).every((c) => c.messages.length === 2), 'every /v2 client to get the update', 15_000);
    // Still answering plain HTTP while 500 sockets are open.
    expect(await rawStatus('GET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n')).toBe(404);

    clients.forEach((c) => c.ws.close());
    await waitFor(() => server.clientCount() === 0, 'every client to be gone', 15_000);
    check(Date.now() - started < 15_000, `500 clients took ${Date.now() - started} ms`);
  });

  test('garbage frames from a client (text, binary, oversize, malformed): ignored or closed, other clients unaffected', async () => {
    const rng = rngFor('client-garbage');
    const bystander = await open('/v2/targets');
    const bad: Client[] = [];
    for (let i = 0; i < 12; i++) bad.push(await open(i % 2 ? '/v2/targets' : '/v1/vessels'));
    await waitFor(() => server.clientCount() === 13, 'all clients');

    for (const [i, c] of bad.entries()) {
      const send = (d: string | Buffer, binary: boolean) => c.ws.readyState === WebSocket.OPEN && c.ws.send(d, { binary });
      send('{"type":"snapshot"', false);
      send('\u0000\u0001', false);
      send(JSON.stringify({ type: 'remove', id: 'vessel:1' }), false);
      send(Buffer.from(Array.from({ length: 200 }, () => rng.int(0, 255))), true);
      if (i % 3 === 0) send('x'.repeat(4096), false); // past maxPayload (1 KiB): the relay closes this one with 1009
      c.ws.ping(Buffer.alloc(100));
    }
    // Raw TCP garbage and a broken handshake on the same port.
    expect(await rawStatus(Buffer.from(Array.from({ length: 300 }, () => rng.int(0, 255))))).toEqual(expect.anything());
    expect(await rawStatus('GET /v2/targets HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')).not.toBe(101);
    expect(await rawStatus('GET /v2/targets HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: !!!\r\nSec-WebSocket-Version: 13\r\n\r\n')).not.toBe(101);

    // The relay never answers a client's frame and never lets it change state.
    expect(hub.snapshot()).toEqual([]);
    hub.sink('test').upsert(target('vessel:5'));
    await waitFor(() => bystander.messages.length === 2, 'the bystander to get the update');
    expect(bystander.messages[1]).toEqual({ type: 'update', target: target('vessel:5') });
    expect(bystander.ws.readyState).toBe(WebSocket.OPEN);
    for (const c of bad) c.messages.filter((m) => m.type !== 'snapshot' && m.type !== 'update').forEach((m) => check(false, `relay answered a client frame: ${JSON.stringify(m)}`));
    // The oversize senders are gone, the rest may stay: either way the count settles with the bystander in it.
    await waitFor(() => server.clientCount() <= 13 && server.clientCount() >= 1, 'a sane client count');
    expect(await rawStatus('GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n')).toBe(200);
  });

  test('unknown paths and spellings: 404 for WebSocket and HTTP alike, and /v2/targets still works afterwards', async () => {
    const paths = [
      '/', '/v3/targets', '/v2', '/v2/targets/', '/V2/TARGETS', '//v2/targets', '/v2//targets', '/v2/targets%00', '/v2/targets%2F..', '/../v2/targets/../x',
      '/v1', '/vessels', '/healthz/x', '/metrics', '/census', '/%', '/%zz', '/' + 'a'.repeat(7000), '/é', '/v2/targets;x=1',
    ];
    for (const p of paths) {
      const upgrade = await rawStatus(`GET ${p} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n`);
      const plain = await rawStatus(`GET ${p} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n`);
      // No such path is ever upgraded; an overlong request line is refused by Node (431) before the router.
      check(upgrade !== 101, `${JSON.stringify(p.slice(0, 40))} was upgraded`);
      check([404, 400, 431, 'closed'].includes(plain as number), `${JSON.stringify(p.slice(0, 40))}: plain GET gave ${plain}`);
    }
    // The ones that are real answer, the odd ones are 404 (as before: queries are ignored).
    expect(await rawStatus('GET /v2/targets?x=1 HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n')).toBe(101);
    const ok = await open('/v2/targets');
    await waitFor(() => ok.messages.length === 1, 'a snapshot');
    expect(await new Promise<number>((resolve, reject) => http.get({ host: '127.0.0.1', port, path: '/healthz' }, (r) => (r.resume(), resolve(r.statusCode ?? 0))).on('error', reject))).toBe(200);
  });

  test('clients that reset mid-handshake and mid-stream do not take the process down', async () => {
    const survivors = await open('/v2/targets');
    const rng = rngFor('reset');
    for (let i = 0; i < 40; i++) {
      await new Promise<void>((resolve) => {
        const s = net.connect(port, '127.0.0.1', () => {
          const req = `GET /v2/targets HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n`;
          s.write(req.slice(0, rng.int(1, req.length)));
          s.resetAndDestroy();
        });
        s.on('error', () => {});
        s.on('close', () => resolve());
      });
    }
    const sink = hub.sink('test');
    for (let i = 0; i < 20; i++) sink.upsert(target(`vessel:${i + 1}`));
    await waitFor(() => survivors.messages.length === 21, 'the survivor to get all 20 updates');
    await waitFor(() => server.clientCount() === 1, 'resets to be reaped');
  });
});
