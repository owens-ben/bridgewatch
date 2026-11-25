import { Census } from './census';
import { ConfigError, loadConfig, type Config } from './config';
import { describeError, guarded, installProcessHandlers, rateLimited } from './guard';
import { relayHealth } from './health';
import { TargetHub } from './hub';
import { RelayMetrics } from './metrics';
import { log } from './log';
import { Registry } from './registry';
import { createRelayServer } from './server';
import { SOURCE_PLUGINS } from './sources';
import { startSources } from './sources/start-sources';

let config: Config;
try {
  config = loadConfig(process.env, SOURCE_PLUGINS);
} catch (err) {
  if (err instanceof ConfigError) {
    console.error(`error: ${err.message}`);
    process.exit(1);
  }
  throw err;
}
// After the config, so a bad setting still fails at boot as before (README, "Failure handling").
installProcessHandlers(process, log, (code) => process.exit(code));

// A subscriber that throws is skipped (the others still get the event); one throwing on every event would log many
// lines a second, so at most one a minute, with a count.
const hubErrors = rateLimited(log);
const hub = new TargetHub(Date.now, (err) => hubErrors(`hub: ERROR: a subscriber threw: ${describeError(err)}`));
// The vessel census: in memory only unless CENSUS_FILE names a file (README, "Census").
const censusFile = process.env.CENSUS_FILE?.trim() || undefined;
const census = new Census({ file: censusFile, log });
const registry = new Registry(); // /v1/vessels
function health() {
  const now = Date.now();
  const report = Object.fromEntries(running.flatMap(({ id, source }) => (source.health ? [[id, source.health(now)]] : [])));
  return relayHealth(report, hub.size, server.clientCount());
}
const metrics = new RelayMetrics({
  health,
  targets: () => hub.snapshot(),
  clients: () => server.clientCounts(),
  publicListenerUp: () => server.publicListening(),
  census,
});
hub.subscribe((event) => metrics.observe(event));
const { access } = config;
const server = createRelayServer({
  registry,
  hub,
  log,
  health,
  metrics,
  census,
  tokens: access.tokens,
  maxClients: access.maxClients,
  publicLimits: access.public,
});
const running = config.sources.map(({ id, create }) => ({
  id,
  source: create({
    sink: hub.sink(id),
    log,
    census,
    legacyVesselUpdate: (update) => {
      registry.apply(update);
      server.broadcast(update);
    },
  }),
}));
const sources = running.map((r) => r.source);

const pruner = setInterval(
  guarded('pruner: failed', log, () => {
    const removed = registry.prune(Date.now());
    if (removed > 0) log(`registry: pruned ${removed} vessel(s), ${registry.size} remain`);
    const expired = hub.sweep();
    if (expired > 0) log(`hub: expired ${expired} target(s), ${hub.size} remain`);
  }),
  5_000,
);
pruner.unref();
// Writes the census when it changed, at most every five minutes (the interval is the census's own).
const censusWriter = setInterval(
  guarded('census: flush failed', log, () => census.flush()),
  30_000,
);
censusWriter.unref();

server.listen(config.port, config.host).then(
  (port) => {
    log(`server: listening on ${config.host}:${port}, sources: ${config.sources.map((s) => s.id).join(', ')}`);
    startSources(running, log);
    startPublic();
  },
  (err: unknown) => {
    log(`server: FATAL: can't listen on ${config.host}:${config.port}: ${describeError(err)}`);
    process.exit(1);
  },
);

/**
 * The public listener fails closed and never takes the relay down with it: with any problem in its settings it isn't
 * started, the error is logged (and `relay_public_listener_up` reads 0), and the main listener and /healthz carry on.
 */
function startPublic(): void {
  for (const error of access.errors) log(`server: ERROR: ${error}`);
  const pub = access.public;
  if (!pub) return;
  server.listenPublic(pub.port, config.host).then(
    (port) =>
      log(
        `server: public listener on ${config.host}:${port}, app token required (${access.tokens.length} accepted), ` +
          `at most ${pub.maxClients} clients and ${pub.maxClientsPerIp} per address`,
      ),
    (err: unknown) => log(`server: ERROR: public listener not started: ${err instanceof Error ? err.message : String(err)}`),
  );
}

let shuttingDown = false;
function shutdown(signal: string): void {
  if (shuttingDown) return;
  shuttingDown = true;
  log(`${signal} received, shutting down`);
  clearInterval(pruner);
  clearInterval(censusWriter);
  for (const source of sources) source.stop();
  census.flush(true);
  metrics.close();
  server.close().then(() => process.exit(0));
  setTimeout(() => process.exit(0), 5000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
