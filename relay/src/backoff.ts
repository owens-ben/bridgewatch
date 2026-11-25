export const BACKOFF_BASE_MS = 1000;
export const BACKOFF_CAP_MS = 60_000;

/** Exponential backoff with jitter in [d/2, d], never below BACKOFF_BASE_MS. attempt starts at 0. */
export function backoffDelay(attempt: number, random: () => number = Math.random): number {
  const d = Math.min(BACKOFF_CAP_MS, BACKOFF_BASE_MS * 2 ** Math.min(attempt, 30));
  return Math.max(BACKOFF_BASE_MS, d / 2 + (random() * d) / 2);
}
