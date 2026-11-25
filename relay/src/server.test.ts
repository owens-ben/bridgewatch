import http from 'node:http';
import net from 'node:net';
import { afterEach, beforeEach, describe, expect, test } from '@jest/globals';
import WebSocket from 'ws';
import { FORWARDING_HEADERS } from './access';
import { Census } from './census';
import { TargetHub } from './hub';
import { Counter, RelayMetrics } from './metrics';
import { Registry } from './registry';
import { createRelayServer, type RelayServer } from './server';
import type { Target } from './targets';
import type { VesselUpdate } from './types';

const NOW = Date.parse('2026-11-10T14:12:00.000Z');
const vessel = (mmsi: number, ts = '2026-11-10T14:11:00.000Z'): VesselUpdate => ({
  mmsi,
  name: 'BOAT',
  lat: 40.7,
  lon: -73.99,
  timestamp: ts,
});

let server: RelayServer;
let port: number;
let registry: Registry;
let hub: TargetHub;

beforeEach(async () => {
  registry = new Registry();
  hub = new TargetHub(() => NOW);
  server = createRelayServer({ registry, hub, now: () => NOW });
  port = await server.listen(0, '127.0.0.1');
});
afterEach(async () => {
  await server.close();
});

/** Opens a client on `path` and collects its messages; `received(n)` resolves once n have arrived. */
function connect(path: string): { ws: WebSocket; messages: any[]; received: (n: number) => Promise<void> } {
  const ws = new WebSocket(`ws://127.0.0.1:${port}${path}`);
  const messages: any[] = [];
  ws.on('message', (d) => messages.push(JSON.parse(d.toString())));
  const received = (n: number) =>
    new Promise<void>((resolve, reject) => {
      const check = () => messages.length >= n && resolve();
      ws.on('message', check);
      ws.on('error', reject);
      check();
    });
  return { ws, messages, received };
}

const target = (id: string): Target => ({
  id,
  kind: 'vessel',
  source: 'aisstream',
  lat: 40.7,
  lon: -73.99,
  timestamp: '2026-11-10T14:11:00.000Z',
  vessel: { mmsi: 1 },
});

function get(path: string): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    http
      .get({ host: '127.0.0.1', port, path }, (res) => {
        let body = '';
        res.on('data', (c) => (body += c));
        res.on('end', () => resolve({ status: res.statusCode ?? 0, body }));
      })
      .on('error', reject);
  });
}

describe('relay server', () => {
  test('sends snapshot first, then live updates', async () => {
    registry.apply(vessel(2));
    registry.apply(vessel(1));
    registry.apply(vessel(3, '2026-11-10T13:00:00.000Z')); // expired
    const ws = new WebSocket(`ws://127.0.0.1:${port}/v1/vessels`);
    const messages: any[] = [];
    const received = (n: number) =>
      new Promise<void>((resolve, reject) => {
        const check = () => messages.length >= n && resolve();
        ws.on('message', check);
        ws.on('error', reject);
        check();
      });
    ws.on('message', (d) => messages.push(JSON.parse(d.toString())));
    await received(1);
    expect(messages[0].type).toBe('snapshot');
    expect(messages[0].vessels.map((v: VesselUpdate) => v.mmsi)).toEqual([1, 2]);

    const update = vessel(9, '2026-11-10T14:11:30.000Z');
    server.broadcast(update);
    await received(2);
    expect(messages[1]).toEqual({ type: 'update', vessel: update });
    expect(Object.keys(messages[1].vessel)).toEqual(['mmsi', 'name', 'lat', 'lon', 'timestamp']);
    expect(messages).toHaveLength(2);
    ws.close();
  });

  test('empty registry gives an empty snapshot', async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/v1/vessels`);
    const msg = await new Promise<any>((resolve, reject) => {
      ws.once('message', (d) => resolve(JSON.parse(d.toString())));
      ws.once('error', reject);
    });
    expect(msg).toEqual({ type: 'snapshot', vessels: [] });
    ws.close();
  });

  test('/v2/targets: snapshot of the hub on connect, then its updates and removals', async () => {
    hub.sink('aisstream').upsert(target('vessel:2'));
    hub.sink('aisstream').upsert(target('vessel:1'));
    const { ws, messages, received } = connect('/v2/targets');
    await received(1);
    expect(messages[0]).toEqual({ type: 'snapshot', targets: [target('vessel:1'), target('vessel:2')] });

    hub.sink('aisstream').upsert(target('vessel:3'));
    hub.sink('aisstream').remove('vessel:1');
    await received(3);
    expect(messages.slice(1)).toEqual([
      { type: 'update', target: target('vessel:3') },
      { type: 'remove', id: 'vessel:1' },
    ]);
    ws.close();
  });

  test('each endpoint gets only its own messages', async () => {
    const v1 = connect('/v1/vessels');
    const v2 = connect('/v2/targets');
    await Promise.all([v1.received(1), v2.received(1)]);
    expect(server.clientCount()).toBe(2);
    server.broadcast(vessel(9));
    hub.sink('aisstream').upsert(target('vessel:9'));
    // A second message on each proves the first one didn't cross over.
    server.broadcast(vessel(10));
    hub.sink('aisstream').upsert(target('vessel:10'));
    await Promise.all([v1.received(3), v2.received(3)]);
    expect(v1.messages.map((m) => m.type)).toEqual(['snapshot', 'update', 'update']);
    expect(v1.messages.slice(1).map((m) => m.vessel.mmsi)).toEqual([9, 10]);
    expect(v2.messages.slice(1).map((m) => m.target.id)).toEqual(['vessel:9', 'vessel:10']);
    v1.ws.close();
    v2.ws.close();
  });

  test('/healthz returns 200 ok; unknown HTTP paths 404', async () => {
    expect(await get('/healthz')).toEqual({ status: 200, body: 'ok' });
    expect((await get('/nope')).status).toBe(404);
    expect((await get('/v1/vessels')).status).toBe(404); // plain GET without upgrade
    expect((await get('/v2/targets')).status).toBe(404);
  });

  test('/healthz with a health check: JSON report, 503 when not ok', async () => {
    let ok = true;
    const checked = createRelayServer({ registry, hub, health: () => ({ ok, vessels: 2 }) });
    const checkedPort = await checked.listen(0, '127.0.0.1');
    try {
      const fetchHealth = () => fetch(`http://127.0.0.1:${checkedPort}/healthz`);
      let res = await fetchHealth();
      expect(res.status).toBe(200);
      expect(res.headers.get('content-type')).toBe('application/json');
      expect(await res.json()).toEqual({ ok: true, vessels: 2 });
      ok = false;
      res = await fetchHealth();
      expect(res.status).toBe(503);
      expect(await res.json()).toEqual({ ok: false, vessels: 2 });
    } finally {
      await checked.close();
    }
  });

  test('/metrics: 404 without metrics; with them, the rendered text and client traffic counted', async () => {
    expect((await get('/metrics')).status).toBe(404);
    const metrics = new RelayMetrics({
      health: () => ({ ok: true, sources: {}, targets: 0, clients: 0 }),
      targets: () => [],
      clients: () => measured.clientCounts(),
    });
    const measured = createRelayServer({ registry, hub, metrics });
    const measuredPort = await measured.listen(0, '127.0.0.1');
    try {
      const ws = new WebSocket(`ws://127.0.0.1:${measuredPort}/v1/vessels`);
      await new Promise((resolve, reject) => {
        ws.once('message', resolve);
        ws.once('error', reject);
      });
      measured.broadcast(vessel(9, '2026-11-10T14:11:30.000Z'));
      await new Promise((resolve) => ws.once('message', resolve));
      const res = await fetch(`http://127.0.0.1:${measuredPort}/metrics`);
      expect(res.status).toBe(200);
      expect(res.headers.get('content-type')).toBe('text/plain; version=0.0.4; charset=utf-8');
      const lines = (await res.text()).split('\n');
      expect(lines).toContain('relay_clients{path="/v1/vessels"} 1');
      expect(lines).toContain('relay_client_connections_total{path="/v1/vessels"} 1');
      expect(lines).toContain('relay_client_messages_total{path="/v1/vessels"} 2'); // snapshot + update
      ws.close();
    } finally {
      await measured.close();
      metrics.close();
    }
  });

  test('websocket upgrade on any other path is rejected', async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/other`);
    const err = await new Promise<Error>((resolve) => ws.once('error', resolve));
    expect(err.message).toContain('404');
  });

  describe('access', () => {
    const TOKEN = 'a-long-enough-app-token';
    const BEARER = { Authorization: `Bearer ${TOKEN}` };

    /** The counters and /metrics text the server needs, without the process monitors RelayMetrics starts. */
    const stubMetrics = () => ({
      render: () => 'relay_up 1\n',
      connections: new Counter('c', 'c'),
      messages: new Counter('m', 'm'),
      rejections: new Counter('r', 'r'),
      drops: new Counter('d', 'd'),
    });
    const count = (c: Counter, labels: Record<string, string>) =>
      c.family().samples.find((s) => JSON.stringify(s.labels) === JSON.stringify(labels))?.value ?? 0;

    let publicPort = 0;
    /** Replaces the server; with `withPublic` it opens the public listener too. */
    async function restart(over: Partial<Parameters<typeof createRelayServer>[0]>, withPublic = false) {
      await server.close();
      server = createRelayServer({ registry, hub, now: () => NOW, ...over });
      port = await server.listen(0, '127.0.0.1');
      if (withPublic) publicPort = await server.listenPublic(0, '127.0.0.1');
    }

    interface Opened {
      status: number;
      ws: WebSocket;
      messages: any[];
      headers: http.IncomingHttpHeaders;
    }
    /**
     * Opens a client on `path` of `on` (default the main port); resolves with the HTTP status if the upgrade was
     * refused, or 101 once it opened. `messages` collects from the start: the snapshot can come right behind the
     * handshake.
     */
    function open(path: string, headers: Record<string, string> = {}, on = port): Promise<Opened> {
      const ws = new WebSocket(`ws://127.0.0.1:${on}${path}`, { headers });
      const messages: any[] = [];
      ws.on('message', (d) => messages.push(JSON.parse(d.toString())));
      return new Promise((resolve, reject) => {
        ws.once('upgrade', (res) => resolve({ status: 101, ws, messages, headers: res.headers }));
        ws.once('unexpected-response', (_req, res) => {
          res.resume();
          resolve({ status: res.statusCode ?? 0, ws, messages, headers: res.headers });
        });
        ws.once('error', reject);
      });
    }
    /** A plain HTTP request; `fetch` won't send some of these (a path starting `//`, HEAD bodies, OPTIONS). */
    function request(method: string, path: string, headers: Record<string, string> = {}, on = port): Promise<number> {
      return new Promise((resolve, reject) => {
        http
          .request({ host: '127.0.0.1', port: on, method, path, headers }, (res) => {
            res.resume();
            res.on('end', () => resolve(res.statusCode ?? 0));
          })
          .on('error', reject)
          .end();
      });
    }
    const waitFor = async (done: () => boolean) => {
      for (let i = 0; i < 300 && !done(); i++) await new Promise((r) => setTimeout(r, 10));
      expect(done()).toBe(true);
    };
    const closeAll = (...clients: Opened[]) => clients.forEach((c) => c.ws.terminate());

    test('a snapshot over the warning size is logged, at most once a minute per path', async () => {
      const lines: string[] = [];
      let t = NOW;
      hub.sink('aisstream').replaceAll([target('vessel:1'), target('vessel:2')]);
      await restart({ log: (m) => lines.push(m), snapshotWarnBytes: 100, now: () => t });
      const warnings = () => lines.filter((l) => l.includes('WARNING snapshot'));
      const first = await open('/v2/targets');
      await waitFor(() => first.messages.length === 1);
      expect(warnings()).toHaveLength(1);
      expect(warnings()[0]).toMatch(/snapshot on \/v2\/targets is \d+ bytes, over 100/);
      const second = await open('/v2/targets');
      await waitFor(() => second.messages.length === 1);
      expect(warnings()).toHaveLength(1);
      t += 60_000;
      const third = await open('/v2/targets');
      await waitFor(() => third.messages.length === 1);
      expect(warnings()).toHaveLength(2);
      closeAll(first, second, third);
    });

    test('a snapshot under the warning size logs no warning', async () => {
      const lines: string[] = [];
      await restart({ log: (m) => lines.push(m) });
      const client = await open('/v2/targets');
      await waitFor(() => client.messages.length === 1);
      expect(lines.some((l) => l.includes('WARNING'))).toBe(false);
      closeAll(client);
    });

    test('defaults (prod today): no token asked, /healthz and /metrics served, no per-address cap, no public listener', async () => {
      const metrics = stubMetrics();
      await restart({ metrics });
      expect(await request('GET', '/healthz')).toBe(200);
      expect(await request('GET', '/metrics')).toBe(200);
      // Far more than the public per-address cap, all from 127.0.0.1, on both paths.
      const clients = await Promise.all(
        Array.from({ length: 24 }, (_, i) => open(i % 2 ? '/v1/vessels' : '/v2/targets')),
      );
      expect(clients.map((c) => c.status)).toEqual(new Array(24).fill(101));
      await waitFor(() => clients.every((c) => c.messages.length === 1));
      expect(clients.every((c) => c.messages[0].type === 'snapshot')).toBe(true);
      expect(metrics.rejections.family().samples).toEqual([]);
      expect(server.publicListening()).toBe(false);
      await expect(server.listenPublic(0, '127.0.0.1')).rejects.toThrow('needs at least one app token');
      expect(server.publicListening()).toBe(false);
      closeAll(...clients);
    });

    test('a token configured changes nothing for direct clients on the main listener', async () => {
      await restart({ tokens: [TOKEN] }, true);
      const v1 = await open('/v1/vessels');
      const v2 = await open('/v2/targets');
      expect([v1.status, v2.status]).toEqual([101, 101]);
      expect(await request('GET', '/healthz')).toBe(200);
      closeAll(v1, v2);
    });

    describe('public listener', () => {
      test('both paths: no token or a wrong one gets 401 with WWW-Authenticate; the token gets the snapshot', async () => {
        const metrics = stubMetrics();
        await restart({ tokens: [TOKEN], metrics }, true);
        expect(server.publicListening()).toBe(true);
        for (const [path, key] of [
          ['/v1/vessels', 'vessels'],
          ['/v2/targets', 'targets'],
        ] as const) {
          const none = await open(path, {}, publicPort);
          expect(none.status).toBe(401);
          expect(none.headers['www-authenticate']).toBe('Bearer');
          expect((await open(path, { Authorization: 'Bearer wrong-token-wrong-token' }, publicPort)).status).toBe(401);
          const ok = await open(path, BEARER, publicPort);
          expect(ok.status).toBe(101);
          await waitFor(() => ok.messages.length > 0);
          expect(ok.messages[0]).toEqual({ type: 'snapshot', [key]: [] });
          ok.ws.close();
        }
        expect(count(metrics.rejections, { listener: 'public', reason: 'unauthorized' })).toBe(4);
      });

      test('every plain request is a 404, whatever the method or spelling, and so is an upgrade anywhere else', async () => {
        await restart({ tokens: [TOKEN], metrics: stubMetrics(), health: () => ({ ok: true }) }, true);
        for (const path of ['/healthz', '/metrics', '//metrics', '/metrics?x', '/v2/targets', '/v1/vessels', '/']) {
          for (const method of ['GET', 'HEAD', 'POST', 'OPTIONS']) {
            expect([method, path, await request(method, path, BEARER, publicPort)]).toEqual([method, path, 404]);
          }
        }
        expect((await open('/metrics', BEARER, publicPort)).status).toBe(404);
        expect((await open('/healthz', BEARER, publicPort)).status).toBe(404);
      });

      test('per address: 429 with Retry-After, keyed by CF-Connecting-IP, IPv6 by its /64; a release frees the slot', async () => {
        const metrics = stubMetrics();
        await restart({ tokens: [TOKEN], metrics, publicLimits: { maxClients: 50, maxClientsPerIp: 1 } }, true);
        const via = (ip: string) => ({ ...BEARER, 'CF-Connecting-IP': ip });
        const a = await open('/v2/targets', via('198.51.100.1'), publicPort);
        expect(a.status).toBe(101);
        const again = await open('/v1/vessels', via('198.51.100.1'), publicPort); // both paths count together
        expect(again.status).toBe(429);
        expect(again.headers['retry-after']).toBe('30');
        const b = await open('/v2/targets', via('198.51.100.2'), publicPort);
        expect(b.status).toBe(101);

        const v6 = await open('/v2/targets', via('2001:db8:1:2::1'), publicPort);
        expect(v6.status).toBe(101);
        expect((await open('/v2/targets', via('2001:db8:1:2:ffff::9'), publicPort)).status).toBe(429); // same /64
        const other64 = await open('/v2/targets', via('2001:db8:1:3::1'), publicPort);
        expect(other64.status).toBe(101);

        // Without a valid header the socket address (127.0.0.1) is the key.
        const bad = await open('/v2/targets', via('not-an-ip'), publicPort);
        expect(bad.status).toBe(101);
        expect((await open('/v2/targets', BEARER, publicPort)).status).toBe(429);
        expect(count(metrics.rejections, { listener: 'public', reason: 'per_ip_limit' })).toBe(3);

        a.ws.close();
        await waitFor(() => server.clientCount() === 4);
        const back = await open('/v2/targets', via('198.51.100.1'), publicPort);
        expect(back.status).toBe(101);
        closeAll(back, b, v6, other64, bad);
      });

      test('in all: past its cap the next client gets 503 with Retry-After; the main listener has its own cap', async () => {
        const metrics = stubMetrics();
        await restart({ tokens: [TOKEN], metrics, maxClients: 1, publicLimits: { maxClients: 1, maxClientsPerIp: 5 } }, true);
        const first = await open('/v2/targets', BEARER, publicPort);
        expect(first.status).toBe(101);
        const full = await open('/v2/targets', BEARER, publicPort);
        expect(full.status).toBe(503);
        expect(full.headers['retry-after']).toBe('10');
        expect(count(metrics.rejections, { listener: 'public', reason: 'capacity' })).toBe(1);

        const lan = await open('/v2/targets');
        expect(lan.status).toBe(101);
        const lanFull = await open('/v1/vessels');
        expect(lanFull.status).toBe(503);
        expect(lanFull.headers['retry-after']).toBe('10');
        closeAll(first, lan);
      });

      test('a failed WebSocket handshake frees its slot', async () => {
        await restart({ tokens: [TOKEN], publicLimits: { maxClients: 1, maxClientsPerIp: 1 } }, true);
        // Passes the token and the caps, then ws refuses it (no Sec-WebSocket-Key).
        const status = await new Promise<number>((resolve, reject) => {
          http
            .request({
              host: '127.0.0.1',
              port: publicPort,
              path: '/v2/targets',
              headers: { ...BEARER, Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13' },
            })
            .on('response', (res) => {
              res.resume();
              resolve(res.statusCode ?? 0);
            })
            .on('error', reject)
            .end();
        });
        expect(status).toBe(400);
        // The slot is freed when that socket closes, which can come a moment after the response.
        let ok = await open('/v2/targets', BEARER, publicPort);
        for (let i = 0; i < 50 && ok.status !== 101; i++) {
          await new Promise((r) => setTimeout(r, 10));
          ok = await open('/v2/targets', BEARER, publicPort);
        }
        expect(ok.status).toBe(101);
        closeAll(ok);
      });
    });

    test('a client that resets the connection while its upgrade is refused does not take the relay down', async () => {
      await restart({ tokens: [TOKEN] }, true);
      // The raw socket of a refused upgrade has no error handler of its own: an RST used to be an unhandled 'error'
      // and exited the process (found by the adversarial run; also true of the relay before the edge work).
      const abort = (on: number, path: string) =>
        new Promise<void>((resolve) => {
          const socket = net.connect(on, '127.0.0.1', () => {
            socket.write(`GET ${path} HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n`);
            // Give the server a moment to start refusing, then reset.
            setTimeout(() => {
              socket.resetAndDestroy();
              resolve();
            }, 2);
          });
          socket.on('error', () => {});
        });
      for (let i = 0; i < 25; i++) {
        await abort(publicPort, '/v2/targets'); // refused: 401
        await abort(publicPort, '/nope'); // refused: 404
        await abort(port, '/nope'); // main listener, refused: 404
        await abort(port, '/v2/targets?x'); // allowed on main: upgrade fails for the missing key
      }
      await new Promise((r) => setTimeout(r, 100));
      expect(await request('GET', '/healthz')).toBe(200);
      const ok = await open('/v2/targets', BEARER, publicPort);
      expect(ok.status).toBe(101);
      closeAll(ok);
    });

    describe('main listener, a request a proxy forwarded', () => {
      test('a spoofed or empty CF-Connecting-IP is treated as public: token required, no /healthz or /metrics', async () => {
        await restart({ tokens: [TOKEN], metrics: stubMetrics() });
        for (const ip of ['198.51.100.1', '']) {
          const header = { 'CF-Connecting-IP': ip };
          expect((await open('/v2/targets', header)).status).toBe(401);
          expect((await open('/v1/vessels', header)).status).toBe(401);
          const ok = await open('/v2/targets', { ...header, ...BEARER });
          expect(ok.status).toBe(101);
          ok.ws.close();
          expect(await request('GET', '/healthz', header)).toBe(404);
          expect(await request('GET', '/metrics', header)).toBe(404);
        }
      });

      test('any one forwarding header is enough', async () => {
        await restart({ tokens: [TOKEN], metrics: stubMetrics() });
        for (const h of FORWARDING_HEADERS) {
          expect([h, (await open('/v2/targets', { [h]: '198.51.100.1' })).status]).toEqual([h, 401]);
          expect([h, await request('GET', '/healthz', { [h]: 'x' })]).toEqual([h, 404]);
          expect([h, await request('GET', '/metrics', { [h]: 'x' })]).toEqual([h, 404]);
        }
      });

      test('with no token configured (prod today) it is always refused: fails closed', async () => {
        await restart({ metrics: stubMetrics() });
        expect((await open('/v2/targets', { 'X-Forwarded-For': '198.51.100.1' })).status).toBe(401);
        expect((await open('/v2/targets', { 'X-Forwarded-For': '198.51.100.1', ...BEARER })).status).toBe(401);
      });

      test('the main listener never applies a per-address cap, even to forwarded requests', async () => {
        await restart({ tokens: [TOKEN] });
        const header = { ...BEARER, 'CF-Connecting-IP': '198.51.100.1' };
        const clients = await Promise.all(Array.from({ length: 15 }, () => open('/v2/targets', header)));
        expect(clients.every((c) => c.status === 101)).toBe(true);
        closeAll(...clients);
      });
    });

    test('other methods and spellings on the main listener: only GET /healthz and /metrics answer', async () => {
      await restart({ metrics: stubMetrics(), health: () => ({ ok: true }) });
      for (const path of ['/healthz', '/metrics']) {
        expect(await request('GET', path)).toBe(200);
        for (const method of ['HEAD', 'POST', 'OPTIONS']) expect([method, path, await request(method, path)]).toEqual([method, path, 404]);
      }
      expect(await request('GET', '//metrics')).toBe(404);
      expect(await request('GET', '/metrics?x')).toBe(200); // as before: the query is ignored
      expect(await request('GET', '/metrics?x', { 'X-Real-IP': '198.51.100.1' })).toBe(404);
    });

    describe('slow clients', () => {
      /** Stops a client's socket from reading, as a phone that lost signal mid-stream would. */
      const pause = (c: Opened) => (c.ws as unknown as { _socket: { pause(): void } })._socket.pause();

      test('a client that stops reading is dropped, and one that keeps up is not', async () => {
        const metrics = stubMetrics();
        await restart({ maxBufferedBytes: 256 * 1024, metrics });
        const slow = await open('/v2/targets');
        const fast = await open('/v2/targets');
        pause(slow);
        await waitFor(() => server.clientCount() === 2);

        const sink = hub.sink('test');
        const big = { ...target('vessel:1'), name: 'x'.repeat(100 * 1024) };
        for (let i = 0; i < 400 && server.clientCount() > 1; i++) {
          sink.upsert(big);
          await new Promise((resolve) => setImmediate(resolve)); // lets the reading client drain, as in production
        }

        await waitFor(() => server.clientCount() === 1);
        expect(count(metrics.drops, { path: '/v2/targets' })).toBe(1);
        expect(fast.ws.readyState).toBe(WebSocket.OPEN);
        expect(fast.messages.length).toBeGreaterThan(3);
        closeAll(slow, fast);
      });

      test('several clients behind are all dropped in the same broadcast: the loop carries on past each', async () => {
        const metrics = stubMetrics();
        await restart({ maxBufferedBytes: 256 * 1024, metrics });
        const slow = [await open('/v2/targets'), await open('/v2/targets'), await open('/v2/targets')];
        const fast = await open('/v2/targets');
        slow.forEach(pause);
        await waitFor(() => server.clientCount() === 4);

        // One message far past the limit leaves every paused client behind, whatever its socket soaked up.
        const sink = hub.sink('test');
        sink.upsert({ ...target('vessel:1'), name: 'x'.repeat(4 * 1024 * 1024) });
        await waitFor(() => fast.messages.length === 2);
        expect(count(metrics.drops, { path: '/v2/targets' })).toBe(0);
        sink.upsert(target('vessel:2'));
        expect(count(metrics.drops, { path: '/v2/targets' })).toBe(3); // counted synchronously, in that one send
        await waitFor(() => fast.messages.length === 3);
        await waitFor(() => server.clientCount() === 1);
        closeAll(...slow, fast);
      });

      test('the total budget drops clients with a backlog before any one reaches its own limit', async () => {
        const metrics = stubMetrics();
        await restart({ maxBufferedBytes: 64 * 1024 * 1024, maxTotalBufferedBytes: 1024 * 1024, metrics });
        const slow = [await open('/v2/targets'), await open('/v2/targets')];
        const fast = await open('/v2/targets');
        slow.forEach(pause);
        await waitFor(() => server.clientCount() === 3);

        const sink = hub.sink('test');
        const big = { ...target('vessel:1'), name: 'x'.repeat(100 * 1024) };
        for (let i = 0; i < 400 && server.clientCount() > 1; i++) {
          sink.upsert(big);
          await new Promise((resolve) => setImmediate(resolve));
        }
        await waitFor(() => server.clientCount() === 1);
        expect(count(metrics.drops, { path: '/v2/targets' })).toBe(2);
        expect(fast.ws.readyState).toBe(WebSocket.OPEN);
        closeAll(...slow, fast);
      });

      test('a client whose snapshot leaves more than the limit unsent is dropped at connect', async () => {
        const metrics = stubMetrics();
        await restart({ maxBufferedBytes: 64 * 1024, metrics });
        const sink = hub.sink('test');
        // A snapshot far bigger than the socket takes at once (~8 MiB), so most of it stays in the relay's buffer.
        for (let i = 0; i < 80; i++) sink.upsert({ ...target(`vessel:${i}`), name: 'x'.repeat(100 * 1024) });
        const client = await open('/v2/targets');
        expect(client.status).toBe(101);
        await new Promise((resolve) => client.ws.once('close', resolve));
        expect(count(metrics.drops, { path: '/v2/targets' })).toBe(1);
        await waitFor(() => server.clientCount() === 0);
      });
    });
  });

  describe('/census', () => {
    const TOKEN = 'a-long-enough-app-token';
    let census: Census;
    let censusPort: number;
    let publicPort = 0;
    let own: RelayServer;

    beforeEach(async () => {
      census = new Census({ now: () => NOW });
      // Ranks: 30 (2 days) first, then 20 (1 day, 3 positions), 10 (1 day, 1 position).
      const position = (mmsi: number, ts = '2026-11-10T14:11:00.000Z'): VesselUpdate => ({ mmsi, lat: 40.7, lon: -73.99, timestamp: ts });
      census.observe(position(10));
      for (let i = 0; i < 3; i++) census.observe(position(20));
      census.observe(position(30, '2026-11-09T14:11:00.000Z'));
      census.observe(vessel(30)); // static: a name, no position
      own = createRelayServer({ registry, hub, now: () => NOW, census, tokens: [TOKEN] });
      censusPort = await own.listen(0, '127.0.0.1');
      publicPort = await own.listenPublic(0, '127.0.0.1');
    });
    afterEach(() => own.close());

    function fetchCensus(path: string, headers: Record<string, string> = {}, on = censusPort): Promise<{ status: number; type?: string; body: string }> {
      return new Promise((resolve, reject) => {
        http
          .get({ host: '127.0.0.1', port: on, path, headers }, (res) => {
            let body = '';
            res.on('data', (c) => (body += c));
            res.on('end', () => resolve({ status: res.statusCode ?? 0, type: res.headers['content-type'], body }));
          })
          .on('error', reject);
      });
    }

    test('on the main listener: JSON, sorted by days seen, positions, mmsi', async () => {
      const res = await fetchCensus('/census');
      expect(res.status).toBe(200);
      expect(res.type).toBe('application/json');
      const body = JSON.parse(res.body);
      expect(Object.keys(body)).toEqual(['version', 'generatedAt', 'vessels']);
      expect(body.version).toBe(1);
      expect(body.generatedAt).toBe(new Date(NOW).toISOString());
      expect(body.vessels.map((v: { mmsi: number }) => v.mmsi)).toEqual([30, 20, 10]);
      expect(body.vessels[0]).toMatchObject({ mmsi: 30, name: 'BOAT', daysSeen: 2, positions: 1 });
    });

    test('limit: honored, a bad one uses the default, other parameters ignored', async () => {
      const ids = async (query: string) => JSON.parse((await fetchCensus(`/census${query}`)).body).vessels.map((v: { mmsi: number }) => v.mmsi);
      expect(await ids('?limit=2')).toEqual([30, 20]);
      expect(await ids('?limit=1&x=y')).toEqual([30]);
      for (const bad of ['?limit=0', '?limit=-1', '?limit=abc', '?limit=', '?limit=1.5', '?limit=1e2', '?limit=99999999999999999999', '?foo=bar']) {
        expect([bad, await ids(bad)]).toEqual([bad, [30, 20, 10]]);
      }
    });

    test('a request with any forwarding header is 404', async () => {
      expect((await fetchCensus('/census')).status).toBe(200);
      for (const h of FORWARDING_HEADERS) {
        expect([h, (await fetchCensus('/census', { [h]: '198.51.100.1' })).status]).toEqual([h, 404]);
      }
      expect((await fetchCensus('/census', { Authorization: `Bearer ${TOKEN}`, 'CF-Connecting-IP': '198.51.100.1' })).status).toBe(404);
    });

    test('on the public listener it is 404, with or without the token', async () => {
      expect((await fetchCensus('/census', {}, publicPort)).status).toBe(404);
      expect((await fetchCensus('/census', { Authorization: `Bearer ${TOKEN}` }, publicPort)).status).toBe(404);
    });

    test('only GET, only that path', async () => {
      expect((await fetchCensus('/census/')).status).toBe(404);
      expect((await fetchCensus('/census.json')).status).toBe(404);
    });

    test('404 when no census is configured', async () => {
      expect((await get('/census')).status).toBe(404);
    });
  });
});
