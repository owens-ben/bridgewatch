import BoatCore
import Foundation
import Testing
@testable import BoatAIS

/// The UI tests' scripted feed (`BOATAR_SCRIPTED_FEED`): a timeline of connects, drops, messages and generated crowds.
@Suite(.timeLimit(.minutes(1)))
struct ScriptedVesselFeedTests {
    @Test func playsStepsInOrderAndRestampsByAge() async throws {
        let script = """
            [{"event":"connect"},
             {"message":\(snapshotFrame),"age":30},
             {"after":0.01,"frame":"not json"},
             {"after":0.01,"frame":\(String(data: try JSONEncoder().encode(removeFrame), encoding: .utf8)!)},
             {"after":0.01,"event":"disconnect"}]
            """
        let feed = try #require(ScriptedVesselFeed(json: script))
        let before = Date()
        let events = await collect(feed.events()) { $0.last == .disconnected }

        #expect(events.count == 5)
        #expect(Array(events.prefix(2)) == [.connecting, .connected])
        guard case .message(.snapshot(let targets)) = events[2] else {
            Issue.record("expected the snapshot, got \(events[2])")
            return
        }
        // Restamped 30 s before the moment it was sent, not the fixture's 2026-11-10.
        let age = before.timeIntervalSince(try #require(targets.first).timestamp)
        #expect(abs(age - 30) < 5)
        // The undecodable frame is skipped; the remove frame decodes like the relay's.
        #expect(events[3] == .message(.remove(id: "vessel:1")))
        #expect(events[4] == .disconnected)
    }

    @Test func repeatsAStep() async throws {
        let feed = try #require(ScriptedVesselFeed(json: #"[{"event":"connect"},{"after":0.001,"event":"disconnect","repeat":3}]"#))
        let events = await collect(feed.events()) { $0.filter { $0 == .disconnected }.count == 3 }
        #expect(events == [.connecting, .connected, .disconnected, .disconnected, .disconnected])
    }

    /// S3's banner in a UI test: a relay that refuses the app, attempt after attempt, then accepts it.
    @Test func playsARefusedRelay() async throws {
        let feed = try #require(ScriptedVesselFeed(json: #"[{"event":"reject"},{"after":0.001,"event":"reject","repeat":2},{"after":0.001,"event":"connect"}]"#))
        let events = await collect(feed.events()) { $0.last == .connected }
        #expect(events == [.connecting, .rejected, .connecting, .rejected, .connecting, .rejected, .connecting, .connected])
    }

    @Test func generatesTheSameCrowdForASeed() throws {
        let spec = try RelayJSON.decoder().decode(
            ScriptedVesselFeed.Synthetic.self, from: Data(#"{"vessels":50,"trains":40,"nameLength":200,"seed":7}"#.utf8))
        let now = Date()
        let crowd = ScriptedVesselFeed.crowd(spec, now: now)

        #expect(crowd == ScriptedVesselFeed.crowd(spec, now: now))
        #expect(crowd.count == 90)
        #expect(Set(crowd.map(\.id)).count == 90)
        // Every generated target is one the app holds: inside the dev area, a valid boat or train.
        var registry = TargetRegistry()
        registry.apply(.snapshot(crowd))
        #expect(registry.vessels.count == 50)
        #expect(registry.trains.count == 40)
        let box = devBoundingBox
        #expect(crowd.allSatisfy { box.minLatitude...box.maxLatitude ~= $0.lat && box.minLongitude...box.maxLongitude ~= $0.lon })
        #expect(crowd.compactMap(\.name).allSatisfy { $0.count == 200 })
    }

    @Test func aScriptThatDoesNotParseIsNotUsed() {
        #expect(ScriptedVesselFeed(json: "[{]") == nil)
        let feed = FeedConfiguration.feed(environment: [FeedConfiguration.scriptedEnvironmentKey: "nope"], relayURL: nil)
        #expect(feed == nil)
    }
}

