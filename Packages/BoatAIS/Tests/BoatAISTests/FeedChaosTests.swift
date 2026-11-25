import BoatCore
import Foundation
import Synchronization
import Testing
@testable import BoatAIS

// Chaos tests for RelayVesselFeed: hostile frames, hostile servers, hostile timing. Everything runs through fakes and
// a virtual clock; no test waits on the wall clock for more than a few hundred ms. Property tests print their seed in
// the failure message; replay one with BOATAR_CHAOS_SEED=<seed>.

// MARK: - Helpers

/// Events collected in the background, so a test can look at them while the feed is still running.
private final class EventLog: Sendable {
    private let events = Mutex<[FeedEvent]>([])
    var all: [FeedEvent] { events.withLock { $0 } }

    /// Consumes `stream` until the returned task is cancelled (which drops the stream and so stops the feed).
    func consume(_ stream: AsyncStream<FeedEvent>) -> Task<Void, Never> {
        Task {
            for await event in stream { events.withLock { $0.append(event) } }
        }
    }
}

/// Every event until the feed ends by itself (the virtual clock's limit).
private func drain(_ stream: AsyncStream<FeedEvent>) async -> [FeedEvent] {
    var events: [FeedEvent] = []
    for await event in stream { events.append(event) }
    return events
}

private func utf8(_ string: String) -> Data { Data(string.utf8) }

private func vesselUpdateFrame(_ n: Int, lat: Double = 40.7, name: String = "V") -> String {
    #"{"type":"update","target":{"id":"vessel:\#(n)","kind":"vessel","source":"aisstream","name":"\#(name)","lat":\#(lat),"lon":-73.99,"timestamp":"2026-11-10T14:00:00.000Z","vessel":{"mmsi":\#(n)}}}"#
}

private func encode(_ message: RelayMessage) -> Data {
    try! RelayJSON.encoder().encode(message)
}

private func vesselTarget(_ n: Int, lat: Double, lon: Double, name: String? = nil, step: Int = 0) -> Target {
    Target(
        id: "vessel:\(n)", kind: .vessel, source: "aisstream", name: name, lat: lat, lon: lon,
        timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(step) * 0.05), vessel: VesselDetails(mmsi: n))
}

/// A connector whose every connection delivers `frames` and then closes.
private func closingConnector(_ frames: [Data]) -> ChaosConnector {
    ChaosConnector { _ in .open(frames: frames, ending: .closes) }
}

private let baseBackoff = Backoff()

/// The un-jittered delay `Backoff` should be working from after `exponent` failures.
private func fullDelay(exponent: Int, base: Duration = .seconds(1), cap: Duration = .seconds(60)) -> Duration {
    min(cap, base * (1 << min(exponent, 30)))
}

/// A `random` closure fed by a seeded generator.
private func seededRandom(_ rng: SplitMix64) -> @Sendable () -> Double {
    let state = Mutex(rng)
    return { state.withLock { Double.random(in: 0...1, using: &$0) } }
}

/// Each recorded delay `i` must lie in [full/2, full] for the exponent `exponents[i]`.
private func expectDelays(
    _ delays: [Duration], exponents: [Int], rng: SplitMix64, sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(delays.count == exponents.count, "delay count \(rng.report)", sourceLocation: sourceLocation)
    for (index, (delay, exponent)) in zip(delays, exponents).enumerated() {
        let full = fullDelay(exponent: exponent)
        #expect(
            delay >= full / 2 && delay <= full,
            "delay #\(index) = \(delay) outside [\(full / 2), \(full)] \(rng.report)", sourceLocation: sourceLocation)
        #expect(delay >= baseBackoff.base / 2 && delay <= baseBackoff.cap, sourceLocation: sourceLocation)
    }
}

// MARK: - Hostile frames

@Suite(.timeLimit(.minutes(1)))
struct FeedHostileFrameTests {
    /// Frames that must never decode.
    private static let mustSkip: [(String, Data)] = {
        let target = #"{"id":"vessel:1","kind":"vessel","source":"aisstream","lat":40.7,"lon":-73.9,"timestamp":"2026-11-10T14:00:00.000Z","vessel":{"mmsi":1}}"#
        return [
            ("empty", Data()),
            ("whitespace", utf8("   \n")),
            ("open brace", utf8("{")),
            ("truncated snapshot", utf8(#"{"type":"snapshot","targets":["#)),
            ("null", utf8("null")),
            ("array", utf8("[]")),
            ("number", utf8("42")),
            ("bare string", utf8(#""snapshot""#)),
            ("not json", utf8("hello relay")),
            ("type is a number", utf8(#"{"type":42}"#)),
            ("type is null", utf8(#"{"type":null}"#)),
            ("no type", utf8(#"{"targets":[]}"#)),
            ("unknown type", utf8(#"{"type":"teleport","id":"x"}"#)),
            ("targets is a string", utf8(#"{"type":"snapshot","targets":"nope"}"#)),
            ("targets is null", utf8(#"{"type":"snapshot","targets":null}"#)),
            ("targets is an object", utf8(#"{"type":"snapshot","targets":{}}"#)),
            ("update without target", utf8(#"{"type":"update"}"#)),
            ("update with empty target", utf8(#"{"type":"update","target":{}}"#)),
            ("update missing fields", utf8(#"{"type":"update","target":{"id":"vessel:1"}}"#)),
            ("update id is a number", utf8(#"{"type":"update","target":{"id":5,"kind":"vessel","source":"s","lat":1,"lon":1,"timestamp":"2026-11-10T14:00:00.000Z"}}"#)),
            ("update lat is a string", utf8(#"{"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"s","lat":"north","lon":1,"timestamp":"2026-11-10T14:00:00.000Z"}}"#)),
            ("update bad timestamp", utf8(#"{"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"s","lat":1,"lon":1,"timestamp":"yesterday"}}"#)),
            ("update timestamp number", utf8(#"{"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"s","lat":1,"lon":1,"timestamp":1700000000}}"#)),
            ("update vessel mmsi wrong type", utf8(#"{"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"s","lat":1,"lon":1,"timestamp":"2026-11-10T14:00:00.000Z","vessel":{"mmsi":"x"}}}"#)),
            ("remove without id", utf8(#"{"type":"remove"}"#)),
            ("remove id is a number", utf8(#"{"type":"remove","id":7}"#)),
            ("v1 snapshot", utf8(#"{"type":"snapshot","vessels":[{"mmsi":367000001,"lat":40.7,"lon":-73.99,"timestamp":"2026-11-10T14:00:00.000Z"}]}"#)),
            ("v1 update", utf8(#"{"type":"update","vessel":{"mmsi":367000001,"lat":40.7,"lon":-73.99,"timestamp":"2026-11-10T14:00:00.000Z"}}"#)),
            ("v1 remove by mmsi", utf8(#"{"type":"remove","mmsi":367000001}"#)),
            ("target but no type", utf8(target)),
            ("deep array nesting", utf8(String(repeating: "[", count: 100_000))),
            ("deep object nesting", utf8(String(repeating: #"{"a":"#, count: 50_000))),
            ("non-UTF-8 bytes", Data([0xFF, 0xFE, 0x00, 0x80, 0xC0, 0xC1])),
            ("all 0x80", Data(repeating: 0x80, count: 4096)),
            ("NUL bytes", Data(repeating: 0, count: 1024)),
            ("1 MB of garbage", utf8(String(repeating: "x", count: 1 << 20))),
            ("1 MB of open braces", utf8(String(repeating: "{", count: 1 << 20))),
            ("1 MB of random bytes", {
                var rng = SplitMix64(seed: 7)
                return Data((0..<(1 << 20)).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
            }()),
        ]
    }()

    /// Frames that may or may not decode; whatever RelayMessage does with them, the feed must do the same.
    private static let mayDecode: [(String, Data)] = {
        func update(lat: String, lon: String = "-73.9", extra: String = "") -> Data {
            utf8(#"{"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"s","lat":\#(lat),"lon":\#(lon),"timestamp":"2026-11-10T14:00:00.000Z","vessel":{"mmsi":1\#(extra)}}}"#)
        }
        return [
            ("huge lat", update(lat: "1e308")),
            ("overflowing lat", update(lat: "1e999")),
            ("negative huge lon", update(lat: "40.7", lon: "-1e308")),
            ("negative zero", update(lat: "-0")),
            ("lat beyond 90", update(lat: "400.5")),
            ("integer overflow mmsi", update(lat: "40.7", extra: #","shipType":99999999999999999999999"#)),
            ("negative mmsi", utf8(#"{"type":"update","target":{"id":"vessel:-1","kind":"vessel","source":"s","lat":1,"lon":1,"timestamp":"2026-11-10T14:00:00.000Z","vessel":{"mmsi":-9223372036854775808}}}"#)),
            ("unknown kind", utf8(#"{"type":"update","target":{"id":"aircraft:1","kind":"aircraft","source":"adsb","lat":1,"lon":1,"timestamp":"2026-11-10T14:00:00.000Z"}}"#)),
            ("kind is a number", utf8(#"{"type":"update","target":{"id":"x:1","kind":7,"source":"s","lat":1,"lon":1,"timestamp":"2026-11-10T14:00:00.000Z"}}"#)),
            ("vessel kind without details", utf8(#"{"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"s","lat":1,"lon":1,"timestamp":"2026-11-10T14:00:00.000Z"}}"#)),
            ("snapshot with good and bad targets", utf8(#"{"type":"snapshot","targets":[{"id":1},{"id":"vessel:9","kind":"vessel","source":"s","lat":1,"lon":1,"timestamp":"2026-11-10T14:00:00.000Z","vessel":{"mmsi":9}},null,"x",[]]}"#)),
            ("empty snapshot", utf8(#"{"type":"snapshot","targets":[]}"#)),
            ("year 99999 timestamp", utf8(#"{"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"s","lat":1,"lon":1,"timestamp":"99999-01-01T00:00:00.000Z","vessel":{"mmsi":1}}}"#)),
            ("invalid UTF-8 inside a string", {
                var data = utf8(#"{"type":"remove","id":"vessel:"#)
                data.append(contentsOf: [0xFF, 0xFE])
                data.append(utf8(#""}"#))
                return data
            }()),
            ("UTF-8 BOM before JSON", Data([0xEF, 0xBB, 0xBF]) + utf8(#"{"type":"remove","id":"vessel:1"}"#)),
            ("1 MB name", utf8(vesselUpdateFrame(1, name: String(repeating: "N", count: 1 << 20)))),
            ("1 MB snapshot", {
                let targets = (0..<3000).map { vesselTarget($0, lat: 40.7, lon: -73.9, name: String(repeating: "n", count: 300)) }
                return encode(.snapshot(targets))
            }()),
        ]
    }()

    private static let goodFrames: [Data] = [
        utf8(snapshotFrame), utf8(updateFrame), utf8(removeFrame), utf8(vesselUpdateFrame(3)), utf8(vesselUpdateFrame(4)),
    ]

    @Test func hostileFramesAreSkippedAndGoodOnesDeliveredInOrder() async {
        for (name, data) in Self.mustSkip {
            #expect((try? RelayMessage.decode(data)) == nil, "RelayMessage.decode accepted '\(name)'")
        }

        // Hostile frames first (so `.connected` must wait for the first decodable one), then good and hostile mixed.
        var frames: [Data] = Self.mustSkip.map(\.1) + Self.mayDecode.map(\.1)
        for (index, good) in Self.goodFrames.enumerated() {
            frames.append(good)
            frames.append(Self.mustSkip[index % Self.mustSkip.count].1)
        }
        let expected = frames.compactMap { try? RelayMessage.decode($0) }
        #expect(expected.count >= Self.goodFrames.count)

        let connector = closingConnector(frames)
        let clock = VirtualClock(maxSleeps: 1)
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: clock.sleep)

        let events = await drain(feed.events())

        #expect(events == [.connecting, .connected] + expected.map(FeedEvent.message) + [.disconnected])
        #expect(connector.stats.open == 0)
    }

    @Test func v1AndV2FramesMixed() async {
        let v1Snapshot = utf8(#"{"type":"snapshot","vessels":[{"mmsi":1,"lat":40.7,"lon":-73.99,"timestamp":"2026-11-10T14:00:00.000Z"}]}"#)
        let v1Update = utf8(#"{"type":"update","vessel":{"mmsi":2,"lat":40.7,"lon":-73.99,"timestamp":"2026-11-10T14:00:00.000Z"}}"#)
        let frames = [v1Snapshot, utf8(snapshotFrame), v1Update, utf8(updateFrame), v1Update, utf8(removeFrame), v1Snapshot]
        let connector = closingConnector(frames)
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: VirtualClock(maxSleeps: 1).sleep)

        let events = await drain(feed.events())

        #expect(events == [
            .connecting, .connected, .message(decoded(snapshotFrame)), .message(decoded(updateFrame)),
            .message(decoded(removeFrame)), .disconnected,
        ])
    }

    @Test func connectedWaitsForTheFirstDecodableFrame() async {
        let hostile = Self.mustSkip.prefix(20).map(\.1)
        let clock = VirtualClock(maxSleeps: 3)
        let connector = ChaosConnector { _ in .open(frames: hostile, ending: .closes) }
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: clock.sleep)

        let events = await drain(feed.events())

        #expect(!events.contains(.connected))
        #expect(!events.contains { if case .message = $0 { true } else { false } })
        #expect(events == [.connecting, .disconnected, .connecting, .disconnected, .connecting, .disconnected])
        // Nothing decodable arrived, so the backoff was never reset.
        expectDelays(clock.delays, exponents: [0, 1, 2], rng: SplitMix64())
    }

    @Test func everyTruncationOfAGoodFrameIsSkipped() async {
        let good = utf8(updateFrame)
        var frames = (0..<good.count).map { good.prefix($0) }.map { Data($0) }
        frames.append(good)
        let connector = closingConnector(frames)
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: VirtualClock(maxSleeps: 1).sleep)

        let events = await drain(feed.events())

        #expect(events == [.connecting, .connected, .message(decoded(updateFrame)), .disconnected])
    }

    @Test func mutatedFramesNeverTrapAndNeverChangeWhatDecodes() async {
        var rng = SplitMix64()
        let seeds = [snapshotFrame, updateFrame, removeFrame, vesselUpdateFrame(5)].map(utf8)
        var frames: [Data] = []
        for _ in 0..<3000 {
            var data = seeds.randomElement(using: &rng)!
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: data = data.prefix(Int.random(in: 0...data.count, using: &rng)).map { $0 }.asData
            case 1:
                for _ in 0..<Int.random(in: 1...4, using: &rng) where !data.isEmpty {
                    data[Int.random(in: 0..<data.count, using: &rng)] = UInt8.random(in: .min ... .max, using: &rng)
                }
            case 2:
                if !data.isEmpty { data.remove(at: Int.random(in: 0..<data.count, using: &rng)) }
            case 3:
                data.insert(UInt8.random(in: .min ... .max, using: &rng), at: Int.random(in: 0...data.count, using: &rng))
            default:
                data = Data((0..<Int.random(in: 0..<64, using: &rng)).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
            }
            frames.append(data)
        }
        let expected = frames.compactMap { try? RelayMessage.decode($0) }
        let connector = closingConnector(frames)
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: VirtualClock(maxSleeps: 1).sleep)

        let events = await drain(feed.events())

        let messages = events.compactMap { event -> RelayMessage? in
            if case .message(let message) = event { message } else { nil }
        }
        #expect(messages == expected, "\(rng.report)")
        #expect(events.contains(.connected) == !expected.isEmpty, "\(rng.report)")
        print("chaos: \(frames.count) mutated frames, \(expected.count) still decodable (seed \(rng.seed))")
    }
}

private extension Array where Element == UInt8 {
    var asData: Data { Data(self) }
}

// MARK: - Hostile servers

private enum Scenario: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case closesImmediately, neverAnswers, answersThenSilent, tokenRejected, flapping

    var testDescription: String { rawValue }

    var behavior: @Sendable (Int) -> ChaosStep {
        switch self {
        case .closesImmediately: { _ in .open(frames: [], ending: .closes) }
        case .neverAnswers: { _ in .neverAnswers }
        case .answersThenSilent: { _ in .open(frames: [Data(snapshotFrame.utf8)], ending: .silent) }
        case .tokenRejected: { _ in .fail(WebSocketError.rejected(status: 401)) }
        case .flapping: { _ in .open(frames: [Data(updateFrame.utf8)], ending: .closes) }
        }
    }

    /// Whether this event, with the ones before it, is enough to stop at.
    func isEnough(_ events: [FeedEvent]) -> Bool {
        switch self {
        case .neverAnswers: events.contains(.connecting)
        case .answersThenSilent: events.contains(.connected)
        default: events.filter { $0 == .connecting }.count >= 3
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct FeedHostileServerTests {
    /// Runs a feed against `behavior` on a virtual clock until `limit`; returns the events, connector and clock.
    private func runToLimit(
        _ limit: Duration, rng: SplitMix64, behavior: @escaping @Sendable (Int) -> ChaosStep
    ) async -> (events: [FeedEvent], connector: ChaosConnector, clock: VirtualClock) {
        let clock = VirtualClock(limit: limit)
        let connector = ChaosConnector(behavior)
        let feed = RelayVesselFeed(
            url: relayURL, connector: connector, random: seededRandom(rng), sleep: clock.sleep)
        return (await drain(feed.events()), connector, clock)
    }

    @Test func serverThatClosesImmediatelyForever() async {
        let rng = SplitMix64()
        let (events, connector, clock) = await runToLimit(.seconds(3600), rng: rng) { _ in
            .open(frames: [], ending: .closes)
        }

        let delays = clock.delays
        expectDelays(delays, exponents: Array(0..<delays.count), rng: rng)
        #expect(delays.count > 50, "an hour of simulated time gave only \(delays.count) attempts \(rng.report)")
        #expect(delays.suffix(10).allSatisfy { $0 >= .seconds(30) && $0 <= .seconds(60) }, "capped \(rng.report)")
        #expect(connector.stats.maxOpen == 1)
        #expect(connector.stats.open == 0)
        #expect(connector.stats.connectAttempts == delays.count)
        #expect(!events.contains(.connected))
        // connecting / disconnected strictly alternate.
        #expect(events == (0..<delays.count).flatMap { _ in [FeedEvent.connecting, .disconnected] })
    }

    @Test func backoffGrowsWithoutJitterUntilItCaps() async {
        let clock = VirtualClock(maxSleeps: 12)
        let connector = ChaosConnector { _ in .open(frames: [], ending: .closes) }
        let feed = RelayVesselFeed(url: relayURL, connector: connector, random: { 1 }, sleep: clock.sleep)
        _ = await drain(feed.events())

        #expect(clock.delays == [1, 2, 4, 8, 16, 32, 60, 60, 60, 60, 60, 60].map(Duration.seconds))
    }

    @Test func serverThatNeverAnswersConnect() async {
        let connector = ChaosConnector { _ in .neverAnswers }
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: VirtualClock().sleep)
        let log = EventLog()
        let consumer = log.consume(feed.events())

        // Simulated time cannot help a connect that never returns: the feed sits at `.connecting`.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(log.all == [.connecting])
        #expect(connector.stats.connectAttempts == 1)

        consumer.cancel()
        #expect(await eventually { connector.stats.connectCancellations == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(connector.stats.connectAttempts == 1, "the feed kept connecting after it was stopped")
        #expect(connector.stats.open == 0)
    }

    /// S1 (fixed by F1): a connection that delivers frames and then goes silent (a half-open path: no data, no pong)
    /// used to keep the feed `.connected` forever. The unanswered ping closes it: `.disconnected`, then a reconnect
    /// after the first backoff step.
    @Test func answersThenGoesSilentIsDroppedAndReconnected() async {
        let clock = VirtualClock()
        let connector = ChaosConnector { attempt in
            attempt == 0 ? .open(frames: [Data(snapshotFrame.utf8)], ending: .silent)
                : .open(frames: [Data(updateFrame.utf8)], ending: .silent)
        }
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: clock.sleep, liveness: fastLiveness)
        let log = EventLog()
        let consumer = log.consume(feed.events())

        #expect(await eventually { log.all.filter { $0 == .connected }.count >= 2 })
        #expect(Array(log.all.prefix(6)) == [.connecting, .connected, .message(decoded(snapshotFrame)), .disconnected,
                                              .connecting, .connected])
        #expect(clock.delays.first.map { $0 >= .milliseconds(500) && $0 <= .seconds(1) } == true)
        #expect(connector.stats.connectAttempts >= 2)
        #expect(connector.stats.maxOpen == 1)

        consumer.cancel()
        #expect(await eventually { connector.stats.open == 0 })
    }

    @Test func flappingEvery200msForASimulatedMinute() async {
        let rng = SplitMix64()
        let clock = VirtualClock(limit: .seconds(60))
        let connector = ChaosConnector { attempt in
            .open(frames: [Data(vesselUpdateFrame(attempt).utf8)], ending: .closesAfter(.milliseconds(200), clock))
        }
        let feed = RelayVesselFeed(
            url: relayURL, connector: connector, random: seededRandom(rng), sleep: clock.sleep)

        let events = await drain(feed.events())

        let delays = clock.delays
        // Every connection delivered a frame, so the backoff restarts at the first step each time.
        expectDelays(delays, exponents: Array(repeating: 0, count: delays.count), rng: rng)
        #expect(delays.count >= 40, "only \(delays.count) cycles in a simulated minute \(rng.report)")
        #expect(clock.now >= .seconds(60))
        #expect(connector.stats.maxOpen == 1)
        #expect(connector.stats.open == 0)
        #expect(connector.stats.opened == delays.count)
        let cycle: (Int) -> [FeedEvent] = { n in
            [.connecting, .connected, .message(decoded(vesselUpdateFrame(n))), .disconnected]
        }
        #expect(events == (0..<delays.count).flatMap(cycle), "\(rng.report)")
    }

    /// S3: a relay that refuses the token (401/403 on the upgrade) is told apart from an outage: `.rejected` instead
    /// of `.disconnected`, and the feed keeps retrying, every 30-60 s (the cap) from the first retry on.
    @Test func tokenRejectedIsReportedAndRetriedAtTheCap() async {
        let rng = SplitMix64()
        let clock = VirtualClock(maxSleeps: 25)
        let connector = ChaosConnector { _ in .fail(WebSocketError.rejected(status: 401)) }
        let feed = RelayVesselFeed(
            url: relayURL, connector: connector, random: seededRandom(rng), sleep: clock.sleep)

        let events = await drain(feed.events())

        #expect(clock.delays.count == 25)
        #expect(clock.delays.allSatisfy { $0 >= .seconds(30) && $0 <= .seconds(60) }, "\(clock.delays) \(rng.report)")
        #expect(connector.stats.connectAttempts == 25)
        #expect(connector.stats.opened == 0)
        #expect(events == (0..<25).flatMap { _ in [FeedEvent.connecting, .rejected] })
    }

    /// URLSession reports a refused upgrade from the first `receive()`, not from `connect`: the same `.rejected`.
    @Test func rejectionFromTheFirstReceiveIsReported() async {
        let clock = VirtualClock(maxSleeps: 3)
        let connector = ChaosConnector { _ in .open(frames: [], ending: .rejects(403)) }
        let feed = RelayVesselFeed(url: relayURL, connector: connector, random: { 1 }, sleep: clock.sleep)

        let events = await drain(feed.events())

        #expect(events == (0..<3).flatMap { _ in [FeedEvent.connecting, .rejected] })
        #expect(clock.delays == [.seconds(60), .seconds(60), .seconds(60)])
        #expect(connector.stats.open == 0)
    }

    /// Other connect failures stay outages, with the usual growing backoff; a refusal after a good connection (the
    /// relay changed its token) is reported, and a good connection after it starts the backoff over.
    @Test func onlyARefusalIsRejected() async {
        let clock = VirtualClock(maxSleeps: 5)
        let connector = ChaosConnector { attempt in
            switch attempt {
            case 0: .fail(ConnectFailed())
            case 1: .open(frames: [Data(updateFrame.utf8)], ending: .closes)
            case 2: .fail(WebSocketError.rejected(status: 403))
            case 3: .open(frames: [], ending: .closes)
            default: .open(frames: [Data(updateFrame.utf8)], ending: .closes)
            }
        }
        let feed = RelayVesselFeed(url: relayURL, connector: connector, random: { 1 }, sleep: clock.sleep)

        let events = await drain(feed.events())

        #expect(events == [.connecting, .disconnected,
                           .connecting, .connected, .message(decoded(updateFrame)), .disconnected,
                           .connecting, .rejected,
                           .connecting, .disconnected,
                           .connecting, .connected, .message(decoded(updateFrame)), .disconnected])
        #expect(clock.delays == [1, 1, 60, 4, 1].map(Duration.seconds))
    }

    /// How URLSession's handshake response maps to the typed error: only 401 and 403 are a refusal.
    @Test func handshakeStatusesThatAreARefusal() throws {
        func response(_ status: Int) -> HTTPURLResponse? {
            HTTPURLResponse(url: relayURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        }
        #expect(URLSessionWebSocketConnection.rejection(response: response(401)) == .rejected(status: 401))
        #expect(URLSessionWebSocketConnection.rejection(response: response(403)) == .rejected(status: 403))
        for status in [101, 200, 404, 426, 500, 502, 503] {
            #expect(URLSessionWebSocketConnection.rejection(response: response(status)) == nil, "\(status)")
        }
        #expect(URLSessionWebSocketConnection.rejection(response: nil) == nil)
        #expect(URLSessionWebSocketConnection.rejection(response: URLResponse(url: relayURL, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)) == nil)
    }

    @Test func backoffResetsToTheFirstStepAfterADeliveredMessage() async {
        let rng = SplitMix64()
        let clock = VirtualClock(maxSleeps: 8)
        // Attempts 3 and 7 connect and deliver; every other one is refused.
        let connector = ChaosConnector { attempt in
            attempt % 4 == 3
                ? .open(frames: [Data(updateFrame.utf8)], ending: .closes) : .fail(ConnectFailed())
        }
        let feed = RelayVesselFeed(
            url: relayURL, connector: connector, random: seededRandom(rng), sleep: clock.sleep)
        _ = await drain(feed.events())

        expectDelays(clock.delays, exponents: [0, 1, 2, 0, 1, 2, 3, 0], rng: rng)
    }

    @Test(arguments: Scenario.allCases)
    fileprivate func stoppingTheStreamClosesTheConnectionAndStopsConnecting(_ scenario: Scenario) async {
        let connector = ChaosConnector(scenario.behavior)
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: VirtualClock().sleep)

        _ = await collect(feed.events(), until: scenario.isEnough)

        #expect(await eventually { connector.stats.open == 0 }, "connection still open after the stream was dropped")
        // Give a loop that missed its cancellation a chance to connect again.
        try? await Task.sleep(for: .milliseconds(100))
        let attempts = connector.stats.connectAttempts
        try? await Task.sleep(for: .milliseconds(100))
        #expect(connector.stats.connectAttempts == attempts, "connect attempts continued after the stream was dropped")
        #expect(connector.stats.open == 0)
        #expect(connector.stats.maxOpen <= 1)
    }

    @Test func twoHundredStartStopCyclesLeaveNothingOpen() async {
        var connectors: [ChaosConnector] = []
        for cycle in 0..<200 {
            let scenario = Scenario.allCases[cycle % Scenario.allCases.count]
            let connector = ChaosConnector(scenario.behavior)
            connectors.append(connector)
            let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: VirtualClock().sleep)
            _ = await collect(feed.events(), until: scenario.isEnough)
        }

        let all = connectors
        #expect(await eventually(grace: .seconds(5)) { all.allSatisfy { $0.stats.open == 0 } },
                "open connections left: \(all.map(\.stats.open).reduce(0, +))")
        try? await Task.sleep(for: .milliseconds(100))
        let attempts = connectors.map(\.stats.connectAttempts)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(connectors.map(\.stats.connectAttempts) == attempts, "a stopped feed kept connecting")
        #expect(connectors.allSatisfy { $0.stats.open == 0 && $0.stats.maxOpen <= 1 })
    }
}

// MARK: - Convergence and scale

@Suite(.timeLimit(.minutes(1)))
struct FeedConvergenceTests {
    /// When the messages are taken to arrive: the targets' own time, so none is held back as too far ahead
    /// (`TargetRegistry.maxFutureLead`) and two registries fed the same messages agree.
    static let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func applyAll(_ events: [FeedEvent]) -> TargetRegistry {
        var registry = TargetRegistry()
        for case .message(let message) in events { registry.apply(message, receivedAt: Self.receivedAt) }
        return registry
    }

    private struct Place: Equatable {
        var lat: Double
        var lon: Double
        var name: String?
    }

    @Test func registryConvergesToTheLastSnapshotPlusLaterUpdates() async {
        var rng = SplitMix64()
        let junk = FeedHostileFrameTests_junk
        var sent: [RelayMessage] = []
        var frames: [Data] = []
        // 600 snapshots, one every 50 ms of simulated time (30 s), with updates, removes and junk in between.
        for step in 0..<600 {
            let ids = (0..<60).filter { _ in Double.random(in: 0...1, using: &rng) < 0.6 }
            let snapshot = RelayMessage.snapshot(ids.map {
                vesselTarget($0, lat: .random(in: 40.675...40.735, using: &rng), lon: .random(in: -74.045 ... -73.955, using: &rng),
                             name: "s\(step)", step: step)
            })
            sent.append(snapshot)
            frames.append(encode(snapshot))
            for _ in 0..<Int.random(in: 0...3, using: &rng) {
                let n = Int.random(in: 0..<60, using: &rng)
                let message: RelayMessage = Bool.random(using: &rng)
                    ? .update(vesselTarget(n, lat: .random(in: 40.675...40.735, using: &rng),
                                           lon: .random(in: -74.045 ... -73.955, using: &rng), name: "u\(step)", step: step))
                    : .remove(id: "vessel:\(n)")
                sent.append(message)
                frames.append(encode(message))
                if Int.random(in: 0..<4, using: &rng) == 0 { frames.append(junk.randomElement(using: &rng)!) }
            }
        }

        // The model: only the last snapshot, then the updates and removes after it.
        let lastSnapshot = sent.lastIndex { if case .snapshot = $0 { true } else { false } }!
        var model: [String: Place] = [:]
        for message in sent[lastSnapshot...] {
            switch message {
            case .snapshot(let targets): model = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, Place(lat: $0.lat, lon: $0.lon, name: $0.name)) })
            case .update(let target): model[target.id] = Place(lat: target.lat, lon: target.lon, name: target.name)
            case .remove(let id): model[id] = nil
            }
        }

        let connector = closingConnector(frames)
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: VirtualClock(maxSleeps: 1).sleep)
        let events = await drain(feed.events())

        let registry = applyAll(events)
        let held = Dictionary(uniqueKeysWithValues: registry.targets.map { ($0.id, Place(lat: $0.lat, lon: $0.lon, name: $0.name)) })
        #expect(events.filter { if case .message = $0 { true } else { false } }.count == sent.count, "\(rng.report)")
        #expect(held == model, "registry differs from last snapshot + later updates \(rng.report)")
        // A registry that saw only the tail agrees with one that saw everything.
        var tail = TargetRegistry()
        for message in sent[lastSnapshot...] { tail.apply(message, receivedAt: Self.receivedAt) }
        #expect(tail == registry, "\(rng.report)")
    }

    @Test func aReconnectsSnapshotReplacesWhatTheDroppedConnectionLeft() async {
        let stale = (0..<10).map { vesselTarget($0, lat: 40.7, lon: -73.99, name: "old") }
        let fresh = (5..<8).map { vesselTarget($0, lat: 40.71, lon: -73.98, name: "new") }
        let connector = ChaosConnector { attempt in
            attempt == 0
                ? .open(frames: [encode(.snapshot(stale)), Data("garbage".utf8), encode(.update(vesselTarget(99, lat: 1, lon: 1)))], ending: .closes)
                : .open(frames: [encode(.snapshot(fresh))], ending: .closes)
        }
        let feed = RelayVesselFeed(
            url: relayURL, connector: connector, random: { 0 }, sleep: VirtualClock(maxSleeps: 2).sleep)

        let registry = applyAll(await drain(feed.events()))

        #expect(registry.targets.map(\.id) == ["vessel:5", "vessel:6", "vessel:7"])
        #expect(registry.targets.allSatisfy { $0.name == "new" })
    }

    @Test func fiveThousandTargetsDecodeAndApplyQuickly() async {
        let targets = (0..<5000).map { vesselTarget($0, lat: 40.7 + Double($0) / 1e6, lon: -73.99, name: "VESSEL \($0)") }
        let frame = encode(.snapshot(targets))
        let connector = ChaosConnector { _ in .open(frames: [frame], ending: .closes) }
        let feed = RelayVesselFeed(url: relayURL, connector: connector, sleep: VirtualClock(maxSleeps: 1).sleep)

        let clock = ContinuousClock()
        var registry = TargetRegistry()
        let elapsed = await clock.measure {
            for await event in feed.events() {
                if case .message(let message) = event { registry.apply(message) }
            }
        }

        print("chaos: 5000-target snapshot (\(frame.count / 1024) KiB) decoded and applied in \(elapsed)")
        #expect(registry.count == 5000)
        #expect(elapsed < .seconds(5), "took \(elapsed)")
    }
}

/// Junk frames for interleaving (a few from the hostile set, all of which must be skipped).
private let FeedHostileFrameTests_junk: [Data] = [
    Data(), Data("{".utf8), Data("null".utf8), Data(#"{"type":"teleport"}"#.utf8), Data([0xFF, 0xFE, 0x00]),
    Data(#"{"type":"snapshot","vessels":[]}"#.utf8), Data(#"{"type":"update","target":{}}"#.utf8),
]

// MARK: - Backoff

@Suite(.timeLimit(.minutes(1)))
struct BackoffChaosTests {
    @Test func randomInputsStayInBoundsAndGrowWithTheAttempt() {
        var rng = SplitMix64()
        let backoff = Backoff()
        let attempts = [Int.min, Int.min + 1, -1_000_000, -1, 0, 1, 29, 30, 31, 63, 64, 1_000, Int.max - 1, Int.max]
        for _ in 0..<5000 {
            let attempt = Bool.random(using: &rng) ? attempts.randomElement(using: &rng)! : Int.random(in: -50...200, using: &rng)
            let unit = Double.random(in: -1...2, using: &rng)
            let delay = backoff.delay(attempt: attempt, unitRandom: unit)
            #expect(delay >= .zero && delay <= backoff.cap, "attempt \(attempt) unit \(unit) gave \(delay) \(rng.report)")
            // Within the clamped jitter range the delay is never below half the un-jittered delay.
            #expect(delay >= fullDelay(exponent: max(attempt, 0)) / 2, "\(rng.report)")
        }
        for _ in 0..<500 {
            let unit = Double.random(in: -1...2, using: &rng)
            var previous = backoff.delay(attempt: Int.min, unitRandom: unit)
            for attempt in (-5...80) {
                let next = backoff.delay(attempt: attempt, unitRandom: unit)
                #expect(next >= previous, "not monotone at attempt \(attempt), unit \(unit): \(previous) then \(next) \(rng.report)")
                previous = next
            }
            #expect(backoff.delay(attempt: Int.max, unitRandom: unit) >= previous, "\(rng.report)")
        }
    }

    @Test func randomBasesAndCapsStayInBounds() {
        var rng = SplitMix64()
        for _ in 0..<2000 {
            let base = Duration.milliseconds(Int.random(in: 1...10_000, using: &rng))
            let cap = base + .milliseconds(Int.random(in: 0...120_000, using: &rng))
            let backoff = Backoff(base: base, cap: cap)
            let attempt = Int.random(in: -5...100, using: &rng)
            let unit = Double.random(in: -1...2, using: &rng)
            let delay = backoff.delay(attempt: attempt, unitRandom: unit)
            #expect(delay >= base / 2 && delay <= cap,
                    "base \(base) cap \(cap) attempt \(attempt) unit \(unit) gave \(delay) \(rng.report)")
        }
    }

    @Test func infiniteRandomValuesAreClamped() {
        let backoff = Backoff()
        #expect(backoff.delay(attempt: 0, unitRandom: .infinity) == .seconds(1))
        #expect(backoff.delay(attempt: 0, unitRandom: -.infinity) == .milliseconds(500))
        #expect(backoff.delay(attempt: 100, unitRandom: .greatestFiniteMagnitude) == .seconds(60))
    }

    /// C4: a NaN random value used to trap (`min(max(NaN, 0), 1)` stays NaN, then `Duration * NaN`). It gives the
    /// full delay now, within the bounds.
    @Test func nanRandomGivesTheFullDelay() {
        let backoff = Backoff()
        #expect(backoff.delay(attempt: 0, unitRandom: .nan) == .seconds(1))
        #expect(backoff.delay(attempt: 3, unitRandom: .nan) == .seconds(8))
        #expect(backoff.delay(attempt: 100, unitRandom: -.nan) == .seconds(60))
    }
}
