import { describe, expect, test } from '@jest/globals';
import { DEFAULT_MAX_CLIENTS } from './access';
import { BOUNDING_BOXES, ConfigError, inBoundingBoxes, loadAccessConfig, loadConfig } from './config';
import { SOURCE_PLUGINS } from './sources';
import type { SourcePlugin } from './sources/source';

const fake = (id: string, needs?: string): SourcePlugin => ({
  id,
  configure(env) {
    if (needs && !env[needs]) throw new ConfigError(`${needs} is required`);
    return () => ({ start() {}, stop() {} });
  },
});
const plugins = [fake('aisstream', 'AISSTREAM_API_KEY'), fake('mta-subway'), fake('planes')];

describe('loadConfig', () => {
  test('defaults: port 8080 on all interfaces, aisstream and the subway', () => {
    const c = loadConfig({ AISSTREAM_API_KEY: 'k' }, plugins);
    expect(c.port).toBe(8080);
    expect(c.host).toBe('0.0.0.0');
    expect(c.sources.map((s) => s.id)).toEqual(['aisstream', 'mta-subway']);
    const blank = loadConfig({ AISSTREAM_API_KEY: 'k', SOURCES: ' ' }, plugins);
    expect(blank.sources.map((s) => s.id)).toEqual(['aisstream', 'mta-subway']);
  });

  test('SOURCES picks the sources, in order, ignoring case, spaces and repeats', () => {
    const c = loadConfig({ SOURCES: ' Planes, mta-subway,,planes ' }, plugins);
    expect(c.sources.map((s) => s.id)).toEqual(['planes', 'mta-subway']);
  });

  test('a source\'s own settings are required only when it is on', () => {
    expect(() => loadConfig({}, plugins)).toThrow('AISSTREAM_API_KEY is required');
    expect(() => loadConfig({ SOURCES: 'mta-subway' }, plugins)).not.toThrow();
  });

  test('rejects unknown sources, an empty list and bad ports', () => {
    expect(() => loadConfig({ SOURCES: 'mta-subway,ferries' }, plugins)).toThrow(
      'unknown source "ferries" in SOURCES (known: aisstream, mta-subway, planes)',
    );
    expect(() => loadConfig({ SOURCES: ',' }, plugins)).toThrow('SOURCES names no source');
    expect(() => loadConfig({ SOURCES: 'mta-subway', PORT: '70000' }, plugins)).toThrow(ConfigError);
  });

  test('the real plug-ins: aisstream needs its key, the subway needs nothing', () => {
    expect(SOURCE_PLUGINS.map((p) => p.id)).toEqual(['aisstream', 'mta-subway']);
    expect(() => loadConfig({}, SOURCE_PLUGINS)).toThrow('AISSTREAM_API_KEY is required');
    expect(loadConfig({ SOURCES: 'mta-subway' }, SOURCE_PLUGINS).sources.map((s) => s.id)).toEqual(['mta-subway']);
  });
});

describe('loadAccessConfig', () => {
  const TOKEN = '0123456789abcdef';

  test('defaults (prod today: no PUBLIC_PORT, no APP_TOKEN): no tokens, main cap 200, no public listener, no errors', () => {
    expect(loadAccessConfig({}, 8080)).toEqual({ tokens: [], maxClients: 200, errors: [] });
    expect(loadConfig({ SOURCES: 'mta-subway' }, plugins).access).toEqual({ tokens: [], maxClients: 200, errors: [] });
  });

  test('PUBLIC_PORT with a token: the public listener with its default caps', () => {
    expect(loadAccessConfig({ PUBLIC_PORT: '8081', APP_TOKEN: TOKEN }, 8080)).toEqual({
      tokens: [TOKEN],
      maxClients: 200,
      public: { port: 8081, maxClients: 200, maxClientsPerIp: 10 },
      errors: [],
    });
    const c = loadAccessConfig(
      { PUBLIC_PORT: '8081', APP_TOKEN: TOKEN, MAX_CLIENTS: '50', PUBLIC_MAX_CLIENTS: '20', PUBLIC_MAX_CLIENTS_PER_IP: '3' },
      8080,
    );
    expect(c).toMatchObject({ maxClients: 50, public: { port: 8081, maxClients: 20, maxClientsPerIp: 3 } });
  });

  test('PUBLIC_PORT without a token: no public listener and an error, never a throw', () => {
    for (const APP_TOKEN of [undefined, '', ' , ']) {
      const c = loadAccessConfig({ PUBLIC_PORT: '8081', APP_TOKEN }, 8080);
      expect(c.public).toBeUndefined();
      expect(c.errors).toEqual(['public listener not started: PUBLIC_PORT is set but APP_TOKEN is not']);
    }
  });

  test('a short token: no tokens at all, no public listener, the same kind of error, never a throw', () => {
    expect(loadAccessConfig({ PUBLIC_PORT: '8081', APP_TOKEN: `${TOKEN},changeme` }, 8080)).toEqual({
      tokens: [],
      maxClients: 200,
      errors: ['public listener not started: each APP_TOKEN must be at least 16 characters'],
    });
    // Without PUBLIC_PORT it is still reported: forwarded requests on the main listener are then all refused.
    expect(loadAccessConfig({ APP_TOKEN: 'changeme' }, 8080)).toEqual({
      tokens: [],
      maxClients: 200,
      errors: ['each APP_TOKEN must be at least 16 characters'],
    });
  });

  test('a comma list with an empty entry is fine', () => {
    expect(loadAccessConfig({ PUBLIC_PORT: '8081', APP_TOKEN: `${TOKEN},,fedcba9876543210,` }, 8080)).toMatchObject({
      tokens: [TOKEN, 'fedcba9876543210'],
      public: { port: 8081 },
      errors: [],
    });
  });

  test('bad public settings leave the public listener off; a bad main cap throws, like PORT', () => {
    for (const env of [
      { PUBLIC_PORT: 'x' },
      { PUBLIC_PORT: '8080' }, // the main port
      { PUBLIC_PORT: '70000' },
      { PUBLIC_PORT: '8081', PUBLIC_MAX_CLIENTS: '0' },
      { PUBLIC_PORT: '8081', PUBLIC_MAX_CLIENTS_PER_IP: '1.5' },
    ]) {
      const c = loadAccessConfig({ APP_TOKEN: TOKEN, ...env }, 8080);
      expect(c.public).toBeUndefined();
      expect(c.errors).toHaveLength(1);
      expect(c.errors[0]).toMatch(/^public listener not started: /);
    }
    // A typo never stops the live relay: the default stays and the problem is reported.
    const typo = loadAccessConfig({ MAX_CLIENTS: 'many' }, 8080);
    expect(typo.maxClients).toBe(DEFAULT_MAX_CLIENTS);
    expect(typo.errors).toEqual([expect.stringContaining('MAX_CLIENTS must be a positive integer')]);
    expect(typo.public).toBeUndefined();
    expect(loadAccessConfig({ MAX_CLIENTS: '0' }, 8080).maxClients).toBe(DEFAULT_MAX_CLIENTS);
  });
});

describe('inBoundingBoxes', () => {
  test('inside, on the edges and corners, and outside the dev box', () => {
    const [[latMin, lonMin], [latMax, lonMax]] = BOUNDING_BOXES[0];
    expect(inBoundingBoxes(40.7, -73.99)).toBe(true);
    expect(inBoundingBoxes(latMin, lonMin)).toBe(true);
    expect(inBoundingBoxes(latMax, lonMax)).toBe(true);
    expect(inBoundingBoxes(latMin - 1e-6, -73.99)).toBe(false);
    expect(inBoundingBoxes(40.7, lonMax + 1e-6)).toBe(false);
    expect(inBoundingBoxes(-73.99, 40.7)).toBe(false);
    expect(inBoundingBoxes(0, 0)).toBe(false);
    expect(inBoundingBoxes(Number.NaN, -73.99)).toBe(false);
  });
});
