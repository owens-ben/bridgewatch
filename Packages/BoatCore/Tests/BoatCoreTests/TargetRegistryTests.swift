import Foundation
import Testing
@testable import BoatCore

@Suite struct TargetRegistryTests {
    let t0 = Date(timeIntervalSince1970: 1_794_319_200) // 2026-11-10T14:00:00Z

    func vessel(_ mmsi: Int, at seconds: TimeInterval = 0, name: String? = nil, lat: Double = 40.705,
                speed: Double? = nil) -> Target {
        vesselTarget(mmsi, name: name, lat: lat, speed: speed, timestamp: t0.addingTimeInterval(seconds))
    }

    func train(_ trip: String, at seconds: TimeInterval = 0) -> Target {
        trainTarget(trip, timestamp: t0.addingTimeInterval(seconds))
    }

    func underground(_ trip: String, at seconds: TimeInterval = 0) -> Target {
        trainTarget(trip, route: "F", stretch: nil, timestamp: t0.addingTimeInterval(seconds))
    }

    func registry(_ message: RelayMessage...) -> TargetRegistry {
        var registry = TargetRegistry()
        for message in message { registry.apply(message) }
        return registry
    }

    // MARK: Messages

    @Test func updateAddsTargetsOfBothKinds() {
        let registry = registry(.update(vessel(1)), .update(train("a")))
        #expect(registry.count == 2)
        #expect(registry.vessels.map(\.mmsi) == [1])
        #expect(registry.trains.map(\.id) == ["train:nyct:a"])
        #expect(registry["vessel:1"] == vessel(1))
        #expect(registry["vessel:2"] == nil)
    }

    @Test func updateReplacesTheTargetWithoutMerging() {
        let registry = registry(
            .update(vessel(1, at: 0, name: "HARBOR LARK", lat: 40.70, speed: 10)),
            // The relay sends full state: what this one omits is gone, and nothing keeps the old position.
            .update(vessel(1, at: 5, lat: 40.71)))
        #expect(registry.count == 1)
        let vessel = try! #require(registry.vessels.first)
        #expect(vessel.name == nil)
        #expect(vessel.sog == nil)
        #expect(vessel.latitude == 40.71)
        #expect(vessel.lastSeen == t0.addingTimeInterval(5))
    }

    @Test func removeDeletesTheTarget() {
        var registry = registry(.update(vessel(1)), .update(vessel(2)), .update(train("a")))
        registry.apply(.remove(id: "vessel:1"))
        registry.apply(.remove(id: "train:nyct:a"))
        #expect(registry.vessels.map(\.mmsi) == [2])
        #expect(registry.trains.isEmpty)
    }

    @Test func removeOfAnUnknownIDChangesNothing() {
        var registry = registry(.update(vessel(1)))
        registry.apply(.remove(id: "vessel:2"))
        registry.apply(.remove(id: "nonsense"))
        #expect(registry.vessels.map(\.mmsi) == [1])
    }

    @Test func snapshotReplacesEverything() {
        let registry = registry(
            .update(vessel(1)), .update(vessel(2)), .update(train("a")),
            .snapshot([vessel(2, at: 10), vessel(9, at: 10), train("b", at: 10), underground("c", at: 10)]))
        #expect(registry.vessels.map(\.mmsi) == [2, 9])
        #expect(registry.trains.map(\.id) == ["train:nyct:b", "train:nyct:c"])
    }

    @Test func undergroundTrainsAreHeldLikeAnyOther() {
        var registry = registry(.update(underground("a")), .update(train("b")))
        #expect(registry.trains.map(\.id) == ["train:nyct:a", "train:nyct:b"])
        #expect(registry["train:nyct:a"]?.train?.underground == true)
        registry.prune(now: t0.addingTimeInterval(61))
        #expect(registry.trains.isEmpty)
    }

    @Test func emptySnapshotEmptiesTheRegistry() {
        let registry = registry(.update(vessel(1)), .update(train("a")), .snapshot([]))
        #expect(registry.count == 0)
        #expect(registry == TargetRegistry())
    }

    // MARK: Unknown and unusable targets

    @Test func unknownKindsAreIgnored() {
        let aircraft = Target(id: "aircraft:abc", kind: .unknown("aircraft"), source: "opensky", lat: 40.7, lon: -73.99,
                              altitude: 1000, timestamp: t0)
        var registry = registry(.update(aircraft), .snapshot([vessel(1), aircraft]))
        #expect(registry.count == 1)
        #expect(registry["aircraft:abc"] == nil)
        registry.apply(.update(aircraft))
        #expect(registry.count == 1)
        #expect(registry.vessels.map(\.mmsi) == [1])
        #expect(registry.trains.isEmpty)
    }

    @Test func targetsMissingTheirKindObjectAreNotHeld() {
        let noVessel = Target(id: "vessel:3", kind: .vessel, source: "aisstream", lat: 40.7, lon: -73.99, timestamp: t0)
        let noTrain = Target(id: "train:nyct:x", kind: .train, source: "mta-subway", lat: 40.7, lon: -73.99, timestamp: t0)
        var registry = registry(.snapshot([noVessel, noTrain, vessel(1)]))
        registry.apply(.update(noVessel))
        #expect(registry.targets == [vessel(1)])
        // A malformed update doesn't add a target, and removes the good one held under its id: it was meant to
        // replace that state, so the old state is out of date (D6).
        registry.apply(.update(Target(id: "vessel:1", kind: .vessel, source: "aisstream", lat: 0, lon: 0, timestamp: t0)))
        #expect(registry.targets.isEmpty)
    }

    // MARK: Lists

    @Test func vesselsAreSortedByMMSIAndTrainsByID() {
        var registry = TargetRegistry()
        for mmsi in [30, 10, 20] { registry.apply(.update(vessel(mmsi))) }
        for trip in ["c", "a", "b"] { registry.apply(.update(train(trip))) }
        #expect(registry.vessels.map(\.mmsi) == [10, 20, 30])
        #expect(registry.trains.map(\.id) == ["train:nyct:a", "train:nyct:b", "train:nyct:c"])
        #expect(registry.targets.map(\.id) == [
            "train:nyct:a", "train:nyct:b", "train:nyct:c", "vessel:10", "vessel:20", "vessel:30",
        ])
    }

    @Test func vesselsAreTheVesselTargetsAsBoats() {
        let target = vesselTarget(7, name: "WREN", shipType: 36, lat: 40.7029, lon: -73.9971, speed: 4.1, course: 80,
                                  heading: 79, timestamp: t0)
        let registry = registry(.update(target), .update(train("a")))
        #expect(registry.vessels == [Vessel(target)!])
    }

    // MARK: Pruning

    @Test func pruneDropsVesselsOlderThanTenMinutes() {
        var registry = registry(.update(vessel(1, at: 0)), .update(vessel(2, at: 0.001)), .update(vessel(3, at: 300)))
        registry.prune(now: t0.addingTimeInterval(600.001))
        // Exactly 600 s old is kept; anything older is dropped.
        #expect(registry.vessels.map(\.mmsi) == [2, 3])
    }

    @Test func pruneDropsTrainsOlderThanAMinute() {
        var registry = registry(.update(train("a", at: 0)), .update(train("b", at: 0.001)), .update(train("c", at: 30)))
        registry.prune(now: t0.addingTimeInterval(60.001))
        #expect(registry.trains.map(\.id) == ["train:nyct:b", "train:nyct:c"])
    }

    @Test func eachKindKeepsItsOwnMaxAge() {
        var registry = registry(.update(vessel(1, at: 0)), .update(train("a", at: 0)))
        registry.prune(now: t0.addingTimeInterval(120))
        #expect(registry.vessels.map(\.mmsi) == [1])
        #expect(registry.trains.isEmpty)
        registry.prune(now: t0.addingTimeInterval(601))
        #expect(registry.count == 0)
    }

    @Test func pruneKeepsTargetsFromTheFuture() {
        // A relay clock a little ahead of the phone's must not drop what it just sent.
        var registry = registry(.update(vessel(1, at: 20)), .update(train("a", at: 20)))
        registry.prune(now: t0)
        #expect(registry.count == 2)
    }
}
