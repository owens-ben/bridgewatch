/**
 * Checks the public edge from outside, end to end: TLS, the tunnel, the app token and what must stay private. Run it
 * from any machine other than the relay host, after setting up the tunnel and after changing the token:
 *
 *   APP_TOKEN=<token> npm run check-edge -- https://relay.example.com
 *
 * The token comes only from the APP_TOKEN environment variable (never an argument, so it stays out of the shell
 * history and the process list) and is never printed. It only connects the way the app does (a WebSocket on each
 * path, a few plain requests); it never changes anything. Exits 1 if any check fails. See deploy/README.md,
 * "Public edge".
 */
import { WebSocket } from 'ws';

export interface Check {
  name: string;
  ok: boolean;
  detail: string;
}

const TIMEOUT_MS = 10_000;

/** What a WebSocket connect to `url` came to: the HTTP status of a refusal, or 101 and the first message. */
function probe(url: string, headers: Record<string, string>): Promise<{ status: number; first?: unknown }> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { headers, handshakeTimeout: TIMEOUT_MS });
    const timer = setTimeout(() => {
      ws.terminate();
      reject(new Error(`no snapshot within ${TIMEOUT_MS / 1000} s`));
    }, TIMEOUT_MS);
    const finish = (value: { status: number; first?: unknown }) => {
      clearTimeout(timer);
      ws.terminate();
      resolve(value);
    };
    ws.once('message', (data) => {
      try {
        finish({ status: 101, first: JSON.parse(data.toString()) });
      } catch {
        finish({ status: 101 });
      }
    });
    ws.once('unexpected-response', (_req, res) => {
      res.resume();
      finish({ status: res.statusCode ?? 0 });
    });
    ws.once('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

async function statusOf(url: string, method: string, headers: Record<string, string>): Promise<number> {
  const res = await fetch(url, { method, headers, signal: AbortSignal.timeout(TIMEOUT_MS) });
  await res.body?.cancel();
  return res.status;
}

/** Plain requests that must all get a 404 from outside: the operator's endpoints, spelled a few ways, other methods. */
export const HIDDEN: readonly { method: string; path: string }[] = [
  { method: 'GET', path: '/healthz' },
  { method: 'GET', path: '/metrics' },
  { method: 'GET', path: '//metrics' },
  { method: 'GET', path: '/metrics?x' },
  { method: 'HEAD', path: '/healthz' },
  { method: 'POST', path: '/metrics' },
  { method: 'POST', path: '/v2/targets' },
  { method: 'GET', path: '/' },
];

/** The WebSocket paths, with the key their snapshot lists its objects under. */
const STREAMS = [
  { path: '/v2/targets', key: 'targets' },
  { path: '/v1/vessels', key: 'vessels' },
] as const;

/**
 * Runs every check against the relay at `base` (an http(s) URL, no path). `headers` go on every request; the tests use
 * them to stand in for the tunnel. The token is only ever sent in the Authorization header.
 */
export async function checkEdge(base: string, token: string, headers: Record<string, string> = {}): Promise<Check[]> {
  const root = base.replace(/\/+$/, '');
  const wsRoot = root.replace(/^http/, 'ws');
  const checks: Check[] = [];
  const run = async (name: string, fn: () => Promise<{ ok: boolean; detail: string }>) => {
    try {
      checks.push({ name, ...(await fn()) });
    } catch (err) {
      checks.push({ name, ok: false, detail: err instanceof Error ? err.message : String(err) });
    }
  };

  for (const { method, path } of HIDDEN) {
    await run(`${method} ${path} is not reachable from outside`, async () => {
      const status = await statusOf(`${root}${path}`, method, headers);
      return { ok: status === 404, detail: `HTTP ${status}, expected 404` };
    });
  }
  for (const { path, key } of STREAMS) {
    const url = `${wsRoot}${path}`;
    await run(`${path}: a client without the token is refused`, async () => {
      const { status } = await probe(url, headers);
      return { ok: status === 401, detail: `HTTP ${status}, expected 401` };
    });
    await run(`${path}: a client with a wrong token is refused`, async () => {
      const { status } = await probe(url, { ...headers, Authorization: 'Bearer not-the-token-not-the-token' });
      return { ok: status === 401, detail: `HTTP ${status}, expected 401` };
    });
    await run(`${path}: a client with the token gets the snapshot`, async () => {
      const { status, first } = await probe(url, { ...headers, Authorization: `Bearer ${token}` });
      if (status !== 101) return { ok: false, detail: `HTTP ${status}, expected the connection to open` };
      const snapshot = first as Record<string, unknown> | undefined;
      const items = snapshot?.[key];
      if (snapshot?.type !== 'snapshot' || !Array.isArray(items)) {
        return { ok: false, detail: 'connected, but the first message is not a snapshot' };
      }
      return { ok: true, detail: `${items.length} ${key}` };
    });
  }
  return checks;
}

async function main(): Promise<void> {
  const base = process.argv[2];
  const token = process.env.APP_TOKEN?.trim();
  if (!base || !/^https?:\/\//.test(base) || !token || process.argv.length > 3) {
    console.error('usage: APP_TOKEN=<token> npm run check-edge -- https://relay.example.com');
    process.exit(2);
  }
  const checks = await checkEdge(base, token);
  for (const c of checks) console.log(`${c.ok ? 'ok  ' : 'FAIL'} ${c.name} (${c.detail})`);
  const failed = checks.filter((c) => !c.ok).length;
  console.log(failed === 0 ? `all ${checks.length} checks passed` : `${failed} of ${checks.length} checks failed`);
  process.exit(failed === 0 ? 0 : 1);
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
