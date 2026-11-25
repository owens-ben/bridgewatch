import { describe, expect, test } from '@jest/globals';
import { decodeFeedMessage, GtfsRtError, INCOMING_AT, IN_TRANSIT_TO, STOPPED_AT } from './gtfsrt';
import { WIRE_START_GROUP, WIRE_END_GROUP } from './protobuf';
import { ProtoWriter } from './tools/protobuf-writer';

const T0 = Date.parse('2026-11-11T02:52:39Z') / 1000;
const TRIP = '127250_Q..N36R';

/** IEEE 754 single-precision bits, for VehiclePosition.position (a field the decoder skips). */
const floatBits = (v: number) => {
  const b = Buffer.alloc(4);
  b.writeFloatLE(v);
  return b.readUInt32LE();
};

/** A feed shaped like NYCT's, with its extensions (nyct-subway.proto, field 1001) on header, trip and stop. */
function nyctLikeFeed(): Uint8Array {
  return new ProtoWriter()
    .message(1, (h) =>
      h
        .string(1, '1.0')
        .varint(2, 0)
        .varint(3, T0)
        .message(1001, (n) =>
          n.string(1, '1.0').message(2, (p) => p.string(1, 'Q').message(2, (r) => r.varint(2, T0 + 1800))),
        ),
    )
    .message(2, (e) =>
      e.string(1, '000001Q').message(3, (tu) =>
        tu
          .message(1, (t) =>
            t
              .string(1, TRIP)
              .string(2, '21:12:22')
              .string(3, '20261110')
              .varint(4, 0)
              .string(5, 'Q')
              .message(1001, (x) => x.string(1, '1Q 2112+ CTL/96S').bool(2, true).varint(3, 1)),
          )
          .message(2, (s) =>
            s
              .message(2, (a) => a.int32(1, -30).varint(2, T0 + 311).int32(3, 0))
              .message(3, (d) => d.varint(2, T0 + 311))
              .string(4, 'Q01N')
              .message(1001, (x) => x.string(1, 'A1').string(2, 'A1')),
          )
          .message(2, (s) => s.message(2, (a) => a.varint(2, T0 + 596)).string(4, 'R20N'))
          .message(2, (s) => s.message(2, (a) => a.varint(2, 0)).string(4, 'R17N'))
          .varint(4, T0),
      ),
    )
    .message(2, (e) =>
      e.string(1, '000002Q').message(4, (v) =>
        v
          .message(1, (t) => t.string(1, TRIP).string(5, 'Q'))
          .message(2, (p) => p.fixed32(1, floatBits(40.7)).fixed32(2, floatBits(-73.99)))
          .varint(3, 12)
          .varint(4, STOPPED_AT)
          .varint(5, T0 - 138)
          .string(7, 'R30N'),
      ),
    )
    .message(2, (e) => e.string(1, 'alert-1').message(5, (a) => a.message(10, (t) => t.message(1, (tr) => tr.string(1, 'x')))))
    .message(2, (e) => e.string(1, 'gone').bool(2, true).message(3, (tu) => tu.message(1, (t) => t.string(1, 'deleted'))))
    .varint(99, 1)
    .finish();
}

describe('decodeFeedMessage', () => {
  test('reads the fields the estimator uses and skips the rest, NYCT extensions included', () => {
    expect(decodeFeedMessage(nyctLikeFeed())).toEqual({
      timestamp: T0,
      entities: [
        {
          id: '000001Q',
          tripUpdate: {
            trip: { tripId: TRIP, startTime: '21:12:22', startDate: '20261110', routeId: 'Q' },
            stopTimeUpdates: [
              { stopId: 'Q01N', arrival: T0 + 311, departure: T0 + 311 },
              { stopId: 'R20N', arrival: T0 + 596 },
              // time 0 means "not set".
              { stopId: 'R17N', arrival: undefined },
            ],
          },
        },
        {
          id: '000002Q',
          vehicle: { trip: { tripId: TRIP, routeId: 'Q' }, currentStatus: STOPPED_AT, timestamp: T0 - 138, stopId: 'R30N' },
        },
        // An alert: kept as a bare entity, which the estimator ignores.
        { id: 'alert-1' },
      ],
    });
  });

  test('a vehicle without current_status is IN_TRANSIT_TO, the proto default', () => {
    const bytes = new ProtoWriter()
      .message(2, (e) => e.string(1, 'v').message(4, (v) => v.message(1, (t) => t.string(1, TRIP)).string(7, 'R30N')))
      .message(2, (e) => e.string(1, 'w').message(4, (v) => v.varint(4, INCOMING_AT)))
      .finish();
    const feed = decodeFeedMessage(bytes);
    expect(feed.timestamp).toBeUndefined();
    expect(feed.entities.map((e) => e.vehicle?.currentStatus)).toEqual([IN_TRANSIT_TO, INCOMING_AT]);
  });

  test('a known field number with an unexpected wire type is skipped, not misread', () => {
    const bytes = new ProtoWriter()
      .message(1, (h) => h.string(3, 'not a timestamp'))
      .message(2, (e) => e.varint(1, 7).message(4, (v) => v.string(5, 'nope').varint(7, 3)))
      .finish();
    expect(decodeFeedMessage(bytes)).toEqual({ entities: [{ id: '', vehicle: { trip: {}, currentStatus: IN_TRANSIT_TO } }] });
  });

  test('deprecated groups inside messages are skipped', () => {
    const bytes = new ProtoWriter()
      .message(1, (h) => h.key(50, WIRE_START_GROUP).varint(1, 1).key(50, WIRE_END_GROUP).varint(3, T0))
      .finish();
    expect(decodeFeedMessage(bytes)).toEqual({ timestamp: T0, entities: [] });
  });

  test('an empty buffer is an empty feed; truncated input throws', () => {
    expect(decodeFeedMessage(new Uint8Array(0))).toEqual({ entities: [] });
    const bytes = nyctLikeFeed();
    // The last 3 bytes are a whole unknown field; 5 cuts into the entity before it.
    expect(() => decodeFeedMessage(bytes.subarray(0, bytes.length - 3))).not.toThrow();
    expect(() => decodeFeedMessage(bytes.subarray(0, bytes.length - 5))).toThrow(GtfsRtError);
    expect(() => decodeFeedMessage(Buffer.from('<html>Service Unavailable</html>'))).toThrow(GtfsRtError);
  });
});
