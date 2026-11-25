import { describe, expect, test } from '@jest/globals';
import { relayHealth, STALE_AFTER_MS, streamHealth } from './health';

describe('streamHealth', () => {
  test('healthy with recent data, and reports its age', () => {
    expect(streamHealth(50_000, 0, { connected: true, lastFrameAt: 45_000 })).toEqual({
      ok: true,
      connected: true,
      lastDataAgeSeconds: 5,
    });
  });

  test('unhealthy once data is older than STALE_AFTER_MS, connected or not', () => {
    const at = 1_000;
    expect(streamHealth(at + STALE_AFTER_MS, 0, { connected: true, lastFrameAt: at }).ok).toBe(true);
    expect(streamHealth(at + STALE_AFTER_MS + 1, 0, { connected: true, lastFrameAt: at }).ok).toBe(false);
  });

  test('before any data, counts from start', () => {
    const upstream = { connected: false };
    expect(streamHealth(STALE_AFTER_MS, 0, upstream).ok).toBe(true);
    const h = streamHealth(STALE_AFTER_MS + 1, 0, upstream);
    expect(h.ok).toBe(false);
    expect(h.lastDataAgeSeconds).toBeUndefined();
  });
});

describe('relayHealth', () => {
  test('ok only when every source is', () => {
    const good = { ok: true, lastDataAgeSeconds: 1 };
    const bad = { ok: false, connected: false };
    expect(relayHealth({ a: good, b: good }, 7, 2)).toEqual({ ok: true, sources: { a: good, b: good }, targets: 7, clients: 2 });
    expect(relayHealth({ a: good, b: bad }, 7, 2).ok).toBe(false);
    expect(relayHealth({}, 0, 0).ok).toBe(true);
  });
});
