import { describe, expect, test } from '@jest/globals';
import { addressKey, FORWARDING_HEADERS, isForwarded, parseTokens, publicClientKey, Slots, TokenCheck } from './access';

const TOKEN = 'a-long-enough-app-token';

const req = (headers: Record<string, string | string[]> = {}, remoteAddress = '203.0.113.7') =>
  ({ headers, socket: { remoteAddress } }) as unknown as Parameters<typeof isForwarded>[0];

describe('parseTokens', () => {
  test('one token or a comma-separated list, trimmed, deduplicated, empty entries ignored', () => {
    expect(parseTokens(undefined)).toEqual({ tokens: [] });
    expect(parseTokens('  ')).toEqual({ tokens: [] });
    expect(parseTokens(' 0123456789abcdef ')).toEqual({ tokens: ['0123456789abcdef'] });
    expect(parseTokens('0123456789abcdef, fedcba9876543210,,0123456789abcdef,')).toEqual({
      tokens: ['0123456789abcdef', 'fedcba9876543210'],
    });
  });

  test('a short token invalidates the whole setting without throwing: no token is accepted', () => {
    expect(parseTokens('changeme')).toEqual({ tokens: [], error: 'each APP_TOKEN must be at least 16 characters' });
    expect(parseTokens('0123456789abcdef,short').tokens).toEqual([]);
  });
});

describe('TokenCheck', () => {
  test('missing, malformed and wrong tokens are refused', () => {
    const check = new TokenCheck([TOKEN]);
    for (const authorization of [undefined, TOKEN, 'Basic abc', 'Bearer nope', 'Bearer ', `Bearer ${TOKEN.slice(0, -1)}`, `Bearer ${TOKEN}x`]) {
      expect(check.authorized(req(authorization === undefined ? {} : { authorization }))).toBe(false);
    }
  });

  test('the right token is accepted, whatever the case of the scheme; several can be, for a rotation', () => {
    const check = new TokenCheck([TOKEN, 'the-previous-app-token']);
    expect(check.authorized(req({ authorization: `Bearer ${TOKEN}` }))).toBe(true);
    expect(check.authorized(req({ authorization: `bearer ${TOKEN}` }))).toBe(true);
    expect(check.authorized(req({ authorization: 'Bearer the-previous-app-token' }))).toBe(true);
  });

  test('with no token configured nothing is accepted (fail closed)', () => {
    const check = new TokenCheck([]);
    expect(check.configured).toBe(false);
    expect(check.authorized(req({ authorization: 'Bearer ' }))).toBe(false);
    expect(check.authorized(req({ authorization: `Bearer ${TOKEN}` }))).toBe(false);
  });
});

describe('isForwarded', () => {
  test('any one forwarding header, even empty, makes a request forwarded; none does not', () => {
    expect(isForwarded(req())).toBe(false);
    expect(isForwarded(req({ authorization: `Bearer ${TOKEN}`, host: 'relay-box:8095' }))).toBe(false);
    for (const h of FORWARDING_HEADERS) {
      expect(isForwarded(req({ [h]: '198.51.100.1' }))).toBe(true);
      expect(isForwarded(req({ [h]: '' }))).toBe(true);
    }
  });
});

describe('client address keys', () => {
  test('IPv4 as is; IPv4-mapped IPv6 as IPv4; IPv6 by its /64', () => {
    expect(addressKey('198.51.100.1')).toBe('198.51.100.1');
    expect(addressKey('::ffff:198.51.100.1')).toBe('198.51.100.1');
    expect(addressKey('2001:db8:1:2:3:4:5:6')).toBe('2001:db8:1:2::/64');
    expect(addressKey('2001:db8:1:2::ffff')).toBe('2001:db8:1:2::/64');
    expect(addressKey('2001:DB8:1:2::1')).toBe('2001:db8:1:2::/64');
    expect(addressKey('2001:db8::1')).toBe('2001:db8:0:0::/64');
    expect(addressKey('::1')).toBe('0:0:0:0::/64');
    expect(addressKey('fe80::1%eth0')).toBe('fe80:0:0:0::/64');
    expect(addressKey('2001:db8:1:2::198.51.100.1')).toBe('2001:db8:1:2::/64');
  });

  test('the public key is CF-Connecting-IP when it is a valid IP, else the socket address', () => {
    expect(publicClientKey(req({ 'cf-connecting-ip': '198.51.100.9' }, '192.0.2.50'))).toBe('198.51.100.9');
    expect(publicClientKey(req({ 'cf-connecting-ip': ' 2001:db8:a:b::7 ' }, '192.0.2.50'))).toBe('2001:db8:a:b::/64');
    expect(publicClientKey(req({ 'cf-connecting-ip': ['198.51.100.8', 'x'] }, '192.0.2.50'))).toBe('198.51.100.8');
    for (const bad of ['', 'not-an-ip', '198.51.100.9, 203.0.113.1', '9'.repeat(500)]) {
      expect(publicClientKey(req({ 'cf-connecting-ip': bad }, '192.0.2.50'))).toBe('192.0.2.50');
    }
    expect(publicClientKey(req({}, '::ffff:192.0.2.50'))).toBe('192.0.2.50');
  });
});

describe('Slots', () => {
  test('per key: the next one is refused, another key is unaffected, and a release frees the slot', () => {
    const slots = new Slots(10, 2);
    const first = slots.admit('a');
    expect(slots.admit('a').ok).toBe(true);
    expect(slots.admit('a')).toEqual({ ok: false, reason: 'per_ip_limit' });
    expect(slots.admit('b').ok).toBe(true);
    if (first.ok) first.release();
    expect(slots.admit('a').ok).toBe(true);
  });

  test('release counts once, however many times it is called', () => {
    const slots = new Slots(10, 1);
    const a = slots.admit('a');
    if (!a.ok) throw new Error('expected admission');
    a.release();
    a.release();
    expect(slots.admit('a').ok).toBe(true);
    expect(slots.active).toBe(1); // a second release of `a` must not have freed the new slot
    expect(slots.admit('a')).toEqual({ ok: false, reason: 'per_ip_limit' });
  });

  test('total: past maxClients everyone is refused as capacity, then let in again as clients leave', () => {
    const slots = new Slots(2, 5);
    const a = slots.admit('1');
    slots.admit('2');
    expect(slots.admit('3')).toEqual({ ok: false, reason: 'capacity' });
    if (a.ok) a.release();
    expect(slots.admit('3').ok).toBe(true);
  });

  test('without a per-key cap (the main listener) only the total counts, and no addresses are kept', () => {
    const slots = new Slots(3);
    for (let i = 0; i < 3; i++) expect(slots.admit().ok).toBe(true);
    expect(slots.admit()).toEqual({ ok: false, reason: 'capacity' });
    expect(slots.keys).toBe(0);
  });
});
