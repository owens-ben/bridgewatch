import type { Logger } from './types';

/** How often a rate-limited logger writes at most, by default. */
export const LOG_EVERY_MS = 60_000;

export interface RateLimitOptions {
  /** At most one line per this many ms (default LOG_EVERY_MS). */
  everyMs?: number;
  /** ms since the epoch (tests inject a clock). */
  now?: () => number;
}

/** Runs of control characters, the line and paragraph separators included (escaped: raw ones would end the line). */
const CONTROL_RUNS = /[\u0000-\u001F\u007F\u2028\u2029]+/g;

/**
 * Text safe for one log line: every run of control characters (CR, LF, tab, the rest of 0x00-0x1F, DEL, and the
 * Unicode line and paragraph separators) becomes one space, and it's trimmed and capped at `max` characters. Trip IDs
 * and error messages can come from third-party feeds and must not be able to forge log lines.
 */
export function safeText(s: string, max = 300): string {
  const flat = s.replace(CONTROL_RUNS, ' ').trim();
  return flat.length > max ? `${flat.slice(0, Math.max(0, max - 1))}…` : flat;
}

/** An error's message for a log line (the message of an Error, anything else as a string), made safe by safeText. */
export function describeError(err: unknown): string {
  let text: string;
  try {
    text = err instanceof Error ? err.message || err.name : String(err);
  } catch {
    text = 'unprintable error';
  }
  return safeText(text);
}

/**
 * A logger that writes at most one line per window: the first call logs at once, later calls inside the window are
 * only counted, and the next line after it says how many were left out (` (and N more since the last line)`).
 */
export function rateLimited(log: Logger, opts: RateLimitOptions = {}): Logger {
  const everyMs = opts.everyMs ?? LOG_EVERY_MS;
  const now = opts.now ?? Date.now;
  let lastAt = -Infinity;
  let skipped = 0;
  return (message) => {
    const t = now();
    if (t - lastAt < everyMs) {
      skipped++;
      return;
    }
    log(skipped > 0 ? `${message} (and ${skipped} more since the last line)` : message);
    lastAt = t;
    skipped = 0;
  };
}

/**
 * `fn` made safe to call from a timer, an event handler or another source's publish: it never throws. Failures are
 * logged as `<label>: <message>` through a rateLimited logger: the first at once, then at most one line a window with
 * a count, so neither a failure that never stops nor one that alternates with successes floods the log.
 */
export function guarded<A extends unknown[]>(
  label: string,
  log: Logger,
  fn: (...args: A) => void,
  opts?: RateLimitOptions,
): (...args: A) => void {
  const limited = rateLimited(log, opts);
  return (...args: A) => {
    try {
      fn(...args);
    } catch (err) {
      try {
        limited(`${label}: ${describeError(err)}`);
      } catch {
        /* a failing logger must not make the guard throw */
      }
    }
  };
}

/** The slice of `process` installProcessHandlers uses; tests pass a fake. */
export interface ProcessEvents {
  on(event: 'unhandledRejection', listener: (reason: unknown) => void): unknown;
  on(event: 'uncaughtException', listener: (err: Error) => void): unknown;
}

/**
 * The last line of defence (README, "Failure handling"). An unhandled rejection is logged (rate limited) and the relay
 * keeps serving: a restart would drop every client, and the vessel set takes minutes to rebuild from AIS. An uncaught
 * exception is logged and the process exits 1: its state is unknown, and Docker restarts the container.
 */
export function installProcessHandlers(
  proc: ProcessEvents,
  log: Logger,
  exit: (code: number) => void,
  opts?: RateLimitOptions,
): void {
  const rejections = rateLimited(log, opts);
  proc.on('unhandledRejection', (reason) => {
    rejections(`process: ERROR: unhandled rejection (still serving): ${describeError(reason)}`);
  });
  proc.on('uncaughtException', (err) => {
    const detail = err instanceof Error && err.stack ? safeText(err.stack, 4000) : describeError(err);
    log(`process: FATAL: uncaught exception, exiting: ${detail}`);
    exit(1);
  });
}
