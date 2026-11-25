import { describe, expect, test } from '@jest/globals';
import {
  forEachField,
  ProtoError,
  ProtoReader,
  WIRE_END_GROUP,
  WIRE_FIXED32,
  WIRE_FIXED64,
  WIRE_LEN,
  WIRE_START_GROUP,
  WIRE_VARINT,
} from './protobuf';
import { ProtoWriter } from './tools/protobuf-writer';

const reader = (...bytes: number[]) => new ProtoReader(Uint8Array.from(bytes));

describe('ProtoReader varints', () => {
  test('one-byte and multi-byte values', () => {
    expect(reader(0x00).uint()).toBe(0);
    expect(reader(0x01).uint()).toBe(1);
    expect(reader(0x7f).uint()).toBe(127);
    expect(reader(0x80, 0x01).uint()).toBe(128);
    expect(reader(0xac, 0x02).uint()).toBe(300);
  });

  test('values past 32 bits stay exact up to 2^53', () => {
    expect(reader(0x80, 0x80, 0x80, 0x80, 0x10).uint()).toBe(2 ** 32);
    // A real GTFS-realtime timestamp: 2026-11-10T14:00:00Z.
    const t = Date.parse('2026-11-10T14:00:00Z') / 1000;
    expect(new ProtoReader(new ProtoWriter().rawVarint(t).finish()).uint()).toBe(t);
    expect(new ProtoReader(new ProtoWriter().rawVarint(Number.MAX_SAFE_INTEGER).finish()).uint()).toBe(Number.MAX_SAFE_INTEGER);
  });

  test('a 10-byte uint64 max reads (approximately) without throwing', () => {
    const r = reader(0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01);
    expect(r.uint()).toBeCloseTo(2 ** 64, -5);
    expect(r.done).toBe(true);
  });

  test('int32: negatives are 10 bytes, sign-extended; only the low 32 bits count', () => {
    for (const v of [0, 1, 300, 2 ** 31 - 1, -1, -2, -300, -(2 ** 31)]) {
      const bytes = new ProtoWriter().int32(1, v).finish();
      const r = new ProtoReader(bytes);
      expect(r.tag()).toEqual({ field: 1, wire: WIRE_VARINT });
      expect(r.int32()).toBe(v);
      expect(r.done).toBe(true);
    }
    expect(new ProtoWriter().int32(1, -1).finish()).toEqual(
      Uint8Array.from([0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]),
    );
  });

  test('truncated or overlong varints throw', () => {
    expect(() => reader(0x80).uint()).toThrow(ProtoError);
    expect(() => reader().uint()).toThrow(ProtoError);
    expect(() => reader(0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01).uint()).toThrow(/longer than 10/);
  });
});

describe('ProtoReader fields', () => {
  test('tags: field number and wire type, including NYCT extension numbers', () => {
    expect(reader(0x0a).tag()).toEqual({ field: 1, wire: WIRE_LEN });
    expect(reader(0x08).tag()).toEqual({ field: 1, wire: WIRE_VARINT });
    // Field 1001 (NYCT's extensions), length-delimited: key 8010 = 0xca 0x3e.
    expect(reader(0xca, 0x3e).tag()).toEqual({ field: 1001, wire: WIRE_LEN });
  });

  test('field 0 and wire types 6 and 7 are malformed', () => {
    expect(() => reader(0x02).tag()).toThrow(ProtoError); // field 0, wire 2
    expect(() => reader(0x0e).tag()).toThrow(ProtoError); // field 1, wire 6
    expect(() => reader(0x0f).tag()).toThrow(ProtoError); // field 1, wire 7
  });

  test('strings, bytes and embedded messages share the buffer', () => {
    const bytes = new ProtoWriter()
      .string(1, 'Smith–9 Sts')
      .bytes(2, Uint8Array.from([1, 2, 3]))
      .message(3, (w) => w.varint(1, 42))
      .bool(4, true)
      .finish();
    const r = new ProtoReader(bytes);
    expect(r.tag().field).toBe(1);
    expect(r.string()).toBe('Smith–9 Sts');
    expect(r.tag().field).toBe(2);
    expect([...r.bytes()]).toEqual([1, 2, 3]);
    expect(r.tag().field).toBe(3);
    const inner = r.message();
    expect(inner.tag()).toEqual({ field: 1, wire: WIRE_VARINT });
    expect(inner.uint()).toBe(42);
    expect(inner.done).toBe(true);
    expect(r.tag().field).toBe(4);
    expect(r.bool()).toBe(true);
    expect(r.done).toBe(true);
  });

  test('a length past the end of the message throws, even inside a larger buffer', () => {
    const r = reader(0x0a, 0x05, 0x61, 0x62);
    r.tag();
    expect(() => r.string()).toThrow(ProtoError);
    // An embedded message can't read past its own end into the parent's bytes.
    const outer = new ProtoReader(new ProtoWriter().bytes(1, Uint8Array.from([0x0a, 0x03, 0x61])).string(2, 'zz').finish());
    outer.tag();
    const inner = outer.message();
    inner.tag();
    expect(() => inner.string()).toThrow(ProtoError);
  });

  test('bad ranges are rejected', () => {
    expect(() => new ProtoReader(Uint8Array.from([1, 2]), 1, 3)).toThrow(ProtoError);
    expect(() => new ProtoReader(Uint8Array.from([1, 2]), 2, 1)).toThrow(ProtoError);
  });
});

describe('skipping unknown fields', () => {
  test('every wire type, including deprecated groups, nested', () => {
    const bytes = new ProtoWriter()
      .varint(10, 2 ** 40)
      .fixed64(11, 123n)
      .string(12, 'skip me')
      .fixed32(13, 7)
      .key(14, WIRE_START_GROUP)
      .varint(1, 5)
      .key(2, WIRE_START_GROUP)
      .string(1, 'nested')
      .key(2, WIRE_END_GROUP)
      .key(14, WIRE_END_GROUP)
      .varint(1, 99)
      .finish();
    const seen: number[] = [];
    let wanted: number | undefined;
    forEachField(new ProtoReader(bytes), (t, r) => {
      seen.push(t.field);
      if (t.field !== 1) return false;
      wanted = r.uint();
      return true;
    });
    expect(seen).toEqual([10, 11, 12, 13, 14, 1]);
    expect(wanted).toBe(99);
  });

  test('a group closed by the wrong field, or never closed, is malformed', () => {
    const wrongEnd = new ProtoWriter().key(5, WIRE_START_GROUP).varint(1, 1).key(6, WIRE_END_GROUP).finish();
    expect(() => forEachField(new ProtoReader(wrongEnd), () => false)).toThrow(/does not match/);
    const unterminated = new ProtoWriter().key(5, WIRE_START_GROUP).varint(1, 1).finish();
    expect(() => forEachField(new ProtoReader(unterminated), () => false)).toThrow(/unterminated/);
    const stray = new ProtoWriter().key(5, WIRE_END_GROUP).finish();
    expect(() => forEachField(new ProtoReader(stray), () => false)).toThrow(/stray end group/);
  });

  test('truncated fixed-width fields throw', () => {
    expect(() => forEachField(new ProtoReader(Uint8Array.from([0x09, 1, 2, 3])), () => false)).toThrow(ProtoError);
    expect(() => forEachField(new ProtoReader(Uint8Array.from([0x0d, 1, 2])), () => false)).toThrow(ProtoError);
  });

  test('wire type constants match the format', () => {
    expect([WIRE_VARINT, WIRE_FIXED64, WIRE_LEN, WIRE_START_GROUP, WIRE_END_GROUP, WIRE_FIXED32]).toEqual([0, 1, 2, 3, 4, 5]);
  });
});
