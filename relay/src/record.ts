import fs from 'node:fs';
import path from 'node:path';
import { ConfigError } from './config';
import { log } from './log';
import { aisstreamApiKey } from './sources/aisstream';
import { UpstreamClient } from './upstream';

let apiKey: string;
try {
  apiKey = aisstreamApiKey(process.env);
} catch (err) {
  if (err instanceof ConfigError) {
    console.error(`error: ${err.message}`);
    process.exit(1);
  }
  throw err;
}

const seconds = Number(process.env.RECORD_SECONDS) > 0 ? Number(process.env.RECORD_SECONDS) : 300;
const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
const dir = path.resolve(__dirname, '..', 'fixtures');
fs.mkdirSync(dir, { recursive: true });
const file = path.join(dir, `aisstream-${stamp}.jsonl`);
const out = fs.createWriteStream(file);
let frames = 0;

const upstream = new UpstreamClient({
  apiKey,
  log,
  onRawFrame: (text) => {
    out.write(text + '\n');
    frames++;
  },
});

log(`recording ${seconds}s to ${file}`);
upstream.start();
setTimeout(() => {
  upstream.stop();
  out.end(() => {
    log(`recorded ${frames} frames`);
    process.exit(0);
  });
}, seconds * 1000);
