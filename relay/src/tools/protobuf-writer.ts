import { WIRE_FIXED32, WIRE_FIXED64, WIRE_LEN, WIRE_VARINT } from '../protobuf';

/** A minimal protobuf wire-format writer, for tests and for building the synthetic fixtures. Not used by the relay itself. */
export class ProtoWriter {
  private readonly chunks: Uint8Array[] = [];

  /** Unsigned varint field (uint32/uint64/enum/bool/int64 >= 0). `value` must be a non-negative integer. */
  varint(field: number, value: number): this {
    return this.key(field, WIRE_VARINT).rawVarint(value);
  }

  /** int32 field; negative values take 10 bytes, sign-extended, as the format requires. */
  int32(field: number, value: number): this {
    this.key(field, WIRE_VARINT);
    if (value >= 0) return this.rawVarint(value);
    const bytes: number[] = [];
    let low = value >>> 0; // two's complement, low 32 bits
    for (let i = 0; i < 4; i++) {
      bytes.push((low & 0x7f) | 0x80);
      low >>>= 7;
    }
    // Byte 5 holds bits 28-34: the last 4 low bits plus 3 sign bits; then 4 bytes of sign, then 0x01.
    bytes.push((low & 0x0f) | 0x70 | 0x80, 0xff, 0xff, 0xff, 0xff, 0x01);
    this.chunks.push(Uint8Array.from(bytes));
    return this;
  }

  bool(field: number, value: boolean): this {
    return this.varint(field, value ? 1 : 0);
  }

  string(field: number, value: string): this {
    return this.bytes(field, Buffer.from(value, 'utf8'));
  }

  bytes(field: number, value: Uint8Array): this {
    this.key(field, WIRE_LEN).rawVarint(value.length);
    this.chunks.push(value);
    return this;
  }

  message(field: number, build: (w: ProtoWriter) => void): this {
    const inner = new ProtoWriter();
    build(inner);
    return this.bytes(field, inner.finish());
  }

  fixed32(field: number, value: number): this {
    const b = Buffer.alloc(4);
    b.writeUInt32LE(value >>> 0);
    this.key(field, WIRE_FIXED32);
    this.chunks.push(b);
    return this;
  }

  fixed64(field: number, value: bigint): this {
    const b = Buffer.alloc(8);
    b.writeBigUInt64LE(value);
    this.key(field, WIRE_FIXED64);
    this.chunks.push(b);
    return this;
  }

  /** Appends bytes as they are, e.g. a field copied from another message. */
  raw(bytes: Uint8Array): this {
    this.chunks.push(bytes);
    return this;
  }

  /** A field key on its own (e.g. to build groups by hand). */
  key(field: number, wire: number): this {
    return this.rawVarint(field * 8 + wire);
  }

  rawVarint(value: number): this {
    if (!Number.isSafeInteger(value) || value < 0) throw new Error(`not a non-negative safe integer: ${value}`);
    const bytes: number[] = [];
    let v = value;
    while (v >= 0x80) {
      bytes.push((v % 0x80) | 0x80);
      v = Math.floor(v / 0x80);
    }
    bytes.push(v);
    this.chunks.push(Uint8Array.from(bytes));
    return this;
  }

  finish(): Uint8Array {
    return Buffer.concat(this.chunks);
  }
}
