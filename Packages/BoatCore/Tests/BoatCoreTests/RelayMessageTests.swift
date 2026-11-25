import Foundation
import Testing
@testable import BoatCore

@Suite struct RelayMessageTests {
    let vesselJSON = """
    {"id":"vessel:367000001","kind":"vessel","source":"aisstream","name":"HARBOR LARK","lat":40.7041,"lon":-73.9952,\
    "speed":14.2,"course":62.5,"heading":61,"timestamp":"2026-11-10T14:00:00.125Z",\
    "vessel":{"mmsi":367000001,"shipType":60}}
    """

    let trainJSON = """
    {"id":"train:nyct:101100_Q..S36R","kind":"train","source":"mta-subway","lat":40.704624,"lon":-73.989301,\
    "altitude":40.6,"speed":17.2,"course":157.1,"timestamp":"2026-11-10T14:12:00.000Z",\
    "train":{"route":"Q","direction":"S","destination":"Coney Island-Stillwell Av","stretch":"manhattan-bridge",\
    "underground":false,"altitudeEstimated":false}}
    """

    /// Underground: no `stretch`, a modelled rail altitude, estimated.
    let undergroundTrainJSON = """
    {"id":"train:nyct:101750_2..S17R","kind":"train","source":"mta-subway","lat":40.702957,"lon":-74.00768,\
    "altitude":-12.8,"speed":13.8,"course":139.3,"timestamp":"2026-11-10T14:12:00.000Z",\
    "train":{"route":"2","direction":"S","destination":"Flatbush Av-Brooklyn College","underground":true,\
    "altitudeEstimated":true}}
    """

    /// From a relay older than the depth model: no `altitudeEstimated`, the flat placeholder altitude.
    let olderUndergroundTrainJSON = """
    {"id":"train:nyct:101750_2..S17R","kind":"train","source":"mta-subway","lat":40.702957,"lon":-74.00768,\
    "altitude":-10,"speed":13.8,"course":139.3,"timestamp":"2026-11-10T14:12:00.000Z",\
    "train":{"route":"2","direction":"S","destination":"Flatbush Av-Brooklyn College","underground":true}}
    """

    func decode(_ json: String) throws -> RelayMessage {
        try RelayMessage.decode(Data(json.utf8))
    }

    // MARK: Decoding

    @Test func decodesEveryKeyOfAVesselTarget() throws {
        let message = try decode(#"{"type":"update","target":\#(vesselJSON)}"#)
        let expected = Target(
            id: "vessel:367000001", kind: .vessel, source: "aisstream", name: "HARBOR LARK", lat: 40.7041, lon: -73.9952,
            speed: 14.2, course: 62.5, heading: 61, timestamp: try date("2026-11-10T14:00:00.125Z"),
            vessel: VesselDetails(mmsi: 367000001, shipType: 60))
        #expect(message == .update(expected))
    }

    @Test func decodesEveryKeyOfAnAboveGroundTrainTarget() throws {
        let message = try decode(#"{"type":"update","target":\#(trainJSON)}"#)
        let expected = Target(
            id: "train:nyct:101100_Q..S36R", kind: .train, source: "mta-subway", lat: 40.704624, lon: -73.989301,
            altitude: 40.6, speed: 17.2, course: 157.1, timestamp: try date("2026-11-10T14:12:00.000Z"),
            train: TrainDetails(
                route: "Q", direction: .south, destination: "Coney Island-Stillwell Av", stretch: "manhattan-bridge",
                underground: false, altitudeEstimated: false))
        #expect(message == .update(expected))
    }

    @Test func decodesEveryKeyOfAnUndergroundTrainTarget() throws {
        let message = try decode(#"{"type":"update","target":\#(undergroundTrainJSON)}"#)
        let expected = Target(
            id: "train:nyct:101750_2..S17R", kind: .train, source: "mta-subway", lat: 40.702957, lon: -74.00768,
            altitude: -12.8, speed: 13.8, course: 139.3, timestamp: try date("2026-11-10T14:12:00.000Z"),
            train: TrainDetails(
                route: "2", direction: .south, destination: "Flatbush Av-Brooklyn College", stretch: nil,
                underground: true, altitudeEstimated: true))
        #expect(message == .update(expected))
        guard case .update(let target) = message else { return }
        let train = try #require(Train(target))
        #expect(train.altitudeEstimated && train.hasModelledAltitude)
    }

    @Test func anOlderRelaysTrainWithoutAltitudeEstimatedDecodesAsNotEstimated() throws {
        guard case .update(let target) = try decode(#"{"type":"update","target":\#(olderUndergroundTrainJSON)}"#) else {
            Issue.record("expected an update")
            return
        }
        #expect(target.train?.altitudeEstimated == nil)
        let train = try #require(Train(target))
        #expect(train.altitude == -10)
        #expect(!train.altitudeEstimated)
        #expect(!train.hasModelledAltitude)
    }

    @Test func altitudeEstimatedRoundTrips() throws {
        let when = try date("2026-11-10T14:12:00.000Z")
        for estimated in [true, false] {
            let message = RelayMessage.update(trainTarget("x", stretch: nil, altitudeEstimated: estimated, timestamp: when))
            let data = try RelayJSON.encoder().encode(message)
            #expect(try RelayMessage.decode(data) == message)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let train = try #require((json["target"] as? [String: Any])?["train"] as? [String: Any])
            #expect(train["altitudeEstimated"] as? Bool == estimated)
        }
    }

    @Test func omittedFieldsDecodeAsNil() throws {
        let json = """
        {"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"aisstream","lat":40.7,"lon":-73.99,\
        "timestamp":"2026-11-10T14:08:00.000Z","vessel":{"mmsi":1}}}
        """
        guard case .update(let target) = try decode(json) else {
            Issue.record("expected an update")
            return
        }
        #expect(target.name == nil)
        #expect(target.altitude == nil)
        #expect(target.speed == nil)
        #expect(target.course == nil)
        #expect(target.heading == nil)
        #expect(target.vessel == VesselDetails(mmsi: 1, shipType: nil))
        #expect(target.train == nil)
    }

    @Test func omittedTrainDestinationDecodesAsNil() throws {
        let json = """
        {"type":"update","target":{"id":"train:nyct:x","kind":"train","source":"mta-subway","lat":40.7,"lon":-73.99,\
        "timestamp":"2026-11-10T14:12:00.000Z","train":{"route":"J","direction":"N","stretch":"williamsburg-bridge",\
        "underground":false}}}
        """
        guard case .update(let target) = try decode(json) else {
            Issue.record("expected an update")
            return
        }
        #expect(target.train == TrainDetails(
            route: "J", direction: .north, destination: nil, stretch: "williamsburg-bridge", underground: false))
        #expect(target.altitude == nil)
        #expect(target.speed == nil)
        #expect(target.course == nil)
        #expect(target.heading == nil)
    }

    @Test func decodesSnapshotOfBothKinds() throws {
        let message = try decode(
            #"{"type":"snapshot","targets":[\#(vesselJSON),\#(trainJSON),\#(undergroundTrainJSON)]}"#)
        guard case .snapshot(let targets) = message else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(targets.map(\.id) == ["vessel:367000001", "train:nyct:101100_Q..S36R", "train:nyct:101750_2..S17R"])
        #expect(targets.map(\.kind) == [.vessel, .train, .train])
    }

    @Test(arguments: [
        // Not an object, no `lat`, a bad timestamp, a direction that isn't N or S, a train without `underground`.
        #""nonsense""#,
        #"{"id":"vessel:2","kind":"vessel","source":"aisstream","lon":-73.99,"timestamp":"2026-11-10T14:00:05Z"}"#,
        #"{"id":"vessel:2","kind":"vessel","source":"aisstream","lat":40.7,"lon":-73.99,"timestamp":"yesterday"}"#,
        #"{"id":"train:nyct:x","kind":"train","source":"mta-subway","lat":40.7,"lon":-73.99,"timestamp":"2026-11-10T14:00:05Z","train":{"route":"Q","direction":"E","underground":true}}"#,
        #"{"id":"train:nyct:x","kind":"train","source":"mta-subway","lat":40.7,"lon":-73.99,"timestamp":"2026-11-10T14:00:05Z","train":{"route":"Q","direction":"S"}}"#,
    ])
    func snapshotSkipsATargetThatDoesNotDecodeAndKeepsTheOthers(_ bad: String) throws {
        let message = try decode(#"{"type":"snapshot","targets":[\#(vesselJSON),\#(bad),\#(trainJSON)]}"#)
        guard case .snapshot(let targets) = message else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(targets.map(\.id) == ["vessel:367000001", "train:nyct:101100_Q..S36R"])
    }

    @Test func decodesEmptySnapshot() throws {
        #expect(try decode(#"{"type":"snapshot","targets":[]}"#) == .snapshot([]))
    }

    @Test func decodesRemove() throws {
        #expect(try decode(#"{"type":"remove","id":"vessel:367000001"}"#) == .remove(id: "vessel:367000001"))
    }

    @Test func unknownKindDecodesAsUnknownWhateverItCarries() throws {
        let json = """
        {"type":"snapshot","targets":[{"id":"aircraft:abc123","kind":"aircraft","source":"opensky","lat":40.7,\
        "lon":-73.99,"altitude":1200,"timestamp":"2026-11-10T14:00:00.000Z","aircraft":{"icao24":"abc123"}},\(vesselJSON)]}
        """
        guard case .snapshot(let targets) = try decode(json) else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(targets.map(\.kind) == [.unknown("aircraft"), .vessel])
        #expect(targets[0].id == "aircraft:abc123")
        #expect(targets[0].altitude == 1200)
        #expect(targets[0].vessel == nil)
    }

    @Test func acceptsTimestampWithoutFractionalSeconds() throws {
        let json = """
        {"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"aisstream","lat":40.7,"lon":-73.99,\
        "timestamp":"2026-11-10T14:00:05Z","vessel":{"mmsi":1}}}
        """
        guard case .update(let target) = try decode(json) else {
            Issue.record("expected an update")
            return
        }
        #expect(target.timestamp == (try date("2026-11-10T14:00:05.000Z")))
    }

    // MARK: Frames that don't decode (the feed skips them)

    @Test(arguments: [
        #"{"type":"bogus","target":{}}"#,
        #"{"type":"vessels"}"#,
        #"{"type":"update"}"#,
        #"{"type":"snapshot"}"#,
        #"{"type":"remove"}"#,
        #"{"type":"snapshot","vessels":[]}"#,
        #"{"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"s","lat":40.7,"lon":-73.99,"timestamp":"yesterday"}}"#,
        #"{"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"s","lon":-73.99,"timestamp":"2026-11-10T14:00:05Z"}}"#,
        #"{"type":"update","target":{"id":"train:x","kind":"train","source":"s","lat":40.7,"lon":-73.99,"timestamp":"2026-11-10T14:00:05Z","train":{"route":"Q","direction":"E","underground":true}}}"#,
        #"{"type":"update","target":{"id":"train:x","kind":"train","source":"s","lat":40.7,"lon":-73.99,"timestamp":"2026-11-10T14:00:05Z","train":{"route":"Q","direction":"S"}}}"#,
        #"{"type":"snapshot","targets":{}}"#,
        "not json",
    ])
    func rejectsUndecodableFrames(_ json: String) {
        #expect(throws: (any Error).self) { try decode(json) }
    }

    // MARK: Encoding

    @Test(arguments: [
        RelayMessage.snapshot([]),
        RelayMessage.remove(id: "train:nyct:101100_Q..S36R"),
    ])
    func encodeDecodeRoundTripOfSimpleMessages(_ message: RelayMessage) throws {
        let data = try RelayJSON.encoder().encode(message)
        #expect(try RelayMessage.decode(data) == message)
    }

    @Test func encodeDecodeRoundTripOfTargets() throws {
        let when = try date("2026-11-10T14:00:30.250Z")
        let targets = [
            vesselTarget(5, name: "WREN", shipType: 36, speed: 4.1, course: 80, heading: 79, timestamp: when),
            vesselTarget(6, timestamp: when),
            trainTarget("101100_Q..S36R", destination: "Coney Island-Stillwell Av", timestamp: when),
            trainTarget("101750_2..S17R", route: "2", stretch: nil, timestamp: when),
            Target(id: "aircraft:abc123", kind: .unknown("aircraft"), source: "opensky", lat: 40.7, lon: -73.99,
                   altitude: 1200, timestamp: when),
        ]
        for message in [RelayMessage.snapshot(targets), .update(targets[0])] {
            let data = try RelayJSON.encoder().encode(message)
            #expect(try RelayMessage.decode(data) == message)
        }
    }

    @Test func encodingOmitsUnknownFieldsInsteadOfWritingNull() throws {
        let when = try date("2026-11-10T14:00:30.250Z")
        let data = try RelayJSON.encoder().encode(RelayMessage.update(vesselTarget(6, timestamp: when)))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "update")
        let target = try #require(json["target"] as? [String: Any])
        #expect(Set(target.keys) == ["id", "kind", "source", "lat", "lon", "timestamp", "vessel"])
        #expect(target["kind"] as? String == "vessel")
        #expect(target["timestamp"] as? String == "2026-11-10T14:00:30.250Z")
        let vessel = try #require(target["vessel"] as? [String: Any])
        #expect(Set(vessel.keys) == ["mmsi"])
    }

    @Test func encodingAnUndergroundTrainOmitsStretchButKeepsUnderground() throws {
        let when = try date("2026-11-10T14:12:00.000Z")
        let data = try RelayJSON.encoder().encode(RelayMessage.update(trainTarget("x", stretch: nil, timestamp: when)))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let target = try #require(json["target"] as? [String: Any])
        let train = try #require(target["train"] as? [String: Any])
        #expect(Set(train.keys) == ["route", "direction", "underground", "altitudeEstimated"])
        #expect(train["underground"] as? Bool == true)
    }
}
