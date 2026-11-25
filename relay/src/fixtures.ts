import path from 'node:path';
import { TargetHub, type HubEvent } from './hub';
import { Normalizer } from './normalizer';
import { Registry } from './registry';
import { AISSTREAM_SOURCE_ID, AisstreamSource } from './sources/aisstream';
import { MTA_SUBWAY_SOURCE_ID, TRAIN_EXPIRY_MS, trainTarget } from './sources/mta-subway';
import { TrainEstimator, type SubwayData } from './subway';
import type { SubwayRound } from './subway-fixtures';
import type { Target } from './targets';
import type { Normalized, VesselUpdate } from './types';

export const FIXTURE_NOW = '2026-11-10T14:12:00.000Z';
/** When the v2 stream's client connects: before the synthetic sample's first AIS message. */
export const V2_STREAM_START = '2026-11-10T13:59:00.000Z';

const RELAY_ROOT = path.resolve(__dirname, '..');
export const SAMPLE_PATH = path.join(RELAY_ROOT, 'fixtures', 'synthetic-sample.jsonl');
export const OUT_DIR = path.resolve(RELAY_ROOT, '..', 'Packages', 'BoatCore', 'Tests', 'BoatCoreTests', 'Fixtures');
export const V2_STREAM_PATH = path.join(OUT_DIR, 'relay-v2-stream.json');
export const V2_SNAPSHOT_PATH = path.join(OUT_DIR, 'relay-v2-snapshot.json');

/**
 * The synthetic sample's normalized messages, in order. Every sample line has a time_utc before FIXTURE_NOW; they are
 * taken as received at FIXTURE_NOW, so each keeps its own time (none is ahead of the receive time).
 */
export function sampleMessages(sampleText: string): Normalized[] {
  const normalizer = new Normalizer();
  const receivedAt = new Date(FIXTURE_NOW);
  return sampleText
    .split('\n')
    .filter((line) => line.trim() !== '')
    .flatMap((line) => normalizer.normalizeAll(line, receivedAt));
}

/** The synthetic sample's updates as /v1/vessels sends them, in order. */
export function sampleUpdates(sampleText: string): VesselUpdate[] {
  return sampleMessages(sampleText)
    .filter((m) => m.legacy)
    .map((m) => m.update);
}

/** The /v1/vessels updates of the synthetic sample, and the /v1 snapshot taken at FIXTURE_NOW. */
export function buildFixtures(sampleText: string): { updates: string; snapshot: string } {
  const registry = new Registry();
  const messages: { type: 'update'; vessel: VesselUpdate }[] = [];
  for (const vessel of sampleUpdates(sampleText)) {
    registry.apply(vessel);
    messages.push({ type: 'update', vessel });
  }
  const snapshot = { type: 'snapshot', vessels: registry.snapshot(Date.parse(FIXTURE_NOW)) };
  return {
    updates: JSON.stringify(messages, null, 2) + '\n',
    snapshot: JSON.stringify(snapshot, null, 2) + '\n',
  };
}

type V2Message = { type: 'snapshot'; targets: Target[] } | HubEvent;

/**
 * What a /v2/targets client gets (PROTOCOL.md, "Fixtures"), through the relay's own hub and sources on a fixed clock:
 * `stream` is the snapshot on connect (the first subway round's trains) and every message after it while
 * the synthetic AIS sample plays and the later subway rounds are published between its messages, ending with the
 * hub's sweep at FIXTURE_NOW. `snapshot` is what a client connecting at FIXTURE_NOW gets.
 *
 * The subway rounds are timed at the end of the AIS sample's window (the last is at FIXTURE_NOW), after its messages.
 * The hub's clock follows the AIS sample; each train expires TRAIN_EXPIRY_MS after its own round, as the mta-subway
 * source sets it, so no train expires during the stream.
 */
export function buildV2Fixtures(
  sampleText: string,
  rounds: readonly SubwayRound[],
  data: SubwayData,
): { stream: string; snapshot: string } {
  let clock = Date.parse(V2_STREAM_START);
  const hub = new TargetHub(() => clock);
  const ais = new AisstreamSource({ apiKey: 'unused', sink: hub.sink(AISSTREAM_SOURCE_ID), log: () => {} });
  const trainSink = hub.sink(MTA_SUBWAY_SOURCE_ID);
  const estimator = new TrainEstimator(data);
  // As MtaSubwaySource.publish, at the round's time.
  const publishTrains = (round: SubwayRound) =>
    trainSink.replaceAll(
      estimator.estimateAll(round.feeds.values(), round.at).map(trainTarget),
      round.at + TRAIN_EXPIRY_MS,
    );

  const [first, ...later] = rounds;
  if (first) publishTrains(first);
  const out: V2Message[] = [{ type: 'snapshot', targets: hub.snapshot() }];
  hub.subscribe((event) => out.push(event));

  const messages = sampleMessages(sampleText);
  // The later rounds go out evenly spaced between the AIS messages.
  const roundAfter = new Map(later.map((round, i) => [Math.floor(((i + 1) * messages.length) / (later.length + 1)), round]));
  messages.forEach(({ update, extras, legacy }, i) => {
    clock = Math.max(clock, Date.parse(update.timestamp));
    ais.ingest(update, extras, legacy);
    const round = roundAfter.get(i + 1);
    if (round) publishTrains(round);
  });

  clock = Date.parse(FIXTURE_NOW);
  hub.sweep();
  const snapshot = { type: 'snapshot', targets: hub.snapshot() };
  return {
    stream: JSON.stringify(out, null, 2) + '\n',
    snapshot: JSON.stringify(snapshot, null, 2) + '\n',
  };
}

/** Where the vessel-details sample's generated fixtures go (PROTOCOL.md, "Fixtures"). */
export const STATIC_SAMPLE_PATH = path.join(RELAY_ROOT, 'fixtures', 'synthetic-static.jsonl');
export const DETAILS_STREAM_PATH = path.join(OUT_DIR, 'relay-v2-details-stream.json');
export const DETAILS_SNAPSHOT_PATH = path.join(OUT_DIR, 'relay-v2-details-snapshot.json');

/**
 * What a /v2/targets client gets while `synthetic-static.jsonl` plays through the aisstream source and the hub on a
 * fixed clock: the empty snapshot on connect, every update after it, and the snapshot at FIXTURE_NOW. The sample is
 * the vessel details' edge cases (sentinels, dirty text, omissions); no trains, and /v1 never plays it.
 */
export function buildDetailsFixtures(sampleText: string): { stream: string; snapshot: string } {
  const messages = sampleMessages(sampleText);
  let clock = Date.parse(messages[0].update.timestamp);
  const hub = new TargetHub(() => clock);
  const ais = new AisstreamSource({ apiKey: 'unused', sink: hub.sink(AISSTREAM_SOURCE_ID), log: () => {} });
  const out: V2Message[] = [{ type: 'snapshot', targets: hub.snapshot() }];
  hub.subscribe((event) => out.push(event));
  for (const { update, extras, legacy } of messages) {
    clock = Math.max(clock, Date.parse(update.timestamp));
    ais.ingest(update, extras, legacy);
  }
  clock = Date.parse(FIXTURE_NOW);
  hub.sweep();
  return {
    stream: JSON.stringify(out, null, 2) + '\n',
    snapshot: JSON.stringify({ type: 'snapshot', targets: hub.snapshot() }, null, 2) + '\n',
  };
}
