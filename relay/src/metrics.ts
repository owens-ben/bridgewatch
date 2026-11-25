import { monitorEventLoopDelay, type IntervalHistogram } from 'node:perf_hooks';
import type { HealthReport } from './health';
import type { HubEvent } from './hub';
import type { Target } from './targets';

/**
 * Prometheus metrics for GET /metrics (README, "Metrics"), in the text exposition format, written out by hand: the
 * relay has a few dozen series, not worth a client library.
 */
export const METRICS_CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8';

export type Labels = Record<string, string>;

/** The event loop sampler's interval. Its readings include this interval, so it's subtracted to get the delay. */
const LOOP_RESOLUTION_MS = 20;

export interface MetricFamily {
  name: string;
  help: string;
  type: 'gauge' | 'counter';
  samples: { labels?: Labels; value: number }[];
}

const escapeHelp = (s: string) => s.replace(/\\/g, '\\\\').replace(/\n/g, '\\n');
const escapeLabel = (s: string) => s.replace(/\\/g, '\\\\').replace(/\n/g, '\\n').replace(/"/g, '\\"');

function formatValue(v: number): string {
  if (Number.isNaN(v)) return 'NaN';
  if (v === Infinity) return '+Inf';
  if (v === -Infinity) return '-Inf';
  return String(v);
}

function formatLabels(labels: Labels | undefined): string {
  const entries = Object.entries(labels ?? {});
  if (entries.length === 0) return '';
  return `{${entries.map(([k, v]) => `${k}="${escapeLabel(v)}"`).join(',')}}`;
}

/** The exposition text for `families`; families with no samples are left out. */
export function formatMetrics(families: MetricFamily[]): string {
  const lines: string[] = [];
  for (const f of families) {
    if (f.samples.length === 0) continue;
    lines.push(`# HELP ${f.name} ${escapeHelp(f.help)}`, `# TYPE ${f.name} ${f.type}`);
    for (const s of f.samples) lines.push(`${f.name}${formatLabels(s.labels)} ${formatValue(s.value)}`);
  }
  return lines.join('\n') + '\n';
}

/** A counter per label set. */
export class Counter {
  private readonly values = new Map<string, { labels: Labels; value: number }>();

  constructor(
    readonly name: string,
    readonly help: string,
  ) {}

  inc(labels: Labels = {}, by = 1): void {
    const key = JSON.stringify(Object.entries(labels).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
    const entry = this.values.get(key);
    if (entry) entry.value += by;
    else this.values.set(key, { labels, value: by });
  }

  family(): MetricFamily {
    return { name: this.name, help: this.help, type: 'counter', samples: [...this.values.values()] };
  }
}

/** What the relay reads at each scrape. */
export interface RelayState {
  health(): HealthReport;
  targets(): readonly Target[];
  /** Connected clients by path. */
  clients(): Record<string, number>;
  /** True while the public listener is open. Absent: it never is. */
  publicListenerUp?(): boolean;
  /** The vessel census, when there is one. */
  census?: { size: number; writeFailures: number };
}

/** Everything /metrics reports: the relay's health and traffic, and the Node process. */
export class RelayMetrics {
  readonly connections = new Counter('relay_client_connections_total', 'WebSocket clients accepted, by path.');
  readonly messages = new Counter(
    'relay_client_messages_total',
    'Messages sent to WebSocket clients, by path; a snapshot counts as one.',
  );
  readonly rejections = new Counter(
    'relay_client_rejections_total',
    'WebSocket upgrades refused, by listener (main, public) and reason: unauthorized (no or wrong token), capacity (too many clients), per_ip_limit (public only).',
  );
  readonly drops = new Counter(
    'relay_clients_dropped_total',
    'Clients disconnected for not keeping up (their unsent data passed its limit, or the total budget), by path.',
  );
  private readonly updates = new Counter('relay_target_updates_total', 'Target updates the sources published.');
  private readonly removals = new Counter('relay_target_removals_total', 'Targets removed (expired or dropped by their source).');
  private readonly loop: IntervalHistogram = monitorEventLoopDelay({ resolution: LOOP_RESOLUTION_MS });

  constructor(private readonly state: RelayState) {
    this.loop.enable();
  }

  /** Counts a hub event (subscribe this to the hub). */
  observe(event: HubEvent): void {
    if (event.type === 'update') this.updates.inc({ source: event.target.source, kind: event.target.kind });
    else this.removals.inc({ kind: event.id.slice(0, Math.max(0, event.id.indexOf(':'))) || 'unknown' });
  }

  render(): string {
    const health = this.state.health();
    const sources = Object.entries(health.sources);
    const byTarget = new Map<string, { labels: Labels; value: number }>();
    for (const t of this.state.targets()) {
      const key = `${t.source}\0${t.kind}`;
      const entry = byTarget.get(key) ?? { labels: { source: t.source, kind: t.kind }, value: 0 };
      entry.value++;
      byTarget.set(key, entry);
    }
    const census = this.state.census;
    const memory = process.memoryUsage();
    const cpu = process.cpuUsage();
    // Event loop delay since the last scrape, then start a fresh window.
    const delay = (ns: number) => Math.max(0, ns / 1e9 - LOOP_RESOLUTION_MS / 1000);
    const loop = { p50: delay(this.loop.percentile(50)), p99: delay(this.loop.percentile(99)), max: delay(this.loop.max) };
    this.loop.reset();

    return formatMetrics([
      { name: 'relay_up', help: '1 when /healthz is ok.', type: 'gauge', samples: [{ value: health.ok ? 1 : 0 }] },
      {
        name: 'relay_source_up',
        help: "1 while the source is ok (not stuck in a way a restart fixes).",
        type: 'gauge',
        samples: sources.map(([source, h]) => ({ labels: { source }, value: h.ok ? 1 : 0 })),
      },
      {
        name: 'relay_source_connected',
        help: 'Streaming sources: 1 while the upstream socket is open.',
        type: 'gauge',
        samples: sources.flatMap(([source, h]) =>
          h.connected === undefined ? [] : [{ labels: { source }, value: h.connected ? 1 : 0 }],
        ),
      },
      {
        name: 'relay_source_data_age_seconds',
        help: "Seconds since the source's newest data; absent before its first.",
        type: 'gauge',
        samples: sources.flatMap(([source, h]) =>
          h.lastDataAgeSeconds === undefined ? [] : [{ labels: { source }, value: h.lastDataAgeSeconds }],
        ),
      },
      { name: 'relay_targets', help: 'Current targets, by source and kind.', type: 'gauge', samples: [...byTarget.values()] },
      {
        name: 'relay_clients',
        help: 'Connected WebSocket clients, by path.',
        type: 'gauge',
        samples: Object.entries(this.state.clients()).map(([path, value]) => ({ labels: { path }, value })),
      },
      {
        name: 'relay_public_listener_up',
        help: '1 while the public listener (PUBLIC_PORT) is open; 0 when it is off or refused to start.',
        type: 'gauge',
        samples: [{ value: this.state.publicListenerUp?.() ? 1 : 0 }],
      },
      {
        name: 'relay_census_vessels',
        help: 'Vessels held in the census (no per-vessel series).',
        type: 'gauge',
        samples: census ? [{ value: census.size }] : [],
      },
      {
        name: 'relay_census_write_failures_total',
        help: 'Census file writes that failed.',
        type: 'counter',
        samples: census ? [{ value: census.writeFailures }] : [],
      },
      this.connections.family(),
      this.messages.family(),
      this.rejections.family(),
      this.drops.family(),
      this.updates.family(),
      this.removals.family(),
      {
        name: 'process_resident_memory_bytes',
        help: 'Resident memory size in bytes.',
        type: 'gauge',
        samples: [{ value: memory.rss }],
      },
      { name: 'nodejs_heap_used_bytes', help: 'V8 heap in use, bytes.', type: 'gauge', samples: [{ value: memory.heapUsed }] },
      {
        name: 'process_cpu_seconds_total',
        help: 'User and system CPU time spent, seconds.',
        type: 'counter',
        samples: [{ value: (cpu.user + cpu.system) / 1e6 }],
      },
      {
        name: 'nodejs_eventloop_delay_seconds',
        help: 'Event loop delay since the previous scrape, by quantile ("max" for the largest).',
        type: 'gauge',
        samples: [
          { labels: { quantile: '0.5' }, value: loop.p50 },
          { labels: { quantile: '0.99' }, value: loop.p99 },
          { labels: { quantile: 'max' }, value: loop.max },
        ],
      },
    ]);
  }

  /** Stops the event loop monitor. */
  close(): void {
    this.loop.disable();
  }
}
