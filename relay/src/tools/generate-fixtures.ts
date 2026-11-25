import fs from 'node:fs';
import { buildDetailsFixtures, buildV2Fixtures, DETAILS_SNAPSHOT_PATH, DETAILS_STREAM_PATH, OUT_DIR, STATIC_SAMPLE_PATH, SAMPLE_PATH, V2_SNAPSHOT_PATH, V2_STREAM_PATH } from '../fixtures';
import { SUBWAY_DATA } from '../subway-data';
import { generatedSubwayFixtures, SUBWAY_FIXTURES_DIR, subwayRounds } from '../subway-fixtures';
import path from 'node:path';

/**
 * Writes every generated fixture: the synthetic subway feeds and their expected targets (relay/fixtures/subway, from
 * tools/subway-scenario.ts), then the BoatCore /v2 fixtures through the relay's own hub and sources.
 */

fs.mkdirSync(SUBWAY_FIXTURES_DIR, { recursive: true });
const generated = generatedSubwayFixtures(SUBWAY_DATA);
for (const file of fs.readdirSync(SUBWAY_FIXTURES_DIR)) {
  if (!generated.has(file)) fs.rmSync(path.join(SUBWAY_FIXTURES_DIR, file));
}
for (const [file, content] of generated) {
  fs.writeFileSync(path.join(SUBWAY_FIXTURES_DIR, file), content);
  console.log(`wrote ${path.join(SUBWAY_FIXTURES_DIR, file)}`);
}

const rounds = subwayRounds();
const { stream, snapshot } = buildV2Fixtures(fs.readFileSync(SAMPLE_PATH, 'utf8'), rounds, SUBWAY_DATA);
fs.mkdirSync(OUT_DIR, { recursive: true });
fs.writeFileSync(V2_STREAM_PATH, stream);
fs.writeFileSync(V2_SNAPSHOT_PATH, snapshot);
console.log(`wrote ${V2_STREAM_PATH}\nwrote ${V2_SNAPSHOT_PATH}`);

const details = buildDetailsFixtures(fs.readFileSync(STATIC_SAMPLE_PATH, 'utf8'));
fs.writeFileSync(DETAILS_STREAM_PATH, details.stream);
fs.writeFileSync(DETAILS_SNAPSHOT_PATH, details.snapshot);
console.log(`wrote ${DETAILS_STREAM_PATH}\nwrote ${DETAILS_SNAPSHOT_PATH}`);
