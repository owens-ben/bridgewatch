import fs from 'node:fs';
import { describe, expect, test } from '@jest/globals';
import {
  buildDetailsFixtures,
  buildFixtures,
  buildV2Fixtures,
  DETAILS_SNAPSHOT_PATH,
  DETAILS_STREAM_PATH,
  SAMPLE_PATH,
  STATIC_SAMPLE_PATH, V2_SNAPSHOT_PATH, V2_STREAM_PATH,
} from './fixtures';
import { SUBWAY_DATA } from './subway-data';
import { subwayRounds } from './subway-fixtures';
import { expectIn, ROUND_COUNT, SCENARIO } from './tools/subway-scenario';

const sample = fs.readFileSync(SAMPLE_PATH, 'utf8');
const built = buildFixtures(sample);
const details = buildDetailsFixtures(fs.readFileSync(STATIC_SAMPLE_PATH, 'utf8'));
const builtV2 = buildV2Fixtures(sample, subwayRounds(), SUBWAY_DATA);

function assertInSync(file: string, expected: string) {
  const committed = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
  if (committed !== expected) {
    throw new Error(`${file} is out of date with the generator output. Run \`npm run fixtures\` and commit the result.`);
  }
}

describe('BoatCore fixtures', () => {
  test('relay-v2-stream.json is in sync with the generator (run `npm run fixtures`)', () => {
    assertInSync(V2_STREAM_PATH, builtV2.stream);
  });
  test('relay-v2-snapshot.json is in sync with the generator (run `npm run fixtures`)', () => {
    assertInSync(V2_SNAPSHOT_PATH, builtV2.snapshot);
  });

  test('relay-v2-details-stream.json and relay-v2-details-snapshot.json are in sync with the generator', () => {
    assertInSync(DETAILS_STREAM_PATH, details.stream);
    assertInSync(DETAILS_SNAPSHOT_PATH, details.snapshot);
  });

  test('the details stream replays to the details snapshot, which holds every boat of synthetic-static.jsonl', () => {
    const stream = JSON.parse(details.stream) as any[];
    const snapshot = JSON.parse(details.snapshot);
    const held = new Map<string, unknown>();
    for (const m of stream) {
      if (m.type === 'snapshot') held.clear();
      else if (m.type === 'update') held.set(m.target.id, m.target);
      else held.delete(m.id);
    }
    expect([...held.values()].sort((a: any, b: any) => (a.id < b.id ? -1 : 1))).toEqual(snapshot.targets);
    expect(snapshot.targets.map((t: any) => t.vessel.mmsi)).toEqual([
      367000010, 367000011, 367000012, 367000013, 367000014,
    ]);
    expect(JSON.stringify(stream)).not.toContain('null');
  });

  test('v2 stream: a snapshot of trains, then vessel and train updates and removes, ending at the snapshot', () => {
    const stream = JSON.parse(builtV2.stream) as any[];
    const snapshot = JSON.parse(builtV2.snapshot);
    expect(stream[0].type).toBe('snapshot');
    expect(stream[0].targets.length).toBeGreaterThan(0);
    expect(stream[0].targets.every((t: any) => t.kind === 'train')).toBe(true);
    expect(new Set(stream.slice(1).map((m) => m.type))).toEqual(new Set(['update', 'remove']));
    const vesselUpdates = stream.filter((m) => m.type === 'update' && m.target.kind === 'vessel');
    expect(vesselUpdates).toHaveLength(13);
    // 367000003 went quiet at 14:00:30: the sweep at FIXTURE_NOW removes it.
    expect(stream.at(-1)).toEqual({ type: 'remove', id: 'vessel:367000003' });
    expect(stream.some((m) => m.type === 'remove' && m.id.startsWith('train:'))).toBe(true);

    // Replaying the stream gives the snapshot.
    const held = new Map<string, unknown>();
    for (const m of stream) {
      if (m.type === 'snapshot') {
        held.clear();
        for (const t of m.targets) held.set(t.id, t);
      } else if (m.type === 'update') held.set(m.target.id, m.target);
      else held.delete(m.id);
    }
    const replayed = [...held.values()].sort((a: any, b: any) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    expect(replayed).toEqual(snapshot.targets);

    const vessels = snapshot.targets.filter((t: any) => t.kind === 'vessel');
    expect(vessels.map((t: any) => t.vessel.mmsi)).toEqual([367000001, 367000002, 367000004, 367000005]);
    // What the Swift fixture tests need: trains underground (no stretch) and on a stretch (with its height).
    const trains = snapshot.targets.filter((t: any) => t.kind === 'train');
    expect(trains.some((t: any) => t.train.underground && t.train.stretch === undefined)).toBe(true);
    expect(trains.some((t: any) => !t.train.underground && t.train.stretch && t.altitude > 0)).toBe(true);
  });

  // Swift's RelayFixtureTests pins the same numbers: 1 snapshot, the vessels' updates and the trains' (every placed train
  // of each later round, whose time has moved on), the trains that left between rounds, and the vessel swept at the end.
  test('v2 stream: its message counts follow from the scenario', () => {
    const stream = JSON.parse(builtV2.stream) as any[];
    const placed = (r: number) => new Set(SCENARIO.filter((t) => expectIn(t, r) !== 'none').map((t) => t.id));
    let trainUpdates = 0;
    let trainRemoves = 0;
    for (let r = 1; r < ROUND_COUNT; r++) {
      trainUpdates += placed(r).size;
      trainRemoves += [...placed(r - 1)].filter((id) => !placed(r).has(id)).length;
    }
    expect(stream[0].targets).toHaveLength(placed(0).size);
    expect(stream.filter((m) => m.type === 'update' && m.target.kind === 'train')).toHaveLength(trainUpdates);
    expect(stream.filter((m) => m.type === 'remove' && m.id.startsWith('train:'))).toHaveLength(trainRemoves);
    expect(stream.filter((m) => m.type === 'remove' && m.id.startsWith('vessel:'))).toHaveLength(1);
    expect(stream).toHaveLength(1 + 13 + trainUpdates + trainRemoves + 1);
    expect(JSON.parse(builtV2.snapshot).targets.filter((t: any) => t.kind === 'train')).toHaveLength(placed(ROUND_COUNT - 1).size);
  });

  test('synthetic sample yields the documented /v1 updates and snapshot', () => {
    const updates = JSON.parse(built.updates) as { type: string; vessel: any }[];
    expect(updates).toHaveLength(13);
    expect(updates.map((u) => [u.vessel.mmsi, u.vessel.timestamp])).toEqual([
      [367000001, '2026-11-10T14:00:00.125Z'],
      [367000001, '2026-11-10T14:00:05.000Z'],
      [367000002, '2026-11-10T14:00:10.500Z'],
      [367000002, '2026-11-10T14:00:20.000Z'],
      [367000003, '2026-11-10T14:00:30.000Z'],
      [367000001, '2026-11-10T14:01:00.000Z'],
      [367000001, '2026-11-10T14:05:00.000Z'],
      [367000002, '2026-11-10T14:06:00.000Z'],
      [367000004, '2026-11-10T14:08:00.000Z'],
      [367000005, '2026-11-10T14:10:00.000Z'],
      [367000005, '2026-11-10T14:09:00.000Z'],
      [367000001, '2026-11-10T14:11:00.999Z'],
      [367000002, '2026-11-10T14:05:30.000Z'],
    ]);
    expect(updates[10].vessel).toEqual({
      mmsi: 367000005, name: 'WATER TAXI 7', shipType: 60, lat: 40.7075, lon: -73.99, timestamp: '2026-11-10T14:09:00.000Z',
    });
    const snap = JSON.parse(built.snapshot);
    expect(snap.vessels.map((v: any) => v.mmsi)).toEqual([367000001, 367000002, 367000004, 367000005]);
  });
});
