import { describe, expect, test } from '@jest/globals';
import { cleanText, Normalizer, parseAisTime } from './normalizer';

const RECV = new Date('2026-11-10T15:00:00.000Z');
const TIME = '2026-11-10 14:00:05.123456789 +0000 UTC';

function pos(over: Record<string, unknown> = {}, meta: Record<string, unknown> = {}) {
  return JSON.stringify({
    MessageType: 'PositionReport',
    MetaData: { MMSI: 1, latitude: 40.7, longitude: -73.99, time_utc: TIME, ...meta },
    Message: {
      PositionReport: { UserID: 1, Sog: 5.5, Cog: 100, TrueHeading: 99, Latitude: 40.7, Longitude: -73.99, ...over },
    },
  });
}

function stat(over: Record<string, unknown> = {}, meta: Record<string, unknown> = {}) {
  return JSON.stringify({
    MessageType: 'ShipStaticData',
    MetaData: { MMSI: 1, latitude: 40.71, longitude: -73.98, time_utc: TIME, ...meta },
    Message: { ShipStaticData: { UserID: 1, Name: 'BOAT@@@@', Type: 60, ...over } },
  });
}

describe('parseAisTime', () => {
  test('truncates nanoseconds to ms', () => {
    expect(parseAisTime('2026-11-10 14:00:05.123999999 +0000 UTC')).toBe('2026-11-10T14:00:05.123Z');
  });
  test('handles missing fraction and short fraction', () => {
    expect(parseAisTime('2026-11-10 14:00:05 +0000 UTC')).toBe('2026-11-10T14:00:05.000Z');
    expect(parseAisTime('2026-11-10 14:00:05.5 +0000 UTC')).toBe('2026-11-10T14:00:05.500Z');
  });
  test('rejects garbage and overflowed fields', () => {
    expect(parseAisTime('nope')).toBeUndefined();
    expect(parseAisTime(undefined)).toBeUndefined();
    expect(parseAisTime('2026-13-10 14:00:05 +0000 UTC')).toBeUndefined();
    expect(parseAisTime('2026-11-10 24:00:05 +0000 UTC')).toBeUndefined();
  });
});

describe('position reports', () => {
  test('normalizes fields with key order', () => {
    const [u] = new Normalizer().normalize(pos(), RECV);
    expect(u).toEqual({ mmsi: 1, lat: 40.7, lon: -73.99, sog: 5.5, cog: 100, heading: 99, timestamp: '2026-11-10T14:00:05.123Z' });
    expect(Object.keys(u)).toEqual(['mmsi', 'lat', 'lon', 'sog', 'cog', 'heading', 'timestamp']);
  });
  test.each([
    ['sog 102.3', { Sog: 102.3 }, 'sog'],
    ['cog 360', { Cog: 360 }, 'cog'],
    ['cog >360', { Cog: 400 }, 'cog'],
    ['heading 511', { TrueHeading: 511 }, 'heading'],
  ])('omits sentinel %s', (_n, over, key) => {
    const [u] = new Normalizer().normalize(pos(over), RECV);
    expect(u).toBeDefined();
    expect(key in u).toBe(false);
    expect(JSON.stringify(u)).not.toContain('null');
  });
  test('keeps valid boundary values', () => {
    const [u] = new Normalizer().normalize(pos({ Sog: 0, Cog: 0, TrueHeading: 359 }), RECV);
    expect(u).toMatchObject({ sog: 0, cog: 0, heading: 359 });
  });
  test.each([
    [{ Latitude: 91, Longitude: 181 }],
    [{ Latitude: 91 }],
    [{ Longitude: 181 }],
    [{ Latitude: -90.5 }],
  ])('drops unavailable/invalid position %j', (over) => {
    expect(new Normalizer().normalize(pos(over), RECV)).toEqual([]);
  });
  test('falls back to receive time when time_utc missing or unparseable', () => {
    const n = new Normalizer();
    expect(n.normalize(pos({}, { time_utc: undefined }), RECV)[0].timestamp).toBe('2026-11-10T15:00:00.000Z');
    expect(n.normalize(pos({}, { time_utc: 'bad' }), RECV)[0].timestamp).toBe('2026-11-10T15:00:00.000Z');
  });
});

describe('static data', () => {
  test('uses MetaData position, trims name, either casing', () => {
    const [a] = new Normalizer().normalize(stat(), RECV);
    expect(a).toEqual({ mmsi: 1, name: 'BOAT', shipType: 60, lat: 40.71, lon: -73.98, timestamp: '2026-11-10T14:00:05.123Z' });
    expect(Object.keys(a)).toEqual(['mmsi', 'name', 'shipType', 'lat', 'lon', 'timestamp']);
    const [b] = new Normalizer().normalize(
      stat({}, { latitude: undefined, longitude: undefined, Latitude: 40.69, Longitude: -74.01 }),
      RECV,
    );
    expect(b).toMatchObject({ lat: 40.69, lon: -74.01 });
  });
  test('trims spaces and @, omits empty name and Type 0', () => {
    const n = new Normalizer();
    expect(n.normalize(stat({ Name: '  @ANNA K @@  ' }), RECV)[0].name).toBe('ANNA K');
    const [u] = n.normalize(stat({ Name: '@@@@   ', Type: 0 }, {}), RECV);
    expect(u).toBeUndefined();
    const [v] = n.normalize(stat({ Name: '@@', Type: 70 }), RECV);
    expect(v).toMatchObject({ shipType: 70 });
    expect('name' in v).toBe(false);
  });
  test('Type 0 omits shipType but keeps name', () => {
    const [u] = new Normalizer().normalize(stat({ Type: 0 }), RECV);
    expect('shipType' in u).toBe(false);
    expect(u.name).toBe('BOAT');
  });
  test('without MetaData position uses last known position', () => {
    const n = new Normalizer();
    n.normalize(pos({ Latitude: 40.72, Longitude: -73.96 }), RECV);
    const [u] = n.normalize(stat({}, { latitude: undefined, longitude: undefined }), RECV);
    expect(u).toMatchObject({ lat: 40.72, lon: -73.96, name: 'BOAT' });
  });
  test('invalid MetaData position (91/181) counts as unusable', () => {
    const n = new Normalizer();
    n.normalize(pos({ Latitude: 40.72, Longitude: -73.96 }), RECV);
    expect(n.normalize(stat({}, { latitude: 91, longitude: 181 }), RECV)[0]).toMatchObject({ lat: 40.72, lon: -73.96 });
  });
  test('held until first position, then emitted right after it with that position', () => {
    const n = new Normalizer();
    const noPos = { latitude: undefined, longitude: undefined };
    expect(n.normalize(stat({}, { ...noPos, time_utc: '2026-11-10 14:09:00.000000000 +0000 UTC' }), RECV)).toEqual([]);
    const out = n.normalize(pos({ Latitude: 40.73, Longitude: -73.96 }), RECV);
    expect(out).toHaveLength(2);
    expect(out[0]).toMatchObject({ lat: 40.73, sog: 5.5 });
    expect(out[1]).toEqual({ mmsi: 1, name: 'BOAT', shipType: 60, lat: 40.73, lon: -73.96, timestamp: '2026-11-10T14:09:00.000Z' });
    expect(n.normalize(pos(), RECV)).toHaveLength(1);
  });
});

describe('ignored input', () => {
  test.each([
    ['subscription confirmation', JSON.stringify({ MessageType: 'SubscriptionConfirmation', Message: {} })],
    ['unknown type', JSON.stringify({ MessageType: 'BaseStationReport', Message: {} })],
    ['malformed json', '{not json'],
    ['non-object json', '[1,2]'],
    ['null', 'null'],
    ['empty', ''],
    ['position type without body', JSON.stringify({ MessageType: 'PositionReport', MetaData: {}, Message: {} })],
    ['missing mmsi', pos({ UserID: undefined }, { MMSI: undefined })],
  ])('%s -> []', (_n, raw) => {
    expect(new Normalizer().normalize(raw, RECV)).toEqual([]);
  });
});

const FULL = {
  ImoNumber: 9123453,
  CallSign: 'WDA0000',
  Destination: 'WALL ST',
  Eta: { Month: 11, Day: 10, Hour: 15, Minute: 30 },
  Dimension: { A: 20, B: 10, C: 4, D: 5 },
  MaximumStaticDraught: 2.14,
};

const extrasOf = (raw: string, n = new Normalizer()) => n.normalizeAll(raw, RECV)[0]?.extras;

describe('static extras', () => {
  test('reads every field', () => {
    expect(extrasOf(stat(FULL))).toEqual({
      imo: 9123453,
      callSign: 'WDA0000',
      destination: 'WALL ST',
      eta: { month: 11, day: 10, hour: 15, minute: 30 },
      length: 30,
      beam: 9,
      draught: 2.1,
    });
  });
  test('rounds draught to one decimal and keeps the AIS maximum', () => {
    expect(extrasOf(stat({ MaximumStaticDraught: 25.5 }))?.draught).toBe(25.5);
    expect(extrasOf(stat({ MaximumStaticDraught: 7.96 }))?.draught).toBe(8);
  });
  test.each([
    ['IMO 0', { ImoNumber: 0 }, 'imo'],
    ['IMO negative', { ImoNumber: -5 }, 'imo'],
    ['IMO fractional', { ImoNumber: 1.5 }, 'imo'],
    ['IMO a string', { ImoNumber: '9123453' }, 'imo'],
    ['draught 0', { MaximumStaticDraught: 0 }, 'draught'],
    ['draught negative', { MaximumStaticDraught: -1 }, 'draught'],
    ['draught above the AIS range', { MaximumStaticDraught: 40 }, 'draught'],
    ['dimensions 0', { Dimension: { A: 0, B: 0, C: 0, D: 0 } }, 'length'],
    ['dimensions 0 (beam)', { Dimension: { A: 0, B: 0, C: 0, D: 0 } }, 'beam'],
    ['dimension part missing', { Dimension: { A: 20, C: 4, D: 4 } }, 'length'],
    ['beam part missing', { Dimension: { A: 20, B: 10, C: 4 } }, 'beam'],
    ['dimension out of range', { Dimension: { A: 600, B: 10, C: 4, D: 4 } }, 'length'],
    ['ETA month 0', { Eta: { Month: 0, Day: 10, Hour: 15, Minute: 0 } }, 'eta'],
    ['ETA month 13', { Eta: { Month: 13, Day: 10, Hour: 15, Minute: 0 } }, 'eta'],
    ['ETA day 0', { Eta: { Month: 11, Day: 0, Hour: 15, Minute: 0 } }, 'eta'],
    ['ETA hour 24', { Eta: { Month: 11, Day: 10, Hour: 24, Minute: 0 } }, 'eta'],
    ['ETA minute 60', { Eta: { Month: 11, Day: 10, Hour: 15, Minute: 60 } }, 'eta'],
    ['ETA all not available', { Eta: { Month: 0, Day: 0, Hour: 24, Minute: 60 } }, 'eta'],
    ['ETA part missing', { Eta: { Month: 11, Day: 10, Hour: 15 } }, 'eta'],
  ])('omits %s', (_n, over, key) => {
    const x = extrasOf(stat({ ...FULL, ...over }));
    expect(x).toBeDefined();
    expect(key in (x as object)).toBe(false);
    expect(JSON.stringify(x)).not.toContain('null');
  });
  test('only the length is omitted when only the beam is known, and the other way round', () => {
    expect(extrasOf(stat({ Dimension: { A: 0, B: 0, C: 3, D: 3 } }))).toEqual({ beam: 6 });
    expect(extrasOf(stat({ Dimension: { A: 5, B: 0, C: 0, D: 0 } }))).toEqual({ length: 5 });
  });
  test('a static message with only extras still normalizes, for /v2 only', () => {
    const only = { Name: '@@', Type: 0, Destination: 'PIER 1' };
    const [n] = new Normalizer().normalizeAll(stat(only), RECV);
    expect(n.legacy).toBe(false);
    expect(n.extras).toEqual({ destination: 'PIER 1' });
    expect(n.update).toEqual({ mmsi: 1, lat: 40.71, lon: -73.98, timestamp: '2026-11-10T14:00:05.123Z' });
    expect(new Normalizer().normalize(stat(only), RECV)).toEqual([]);
  });
  test('a static message with nothing usable is ignored', () => {
    const none = { Name: '@@', Type: 0, ImoNumber: 0, Destination: '@@@@' };
    expect(new Normalizer().normalizeAll(stat(none), RECV)).toEqual([]);
  });
  test('held with no position: extras merge per key, v1 fields stay as before, all emitted after the first position', () => {
    const n = new Normalizer();
    const noPos = { latitude: undefined, longitude: undefined };
    n.normalizeAll(stat({ Name: 'BOAT', Type: 60, Destination: 'A', ImoNumber: 7 }, noPos), RECV);
    n.normalizeAll(stat({ Name: '@@', Type: 0, Destination: 'B' }, noPos), RECV);
    const out = n.normalizeAll(pos({ Latitude: 40.73, Longitude: -73.96, NavigationalStatus: 5 }), RECV);
    expect(out).toHaveLength(2);
    expect(out[0].extras).toEqual({ navStatus: 5 });
    expect(out[1]).toMatchObject({
      legacy: true,
      extras: { destination: 'B', imo: 7 },
      update: { name: 'BOAT', shipType: 60, lat: 40.73, lon: -73.96 },
    });
  });
  test('held extras without a name or type are v2 only', () => {
    const n = new Normalizer();
    const held = stat({ Name: '@@', Type: 0, Destination: 'B' }, { latitude: undefined, longitude: undefined });
    expect(n.normalize(held, RECV)).toEqual([]);
    const out = n.normalizeAll(pos(), RECV);
    expect(out[1].legacy).toBe(false);
    expect(n.normalize(pos(), RECV)).toHaveLength(1);
  });
});

describe('navigational status', () => {
  test.each([[0], [5], [14]])('keeps %d', (s) => {
    expect(extrasOf(pos({ NavigationalStatus: s }))).toEqual({ navStatus: s });
  });
  test.each([[15], [16], [-1], [2.5], ['5']])('omits %j', (s) => {
    expect(extrasOf(pos({ NavigationalStatus: s }))).toBeUndefined();
  });
  test('absent', () => {
    expect(extrasOf(pos())).toBeUndefined();
  });
});

describe('cleanText', () => {
  test('trims @ and space padding and collapses whitespace', () => {
    expect(cleanText('  NEW   YORK@@@@@@', 20)).toBe('NEW YORK');
    expect(cleanText('@@ A  B @', 20)).toBe('A B');
  });
  test('drops empty results', () => {
    expect(cleanText('@@@@@@@', 7)).toBeUndefined();
    expect(cleanText('   ', 7)).toBeUndefined();
    expect(cleanText('‮\n\u0000', 7)).toBeUndefined();
    expect(cleanText(7, 7)).toBeUndefined();
    expect(cleanText(undefined, 7)).toBeUndefined();
  });
  test('control characters become spaces, so words do not fuse', () => {
    expect(cleanText('PIER\n9\r\nSLIP\t3\u0000X', 20)).toBe('PIER 9 SLIP 3 X');
    expect(cleanText('A B C', 20)).toBe('A B C');
  });
  test('bidi controls and zero-width characters are removed', () => {
    expect(cleanText('‮GNIRTS‬', 20)).toBe('GNIRTS');
    expect(cleanText('A⁦B⁩‎C‏D؜E​F﻿G', 20)).toBe('ABCDEFG');
  });
  test('caps at the AIS field length, then trims what the cut leaves', () => {
    expect(cleanText('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 20)).toBe('ABCDEFGHIJKLMNOPQRST');
    expect(cleanText('ABCDEFGHI JKLMNOPQRS TUVW', 20)).toBe('ABCDEFGHI JKLMNOPQRS');
    expect(cleanText('ABCDEFGHI', 7)).toBe('ABCDEFG');
  });
  test('the cap counts characters, not UTF-16 units', () => {
    expect(cleanText('\u{1F6A2}'.repeat(10), 7)).toBe('\u{1F6A2}'.repeat(7));
  });
  test('call sign and destination run through it in the normalizer', () => {
    const x = extrasOf(stat({ CallSign: '@@WD‮A12345678', Destination: 'NEW\nYORK ​@@@@@@@@@@@@@@@@@@@@@@' }));
    expect(x).toEqual({ callSign: 'WDA1234', destination: 'NEW YORK' });
  });
  test('name is cleaned as before: trimmed only', () => {
    expect(new Normalizer().normalize(stat({ Name: '@A\nB@' }), RECV)[0].name).toBe('A\nB');
  });
});
