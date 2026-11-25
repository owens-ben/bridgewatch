import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import { describe, expect, test } from '@jest/globals';
import { Census } from '../census';
import { ConfigError } from '../config';
import { FIXTURE_NOW, SAMPLE_PATH, STATIC_SAMPLE_PATH } from '../fixtures';
import { STALE_AFTER_MS } from '../health';
import { TargetHub } from '../hub';
import { Normalizer } from '../normalizer';
import { Registry } from '../registry';
import type { Target, VesselDetails } from '../targets';
import type { VesselUpdate } from '../types';
import type { UpstreamSocket } from '../upstream';
import { aisstream, AisstreamSource } from './aisstream';

class FakeSocket extends EventEmitter implements UpstreamSocket {
  send() {}
  close() {}
}

/** The synthetic sample's normalized updates, in order. */
function sampleUpdates(): VesselUpdate[] {
  const normalizer = new Normalizer();
  return fs
    .readFileSync(SAMPLE_PATH, 'utf8')
    .split('\n')
    .filter((line) => line.trim() !== '')
    .flatMap((line) => normalizer.normalize(line, new Date(FIXTURE_NOW)));
}

function makeSource(now: number) {
  const hub = new TargetHub(() => now);
  const legacy: VesselUpdate[] = [];
  const source = new AisstreamSource({
    apiKey: 'k',
    sink: hub.sink('aisstream'),
    log: () => {},
    legacyVesselUpdate: (u) => legacy.push(u),
  });
  return { hub, source, legacy };
}

describe('aisstream source', () => {
  test('publishes each vessel\'s merged state as a target, matching the /v1 snapshot', () => {
    const now = Date.parse(FIXTURE_NOW);
    const { hub, source, legacy } = makeSource(now);
    const updates = sampleUpdates();
    for (const u of updates) source.ingest(u);
    expect(legacy).toEqual(updates);

    const v1 = new Registry();
    for (const u of updates) v1.apply(u);
    const expected = v1.snapshot(now).map((v) => ({
      id: `vessel:${v.mmsi}`,
      name: v.name,
      lat: v.lat,
      lon: v.lon,
      speed: v.sog,
      course: v.cog,
      heading: v.heading,
      timestamp: v.timestamp,
      shipType: v.shipType,
    }));
    // 367000003 was last heard at 14:00:30, more than 10 minutes before FIXTURE_NOW.
    expect(expected.map((v) => v.id)).not.toContain('vessel:367000003');
    expect(
      hub.snapshot().map((t) => ({
        id: t.id,
        name: t.name,
        lat: t.lat,
        lon: t.lon,
        speed: t.speed,
        course: t.course,
        heading: t.heading,
        timestamp: t.timestamp,
        shipType: t.vessel?.shipType,
      })),
    ).toEqual(expected);
  });

  test('a target has the PROTOCOL.md key order and expires 10 minutes after the vessel\'s newest message', () => {
    const now = Date.parse(FIXTURE_NOW);
    const { hub, source } = makeSource(now);
    for (const u of sampleUpdates()) source.ingest(u);
    const lark = hub.snapshot()[0];
    expect(lark).toEqual({
      id: 'vessel:367000001',
      kind: 'vessel',
      source: 'aisstream',
      name: 'HARBOR LARK',
      lat: 40.7101,
      lon: -73.9866,
      speed: 13.8,
      course: 64,
      heading: 63,
      timestamp: '2026-11-10T14:11:00.999Z',
      vessel: { mmsi: 367000001, shipType: 60 },
    });
    expect(Object.keys(lark)).toEqual(['id', 'kind', 'source', 'name', 'lat', 'lon', 'speed', 'course', 'heading', 'timestamp', 'vessel']);
    const bare = hub.snapshot().find((t) => t.id === 'vessel:367000004');
    expect(bare).toEqual({
      id: 'vessel:367000004',
      kind: 'vessel',
      source: 'aisstream',
      lat: 40.7102,
      lon: -73.9862,
      timestamp: '2026-11-10T14:08:00.000Z',
      vessel: { mmsi: 367000004 },
    });

    const later = new TargetHub(() => Date.parse('2026-11-10T14:18:00.000Z'));
    const again = new AisstreamSource({ apiKey: 'k', sink: later.sink('aisstream'), log: () => {} });
    for (const u of sampleUpdates()) again.ingest(u);
    // 367000004 was last heard at 14:08:00: still there at 14:18:00 exactly; the rest went earlier.
    expect(later.snapshot().map((t) => t.id)).toEqual(['vessel:367000001', 'vessel:367000004', 'vessel:367000005']);
  });

  test('start connects upstream, publishes what arrives and reports the stream\'s health', () => {
    const hub = new TargetHub(() => Date.parse('2026-11-10T14:00:01.000Z'));
    const sockets: FakeSocket[] = [];
    const source = new AisstreamSource({
      apiKey: 'k',
      sink: hub.sink('aisstream'),
      log: () => {},
      upstream: {
        socketFactory: () => {
          const s = new FakeSocket();
          sockets.push(s);
          return s;
        },
      },
    });
    source.start();
    sockets[0].emit('open');
    sockets[0].emit(
      'message',
      JSON.stringify({
        MessageType: 'PositionReport',
        MetaData: { MMSI: 5, time_utc: '2026-11-10 14:00:00.000000000 +0000 UTC' },
        Message: { PositionReport: { UserID: 5, Latitude: 40.7, Longitude: -73.99, Sog: 1, Cog: 2, TrueHeading: 3 } },
      }),
    );
    const now = Date.now();
    expect(source.health(now)).toEqual({ ok: true, connected: true, lastDataAgeSeconds: 0 });
    expect(source.health(now + STALE_AFTER_MS + 1000)).toMatchObject({ ok: false, connected: true });
    source.stop();
    expect(hub.snapshot().map((t) => [t.id, t.speed])).toEqual([['vessel:5', 1]]);
    expect(source.health(now).connected).toBe(false);
  });

  test('configure needs AISSTREAM_API_KEY', () => {
    expect(() => aisstream.configure({})).toThrow(ConfigError);
    expect(() => aisstream.configure({ AISSTREAM_API_KEY: '  ' })).toThrow(/AISSTREAM_API_KEY is required/);
    expect(typeof aisstream.configure({ AISSTREAM_API_KEY: 'k' })).toBe('function');
  });
});

describe('vessel details (v2 only)', () => {
  const FRAMES = fs.readFileSync(STATIC_SAMPLE_PATH, 'utf8');
  const lines = (text: string) => text.split('\n').filter((l) => l.trim() !== '');

  /** Every frame as the upstream client would deliver it: what /v1 got, and the source's targets. */
  function play(frames: string[]) {
    const now = Date.parse('2026-11-10T14:12:00.000Z');
    const hub = new TargetHub(() => now);
    const legacy: VesselUpdate[] = [];
    const source = new AisstreamSource({
      apiKey: 'k',
      sink: hub.sink('aisstream'),
      log: () => {},
      legacyVesselUpdate: (u) => legacy.push(u),
      upstream: { socketFactory: () => (sock = new FakeSocket()) },
    });
    let sock: FakeSocket;
    source.start();
    sock!.emit('open');
    for (const f of frames) sock!.emit('message', f);
    source.stop();
    return { legacy, targets: hub.snapshot() };
  }

  /** The same frames with every v2-only field removed or neutralized: what an app before the details would have seen. */
  function stripped(frame: string): string | undefined {
    const m = JSON.parse(frame);
    const s = m.Message.ShipStaticData;
    if (s) {
      if ((s.Name ?? '').replace(/[@\s]/g, '') === '' && !s.Type) return undefined; // extras only: /v1 never saw it
      Object.assign(s, { ImoNumber: 0, CallSign: '', Destination: '', MaximumStaticDraught: 0 });
      s.Dimension = { A: 0, B: 0, C: 0, D: 0 };
      s.Eta = { Month: 0, Day: 0, Hour: 24, Minute: 60 };
    }
    const p = m.Message.PositionReport;
    if (p) delete p.NavigationalStatus;
    return JSON.stringify(m);
  }

  test('/v1 messages are identical with and without the new fields', () => {
    const withFields = lines(FRAMES);
    const without = withFields.flatMap((f) => stripped(f) ?? []);
    expect(play(withFields).legacy).toEqual(play(without).legacy);
    expect(JSON.stringify(play(withFields).legacy)).toBe(JSON.stringify(play(without).legacy));
    expect(play(withFields).legacy.length).toBeGreaterThan(10);
    // None of the new keys can leak into a VesselUpdate.
    const keys = new Set(play(withFields).legacy.flatMap((u) => Object.keys(u)));
    expect([...keys].sort()).toEqual(['cog', 'heading', 'lat', 'lon', 'mmsi', 'name', 'shipType', 'sog', 'timestamp']);
  });

  test('the main synthetic sample (all fields present) gives the same /v1 messages with its fields stripped', () => {
    const withFields = lines(fs.readFileSync(SAMPLE_PATH, 'utf8'));
    const without = withFields.flatMap((f) => stripped(f) ?? []);
    expect(JSON.stringify(play(withFields).legacy)).toBe(JSON.stringify(play(without).legacy));
  });

  test('v2 targets carry the details, with the key order of PROTOCOL.md', () => {
    const { targets } = play(lines(FRAMES));
    const byMmsi = (mmsi: number) => targets.find((t) => t.id === `vessel:${mmsi}`) as Target;
    const full = byMmsi(367000010);
    expect(full.vessel).toEqual({
      mmsi: 367000010,
      shipType: 69,
      imo: 9123453,
      callSign: 'WDB1234',
      destination: 'PIER 11 WALL ST',
      eta: { month: 11, day: 10, hour: 18, minute: 45 },
      length: 158,
      beam: 28,
      draught: 6.4,
      navStatus: 5,
    });
    expect(Object.keys(full.vessel as object)).toEqual([
      'mmsi', 'shipType', 'imo', 'callSign', 'destination', 'eta', 'length', 'beam', 'draught', 'navStatus',
    ]);
    expect(Object.keys((full.vessel as VesselDetails).eta as object)).toEqual(['month', 'day', 'hour', 'minute']);
    expect(Object.keys(full)).toEqual(['id', 'kind', 'source', 'name', 'lat', 'lon', 'speed', 'course', 'heading', 'timestamp', 'vessel']);
    expect(JSON.stringify(targets)).not.toContain('null');
  });

  test('sentinels and invalid values are omitted, dirty text is cleaned', () => {
    const { targets } = play(lines(FRAMES));
    const byMmsi = (mmsi: number) => (targets.find((t) => t.id === `vessel:${mmsi}`) as Target).vessel;
    expect(byMmsi(367000011)).toEqual({ mmsi: 367000011, shipType: 70 });
    expect(byMmsi(367000012)).toEqual({
      mmsi: 367000012,
      shipType: 37,
      imo: 1000000,
      callSign: 'WD C 99',
      destination: 'NEW YORK HARBOR ANCH',
      length: 12,
      draught: 1.3,
    });
  });

  test('a vessel name is cleaned on /v2 like any boat text, and left as it was on /v1', () => {
    const hub = new TargetHub(() => Date.parse('2026-11-10T14:00:01.000Z'));
    const v1: VesselUpdate[] = [];
    const source = new AisstreamSource({
      apiKey: 'k',
      sink: hub.sink('aisstream'),
      log: () => {},
      legacyVesselUpdate: (u) => v1.push(u),
    });
    const dirty = 'EVIL\u202eBOAT\nNAME   WITH   A   VERY   LONG   TAIL';
    source.ingest({ mmsi: 77, name: dirty, lat: 40.7, lon: -73.99, timestamp: '2026-11-10T14:00:00.000Z' });
    expect(hub.snapshot().find((t) => t.id === 'vessel:77')?.name).toBe('EVILBOAT NAME WITH A');
    expect(v1[0].name).toBe(dirty);
  });

  test('later messages that omit fields never null out what is known; nav status 15 keeps the last one', () => {
    const { targets } = play(lines(FRAMES));
    const two = (targets.find((t) => t.id === 'vessel:367000013') as Target).vessel;
    expect(two).toEqual({
      mmsi: 367000013,
      shipType: 60,
      imo: 9111111,
      callSign: 'WDC0001',
      destination: 'GOVERNORS IS',
      eta: { month: 11, day: 11, hour: 9, minute: 30 },
      length: 40,
      beam: 10,
      draught: 3,
      navStatus: 0,
    });
  });

  test('details heard before the first position are published with it; /v1 sees nothing extra', () => {
    const { targets, legacy } = play(lines(FRAMES));
    const held = targets.find((t) => t.id === 'vessel:367000014') as Target;
    expect(held.vessel).toEqual({
      mmsi: 367000014,
      imo: 9222222,
      destination: 'DUMBO',
      eta: { month: 11, day: 10, hour: 20, minute: 0 },
      navStatus: 8,
    });
    expect(legacy.filter((u) => u.mmsi === 367000014)).toHaveLength(1);
  });

  test('every normalized message, static or position, feeds the census', () => {
    const now = Date.parse(FIXTURE_NOW);
    const census = new Census({ now: () => now });
    const hub = new TargetHub(() => now);
    const source = new AisstreamSource({ apiKey: 'k', sink: hub.sink('aisstream'), log: () => {}, census });
    const normalizer = new Normalizer();
    let messages = 0;
    for (const file of [SAMPLE_PATH, STATIC_SAMPLE_PATH]) {
      for (const line of fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim() !== '')) {
        for (const n of normalizer.normalizeAll(line, new Date(now))) {
          source.ingest(n.update, n.extras, n.legacy);
          messages++;
        }
      }
    }
    const { vessels } = census.report();
    const positions = vessels.reduce((sum, v) => sum + v.positions, 0);
    expect(vessels.length).toBeGreaterThan(0);
    expect(positions).toBeGreaterThan(0);
    expect(positions).toBeLessThan(messages); // static messages are not position reports
    expect(vessels.find((v) => v.mmsi === 367000001)).toMatchObject({ name: 'HARBOR LARK', shipType: 60, daysSeen: 1 });
    expect(vessels.some((v) => v.imo !== undefined && v.length !== undefined && v.callSign !== undefined)).toBe(true);
  });

  describe('a side job that throws doesn\'t keep the boat off /v2', () => {
    const now = Date.parse('2026-11-10T14:00:10.000Z');
    const update: VesselUpdate = { mmsi: 367000001, lat: 40.7, lon: -73.99, timestamp: '2026-11-10T14:00:00.000Z' };
    const throwingCensus = {
      observe: () => {
        throw new Error('census broke');
      },
    };
    const throwingLegacy = () => {
      throw new Error('v1 broke');
    };
    test.each([
      ['the census', { census: throwingCensus }, ['aisstream: census failed: census broke']],
      ['the /v1 update', { legacyVesselUpdate: throwingLegacy }, ['aisstream: v1 update failed: v1 broke']],
      [
        'both',
        { census: throwingCensus, legacyVesselUpdate: throwingLegacy },
        ['aisstream: v1 update failed: v1 broke', 'aisstream: census failed: census broke'],
      ],
    ])('%s', (_name, broken, expectedLogs) => {
      const hub = new TargetHub(() => now);
      const logs: string[] = [];
      const source = new AisstreamSource({ apiKey: 'k', sink: hub.sink('aisstream'), log: (m) => logs.push(m), ...broken });
      expect(() => source.ingest(update)).not.toThrow();
      expect(() => source.ingest({ ...update, lat: 40.71, timestamp: '2026-11-10T14:00:05.000Z' })).not.toThrow();
      expect(hub.snapshot().map((t) => [t.id, t.lat])).toEqual([['vessel:367000001', 40.71]]);
      expect(logs).toEqual(expectedLogs);
    });
  });
});
