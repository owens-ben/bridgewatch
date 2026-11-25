import { ConfigError } from '../config';
import { guarded } from '../guard';
import { streamHealth, type SourceHealth } from '../health';
import { EXPIRY_MS, Registry, type VesselState } from '../registry';
import { cleanText, NAME_MAX } from '../normalizer';
import { makeTarget, type Target } from '../targets';
import type { VesselExtras, VesselUpdate } from '../types';
import { UpstreamClient, type UpstreamOptions } from '../upstream';
import type { Source, SourceContext, SourcePlugin } from './source';

export const AISSTREAM_SOURCE_ID = 'aisstream';
const PRUNE_INTERVAL_MS = 30_000;

export function aisstreamApiKey(env: NodeJS.ProcessEnv): string {
  const apiKey = env.AISSTREAM_API_KEY?.trim();
  if (!apiKey) {
    throw new ConfigError('AISSTREAM_API_KEY is required (set it in the environment or relay/.env)');
  }
  return apiKey;
}

/** Boats from aisstream.io's free AIS feed, inside BOUNDING_BOXES. */
export const aisstream: SourcePlugin = {
  id: AISSTREAM_SOURCE_ID,
  configure(env) {
    const apiKey = aisstreamApiKey(env);
    return (context) => new AisstreamSource({ ...context, apiKey });
  },
};

/** A vessel's merged state as a target, positioned at its newest position (PROTOCOL.md, "Vessels"). */
export function vesselTarget(v: Readonly<VesselState>, source: string): Target {
  return makeTarget({
    id: `vessel:${v.mmsi}`,
    kind: 'vessel',
    source,
    // A boat's name is untrusted text like its destination: /v2 sends it cleaned (/v1 keeps what it always sent).
    name: cleanText(v.name, NAME_MAX),
    lat: v.lat,
    lon: v.lon,
    speed: v.sog,
    course: v.cog,
    heading: v.heading,
    timestamp: new Date(v.posTs).toISOString(),
    vessel: { mmsi: v.mmsi, shipType: v.shipType, ...v.extras },
  });
}

export interface AisstreamSourceOptions extends SourceContext {
  apiKey: string;
  /** Overrides for the upstream client (tests inject a fake socket). */
  upstream?: Partial<UpstreamOptions>;
}

/** Holds the aisstream connection, merges each vessel's messages and publishes its full state. */
export class AisstreamSource implements Source {
  private readonly registry = new Registry();
  private readonly upstream: UpstreamClient;
  private pruner?: ReturnType<typeof setInterval>;
  private startedAt = 0;
  /** The side jobs of ingest(), each guarded: a bug in /v1 or the census must not keep a boat off /v2. */
  private readonly legacyUpdate: (update: VesselUpdate) => void;
  private readonly observe: (update: VesselUpdate, extras?: VesselExtras) => void;
  private readonly publish: (update: VesselUpdate, extras?: VesselExtras) => void;

  constructor(private readonly o: AisstreamSourceOptions) {
    this.legacyUpdate = guarded('aisstream: v1 update failed', o.log, (u: VesselUpdate) => o.legacyVesselUpdate?.(u));
    this.observe = guarded('aisstream: census failed', o.log, (u: VesselUpdate, e?: VesselExtras) =>
      o.census?.observe(u, e),
    );
    this.publish = guarded('aisstream: publish failed', o.log, (u: VesselUpdate, e?: VesselExtras) => {
      this.registry.apply(u, e);
      const state = this.registry.get(u.mmsi);
      if (state) this.o.sink.upsert(vesselTarget(state, AISSTREAM_SOURCE_ID), state.lastSeen + EXPIRY_MS);
    });
    this.upstream = new UpstreamClient({
      apiKey: o.apiKey,
      log: o.log,
      onMessage: (n) => this.ingest(n.update, n.extras, n.legacy),
      ...o.upstream,
    });
  }

  start(): void {
    this.startedAt = Date.now();
    this.upstream.start();
    this.pruner = setInterval(
      guarded('aisstream: prune failed', this.o.log, () => this.registry.prune(Date.now())),
      PRUNE_INTERVAL_MS,
    );
    this.pruner.unref();
  }

  stop(): void {
    clearInterval(this.pruner);
    this.upstream.stop();
  }

  health(now: number): SourceHealth {
    return streamHealth(now, this.startedAt, this.upstream.status());
  }

  /**
   * One normalized AIS update: merged per PROTOCOL.md "Merge rules", then published as the vessel's full state.
   * /v1 gets the update as it is, never the extras, and not at all when `legacy` is false. The /v1 update and the
   * census run guarded, so a failure in either is logged and the vessel is still published. Never throws.
   */
  ingest(update: VesselUpdate, extras?: VesselExtras, legacy = true): void {
    if (legacy) this.legacyUpdate(update);
    this.observe(update, extras);
    this.publish(update, extras);
  }
}
