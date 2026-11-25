import Foundation
import Testing
@testable import BoatCore

struct DataFreshnessTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func freshness(boat: TimeInterval? = nil, train: TimeInterval? = nil) -> DataFreshness {
        DataFreshness(newestBoat: boat.map { now.addingTimeInterval(-$0) },
                      newestTrain: train.map { now.addingTimeInterval(-$0) })
    }

    @Test func trainsAtTheThreshold() {
        #expect(freshness(train: 59).notice(now: now, isLive: true) == nil)
        #expect(freshness(train: 60).notice(now: now, isLive: true) == nil)
        #expect(freshness(train: 61).notice(now: now, isLive: true) == "Trains last updated 1 min ago")
        #expect(freshness(train: 120).notice(now: now, isLive: true) == "Trains last updated 2 min ago")
    }

    @Test func boatsAtTheThreshold() {
        #expect(freshness(boat: 190).notice(now: now, isLive: true) == nil)
        #expect(freshness(boat: 300).notice(now: now, isLive: true) == nil)
        #expect(freshness(boat: 301).notice(now: now, isLive: true) == "Boats last updated 5 min ago")
        #expect(freshness(boat: 420).notice(now: now, isLive: true) == "Boats last updated 7 min ago")
    }

    @Test func bothLate() {
        #expect(freshness(boat: 420, train: 120).notice(now: now, isLive: true)
                == "Trains last updated 2 min ago. Boats last updated 7 min ago")
    }

    @Test func onlyWhileClaimingToBeLive() {
        #expect(freshness(boat: 900, train: 900).notice(now: now, isLive: false) == nil)
    }

    @Test func nothingReceivedMeansNothingToSay() {
        #expect(freshness().notice(now: now, isLive: true) == nil)
        #expect(freshness(boat: 10).notice(now: now, isLive: true) == nil)
    }

    @Test func trainsTurnedOffAreNotMentioned() {
        #expect(freshness(train: 600).notice(now: now, isLive: true, showTrains: false) == nil)
    }

    @Test func spokenInFull() {
        #expect(freshness(train: 120).spokenNotice(now: now, isLive: true) == "Trains last updated 2 minutes ago")
        #expect(freshness(train: 60).spokenNotice(now: now, isLive: true) == nil)
    }

    @Test func observeKeepsTheNewestPerKind() {
        var f = DataFreshness()
        func target(_ id: String, _ kind: TargetKind, _ age: TimeInterval) -> Target {
            Target(id: id, kind: kind, source: "x", lat: 40.7, lon: -74, timestamp: now.addingTimeInterval(-age))
        }
        f.observe(.snapshot([target("train:a", .train, 200), target("vessel:1", .vessel, 30)]), receivedAt: now)
        f.observe(.update(target("train:b", .train, 100)), receivedAt: now)
        f.observe(.update(target("train:c", .train, 150)), receivedAt: now)
        f.observe(.remove(id: "train:b"), receivedAt: now)
        #expect(f.newestTrain == now.addingTimeInterval(-100))
        #expect(f.newestBoat == now.addingTimeInterval(-30))
    }

    @Test func aClockAheadDoesNotHideALateFeed() {
        var f = DataFreshness()
        let ahead = Target(id: "train:a", kind: .train, source: "x", lat: 40.7, lon: -74,
                           timestamp: now.addingTimeInterval(600))
        f.observe(.update(ahead), receivedAt: now.addingTimeInterval(-300))
        #expect(f.notice(now: now, isLive: true) == "Trains last updated 5 min ago")
    }
}
