import Foundation
import Testing
@testable import BoatCore

/// Runs the relay's generated fixtures (relay/PROTOCOL.md, "Fixtures"; regenerate with `npm run fixtures`) through
/// the Swift decoding and registry. The stream is what a /v2/targets client gets from the relay's own hub while the
/// synthetic AIS sample plays and the synthetic subway rounds are published; the app must end up with the relay's
/// own snapshot. The counts below follow from the scenario in relay/src/tools/subway-scenario.ts (a relay test derives
/// the same numbers from it): 69 trains placed in round 0, 65 in round 1 and 68 in round 2 (54 underground, 14 above
/// ground); each later round updates every train it places (65 + 68 = 133) and removes the ones the previous round
/// placed and it doesn't (6 trains); the one vessel swept at the end makes 7 removes.
@Suite struct RelayFixtureTests {
    /// The clock the relay used for relay-v2-snapshot.json.
    let snapshotTime = try! date("2026-11-10T14:12:00.000Z")

    func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func stream() throws -> [RelayMessage] {
        try RelayJSON.decoder().decode([RelayMessage].self, from: fixture("relay-v2-stream"))
    }

    func snapshotTargets() throws -> [Target] {
        guard case .snapshot(let targets) = try RelayMessage.decode(fixture("relay-v2-snapshot")) else {
            Issue.record("relay-v2-snapshot.json is not a snapshot")
            return []
        }
        return targets
    }

    func applied(_ messages: [RelayMessage]) -> TargetRegistry {
        var registry = TargetRegistry()
        for message in messages { registry.apply(message) }
        registry.prune(now: snapshotTime)
        return registry
    }

    // MARK: Decoding

    @Test func snapshotFixtureDecodesEveryTarget() throws {
        let targets = try snapshotTargets()
        // Every target in the file decodes: none is skipped.
        let raw = try #require(
            JSONSerialization.jsonObject(with: fixture("relay-v2-snapshot")) as? [String: Any])
        #expect(targets.count == (raw["targets"] as? [Any])?.count)
        #expect(targets.count == 72)
        #expect(targets.filter { $0.kind == .vessel }.count == 4)
        #expect(targets.filter { $0.kind == .train }.count == 68)
    }

    @Test func streamFixtureDecodesEveryMessage() throws {
        let messages = try stream()
        #expect(messages.count == 154)
        guard case .snapshot(let first) = messages.first else {
            Issue.record("the stream doesn't start with a snapshot")
            return
        }
        // The client connected while only trains were on the relay.
        #expect(first.count == 69)
        #expect(first.allSatisfy { $0.kind == .train })
        let updates = messages.compactMap { if case .update(let target) = $0 { target } else { nil } }
        #expect(updates.filter { $0.kind == .vessel }.count == 13)
        #expect(updates.filter { $0.kind == .train }.count == 133)
        let removes = messages.compactMap { if case .remove(let id) = $0 { id } else { nil } }
        #expect(removes.count == 7)
        // 367000003 went quiet at 14:00:30: the relay's last sweep removes it.
        #expect(messages.last == .remove(id: "vessel:367000003"))
    }

    // MARK: Registry

    @Test func streamAppliedToAnEmptyRegistryGivesTheRelaySnapshot() throws {
        let registry = applied(try stream())
        let relaySnapshot = try snapshotTargets()
        #expect(registry.targets == relaySnapshot)
        #expect(registry.vessels == relaySnapshot.compactMap(Vessel.init).sorted { $0.mmsi < $1.mmsi })
        #expect(registry.trains == relaySnapshot.compactMap(Train.init))
    }

    @Test func snapshotFixtureAppliedAloneGivesTheSameState() throws {
        let registry = applied([.snapshot(try snapshotTargets())])
        #expect(registry == applied(try stream()))
    }

    @Test func pruneAloneAgreesWithTheRelaysVesselSweep() throws {
        // Without the relay's final remove, the app's own safety net drops the same vessel.
        let withoutSweep = try stream().dropLast()
        #expect(applied(Array(withoutSweep)) == applied(try stream()))
    }

    @Test func vesselsMatchTheSample() throws {
        let registry = applied(try stream())

        // 367000003 was last seen 11.5 minutes before the snapshot.
        #expect(registry.vessels.map(\.mmsi) == [367000001, 367000002, 367000004, 367000005])

        let vessels = Dictionary(uniqueKeysWithValues: registry.vessels.map { ($0.mmsi, $0) })

        let lark = try #require(vessels[367000001])
        #expect(lark.name == "HARBOR LARK")
        #expect(lark.shipType == 60)
        #expect(lark.latitude == 40.7101)
        #expect(lark.heading == 63)
        #expect(lark.positionTimestamp == (try date("2026-11-10T14:11:00.999Z")))

        // The out-of-order 14:05:30 report arrives last but must not move the tug, and its target keeps the time of
        // the position it shows.
        let tug = try #require(vessels[367000002])
        #expect(tug.name == "ANNABEL K")
        #expect(tug.latitude == 40.706)
        #expect(tug.positionTimestamp == (try date("2026-11-10T14:06:00.000Z")))
        #expect(tug.lastSeen == tug.positionTimestamp)

        // All motion fields were "not available".
        let unknown = try #require(vessels[367000004])
        #expect(unknown.name == nil)
        #expect(unknown.sog == nil)
        #expect(unknown.cog == nil)
        #expect(unknown.heading == nil)

        // Static data arrived before the first position and was held by the relay. The static message (14:09) is
        // older than the position (14:10): the target's timestamp is the position's.
        let taxi = try #require(vessels[367000005])
        #expect(taxi.name == "WATER TAXI 7")
        #expect(taxi.sog == 18)
        #expect(taxi.positionTimestamp == (try date("2026-11-10T14:10:00.000Z")))
    }

    // MARK: Trains

    @Test func trainsHaveRouteDirectionAndLevel() throws {
        let trains = applied(try stream()).targets.filter { $0.kind == .train }
        #expect(trains.count == 68)

        let routesByStretch: [String: Set<String>] = [
            "manhattan-bridge": ["B", "D", "N", "Q"],
            "williamsburg-bridge": ["J", "M", "Z"],
            "culver-viaduct": ["F", "FX", "G"],
            "franklin-av": ["FS"],
        ]
        for train in trains {
            let details = try #require(train.train)
            #expect(train.id.hasPrefix("train:nyct:"))
            #expect(train.source == "mta-subway")
            #expect(train.name == nil)
            // Placed along the track: height and direction of travel, but nowhere a bow points.
            #expect(train.altitude != nil)
            #expect(train.course != nil)
            #expect(train.speed != nil)
            #expect(train.heading == nil)
            if details.underground {
                #expect(details.stretch == nil, "\(train.id)")
                // The depth model's rail altitude (relay/PROTOCOL.md, "Levels"), every one of them estimated.
                let altitude = try #require(train.altitude, "\(train.id)")
                #expect(altitude.isFinite && (-45...35).contains(altitude), "\(train.id)")
                #expect(details.altitudeEstimated == true, "\(train.id)")
            } else {
                let stretch = try #require(details.stretch, "\(train.id)")
                #expect(routesByStretch[stretch]?.contains(details.route) == true, "\(train.id): \(details)")
                #expect((train.altitude ?? 0) > 0, "\(train.id)")
                // Lidar-measured except the Franklin Av shuttle's embankment.
                #expect(details.altitudeEstimated == (stretch == "franklin-av"), "\(train.id)")
            }
        }
        #expect(trains.filter { $0.train?.underground == true }.count == 54)
        #expect(trains.filter { $0.train?.underground == false }.count == 14)
        // The modelled depths vary (the old relay put every underground train at a flat -10 m); the F in the middle of
        // the East River tunnel is at the tube's low point.
        let depths = Set(trains.filter { $0.train?.underground == true }.compactMap(\.altitude))
        #expect(depths.count > 10)
        #expect(depths.contains { $0 < -15 })
    }

    @Test func trainsAreNotBoats() throws {
        var registry = TargetRegistry()
        registry.apply(.snapshot(try snapshotTargets().filter { $0.kind == .train }))
        #expect(registry.vessels.isEmpty)
        #expect(registry.trains.count == 68)
    }

    @Test func trainsAreGoneOnceTheirPositionIsAMinuteOld() throws {
        var registry = applied(try stream())
        let newest = try #require(registry.trains.map(\.timestamp).max())
        registry.prune(now: newest.addingTimeInterval(TargetRegistry.trainMaxAge))
        #expect(!registry.trains.isEmpty)
        registry.prune(now: newest.addingTimeInterval(TargetRegistry.trainMaxAge + 0.001))
        #expect(registry.trains.isEmpty)
    }
}
