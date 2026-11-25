import Synchronization

/// Hands the newest of a fast stream of values (a zoom ramp's 30-60 changes a second) to another actor with at most
/// one hop in flight (docs/CRASH-HUNT.md, F15). `post` from any thread; when it returns true, schedule one hop that
/// calls `take`. A value posted after a `take` schedules the next hop, so the last value always arrives and an older
/// one can never land after it: each hop takes whatever is newest when it runs.
public final class LatestValue<Value: Sendable>: Sendable {
    private let pending = Mutex<Value?>(nil)

    public init() {}

    /// Stores `value` in place of any not yet taken. Returns true when no hop is pending: the caller schedules one.
    public func post(_ value: Value) -> Bool {
        pending.withLock { pending in
            defer { pending = value }
            return pending == nil
        }
    }

    /// The newest value posted since the last take, or nil if there's none.
    public func take() -> Value? {
        pending.withLock { pending in
            defer { pending = nil }
            return pending
        }
    }
}
