/**
 * A minimal protobuf wire-format reader: just enough to pull a few fields out of GTFS-realtime feeds without a
 * protobuf library. It knows nothing about schemas: callers loop over fields, read the ones they want by number and
 * skip the rest (unknown fields, extensions such as NYCT's, deprecated groups).
 *
 * Wire format: https://protobuf.dev/programming-guides/encoding/
 */

export const WIRE_VARINT = 0;
export const WIRE_FIXED64 = 1;
export const WIRE_LEN = 2;
export const WIRE_START_GROUP = 3;
export const WIRE_END_GROUP = 4;
export const WIRE_FIXED32 = 5;

export class ProtoError extends Error {}

export interface Tag {
  field: number;
  wire: number;
}

const TWO_POW_32 = 2 ** 32;
const MAX_GROUP_DEPTH = 32;

/** Reads fields from `buf[start, end)`. Every read checks bounds and throws ProtoError on malformed input. */
export class ProtoReader {
  private pos: number;
  private readonly end: number;

  constructor(
    private readonly buf: Uint8Array,
    start = 0,
    end = buf.length,
  ) {
    if (start < 0 || end > buf.length || start > end) throw new ProtoError('bad range');
    this.pos = start;
    this.end = end;
  }

  /** True when every field has been read. */
  get done(): boolean {
    return this.pos >= this.end;
  }

  /** Byte offset of the next read, within the underlying buffer. */
  get offset(): number {
    return this.pos;
  }

  /** Reads a field key. Field number 0 and wire types 6 and 7 do not exist and throw. */
  tag(): Tag {
    const key = this.uint();
    const field = Math.floor(key / 8);
    const wire = key % 8;
    if (field < 1 || field > 0x1fffffff || wire > 5) throw new ProtoError(`bad field key ${key}`);
    return { field, wire };
  }

  /**
   * Reads an unsigned varint (uint32, uint64, int64 >= 0, enum, bool) as a number. Exact up to 2^53; GTFS-realtime
   * timestamps and counters are far below that. At most 10 bytes, as the format allows.
   */
  uint(): number {
    let value = 0;
    let scale = 1;
    for (let i = 0; i < 10; i++) {
      if (this.pos >= this.end) throw new ProtoError('truncated varint');
      const b = this.buf[this.pos++];
      value += (b & 0x7f) * scale;
      if (b < 0x80) return value;
      scale *= 128;
    }
    throw new ProtoError('varint longer than 10 bytes');
  }

  /** Reads an int32 varint. Negative values are sign-extended to 10 bytes on the wire; only the low 32 bits count. */
  int32(): number {
    const start = this.pos;
    this.uint();
    // Recompute the low 32 bits exactly from the first five bytes (the double above loses them for negatives).
    let low = 0;
    let scale = 1;
    for (let i = start; i < this.pos && i < start + 5; i++) {
      low += (this.buf[i] & 0x7f) * scale;
      scale *= 128;
    }
    return (low % TWO_POW_32) | 0;
  }

  bool(): boolean {
    return this.uint() !== 0;
  }

  /** Reads a length-delimited field's payload. */
  bytes(): Uint8Array {
    const [start, end] = this.lengthDelimited();
    return this.buf.subarray(start, end);
  }

  string(): string {
    const [start, end] = this.lengthDelimited();
    return Buffer.from(this.buf.buffer, this.buf.byteOffset + start, end - start).toString('utf8');
  }

  /** A reader over an embedded message, sharing the buffer. */
  message(): ProtoReader {
    const [start, end] = this.lengthDelimited();
    return new ProtoReader(this.buf, start, end);
  }

  /** Skips the value of a field whose key was just read. */
  skip(wire: number, field = 0, depth = 0): void {
    switch (wire) {
      case WIRE_VARINT:
        this.uint();
        return;
      case WIRE_FIXED64:
        this.advance(8);
        return;
      case WIRE_LEN:
        this.lengthDelimited();
        return;
      case WIRE_FIXED32:
        this.advance(4);
        return;
      case WIRE_START_GROUP: {
        // Deprecated groups: skip nested fields up to the matching end-group key.
        if (depth >= MAX_GROUP_DEPTH) throw new ProtoError('groups nested too deep');
        for (;;) {
          if (this.done) throw new ProtoError('unterminated group');
          const t = this.tag();
          if (t.wire === WIRE_END_GROUP) {
            if (t.field !== field) throw new ProtoError(`end group ${t.field} does not match ${field}`);
            return;
          }
          this.skip(t.wire, t.field, depth + 1);
        }
      }
      default:
        throw new ProtoError(`unexpected wire type ${wire}`);
    }
  }

  private advance(n: number): void {
    if (this.pos + n > this.end) throw new ProtoError('truncated field');
    this.pos += n;
  }

  private lengthDelimited(): [number, number] {
    const length = this.uint();
    const start = this.pos;
    this.advance(length);
    return [start, start + length];
  }
}

/**
 * Calls `onField` for each field of a message. `onField` reads the value it wants and returns true; returning false
 * (or nothing) skips it. Throws ProtoError on malformed input, and if a group is opened at this level and never closed.
 */
export function forEachField(reader: ProtoReader, onField: (tag: Tag, reader: ProtoReader) => boolean | void): void {
  while (!reader.done) {
    const tag = reader.tag();
    if (tag.wire === WIRE_END_GROUP) throw new ProtoError(`stray end group ${tag.field}`);
    if (!onField(tag, reader)) reader.skip(tag.wire, tag.field);
  }
}
