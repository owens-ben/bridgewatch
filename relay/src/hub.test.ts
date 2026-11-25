import { describe, expect, test } from '@jest/globals';
import { TargetHub, type HubEvent } from './hub';
import type { Target } from './targets';

const T0 = Date.parse('2026-11-10T14:00:00.000Z');
const iso = (ms: number) => new Date(ms).toISOString();
const target = (id: string, ms = T0, extra: Partial<Target> = {}): Target => ({
  id,
  kind: 'vessel',
  source: 'test',
  lat: 40.7,
  lon: -73.99,
  timestamp: iso(ms),
  ...extra,
});

function makeHub(start = T0) {
  let now = start;
  const hub = new TargetHub(() => now);
  const events: HubEvent[] = [];
  hub.subscribe((e) => events.push(e));
  return { hub, events, setNow: (ms: number) => (now = ms) };
}

describe('TargetHub', () => {
  test('upsert replaces the full state and sends an update; snapshot is sorted by id', () => {
    const { hub, events } = makeHub();
    const a = hub.sink('a');
    a.upsert(target('vessel:2'));
    a.upsert(target('vessel:1', T0, { name: 'ONE', speed: 4 }));
    a.upsert(target('vessel:1', T0 + 1000));
    expect(hub.snapshot().map((t) => [t.id, t.name, t.speed])).toEqual([
      ['vessel:1', undefined, undefined],
      ['vessel:2', undefined, undefined],
    ]);
    expect(events.map((e) => e.type)).toEqual(['update', 'update', 'update']);
    expect(events[2]).toEqual({ type: 'update', target: target('vessel:1', T0 + 1000) });
  });

  test('remove only touches the source\'s own targets', () => {
    const { hub, events } = makeHub();
    hub.sink('a').upsert(target('x'));
    hub.sink('b').remove('x');
    expect(hub.size).toBe(1);
    hub.sink('a').remove('x');
    hub.sink('a').remove('x');
    expect(hub.size).toBe(0);
    expect(events.slice(1)).toEqual([{ type: 'remove', id: 'x' }]);
  });

  test('two sources, one id: the newer position wins, and a tie goes to the later message', () => {
    const { hub } = makeHub();
    hub.sink('a').upsert(target('x', T0 + 5000, { source: 'a' }));
    hub.sink('b').upsert(target('x', T0, { source: 'b' }));
    expect(hub.snapshot()[0].source).toBe('a');
    hub.sink('b').upsert(target('x', T0 + 5000, { source: 'b' }));
    expect(hub.snapshot()[0].source).toBe('b');
    // Now b holds it: a can't remove it, and its own older position still loses.
    hub.sink('a').remove('x');
    hub.sink('a').upsert(target('x', T0 + 1000, { source: 'a' }));
    expect(hub.snapshot()[0].source).toBe('b');
  });

  test('the source holding a target may move it back in time (its own merge rules decide)', () => {
    const { hub } = makeHub();
    hub.sink('a').upsert(target('x', T0 + 5000));
    hub.sink('a').upsert(target('x', T0));
    expect(hub.snapshot()[0].timestamp).toBe(iso(T0));
  });

  test('expiry: kept up to and including expiresAt, then left out of snapshots and removed by sweep', () => {
    const { hub, events, setNow } = makeHub();
    hub.sink('a').upsert(target('x'), T0 + 600_000);
    hub.sink('a').upsert(target('forever'));
    setNow(T0 + 600_000);
    expect(hub.snapshot().map((t) => t.id)).toEqual(['forever', 'x']);
    expect(hub.sweep()).toBe(0);
    setNow(T0 + 600_001);
    expect(hub.snapshot().map((t) => t.id)).toEqual(['forever']);
    expect(hub.size).toBe(2);
    expect(hub.sweep()).toBe(1);
    expect(hub.size).toBe(1);
    expect(events.at(-1)).toEqual({ type: 'remove', id: 'x' });
  });

  test('an already expired upsert is dropped, and removes what the source had', () => {
    const { hub, events } = makeHub();
    hub.sink('a').upsert(target('new'), T0 - 1);
    expect(hub.size).toBe(0);
    expect(events).toEqual([]);
    hub.sink('a').upsert(target('x'));
    hub.sink('a').upsert(target('x'), T0 - 1);
    expect(hub.size).toBe(0);
    expect(events.at(-1)).toEqual({ type: 'remove', id: 'x' });
  });

  test('another source may take over an expired target even with an older position', () => {
    const { hub, setNow } = makeHub();
    hub.sink('a').upsert(target('x', T0 + 5000, { source: 'a' }), T0 + 10_000);
    setNow(T0 + 10_001);
    hub.sink('b').upsert(target('x', T0 + 1000, { source: 'b' }));
    expect(hub.snapshot().map((t) => t.source)).toEqual(['b']);
  });

  test('replaceAll publishes the list and removes the source\'s targets missing from it, not other sources\'', () => {
    const { hub, events } = makeHub();
    const a = hub.sink('a');
    a.replaceAll([target('1'), target('2')]);
    hub.sink('b').upsert(target('3'));
    events.length = 0;
    a.replaceAll([target('2', T0 + 1000)]);
    expect(events).toEqual([
      { type: 'remove', id: '1' },
      { type: 'update', target: target('2', T0 + 1000) },
    ]);
    a.replaceAll([]);
    expect(hub.snapshot().map((t) => t.id)).toEqual(['3']);
  });

  test('ignores targets with unparseable timestamps; unsubscribe stops events', () => {
    const { hub, events } = makeHub();
    hub.sink('a').upsert({ ...target('x'), timestamp: 'nope' });
    expect(hub.size).toBe(0);
    const seen: HubEvent[] = [];
    const stop = hub.subscribe((e) => seen.push(e));
    stop();
    hub.sink('a').upsert(target('y'));
    expect(seen).toEqual([]);
    expect(events).toHaveLength(1);
  });
});

describe('TargetHub, a throwing subscriber', () => {
  function makeIsolatedHub() {
    let now = T0;
    const errors: unknown[] = [];
    const hub = new TargetHub(
      () => now,
      (err) => errors.push(err),
    );
    const before: HubEvent[] = [];
    const after: HubEvent[] = [];
    hub.subscribe((e) => before.push(e));
    hub.subscribe(() => {
      throw new Error('subscriber broke');
    });
    hub.subscribe((e) => after.push(e));
    return { hub, errors, before, after, setNow: (ms: number) => (now = ms) };
  }

  test('doesn\'t stop the other subscribers or throw out of upsert, replaceAll, remove or sweep', () => {
    const { hub, errors, before, after, setNow } = makeIsolatedHub();
    const a = hub.sink('a');
    expect(() => a.upsert(target('x'))).not.toThrow();
    expect(() => a.replaceAll([target('y'), target('z')], T0 + 1000)).not.toThrow();
    expect(() => a.remove('y')).not.toThrow();
    setNow(T0 + 1001);
    expect(() => hub.sweep()).not.toThrow();

    const expected: HubEvent[] = [
      { type: 'update', target: target('x') },
      { type: 'remove', id: 'x' },
      { type: 'update', target: target('y') },
      { type: 'update', target: target('z') },
      { type: 'remove', id: 'y' },
      { type: 'remove', id: 'z' },
    ];
    expect(before).toEqual(expected);
    expect(after).toEqual(expected);
    expect(errors).toHaveLength(expected.length);
    expect((errors[0] as Error).message).toBe('subscriber broke');
    expect(hub.size).toBe(0);
  });

  test('leaves the hub\'s state consistent: replaceAll finishes', () => {
    const { hub } = makeIsolatedHub();
    const a = hub.sink('a');
    a.replaceAll([target('1'), target('2'), target('3')]);
    a.replaceAll([target('2'), target('4')]);
    expect(hub.snapshot().map((t) => t.id)).toEqual(['2', '4']);
    expect(hub.size).toBe(2);
  });

  test('without onError the throw is still contained', () => {
    const hub = new TargetHub(() => T0);
    hub.subscribe(() => {
      throw new Error('nobody listening');
    });
    expect(() => hub.sink('a').upsert(target('x'))).not.toThrow();
    expect(hub.snapshot().map((t) => t.id)).toEqual(['x']);
  });
});
