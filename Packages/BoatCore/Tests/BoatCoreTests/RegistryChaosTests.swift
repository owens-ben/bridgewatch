import Foundation
import Testing
@testable import BoatCore

/// `TargetRegistry` under random message sequences, checked against a model of the rules in its doc comments, plus
/// the cases the chaos suite found (D1, D4, D5, D6), now asserting the fixed behaviour.
@Suite(.timeLimit(.minutes(1))) struct RegistryChaosTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A model of what the registry should hold: a target is kept when its kind has the object it needs and a boat
    /// or train has a position that can be real, keyed by id. Timestamps are held at most `maxFutureLead` past the
    /// receive time; the newest (held) timestamp per id wins, a tie going to the later message. An update that can't
    /// be used and isn't out of date removes its id; in a snapshot it's skipped.
    struct Model {
        var held: [String: Target] = [:]

        static func isUsable(_ target: Target) -> Bool {
            switch target.kind {
            case .vessel: return target.vessel != nil && abs(target.lat) <= 90 && abs(target.lon) <= 180
            case .train: return target.train != nil && Train(target) != nil
            case .unknown: return false
            }
        }

        static func clamped(_ target: Target, receivedAt: Date) -> Target {
            var target = target
            target.timestamp = min(target.timestamp, receivedAt.addingTimeInterval(TargetRegistry.maxFutureLead))
            return target
        }

        mutating func apply(_ message: RelayMessage, receivedAt: Date) {
            switch message {
            case .snapshot(let targets):
                held = [:]
                for target in targets.map({ Self.clamped($0, receivedAt: receivedAt) }) where Self.isUsable(target) {
                    if let old = held[target.id], old.timestamp > target.timestamp { continue }
                    held[target.id] = target
                }
            case .update(let target):
                let target = Self.clamped(target, receivedAt: receivedAt)
                if let old = held[target.id], old.timestamp > target.timestamp { return }
                held[target.id] = Self.isUsable(target) ? target : nil
            case .remove(let id):
                held[id] = nil
            }
        }
    }

    /// A random target for a pool of `ids`: any kind (including an id that changes kind), timestamps from decades
    /// ago to decades ahead, sometimes without the object its kind needs, sometimes a hostile position.
    static func randomTarget(_ rng: inout SplitMix64, ids: Int) -> Target {
        let n = rng.int(0...ids)
        let id = rng.pick(["vessel:\(n)", "train:nyct:\(n)", "aircraft:\(n)", "\(n)", ""])
        let offsets: [TimeInterval] = [0, -5, -30, -59, -61, -601, -3_600, 5, 3_600, -86_400 * 365 * 30, 86_400 * 365 * 30, -1e10, 1e10]
        let stamp = now.addingTimeInterval(rng.pick(offsets) + rng.double(-2 ... 2))
        let lat = rng.chance(0.1) ? rng.pick([91, -91, 1e300, 0, -0.0]) : rng.double(40.6...40.8)
        let lon = rng.chance(0.1) ? rng.pick([181, -181, 1e300, 0, -0.0]) : rng.double(-74.1 ... -73.9)
        let kind: TargetKind = rng.pick([.vessel, .vessel, .train, .train, .unknown("aircraft"), .unknown("")])
        // The object may be the wrong one for the kind, or missing.
        let vessel = rng.chance(0.85) ? VesselDetails(mmsi: rng.int(0...5), shipType: rng.pick([nil, 0, 60, 99, 1000, -1])) : nil
        let train = rng.chance(0.85)
            ? TrainDetails(route: rng.pick(["Q", "6X", "", "ZZZ"]), direction: rng.pick([.north, .south]),
                           stretch: rng.pick([nil, "manhattan-bridge", "nowhere"]), underground: rng.chance(0.5))
            : nil
        return Target(id: id, kind: kind, source: "chaos", name: rng.chance(0.3) ? nil : "N\(n)", lat: lat, lon: lon,
                      altitude: rng.pick([nil, -10, 20, 1e300]), speed: rng.pick([nil, 0, 5, -3, 500]),
                      course: rng.pick([nil, 0, 90, -720]), heading: nil, timestamp: stamp,
                      vessel: vessel, train: train)
    }

    static func randomMessage(_ rng: inout SplitMix64, ids: Int) -> RelayMessage {
        switch rng.int(0...9) {
        case 0:
            return .snapshot((0..<rng.pick([0, 1, 5, 40])).map { _ in randomTarget(&rng, ids: ids) })
        case 1, 2: return .remove(id: rng.pick(["vessel:\(rng.int(0...ids))", "train:nyct:\(rng.int(0...ids))", "never-seen", ""]))
        default: return .update(randomTarget(&rng, ids: ids))
        }
    }

    func checkInvariants(_ registry: TargetRegistry, _ model: Model, _ context: Comment) {
        let ids = registry.targets.map(\.id)
        #expect(registry.count == model.held.count, context)
        #expect(Set(ids).count == ids.count, context)
        #expect(Set(ids) == Set(model.held.keys), context)
        #expect(ids == ids.sorted(), context)
        for id in ids { #expect(registry[id] == model.held[id], context) }
        let vesselTargets = registry.targets.filter { $0.kind == .vessel }
        let trainTargets = registry.targets.filter { $0.kind == .train }
        // One vessel per MMSI (F14), whatever the target ids.
        #expect(registry.vessels.count == Set(vesselTargets.compactMap { $0.vessel?.mmsi }).count, context)
        #expect(registry.trains.count == trainTargets.count, context)
        #expect(vesselTargets.count + trainTargets.count == registry.count, context)
        #expect(registry.vessels.map(\.mmsi) == registry.vessels.map(\.mmsi).sorted(), context)
        #expect(registry.trains.map(\.id) == registry.trains.map(\.id).sorted(), context)
        #expect(registry.targets.allSatisfy { Model.isUsable($0) }, context)
    }

    @Test func randomSequencesKeepTheInvariants() {
        var rng = Chaos.rng("randomSequencesKeepTheInvariants")
        for sequence in 0..<150 {
            var registry = TargetRegistry(), model = Model()
            var log: [String] = []
            for step in 0..<rng.int(1...60) {
                let message = Self.randomMessage(&rng, ids: rng.pick([2, 8, 30]))
                log.append(String(describing: message).prefix(120).description)
                registry.apply(message, receivedAt: Self.now)
                model.apply(message, receivedAt: Self.now)
                checkInvariants(registry, model, Chaos.context("registry", iteration: sequence * 1000 + step, log.suffix(3).joined(separator: " | ")))
            }
            // Prune removes exactly the over-age ones, at any time of day.
            for later in [0, 30, 61, 601, 100_000, -100_000].map({ Self.now.addingTimeInterval($0) }) {
                var pruned = registry
                pruned.prune(now: later)
                var expected = Set<String>()
                for target in registry.targets {
                    let maxAge = target.kind == .vessel ? TargetRegistry.vesselMaxAge : TargetRegistry.trainMaxAge
                    if later.timeIntervalSince(target.timestamp) <= maxAge { expected.insert(target.id) }
                }
                #expect(Set(pruned.targets.map(\.id)) == expected,
                        Chaos.context("prune", iteration: sequence, "later=\(later.timeIntervalSince(Self.now)) ids=\(registry.targets.map(\.id))"))
                #expect(pruned.count == expected.count)
                for target in pruned.targets { #expect(pruned[target.id] == target) }
            }
        }
    }

    @Test func aSnapshotReplacesEverythingAndLaterDuplicatesWin() {
        var rng = Chaos.rng("aSnapshotReplacesEverythingAndLaterDuplicatesWin")
        for iteration in 0..<300 {
            var registry = TargetRegistry()
            for _ in 0..<rng.int(0...10) { registry.apply(.update(Self.randomTarget(&rng, ids: 6)), receivedAt: Self.now) }
            // Duplicate ids in one snapshot: the newest usable one is held, whatever the order.
            let targets = (0..<rng.int(0...30)).map { _ in Self.randomTarget(&rng, ids: 4) }
            registry.apply(.snapshot(targets), receivedAt: Self.now)
            var model = Model()
            model.apply(.snapshot(targets), receivedAt: Self.now)
            var reversed = TargetRegistry()
            reversed.apply(.snapshot(targets.reversed()), receivedAt: Self.now)
            // The same ids and timestamps either way (on a tie the content can differ: the later one wins).
            #expect(reversed.targets.map(\.id) == registry.targets.map(\.id))
            #expect(reversed.targets.map(\.timestamp) == registry.targets.map(\.timestamp))
            checkInvariants(registry, model, Chaos.context("snapshot", iteration: iteration, targets.map(\.id).joined(separator: ",")))
        }
    }

    @Test func aBigSnapshotAndItsPrune() {
        var rng = Chaos.rng("aBigSnapshotAndItsPrune")
        var targets: [Target] = []
        for i in 0..<5_000 {
            let age = TimeInterval(i % 1_300) - 650
            targets.append(i % 3 == 0
                ? trainTarget("trip\(i)", stretch: i % 2 == 0 ? nil : "manhattan-bridge", timestamp: Self.now.addingTimeInterval(-age / 10))
                : vesselTarget(1_000 + i, lat: rng.double(40.6...40.8), lon: rng.double(-74.1 ... -73.9), speed: rng.double(0...30),
                               course: rng.double(0...360), timestamp: Self.now.addingTimeInterval(-age)))
        }
        var registry = TargetRegistry()
        registry.apply(.snapshot(targets))
        #expect(registry.count == 5_000)
        #expect(registry.vessels.count + registry.trains.count == 5_000)
        let list = VesselList(vessels: registry.vessels, observer: nil, now: Self.now)
        #expect(list.rows.count <= registry.vessels.count)
        registry.prune(now: Self.now)
        for target in registry.targets {
            let maxAge = target.kind == .vessel ? TargetRegistry.vesselMaxAge : TargetRegistry.trainMaxAge
            #expect(Self.now.timeIntervalSince(target.timestamp) <= maxAge)
        }
        let expected = targets.filter {
            Self.now.timeIntervalSince($0.timestamp) <= ($0.kind == .vessel ? TargetRegistry.vesselMaxAge : TargetRegistry.trainMaxAge)
        }.count
        #expect(registry.count == expected)
        // Decades later: all gone.
        registry.prune(now: Self.now.addingTimeInterval(86_400 * 365 * 40))
        #expect(registry.count == 0)
    }

    @Test func anIdSwitchingKind() {
        let t = Self.now
        var registry = TargetRegistry()
        registry.apply(.update(vesselTarget(7, timestamp: t)))
        #expect(registry.vessels.count == 1 && registry.trains.isEmpty)
        // Same id, now a train: replaces the vessel.
        var asTrain = trainTarget("7", timestamp: t)
        asTrain.id = "vessel:7"
        registry.apply(.update(asTrain))
        #expect(registry.count == 1 && registry.vessels.isEmpty && registry.trains.count == 1)
        // Same id, now a kind this version doesn't know: the train it replaces is wrong now, so it's removed (D6).
        var asAircraft = asTrain
        asAircraft.kind = .unknown("aircraft")
        registry.apply(.update(asAircraft))
        #expect(registry.count == 0)
        // The same for a vessel without its `vessel` object and a train off the planet.
        registry.apply(.update(vesselTarget(7, timestamp: t)))
        var broken = vesselTarget(7, timestamp: t)
        broken.vessel = nil
        registry.apply(.update(broken))
        #expect(registry.count == 0)
        registry.apply(.update(asTrain))
        #expect(registry.trains.count == 1)
        var offThePlanet = asTrain
        offThePlanet.lat = 1e300
        registry.apply(.update(offThePlanet))
        #expect(registry.count == 0)
        // An unusable update that is out of date (older than what's held) is ignored like any other.
        registry.apply(.update(vesselTarget(7, timestamp: t)))
        var olderBroken = vesselTarget(7, timestamp: t.addingTimeInterval(-60))
        olderBroken.vessel = nil
        registry.apply(.update(olderBroken))
        #expect(registry.vessels.count == 1)
        // In a snapshot an unusable target is skipped: the usable one with its id is held.
        registry.apply(.snapshot([vesselTarget(7, timestamp: t), broken]))
        #expect(registry.vessels.count == 1)
        registry.apply(.remove(id: "vessel:7"))
        #expect(registry.count == 0)
        registry.apply(.remove(id: "vessel:7"))
        registry.apply(.remove(id: ""))
        #expect(registry.count == 0)
    }

    // MARK: Found by the chaos suite, fixed

    /// D1 (fixed by F14): two target ids carrying the same MMSI (id `vessel:1` and `vessel:2`, both mmsi 5; outside
    /// the relay's contract) used to give two vessels with one `Vessel.id`. `registry.vessels` keeps one per MMSI, the
    /// newest position (on a tie, the lower target id).
    @Test func duplicateMMSIGivesOneVesselTheNewest() {
        var registry = TargetRegistry()
        var a = vesselTarget(5, name: "A", timestamp: Self.now)
        a.id = "vessel:1"
        var b = vesselTarget(5, name: "B", timestamp: Self.now.addingTimeInterval(10))
        b.id = "vessel:2"
        registry.apply(.snapshot([a, b]), receivedAt: Self.now)
        #expect(registry.count == 2)
        #expect(registry.vessels.count == 1)
        #expect(registry.vessels.first?.name == "B")
        let list = VesselList(vessels: registry.vessels, observer: nil, now: Self.now)
        #expect(list.rows.count == 1 && list.row(mmsi: 5)?.vessel.name == "B")
        // A tie goes to the lower target id.
        b.timestamp = Self.now
        registry.apply(.snapshot([b, a]), receivedAt: Self.now)
        #expect(registry.vessels.map(\.name) == ["A"])
    }

    /// D4 (fixed by F12): a timestamp far in the future (year 9999) used to keep a target live and unpruned forever.
    /// It's held at receipt + `maxFutureLead`, so prune drops it within that plus its max age.
    @Test func futureTimestampIsPrunedEventually() throws {
        let future = Self.now.addingTimeInterval(86_400 * 365 * 8_000)
        var registry = TargetRegistry()
        registry.apply(.update(vesselTarget(1, timestamp: future)), receivedAt: Self.now)
        registry.apply(.update(trainTarget("t", timestamp: future)), receivedAt: Self.now)
        #expect(registry.count == 2)
        let held = Self.now.addingTimeInterval(TargetRegistry.maxFutureLead)
        #expect(registry.targets.allSatisfy { $0.timestamp == held })
        // Live meanwhile (age clamped at 0) ...
        let vessel = try #require(registry.vessels.first)
        let row = VesselRow(vessel: vessel, observer: nil, now: Self.now)
        #expect(row.ageSeconds == 0 && row.freshness == .live && row.ageText == "0 s ago")
        // ... the train gone a minute past the lead, the boat ten minutes past it.
        registry.prune(now: held.addingTimeInterval(TargetRegistry.trainMaxAge + 1))
        #expect(registry.trains.isEmpty && registry.vessels.count == 1)
        registry.prune(now: held.addingTimeInterval(TargetRegistry.vesselMaxAge + 1))
        #expect(registry.count == 0)
    }

    /// D5: an out-of-order (older) update used to replace the newer state it arrived after, moving a boat back to
    /// where it was. The newer timestamp is kept, in updates and within a snapshot whatever the order; an equal
    /// timestamp applies (a re-send with new fields).
    @Test func olderUpdateIsIgnored() {
        var registry = TargetRegistry()
        let newer = vesselTarget(9, lat: 40.71, lon: -74.0, speed: 5, course: 10, timestamp: Self.now)
        let older = vesselTarget(9, lat: 40.70, lon: -73.99, speed: 4, course: 20, timestamp: Self.now.addingTimeInterval(-300))
        registry.apply(.update(newer), receivedAt: Self.now)
        registry.apply(.update(older), receivedAt: Self.now)
        #expect(registry["vessel:9"] == newer)
        #expect(registry.vessels.first?.lastSeen == newer.timestamp)
        // The same time with new fields: applied.
        var resent = newer
        resent.name = "RENAMED"
        registry.apply(.update(resent), receivedAt: Self.now)
        #expect(registry["vessel:9"] == resent)
        // A snapshot with both: the newer one, in either order.
        registry.apply(.snapshot([newer, older]), receivedAt: Self.now)
        #expect(registry["vessel:9"] == newer)
        registry.apply(.snapshot([older, newer]), receivedAt: Self.now)
        #expect(registry["vessel:9"] == newer)
        // A snapshot still replaces everything: an older position after a reconnect is what the relay has now.
        registry.apply(.snapshot([older]), receivedAt: Self.now)
        #expect(registry["vessel:9"] == older)
    }

    /// D5 with F12: the comparison uses the held (clamped) timestamps. Two updates both far in the future are held at
    /// their own receipt + lead, so the later-received one (held later) wins; an update an hour ahead received at the
    /// same time as one a year ahead ties with it (both held at receipt + lead), and the later message wins.
    @Test func newestWinsComparesClampedTimestamps() {
        var registry = TargetRegistry()
        let lead = TargetRegistry.maxFutureLead
        let yearAhead = vesselTarget(3, name: "YEAR", timestamp: Self.now.addingTimeInterval(86_400 * 365))
        let hourAhead = vesselTarget(3, name: "HOUR", timestamp: Self.now.addingTimeInterval(lead + 3_600))
        registry.apply(.update(yearAhead), receivedAt: Self.now)
        registry.apply(.update(hourAhead), receivedAt: Self.now)
        #expect(registry["vessel:3"]?.name == "HOUR")
        // A real report a minute later than the held time replaces the clamped one.
        let real = vesselTarget(3, name: "REAL", timestamp: Self.now.addingTimeInterval(lead + 60))
        registry.apply(.update(real), receivedAt: Self.now.addingTimeInterval(120))
        #expect(registry["vessel:3"]?.name == "REAL")
        // One before the held time is out of date.
        registry.apply(.update(vesselTarget(3, name: "LATE", timestamp: Self.now)), receivedAt: Self.now.addingTimeInterval(180))
        #expect(registry["vessel:3"]?.name == "REAL")
    }
}
