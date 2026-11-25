import Synchronization

/// How the feed tells a connection that still looks open from one that works (docs/CRASH-HUNT.md, F1 and F11).
///
/// A socket can stop delivering without failing: the relay process wedged, the tunnel stalled, or a half-open TCP
/// path after a Wi-Fi to cellular handover. `receive()` then waits forever. The feed pings the relay every
/// `pingInterval`; no pong within `pongTimeout` closes the connection, so the feed reports `.disconnected` and
/// reconnects with backoff. The relay sends its snapshot as soon as a client connects (relay/PROTOCOL.md, "On
/// connect, exactly one snapshot"), so a connection with no message this version can decode within
/// `firstMessageTimeout` (a wrong host or path, a protocol it doesn't speak) is closed the same way. There's no idle
/// timeout after that: the protocol promises no cadence (a quiet harbor sends nothing for minutes), and the ping
/// covers a dead path.
public struct Liveness: Sendable, Equatable {
    public var pingInterval: Duration
    public var pongTimeout: Duration
    public var firstMessageTimeout: Duration

    public init(pingInterval: Duration = .seconds(15), pongTimeout: Duration = .seconds(10),
                firstMessageTimeout: Duration = .seconds(20)) {
        self.pingInterval = pingInterval
        self.pongTimeout = pongTimeout
        self.firstMessageTimeout = firstMessageTimeout
    }
}

/// A continuation that is resumed exactly once, whichever comes first: the value (from a callback, a deadline or a
/// cancellation handler) or `arm` (the continuation itself). Later values are dropped.
final class ResumeOnce<Value: Sendable>: Sendable {
    private enum State {
        case idle
        case armed(CheckedContinuation<Value, Never>)
        /// Resolved before the continuation was armed.
        case resolved(Value)
        case finished
    }

    private let state = Mutex(State.idle)

    /// Hands over the continuation; resumes it at once if a value came first. Call once.
    func arm(_ continuation: CheckedContinuation<Value, Never>) {
        let ready: Value? = state.withLock { state in
            switch state {
            case .idle:
                state = .armed(continuation)
                return nil
            case .resolved(let value):
                state = .finished
                return value
            case .armed, .finished:
                return nil
            }
        }
        if let ready { continuation.resume(returning: ready) }
    }

    /// Resumes with `value` unless something already did. Returns whether this call was the one.
    @discardableResult
    func resume(_ value: Value) -> Bool {
        let action: (CheckedContinuation<Value, Never>?, Bool) = state.withLock { state in
            switch state {
            case .idle:
                state = .resolved(value)
                return (nil, true)
            case .armed(let continuation):
                state = .finished
                return (continuation, true)
            case .resolved, .finished:
                return (nil, false)
            }
        }
        action.0?.resume(returning: value)
        return action.1
    }
}

enum PingOutcome: Sendable, Equatable {
    case pong
    /// The ping failed (the connection closed or errored).
    case failed
    case timedOut
    /// The caller was cancelled.
    case cancelled
}

/// Pings and waits at most `timeout` for the pong. Returns as soon as one of pong, failure, deadline or the caller's
/// cancellation happens, even if the connection's `ping()` ignores cancellation (its late answer is dropped).
func ping(_ connection: any WebSocketConnection, timeout: Duration,
          timer: @escaping @Sendable (Duration) async throws -> Void) async -> PingOutcome {
    let once = ResumeOnce<PingOutcome>()
    let pinging = Task {
        do {
            try await connection.ping()
            once.resume(.pong)
        } catch {
            once.resume(.failed)
        }
    }
    let deadline = Task {
        do {
            try await timer(timeout)
            once.resume(.timedOut)
        } catch {
            // Cancelled: the ping answered first.
        }
    }
    let outcome = await withTaskCancellationHandler {
        await withCheckedContinuation { once.arm($0) }
    } onCancel: {
        once.resume(.cancelled)
    }
    pinging.cancel()
    deadline.cancel()
    return outcome
}
