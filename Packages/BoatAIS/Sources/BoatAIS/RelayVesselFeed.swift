import BoatCore
import Foundation
import Synchronization

/// Streams vessels from the relay (relay/PROTOCOL.md) and reconnects with backoff. A relay that refuses the
/// app (HTTP 401/403 on the upgrade, `WebSocketError.rejected`) gives `.rejected` instead of `.disconnected`, and the
/// next try waits the backoff's cap.
public struct RelayVesselFeed: VesselFeed {
    public let url: URL
    private let connector: any WebSocketConnecting
    private let backoff: Backoff
    private let random: @Sendable () -> Double
    private let sleep: @Sendable (Duration) async throws -> Void
    private let liveness: Liveness
    private let timer: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - sleep: waits out a backoff delay.
    ///   - liveness: when a connection counts as dead though it's still open (see `Liveness`).
    ///   - timer: waits for the liveness intervals; separate from `sleep` so tests can skip backoff delays and still
    ///     run the liveness checks on real (short) intervals.
    public init(
        url: URL,
        connector: any WebSocketConnecting = URLSessionWebSocketConnector(),
        backoff: Backoff = Backoff(),
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        liveness: Liveness = Liveness(),
        timer: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.url = url
        self.connector = connector
        self.backoff = backoff
        self.random = random
        self.sleep = sleep
        self.liveness = liveness
        self.timer = timer
    }

    public func events() -> AsyncStream<FeedEvent> {
        let current = CurrentConnection()
        return AsyncStream { continuation in
            let task = Task {
                var attempt = 0
                while !Task.isCancelled {
                    continuation.yield(.connecting)
                    var rejected = false
                    do {
                        let connection = try await connector.connect(to: url)
                        current.set(connection)
                        if Task.isCancelled { connection.close() }
                        let outcome = await pump(connection, into: continuation)
                        if outcome.delivered { attempt = 0 }
                        rejected = outcome.rejected
                        connection.close()
                        current.set(nil)
                    } catch {
                        rejected = error is WebSocketError
                    }
                    if Task.isCancelled { break }
                    continuation.yield(rejected ? .rejected : .disconnected)
                    // A refusal won't go away in seconds (someone has to fix the token): retry at the cap.
                    let delay = backoff.delay(attempt: rejected ? Self.capAttempt : attempt, unitRandom: random())
                    attempt += 1
                    do { try await sleep(delay) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                // URLSession's receive() doesn't observe task cancellation; closing the socket ends it.
                current.close()
            }
        }
    }

    /// An attempt high enough that `Backoff.delay` gives its cap.
    private static let capAttempt = 30

    /// Why `pump` stopped reading a connection.
    private enum PumpEnd: Sendable {
        /// `receive()` failed: the connection closed or errored.
        case connectionEnded
        /// `receive()` reported that the server refused the upgrade (`WebSocketError.rejected`).
        case rejected
        /// No pong within the deadline, or the ping failed (F1).
        case noPong
        /// No decodable message within `firstMessageTimeout` (F11).
        case noMessage
        /// A first message arrived in time; keep waiting for the others.
        case firstMessageInTime
        /// The feed is stopping.
        case cancelled
    }

    /// Forwards frames until the connection fails, stops answering pings, or delivers nothing decodable in time; it
    /// is closed in each case. Returns whether any message arrived, and whether the server refused the connection.
    private func pump(
        _ connection: any WebSocketConnection, into continuation: AsyncStream<FeedEvent>.Continuation
    ) async -> (delivered: Bool, rejected: Bool) {
        let delivered = Atomic(false)
        let liveness = liveness, timer = timer
        let end = await withTaskGroup(of: PumpEnd.self) { group -> PumpEnd? in
            group.addTask {
                while !Task.isCancelled {
                    let data: Data
                    do {
                        data = try await connection.receive()
                    } catch is WebSocketError {
                        return .rejected
                    } catch {
                        return .connectionEnded
                    }
                    // A frame we can't decode is skipped rather than dropping the connection (a newer relay may send
                    // message types this version doesn't know); the first-message deadline covers a connection that
                    // sends nothing but such frames.
                    guard let message = try? RelayMessage.decode(data) else { continue }
                    if !delivered.exchange(true, ordering: .sequentiallyConsistent) {
                        continuation.yield(.connected)
                    }
                    continuation.yield(.message(message))
                }
                return .cancelled
            }
            group.addTask {
                do { try await timer(liveness.firstMessageTimeout) } catch { return .cancelled }
                return delivered.load(ordering: .sequentiallyConsistent) ? .firstMessageInTime : .noMessage
            }
            group.addTask {
                while true {
                    do { try await timer(liveness.pingInterval) } catch { return .cancelled }
                    switch await ping(connection, timeout: liveness.pongTimeout, timer: timer) {
                    case .pong: continue
                    case .failed, .timedOut: return .noPong
                    case .cancelled: return .cancelled
                    }
                }
            }
            var end: PumpEnd?
            repeat { end = await group.next() } while end == .firstMessageInTime
            // Whatever ended first, end the rest: closing makes a pending receive() throw (URLSession's doesn't
            // observe cancellation), and cancelling ends the timers and a pending ping.
            connection.close()
            group.cancelAll()
            return end
        }
        let wasDelivered = delivered.load(ordering: .sequentiallyConsistent)
        return (wasDelivered, end == .rejected && !wasDelivered)
    }
}

/// The open connection, so stopping the stream can close it from another task.
private final class CurrentConnection: Sendable {
    private let connection = Mutex<(any WebSocketConnection)?>(nil)

    func set(_ new: (any WebSocketConnection)?) {
        connection.withLock { $0 = new }
    }

    func close() {
        connection.withLock { $0?.close() }
    }
}
