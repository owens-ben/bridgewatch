import { describe, expect, test } from '@jest/globals';
import { describeError, guarded, installProcessHandlers, LOG_EVERY_MS, rateLimited, safeText, type ProcessEvents } from './guard';

/** A clock the test moves by hand. */
function clock(start = 1_000_000) {
  let t = start;
  return { now: () => t, advance: (ms: number) => (t += ms) };
}

describe('rateLimited', () => {
  test('logs the first line at once, counts the ones inside the window, and reports the count on the next line', () => {
    const c = clock();
    const lines: string[] = [];
    const log = rateLimited((m) => lines.push(m), { now: c.now });
    log('one');
    log('two');
    c.advance(LOG_EVERY_MS - 1);
    log('three');
    expect(lines).toEqual(['one']);
    c.advance(1);
    log('four');
    expect(lines).toEqual(['one', 'four (and 2 more since the last line)']);
    c.advance(LOG_EVERY_MS);
    log('five');
    expect(lines).toEqual(['one', 'four (and 2 more since the last line)', 'five']);
  });

  test('the window can be set', () => {
    const c = clock();
    const lines: string[] = [];
    const log = rateLimited((m) => lines.push(m), { now: c.now, everyMs: 10 });
    log('a');
    c.advance(10);
    log('b');
    expect(lines).toEqual(['a', 'b']);
  });
});

describe('guarded', () => {
  test('passes its arguments through and logs nothing while it works', () => {
    const lines: string[] = [];
    const seen: number[] = [];
    const f = guarded('t', (m) => lines.push(m), (a: number, b: number) => seen.push(a + b));
    f(1, 2);
    f(3, 4);
    expect(seen).toEqual([3, 7]);
    expect(lines).toEqual([]);
  });

  test('never throws; a failure that never stops logs once per window, with a count', () => {
    const c = clock();
    const lines: string[] = [];
    const f = guarded(
      'pruner: failed',
      (m) => lines.push(m),
      () => {
        throw new Error('boom');
      },
      { now: c.now },
    );
    expect(() => f()).not.toThrow();
    for (let i = 0; i < 5; i++) {
      c.advance(1000);
      expect(() => f()).not.toThrow();
    }
    expect(lines).toEqual(['pruner: failed: boom']);
    c.advance(LOG_EVERY_MS);
    f();
    expect(lines).toEqual(['pruner: failed: boom', 'pruner: failed: boom (and 5 more since the last line)']);
  });

  test('failures alternating with successes log at most one line per window, and no "recovered" line', () => {
    const c = clock();
    const lines: string[] = [];
    let n = 0;
    const f = guarded(
      'upstream: frame processing failed',
      (m) => lines.push(m),
      () => {
        if (n++ % 2 === 0) throw new Error('bad frame');
      },
      { now: c.now },
    );
    for (let i = 0; i < 100; i++) {
      f();
      c.advance(1000); // 100 calls over 100 s: two windows
    }
    expect(lines).toEqual([
      'upstream: frame processing failed: bad frame',
      'upstream: frame processing failed: bad frame (and 29 more since the last line)',
    ]);
  });

  test('a failure\'s message can\'t forge log lines', () => {
    const lines: string[] = [];
    guarded('x', (m) => lines.push(m), () => {
      throw new Error('bad\n2026-11-16T00:00:00.000Z server: FAKE');
    })();
    expect(lines).toEqual(['x: bad 2026-11-16T00:00:00.000Z server: FAKE']);
  });
});

describe('safeText and describeError', () => {
  test('safeText collapses control characters into one space, trims and caps', () => {
    expect(safeText('a\r\n\tb\u0000c\u007Fd\u2028e\u2029f')).toBe('a b c d e f');
    expect(safeText('  \n padded \r\n ')).toBe('padded');
    expect(safeText('x'.repeat(400))).toHaveLength(300);
    expect(safeText('x'.repeat(400)).endsWith('…')).toBe(true);
    expect(safeText('abcdef', 4)).toBe('abc…');
    expect(safeText('abcd', 4)).toBe('abcd');
  });

  test('describeError takes anything thrown and returns one safe line', () => {
    expect(describeError(new TypeError('bad'))).toBe('bad');
    expect(describeError('plain\nline')).toBe('plain line');
    expect(describeError(42)).toBe('42');
    expect(describeError(undefined)).toBe('undefined');
  });
});

describe('installProcessHandlers', () => {
  function fakeProcess() {
    const handlers = new Map<string, (arg: never) => void>();
    const proc = { on: (event: string, listener: (arg: never) => void) => handlers.set(event, listener) } as ProcessEvents;
    return { proc, handlers };
  }

  test('an unhandled rejection is logged, rate limited, and the relay keeps serving', () => {
    const c = clock();
    const { proc, handlers } = fakeProcess();
    const lines: string[] = [];
    const exits: number[] = [];
    installProcessHandlers(proc, (m) => lines.push(m), (code) => exits.push(code), { now: c.now });
    const reject = handlers.get('unhandledRejection') as (r: unknown) => void;
    reject(new Error('lost promise'));
    reject(new Error('lost promise'));
    reject(new Error('lost promise'));
    expect(lines).toEqual(['process: ERROR: unhandled rejection (still serving): lost promise']);
    c.advance(LOG_EVERY_MS);
    reject(new Error('another'));
    expect(lines).toEqual([
      'process: ERROR: unhandled rejection (still serving): lost promise',
      'process: ERROR: unhandled rejection (still serving): another (and 2 more since the last line)',
    ]);
    expect(exits).toEqual([]);
  });

  test('an uncaught exception is logged, on one line, and exits 1', () => {
    const { proc, handlers } = fakeProcess();
    const lines: string[] = [];
    const exits: number[] = [];
    installProcessHandlers(proc, (m) => lines.push(m), (code) => exits.push(code));
    (handlers.get('uncaughtException') as (e: Error) => void)(new Error('state unknown'));
    expect(exits).toEqual([1]);
    expect(lines).toHaveLength(1);
    expect(lines[0]).toMatch(/^process: FATAL: uncaught exception, exiting: Error: state unknown +at /);
    expect(lines[0]).not.toContain('\n');
  });
});
