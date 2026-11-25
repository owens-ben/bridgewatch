import { afterEach, describe, expect, test } from '@jest/globals';
import { TargetHub } from '../hub';
import { Counter } from '../metrics';
import { Registry } from '../registry';
import { createRelayServer, type RelayServer } from '../server';
import { checkEdge, HIDDEN } from './check-edge';

const TOKEN = 'a-long-enough-app-token';
const CHECKS = HIDDEN.length + 6;

let server: RelayServer | undefined;
afterEach(async () => {
  await server?.close();
  server = undefined;
});

/** A relay with a token; resolves with the base URL of its public listener, or of its main one with `main`. */
async function start(opts: { main?: boolean; tokens?: string[] } = {}): Promise<string> {
  server = createRelayServer({
    registry: new Registry(),
    hub: new TargetHub(),
    tokens: opts.tokens ?? [TOKEN],
    health: () => ({ ok: true }),
    metrics: {
      render: () => 'relay_up 1\n',
      connections: new Counter('c', 'c'),
      messages: new Counter('m', 'm'),
      rejections: new Counter('r', 'r'),
      drops: new Counter('d', 'd'),
    },
  });
  const main = await server.listen(0, '127.0.0.1');
  const port = opts.main ? main : await server.listenPublic(0, '127.0.0.1');
  return `http://127.0.0.1:${port}`;
}

describe('checkEdge', () => {
  test('the public listener passes every check, on both paths', async () => {
    const base = await start();
    const checks = await checkEdge(base, TOKEN);
    expect(checks.filter((c) => !c.ok)).toEqual([]);
    expect(checks).toHaveLength(CHECKS);
    expect(checks.map((c) => c.name)).toEqual(
      expect.arrayContaining([
        'GET //metrics is not reachable from outside',
        'GET /metrics?x is not reachable from outside',
        'POST /metrics is not reachable from outside',
        '/v1/vessels: a client without the token is refused',
        '/v1/vessels: a client with the token gets the snapshot',
      ]),
    );
    expect(checks.find((c) => c.name === '/v2/targets: a client with the token gets the snapshot')?.detail).toBe('0 targets');
    expect(checks.find((c) => c.name === '/v1/vessels: a client with the token gets the snapshot')?.detail).toBe('0 vessels');
  });

  test('a trailing slash on the address is fine', async () => {
    const base = await start();
    expect((await checkEdge(`${base}/`, TOKEN)).every((c) => c.ok)).toBe(true);
  });

  test('the tunnel pointed at the main listener: the forwarded header still hides /healthz and asks the token', async () => {
    const base = await start({ main: true });
    // Belt and braces (PROTOCOL.md, "Access"): a misrouted tunnel still fails closed.
    const failed = (await checkEdge(base, TOKEN, { 'CF-Connecting-IP': '203.0.113.5' })).filter((c) => !c.ok);
    expect(failed).toEqual([]);
  });

  test('the main listener reached without any proxy header is open, and the check says so', async () => {
    const base = await start({ main: true });
    const failed = (await checkEdge(base, TOKEN)).filter((c) => !c.ok).map((c) => c.name);
    expect(failed).toEqual(
      expect.arrayContaining([
        'GET /healthz is not reachable from outside',
        'GET /metrics is not reachable from outside',
        '/v2/targets: a client without the token is refused',
        '/v1/vessels: a client with a wrong token is refused',
      ]),
    );
  });

  test('the wrong token fails the two snapshot checks; an address that does not answer fails them all without throwing', async () => {
    const base = await start();
    const wrong = await checkEdge(base, 'this-is-not-the-token');
    expect(wrong.filter((c) => !c.ok).map((c) => c.name)).toEqual([
      '/v2/targets: a client with the token gets the snapshot',
      '/v1/vessels: a client with the token gets the snapshot',
    ]);
    const dead = await checkEdge('http://127.0.0.1:1', TOKEN);
    expect(dead).toHaveLength(CHECKS);
    expect(dead.every((c) => !c.ok)).toBe(true);
  });
});
