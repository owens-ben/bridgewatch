import type { Target } from './targets';

/** A change to the hub's targets, as sent on /v2/targets. */
export type HubEvent = { type: 'update'; target: Target } | { type: 'remove'; id: string };

/** Where one source publishes. It can only change or remove targets it holds itself. */
export interface TargetSink {
  /**
   * Publishes a target's full state. `expiresAt` (ms since the epoch): the hub drops the target once the clock passes
   * it, unless it's published again first. Without it, the target stays until the source removes it.
   */
  upsert(target: Target, expiresAt?: number): void;
  remove(id: string): void;
  /** Makes `targets` the source's complete set: publishes each and removes the source's targets that aren't in it. */
  replaceAll(targets: readonly Target[], expiresAt?: number): void;
}

interface Entry {
  target: Target;
  source: string;
  /** Position time, ms since the epoch. */
  ts: number;
  expiresAt: number;
}

/**
 * The current targets from every source, and the stream of changes to them (PROTOCOL.md, "/v2/targets").
 * Targets are keyed by id: when two sources report the same object, the newer position wins.
 */
export class TargetHub {
  private readonly entries = new Map<string, Entry>();
  private readonly listeners = new Set<(event: HubEvent) => void>();

  /**
   * `onError` hears about a subscriber that threw. Subscribers are isolated: one that throws doesn't stop the others,
   * and doesn't throw into the source that published.
   */
  constructor(
    private readonly now: () => number = Date.now,
    private readonly onError?: (err: unknown) => void,
  ) {}

  get size(): number {
    return this.entries.size;
  }

  sink(source: string): TargetSink {
    const sink: TargetSink = {
      upsert: (target, expiresAt) => this.upsert(source, target, expiresAt),
      remove: (id) => this.removeOwned(source, id),
      replaceAll: (targets, expiresAt) => {
        const keep = new Set(targets.map((t) => t.id));
        for (const [id, e] of this.entries) {
          if (e.source === source && !keep.has(id)) this.delete(id);
        }
        for (const t of targets) sink.upsert(t, expiresAt);
      },
    };
    return sink;
  }

  /** Every live target, sorted by id. */
  snapshot(): Target[] {
    const now = this.now();
    return [...this.entries.values()]
      .filter((e) => now <= e.expiresAt)
      .map((e) => e.target)
      .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  }

  /** Removes expired targets (sending a `remove` for each) and returns how many. */
  sweep(): number {
    const now = this.now();
    let removed = 0;
    for (const [id, e] of this.entries) {
      if (now > e.expiresAt) {
        this.delete(id);
        removed++;
      }
    }
    return removed;
  }

  /** Calls `listener` with every change from now on. Returns a function that stops it. */
  subscribe(listener: (event: HubEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private upsert(source: string, target: Target, expiresAt = Infinity): void {
    const ts = Date.parse(target.timestamp);
    if (Number.isNaN(ts)) return;
    const now = this.now();
    if (now > expiresAt) {
      this.removeOwned(source, target.id);
      return;
    }
    const existing = this.entries.get(target.id);
    if (existing && existing.source !== source && now <= existing.expiresAt && ts < existing.ts) return;
    this.entries.set(target.id, { target, source, ts, expiresAt });
    this.emit({ type: 'update', target });
  }

  private removeOwned(source: string, id: string): void {
    if (this.entries.get(id)?.source === source) this.delete(id);
  }

  private delete(id: string): void {
    this.entries.delete(id);
    this.emit({ type: 'remove', id });
  }

  private emit(event: HubEvent): void {
    for (const listener of this.listeners) {
      try {
        listener(event);
      } catch (err) {
        try {
          this.onError?.(err);
        } catch {
          /* the error handler failing must not break publishing either */
        }
      }
    }
  }
}
