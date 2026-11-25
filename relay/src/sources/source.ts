import type { SourceHealth } from '../health';
import type { TargetSink } from '../hub';
import type { Logger, VesselExtras, VesselUpdate } from '../types';

/** A running feed of targets (README, "Sources"). */
export interface Source {
  start(): void;
  stop(): void;
  /** Its part of /healthz (README, "Health"). `now` is ms since the epoch. */
  health?(now: number): SourceHealth;
}

export interface SourceContext {
  /** Where the source publishes its targets. */
  sink: TargetSink;
  log: Logger;
  /** /v1/vessels only (app builds from before /v2/targets): each normalized AIS update. Goes when /v1 does. */
  legacyVesselUpdate?: (update: VesselUpdate) => void;
  /** The vessel census (README, "Census"): AIS sources report every normalized message to it. */
  census?: { observe(update: VesselUpdate, extras?: VesselExtras): void };
}

/** A kind of source the relay can run, enabled by name in SOURCES. */
export interface SourcePlugin {
  /** Its name in SOURCES and in each target's `source`. */
  id: string;
  /** Reads and checks the source's settings from `env` (throws ConfigError) and returns how to start it. */
  configure(env: NodeJS.ProcessEnv): (context: SourceContext) => Source;
}
