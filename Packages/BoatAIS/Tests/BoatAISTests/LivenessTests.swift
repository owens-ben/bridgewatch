import BoatCore
import Foundation
import Synchronization
import Testing
@testable import BoatAIS

/// Short intervals so the liveness checks run in a test's time.
let fastLiveness = Liveness(pingInterval: .milliseconds(50), pongTimeout: .milliseconds(150),
                            firstMessageTimeout: .milliseconds(300))

/// Reads events until `stop` holds or `timeout` passes; then stops the stream.
func events(of feed: RelayVesselFeed, for timeout: Duration,
            until stop: @escaping @Sendable ([FeedEvent]) -> Bool = { _ in false }) async -> [FeedEvent] {
    await withTaskGroup(of: [FeedEvent]?.self) { group in
        group.addTask {
            var events: [FeedEvent] = []
            for await event in feed.events() {
                events.append(event)
                if stop(events) || Task.isCancelled { break }
            }
            return events
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        var result: [FeedEvent] = []
        while let next = await group.next() {
            if let next {
                result = next
                break
            }
            // The timeout: stop the reader, which returns what it has.
            group.cancelAll()
        }
        group.cancelAll()
        return result
    }
}

@Suite(.timeLimit(.minutes(1)))
struct LivenessTests {
    /// F1: a connection that answers its pings stays up however quiet it is.
    @Test func answeredPingsKeepAQuietConnection() async throws {
        let connector = FakeConnector([.framesThenSilence([snapshotFrame], pong: .immediate)])
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: RecordingSleep().sleep,
                                   liveness: fastLiveness)

        let seen = await events(of: feed, for: .milliseconds(700))

        #expect(seen == [.connecting, .connected, .message(decoded(snapshotFrame))])
        let connection = try #require(connector.connections.first)
        #expect(connection.pings.answered >= 3)
    }

    /// F1: a pong that comes after the deadline (after the connection was closed) is dropped: the feed has already
    /// reported `.disconnected` once and moved on to the next connection.
    @Test func latePongAfterCloseIsIgnored() async throws {
        let connector = FakeConnector([
            .framesThenSilence([snapshotFrame], pong: .late(.milliseconds(400))), .framesThenHang([updateFrame]),
        ])
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: RecordingSleep().sleep,
                                   liveness: Liveness(pingInterval: .milliseconds(50), pongTimeout: .milliseconds(100),
                                                      firstMessageTimeout: .seconds(10)))

        // Long enough for the late pong to arrive on the closed first connection.
        let seen = await events(of: feed, for: .milliseconds(900))

        #expect(Array(seen.prefix(6)) == [
            .connecting, .connected, .message(decoded(snapshotFrame)), .disconnected,
            .connecting, .connected,
        ])
        #expect(seen.filter { $0 == .disconnected }.count == 1)
        let first = try #require(connector.connections.first)
        #expect(first.isClosed)
        #expect(first.pings.sent == 1)
    }

    /// F1: stopping the feed while a ping waits for its pong closes the connection and ends the stream at once,
    /// though the fake's ping ignores cancellation (as URLSession's does).
    @Test func cancellingMidPingClosesTheConnection() async throws {
        let connector = FakeConnector([.framesThenSilence([snapshotFrame], pong: .never)])
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: RecordingSleep().sleep,
                                   liveness: Liveness(pingInterval: .milliseconds(20), pongTimeout: .seconds(30),
                                                      firstMessageTimeout: .seconds(30)))
        let reader = Task { await collect(feed.events()) { _ in false } }
        let connection = try await firstConnection(of: connector)
        for _ in 0..<200 where connection.pings.sent == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(connection.pings.sent == 1)

        let start = ContinuousClock.now
        reader.cancel()
        let seen = await reader.value

        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(!seen.contains(.disconnected))
        for _ in 0..<100 where !connection.isClosed {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(connection.isClosed)
    }

    /// F11: a server that sends only frames this version can't decode (a wrong host or path, another protocol)
    /// counts as a failed connection: `.disconnected`, then backoff that keeps growing.
    @Test func noDecodableMessageInTimeIsAFailedConnection() async {
        let sleep = RecordingSleep()
        let connector = FakeConnector([
            .framesThenSilence(["not json", #"{"type":"bogus"}"#], pong: .immediate),
            .framesThenSilence([], pong: .immediate),
        ])
        let feed = RelayVesselFeed(url: relayURL, connector: connector, random: { 1 }, sleep: sleep.sleep,
                                   liveness: fastLiveness)

        let seen = await events(of: feed, for: .seconds(5)) { $0.filter { $0 == .disconnected }.count == 2 }

        #expect(seen == [.connecting, .disconnected, .connecting, .disconnected])
        #expect(sleep.recorded == [.seconds(1), .seconds(2)])
        let allClosed = connector.connections.allSatisfy { $0.isClosed }
        #expect(allClosed)
    }

    /// F11: an undecodable frame after the snapshot is skipped as before (a newer relay may add message types).
    @Test func undecodableFramesAfterTheFirstMessageAreSkipped() async {
        let connector = FakeConnector([
            .framesThenSilence([snapshotFrame, "not json", #"{"type":"bogus"}"#, updateFrame], pong: .immediate),
        ])
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: RecordingSleep().sleep,
                                   liveness: fastLiveness)

        let seen = await events(of: feed, for: .milliseconds(600))

        #expect(seen == [
            .connecting, .connected, .message(decoded(snapshotFrame)), .message(decoded(updateFrame)),
        ])
    }

    @Test func pingReturnsOnTheFirstOutcome() async {
        let timer: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        let quick = FakeConnection(frames: [], hangs: true, pong: .immediate)
        let answered = await ping(quick, timeout: .seconds(10), timer: timer)
        #expect(answered == .pong)

        let silent = FakeConnection(frames: [], hangs: true, pong: .never)
        let timedOut = await ping(silent, timeout: .milliseconds(50), timer: timer)
        #expect(timedOut == .timedOut)
        silent.close()

        let closed = FakeConnection(frames: [], hangs: true, pong: .never)
        closed.close()
        let failed = await ping(closed, timeout: .seconds(10), timer: timer)
        #expect(failed == .failed)

        let waiting = FakeConnection(frames: [], hangs: true, pong: .never)
        let task = Task { await ping(waiting, timeout: .seconds(30), timer: timer) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let cancelled = await task.value
        #expect(cancelled == .cancelled)
        waiting.close()
    }

    @Test func resumeOnceResumesExactlyOnce() async {
        // A value before the continuation: arm resumes at once with it; later values are dropped.
        let early = ResumeOnce<Int>()
        #expect(early.resume(1))
        #expect(!early.resume(2))
        #expect(await withCheckedContinuation { early.arm($0) } == 1)
        #expect(!early.resume(3))

        // The continuation first, then racing values from many tasks: exactly one wins.
        let raced = ResumeOnce<Int>()
        let wins = Atomic(0)
        let value = await withCheckedContinuation { continuation in
            raced.arm(continuation)
            DispatchQueue.concurrentPerform(iterations: 50) { index in
                if raced.resume(index) { wins.add(1, ordering: .sequentiallyConsistent) }
            }
        }
        #expect((0..<50).contains(value))
        #expect(wins.load(ordering: .sequentiallyConsistent) == 1)
    }

    /// F10: the URLSession connection accepts messages up to 8 MiB instead of the default 1 MiB. The connection goes
    /// to a closed local port and is closed at once: no network.
    @Test func connectionAcceptsLargeMessages() async throws {
        let connection = try await URLSessionWebSocketConnector().connect(to: URL(string: "ws://127.0.0.1:9/")!)
        let task = try #require((connection as? URLSessionWebSocketConnection)?.task)
        #expect(task.maximumMessageSize == 8 * 1024 * 1024)
        connection.close()
    }
}

private func firstConnection(of connector: FakeConnector) async throws -> FakeConnection {
    for _ in 0..<500 {
        if let connection = connector.connections.first { return connection }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ConnectionRefused()
}
