import BoatCore
import Foundation
import Testing
@testable import BoatAIS

/// Tests for findings in docs/CRASH-HUNT.md. They were written failing (wrapped in `withKnownIssue`); each fix removed
/// its wrapper, so they now guard the fixes. More liveness cases are in LivenessTests.swift.
@Suite(.timeLimit(.minutes(1)))
struct FeedCrashHuntTests {
    /// F1. A connection that opens, delivers, then goes silent without failing (relay process wedged, Cloudflare
    /// tunnel stalled, a half-open TCP path after a network change) used to be waited on forever: `pump` awaited
    /// `receive()` with no deadline and the client sent no pings of its own, so the feed never yielded
    /// `.disconnected` and the store stayed `.live` while `prune` emptied the list. Now the feed pings, and a pong
    /// that doesn't come within the deadline closes the connection.
    @Test func silentConnectionIsEventuallyDropped() async throws {
        let connector = FakeConnector([.framesThenSilence([snapshotFrame], pong: .never)])
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: RecordingSleep().sleep,
                                   liveness: fastLiveness)

        let disconnected = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in feed.events() where event == .disconnected { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            // Stops the stream, which closes the fake socket and ends the reader.
            group.cancelAll()
            return first
        }

        #expect(disconnected)
        let connection = try #require(connector.connections.first)
        #expect(connection.isClosed)
        #expect(connection.pings.sent >= 1)
        #expect(connection.pings.answered == 0)
    }
}
