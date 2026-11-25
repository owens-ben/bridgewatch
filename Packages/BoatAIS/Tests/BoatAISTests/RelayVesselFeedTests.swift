import BoatCore
import Foundation
import Testing
@testable import BoatAIS

@Suite(.timeLimit(.minutes(1)))
struct RelayVesselFeedTests {
    @Test func deliversSnapshotThenUpdatesAndRemoves() async {
        let feed = RelayVesselFeed(
            url: relayURL, connector: FakeConnector([.frames([snapshotFrame, updateFrame, removeFrame])]),
            sleep: RecordingSleep().sleep)

        let events = await collect(feed.events()) { $0.last == .disconnected }

        #expect(events == [
            .connecting, .connected, .message(decoded(snapshotFrame)), .message(decoded(updateFrame)),
            .message(.remove(id: "vessel:1")), .disconnected,
        ])
    }

    @Test func reconnectsWithGrowingBackoffAndResetsAfterSuccess() async {
        let sleep = RecordingSleep()
        let feed = RelayVesselFeed(
            url: relayURL,
            connector: FakeConnector([.refuse, .refuse, .frames([snapshotFrame]), .refuse]),
            random: { 1 }, sleep: sleep.sleep)

        // The fifth attempt starts only after the fourth delay was requested.
        let events = await collect(feed.events()) { events in events.filter { $0 == .connecting }.count == 5 }

        #expect(events.filter { $0 == .disconnected }.count == 4)
        // 1 s, 2 s, then a delivered message resets the attempt count: 1 s, 2 s again.
        #expect(sleep.recorded == [.seconds(1), .seconds(2), .seconds(1), .seconds(2)])
    }

    @Test func skipsUndecodableFrames() async {
        let feed = RelayVesselFeed(
            url: relayURL,
            connector: FakeConnector([.frames([
                "not json", #"{"type":"bogus"}"#, #"{"type":"snapshot","vessels":[]}"#, updateFrame,
            ])]),
            sleep: RecordingSleep().sleep)

        let events = await collect(feed.events()) { $0.last == .disconnected }

        #expect(events == [.connecting, .connected, .message(decoded(updateFrame)), .disconnected])
    }

    @Test func connectionThatNeverDeliversDoesNotResetBackoff() async {
        let sleep = RecordingSleep()
        let feed = RelayVesselFeed(
            url: relayURL, connector: FakeConnector([.frames([]), .frames(["not json"]), .refuse]),
            random: { 1 }, sleep: sleep.sleep)

        _ = await collect(feed.events()) { events in events.filter { $0 == .connecting }.count == 4 }

        #expect(sleep.recorded == [.seconds(1), .seconds(2), .seconds(4)])
    }

    @Test func stoppingTheStreamClosesTheConnection() async throws {
        let connector = FakeConnector([.framesThenHang([snapshotFrame])])
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: RecordingSleep().sleep)

        let events = await collect(feed.events()) { $0.last == .message(decoded(snapshotFrame)) }
        #expect(events.last == .message(decoded(snapshotFrame)))

        // Leaving the loop drops the stream, which cancels the feed and closes its socket.
        let connection = try #require(connector.connections.first)
        for _ in 0..<100 where !connection.isClosed {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(connection.isClosed)
    }
}

@Suite struct BackoffTests {
    let backoff = Backoff()

    @Test func firstRetryIsBetweenHalfAndOneSecond() {
        #expect(backoff.delay(attempt: 0, unitRandom: 0) == .milliseconds(500))
        #expect(backoff.delay(attempt: 0, unitRandom: 1) == .seconds(1))
    }

    @Test func doublesPerAttempt() {
        #expect(backoff.delay(attempt: 1, unitRandom: 1) == .seconds(2))
        #expect(backoff.delay(attempt: 3, unitRandom: 1) == .seconds(8))
        #expect(backoff.delay(attempt: 3, unitRandom: 0.5) == .seconds(6))
    }

    @Test func capsAtSixtySeconds() {
        #expect(backoff.delay(attempt: 10, unitRandom: 1) == .seconds(60))
        #expect(backoff.delay(attempt: 10, unitRandom: 0) == .seconds(30))
        #expect(backoff.delay(attempt: 1_000, unitRandom: 1) == .seconds(60))
    }

    @Test func clampsOutOfRangeInputs() {
        #expect(backoff.delay(attempt: -3, unitRandom: 2) == .seconds(1))
        #expect(backoff.delay(attempt: 0, unitRandom: -1) == .milliseconds(500))
    }
}
