import { describe, expect, test } from '@jest/globals';
import type { HealthReport } from './health';
import { Counter, formatMetrics, RelayMetrics } from './metrics';
import { makeTarget, type Target } from './targets';

describe('formatMetrics', () => {
  test('writes HELP, TYPE and samples; escapes; skips empty families', () => {
    const text = formatMetrics([
      { name: 'a', help: 'line\none \\ two', type: 'gauge', samples: [{ value: 1.5 }] },
      { name: 'b', help: 'labels', type: 'counter', samples: [{ labels: { path: 'x"y\\z\n', q: '1' }, value: NaN }] },
      { name: 'c', help: 'empty', type: 'gauge', samples: [] },
    ]);
    expect(text).toBe(
      [
        '# HELP a line\\none \\\\ two',
        '# TYPE a gauge',
        'a 1.5',
        '# HELP b labels',
        '# TYPE b counter',
        'b{path="x\\"y\\\\z\\n",q="1"} NaN',
        '',
      ].join('\n'),
    );
  });
});

describe('Counter', () => {
  test('one sample per label set, whatever the key order', () => {
    const c = new Counter('n_total', 'h');
    c.inc({ a: '1', b: '2' });
    c.inc({ b: '2', a: '1' }, 2);
    c.inc();
    expect(c.family().samples).toEqual([
      { labels: { a: '1', b: '2' }, value: 3 },
      { labels: {}, value: 1 },
    ]);
  });
});

describe('RelayMetrics', () => {
  const vessel = (id: number): Target =>
    makeTarget({ id: `vessel:${id}`, kind: 'vessel', source: 'aisstream', lat: 40.7, lon: -74, timestamp: '2026-11-12T00:00:00.000Z' });

  test('reports health, targets, clients, traffic and the process', () => {
    let health: HealthReport = {
      ok: true,
      sources: {
        aisstream: { ok: true, connected: true, lastDataAgeSeconds: 3 },
        'mta-subway': { ok: true },
      },
      targets: 2,
      clients: 1,
    };
    const metrics = new RelayMetrics({
      health: () => health,
      targets: () => [vessel(1), vessel(2)],
      clients: () => ({ '/v1/vessels': 0, '/v2/targets': 1 }),
      publicListenerUp: () => publicUp,
    });
    let publicUp = true;
    try {
      metrics.observe({ type: 'update', target: vessel(1) });
      metrics.observe({ type: 'remove', id: 'vessel:1' });
      metrics.connections.inc({ path: '/v2/targets' });
      metrics.messages.inc({ path: '/v2/targets' }, 4);
      metrics.rejections.inc({ listener: 'public', reason: 'unauthorized' }, 2);
      metrics.drops.inc({ path: '/v2/targets' });
      const text = metrics.render();
      for (const line of [
        'relay_up 1',
        'relay_source_up{source="aisstream"} 1',
        'relay_source_up{source="mta-subway"} 1',
        'relay_source_connected{source="aisstream"} 1',
        'relay_source_data_age_seconds{source="aisstream"} 3',
        'relay_targets{source="aisstream",kind="vessel"} 2',
        'relay_clients{path="/v1/vessels"} 0',
        'relay_clients{path="/v2/targets"} 1',
        'relay_client_connections_total{path="/v2/targets"} 1',
        'relay_client_messages_total{path="/v2/targets"} 4',
        'relay_public_listener_up 1',
        'relay_client_rejections_total{listener="public",reason="unauthorized"} 2',
        'relay_clients_dropped_total{path="/v2/targets"} 1',
        'relay_target_updates_total{source="aisstream",kind="vessel"} 1',
        'relay_target_removals_total{kind="vessel"} 1',
      ]) {
        expect(text.split('\n')).toContain(line);
      }
      // Sources without a socket or data yet report neither.
      expect(text).not.toContain('relay_source_connected{source="mta-subway"}');
      expect(text).not.toContain('relay_source_data_age_seconds{source="mta-subway"}');
      expect(text).toMatch(/^process_resident_memory_bytes \d+$/m);
      expect(text).toMatch(/^process_cpu_seconds_total [\d.]+$/m);
      expect(text).toMatch(/^nodejs_eventloop_delay_seconds\{quantile="0.99"\} /m);

      health = { ...health, ok: false, sources: { aisstream: { ok: false, connected: false } } };
      publicUp = false;
      const down = metrics.render();
      expect(down).toContain('relay_up 0\n');
      expect(down).toContain('relay_source_up{source="aisstream"} 0\n');
      expect(down).toContain('relay_source_connected{source="aisstream"} 0\n');
      expect(down).toContain('relay_public_listener_up 0\n');
    } finally {
      metrics.close();
    }
  });
  test('census: vessels held and write failures, only when there is a census', () => {
    const base = {
      health: (): HealthReport => ({ ok: true, sources: {}, targets: 0, clients: 0 }),
      targets: () => [],
      clients: () => ({}),
    };
    const census = { size: 7, writeFailures: 0 };
    const metrics = new RelayMetrics({ ...base, census });
    const without = new RelayMetrics(base);
    try {
      expect(metrics.render().split('\n')).toEqual(expect.arrayContaining(['relay_census_vessels 7', 'relay_census_write_failures_total 0']));
      census.size = 8;
      census.writeFailures = 2;
      const text = metrics.render();
      expect(text).toContain('relay_census_vessels 8\n');
      expect(text).toContain('relay_census_write_failures_total 2\n');
      expect(text).toContain('# TYPE relay_census_write_failures_total counter');
      expect(without.render()).not.toContain('relay_census');
    } finally {
      metrics.close();
      without.close();
    }
  });
});
