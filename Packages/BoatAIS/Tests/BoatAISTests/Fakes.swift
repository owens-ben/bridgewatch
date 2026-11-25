import BoatAIS
import BoatCore
import Foundation
import Synchronization

/// What one connection attempt does.
enum ConnectionScript {
    /// `connect` throws.
    case refuse
    /// Delivers these frames, then the connection ends.
    case frames([String])
    /// Delivers these frames, then stays open until closed.
    case framesThenHang([String])
    /// Delivers these frames, then stays open until closed, answering pings as `pong` says.
    case framesThenSilence([String], pong: Pong)
}

/// How a fake connection answers pings.
enum Pong: Sendable {
    /// At once.
    case immediate
    /// Never: the ping waits until the connection is closed (then throws), ignoring task cancellation like
    /// URLSession's does.
    case never
    /// After this long, whatever happened meanwhile (closed, cancelled): a pong that arrives late.
    case late(Duration)
}

struct ConnectionRefused: Error {}
struct ConnectionEnded: Error {}

final class FakeConnector: WebSocketConnecting {
    private let scripts: Mutex<[ConnectionScript]>
    private let opened = Mutex<[FakeConnection]>([])

    init(_ scripts: [ConnectionScript]) {
        self.scripts = Mutex(scripts)
    }

    var connections: [FakeConnection] { opened.withLock { $0 } }

    func connect(to url: URL) async throws -> any WebSocketConnection {
        guard let script = scripts.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
            // Out of scripts: wait until the test stops the feed.
            try await Task.sleep(for: .seconds(3600))
            throw ConnectionRefused()
        }
        let connection: FakeConnection
        switch script {
        case .refuse: throw ConnectionRefused()
        case .frames(let frames): connection = FakeConnection(frames: frames, hangs: false)
        case .framesThenHang(let frames): connection = FakeConnection(frames: frames, hangs: true)
        case .framesThenSilence(let frames, let pong): connection = FakeConnection(frames: frames, hangs: true, pong: pong)
        }
        opened.withLock { $0.append(connection) }
        return connection
    }
}

final class FakeConnection: WebSocketConnection {
    private let frames: Mutex<[Data]>
    private let hangs: Bool
    private let closedFlag = Mutex(false)
    private let closedLatch = Latch()
    private let pong: Pong
    private let pingCounts = Mutex((sent: 0, answered: 0))

    init(frames: [String], hangs: Bool, pong: Pong = .immediate) {
        self.frames = Mutex(frames.map { Data($0.utf8) })
        self.hangs = hangs
        self.pong = pong
    }

    var isClosed: Bool { closedFlag.withLock { $0 } }
    /// Pings sent, and how many of them got a pong back (returned without throwing).
    var pings: (sent: Int, answered: Int) { pingCounts.withLock { $0 } }

    func ping() async throws {
        pingCounts.withLock { $0.sent += 1 }
        switch pong {
        case .immediate:
            break
        case .never:
            await closed()
            throw ConnectionEnded()
        case .late(let delay):
            // Not cancellable on purpose (Task.sleep would be): a late pong comes whether anyone waits or not.
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
            }
        }
        pingCounts.withLock { $0.answered += 1 }
    }

    private func closed() async {
        await closedLatch.wait()
    }

    func receive() async throws -> Data {
        if let next = frames.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { return next }
        if hangs {
            await closedLatch.wait()
        }
        throw ConnectionEnded()
    }

    func close() {
        closedFlag.withLock { $0 = true }
        closedLatch.open()
    }
}

/// Opens once; any number of tasks can wait for it (an AsyncStream allows only one).
final class Latch: Sendable {
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// Records requested delays and returns immediately.
final class RecordingSleep: Sendable {
    private let delays = Mutex<[Duration]>([])

    var recorded: [Duration] { delays.withLock { $0 } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { duration in self.delays.withLock { $0.append(duration) } }
    }
}

/// Reads events until `stop` returns true for the events so far.
func collect(_ stream: AsyncStream<FeedEvent>, until stop: ([FeedEvent]) -> Bool) async -> [FeedEvent] {
    var events: [FeedEvent] = []
    for await event in stream {
        events.append(event)
        if stop(events) { break }
    }
    return events
}

let relayURL = URL(string: "ws://relay.test:8080/v2/targets")!

let snapshotFrame = #"{"type":"snapshot","targets":[{"id":"vessel:1","kind":"vessel","source":"aisstream","lat":40.705,"lon":-73.99,"timestamp":"2026-11-10T14:00:00.000Z","vessel":{"mmsi":1}}]}"#
let updateFrame = #"{"type":"update","target":{"id":"vessel:2","kind":"vessel","source":"aisstream","name":"ANNABEL K","lat":40.706,"lon":-73.9905,"timestamp":"2026-11-10T14:00:10.000Z","vessel":{"mmsi":2}}}"#
let removeFrame = #"{"type":"remove","id":"vessel:1"}"#

func decoded(_ frame: String) -> RelayMessage {
    try! RelayMessage.decode(Data(frame.utf8))
}

// MARK: - Chaos fakes

/// A connect failure that isn't a refusal (no route, DNS, TLS): an outage.
struct ConnectFailed: Error, Equatable {}

/// Simulated time. `sleep` advances it instead of waiting, records each delay, and, once `limit` has passed (or
/// `maxSleeps` sleeps were asked for), throws `CancellationError`, which ends the feed's loop and so its stream.
final class VirtualClock: Sendable {
    private struct State {
        var now: Duration = .zero
        var delays: [Duration] = []
    }

    private let state = Mutex(State())
    private let limit: Duration?
    private let maxSleeps: Int?

    init(limit: Duration? = nil, maxSleeps: Int? = nil) {
        self.limit = limit
        self.maxSleeps = maxSleeps
    }

    var now: Duration { state.withLock { $0.now } }
    var delays: [Duration] { state.withLock { $0.delays } }

    func advance(by duration: Duration) {
        state.withLock { $0.now += duration }
    }

    var sleep: @Sendable (Duration) async throws -> Void {
        { duration in
            try Task.checkCancellation()
            let stop = self.state.withLock { state -> Bool in
                state.delays.append(duration)
                state.now += duration
                if let limit = self.limit, state.now >= limit { return true }
                if let maxSleeps = self.maxSleeps, state.delays.count >= maxSleeps { return true }
                return false
            }
            if stop { throw CancellationError() }
            await Task.yield()
        }
    }
}

/// What one connect call does.
enum ChaosStep: Sendable {
    /// `connect` throws.
    case fail(any Error)
    /// `connect` never returns (until its task is cancelled).
    case neverAnswers
    /// `connect` returns a connection that delivers `frames`, then `ending`.
    case open(frames: [Data], ending: ChaosEnding)
}

enum ChaosEnding: Sendable {
    /// `receive` throws.
    case closes
    /// `receive` waits until the connection is closed: the server stays connected and says nothing.
    case silent
    /// `receive` throws after `lifetime` of simulated time has passed on `clock`.
    case closesAfter(Duration, VirtualClock)
    /// `receive` throws `WebSocketError.rejected(status:)`: the upgrade was refused (how URLSession reports it).
    case rejects(Int)
}

/// Counters shared by a `ChaosConnector` and its connections.
final class ChaosStats: Sendable {
    private struct State {
        var connectAttempts = 0
        var connectCancellations = 0
        var open = 0
        var maxOpen = 0
        var opened = 0
    }

    private let state = Mutex(State())

    var connectAttempts: Int { state.withLock { $0.connectAttempts } }
    var connectCancellations: Int { state.withLock { $0.connectCancellations } }
    /// Connections returned by `connect` and not yet closed.
    var open: Int { state.withLock { $0.open } }
    /// The most connections that were open at the same time.
    var maxOpen: Int { state.withLock { $0.maxOpen } }
    var opened: Int { state.withLock { $0.opened } }

    func attempt() -> Int {
        state.withLock {
            $0.connectAttempts += 1
            return $0.connectAttempts - 1
        }
    }

    func cancelledConnect() { state.withLock { $0.connectCancellations += 1 } }

    func didOpen() {
        state.withLock {
            $0.open += 1
            $0.opened += 1
            $0.maxOpen = max($0.maxOpen, $0.open)
        }
    }

    func didClose() { state.withLock { $0.open -= 1 } }
}

/// A connector whose every connect attempt is decided by `behavior(attemptIndex)`, counting attempts and open
/// connections.
final class ChaosConnector: WebSocketConnecting {
    let stats = ChaosStats()
    private let behavior: @Sendable (Int) -> ChaosStep

    init(_ behavior: @escaping @Sendable (Int) -> ChaosStep) {
        self.behavior = behavior
    }

    func connect(to url: URL) async throws -> any WebSocketConnection {
        switch behavior(stats.attempt()) {
        case .fail(let error):
            throw error
        case .neverAnswers:
            do { try await Task.sleep(for: .seconds(3600)) } catch {
                stats.cancelledConnect()
                throw error
            }
            throw ConnectionRefused()
        case .open(let frames, let ending):
            let connection = ChaosConnection(frames: frames, ending: ending, stats: stats)
            stats.didOpen()
            return connection
        }
    }
}

final class ChaosConnection: WebSocketConnection {
    private let frames: Mutex<[Data]>
    private let ending: ChaosEnding
    private let stats: ChaosStats
    private let closedFlag = Mutex(false)
    private let closedSignal = AsyncStream<Void>.makeStream()

    init(frames: [Data], ending: ChaosEnding, stats: ChaosStats) {
        self.frames = Mutex(frames)
        self.ending = ending
        self.stats = stats
    }

    var isClosed: Bool { closedFlag.withLock { $0 } }

    /// A silent server (a half-open path) never answers: the ping waits until the connection is closed. Any other
    /// connection answers at once.
    func ping() async throws {
        guard case .silent = ending else { return }
        for await _ in closedSignal.stream {}
        throw ConnectionEnded()
    }

    func receive() async throws -> Data {
        if let next = frames.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { return next }
        switch ending {
        case .closes:
            throw ConnectionEnded()
        case .closesAfter(let lifetime, let clock):
            clock.advance(by: lifetime)
            throw ConnectionEnded()
        case .silent:
            for await _ in closedSignal.stream {}
            throw ConnectionEnded()
        case .rejects(let status):
            throw WebSocketError.rejected(status: status)
        }
    }

    func close() {
        // The feed closes a connection from two places; count it once.
        let first = closedFlag.withLock { flag -> Bool in
            defer { flag = true }
            return !flag
        }
        if first { stats.didClose() }
        closedSignal.continuation.finish()
    }
}

/// Waits (real time, in a few ms steps, at most `grace`) until `condition` holds; returns whether it did.
func eventually(grace: Duration = .seconds(2), _ condition: @Sendable () -> Bool) async -> Bool {
    let steps = Int(grace / .milliseconds(5))
    for _ in 0..<steps {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
