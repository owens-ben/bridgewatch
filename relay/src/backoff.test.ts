import { describe, expect, test } from '@jest/globals';
import { backoffDelay } from './backoff';

describe('backoffDelay', () => {
  test('doubles per attempt; random=1 gives the full delay', () => {
    expect([0, 1, 2, 3, 4, 5, 6].map((a) => backoffDelay(a, () => 1))).toEqual([1000, 2000, 4000, 8000, 16000, 32000, 60000]);
  });
  test('jitter stays within [d/2, d]', () => {
    expect(backoffDelay(3, () => 0)).toBe(4000);
    expect(backoffDelay(3, () => 0.5)).toBe(6000);
    expect(backoffDelay(3, () => 1)).toBe(8000);
  });
  test('capped at 60000 even for huge attempts', () => {
    for (const a of [6, 10, 50, 1000]) {
      expect(backoffDelay(a, () => 1)).toBe(60000);
      expect(backoffDelay(a, () => 0)).toBe(30000);
    }
  });
  test('never below 1000 ms', () => {
    for (let a = 0; a < 20; a++) {
      for (const r of [0, 0.1, 0.5, 0.99, 1]) expect(backoffDelay(a, () => r)).toBeGreaterThanOrEqual(1000);
    }
    expect(backoffDelay(0, () => 0)).toBe(1000);
  });
  test('uses Math.random by default within bounds', () => {
    for (let i = 0; i < 50; i++) {
      const d = backoffDelay(4);
      expect(d).toBeGreaterThanOrEqual(8000);
      expect(d).toBeLessThanOrEqual(16000);
    }
  });
});
