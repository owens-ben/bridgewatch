import fs from 'node:fs';
import path from 'node:path';
import { decodeFeedMessage, type FeedMessage } from './gtfsrt';
import { trainTarget } from './sources/mta-subway';
import { TrainEstimator, type SubwayData, type TrainEstimate } from './subway';
import { buildRound, ROUND_COUNT, roundStamp } from './tools/subway-scenario';

/**
 * Synthetic subway feeds (tools/subway-scenario.ts, written by `npm run fixtures`): <UTC time>-<feed>.pb, plus the
 * expected targets, <UTC time>-targets.json.
 */
export const SUBWAY_FIXTURES_DIR = path.resolve(__dirname, '..', 'fixtures', 'subway');

export interface SubwayRound {
  /** e.g. 20261111T031521Z */
  stamp: string;
  /** Feed short name (feedName in subway-feed.ts: numbered, ace, bdfm, ...) to decoded message. */
  feeds: Map<string, FeedMessage>;
  /** The newest header time of the round's feeds, ms: the time the round's trains are estimated for. */
  at: number;
}

export function subwayRounds(dir = SUBWAY_FIXTURES_DIR): SubwayRound[] {
  const rounds = new Map<string, Map<string, FeedMessage>>();
  for (const file of fs.readdirSync(dir).sort()) {
    const m = /^(\d{8}T\d{6}Z)-([a-z0-9]+)\.pb$/.exec(file);
    if (!m) continue;
    let feeds = rounds.get(m[1]);
    if (!feeds) rounds.set(m[1], (feeds = new Map()));
    feeds.set(m[2], decodeFeedMessage(fs.readFileSync(path.join(dir, file))));
  }
  return [...rounds].map(([stamp, feeds]) => ({
    stamp,
    feeds,
    at: Math.max(...[...feeds.values()].map((f) => f.timestamp ?? 0)) * 1000,
  }));
}

export function expectedTargetsPath(stamp: string, dir = SUBWAY_FIXTURES_DIR): string {
  return path.join(dir, `${stamp}-targets.json`);
}

/** The trains estimated for a round, and the /v2/targets snapshot of them as the fixture file stores it. */
export function trainsFixture(round: SubwayRound, data: SubwayData): { trains: TrainEstimate[]; text: string } {
  const trains = new TrainEstimator(data).estimateAll(round.feeds.values(), round.at);
  const snapshot = { type: 'snapshot', targets: trains.map(trainTarget) };
  return { trains, text: JSON.stringify(snapshot, null, 2) + '\n' };
}

/** A round as the files hold it: its feeds decoded from the bytes. */
export function roundFromBytes(stamp: string, feeds: ReadonlyMap<string, Uint8Array>): SubwayRound {
  const decoded = new Map([...feeds].map(([name, bytes]) => [name, decodeFeedMessage(bytes)] as const));
  return { stamp, feeds: decoded, at: Math.max(...[...decoded.values()].map((f) => f.timestamp ?? 0)) * 1000 };
}

/** Every file of the fixtures directory the scenario generates (name to content): the feeds and the expected targets. */
export function generatedSubwayFixtures(data: SubwayData): Map<string, Uint8Array | string> {
  const files = new Map<string, Uint8Array | string>();
  for (let r = 0; r < ROUND_COUNT; r++) {
    const stamp = roundStamp(r);
    const feeds = buildRound(r);
    for (const [name, bytes] of feeds) files.set(`${stamp}-${name}.pb`, bytes);
    files.set(`${stamp}-targets.json`, trainsFixture(roundFromBytes(stamp, feeds), data).text);
  }
  return files;
}
