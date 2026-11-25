/// When to publish state that changes in bursts (docs/CRASH-HUNT.md, F6): the first change after a quiet spell goes
/// out at once (first data appears immediately), and the changes that follow within `interval` of a publish are
/// gathered into one publish at the end of it. Every change is published within `interval`.
///
/// Pure: the caller passes the time, so tests drive it with made-up instants.
public struct PublishThrottle<Instant: InstantProtocol>: Sendable where Instant.Duration == Duration {
    public enum Decision: Sendable, Equatable {
        /// Publish now (then call `published(at:)`).
        case now
        /// Schedule one publish at this time (then call `published(at:)` when it runs).
        case at(Instant)
        /// A publish is already scheduled; it will include this change.
        case scheduled
    }

    public let interval: Duration
    public private(set) var lastPublish: Instant?
    public private(set) var isScheduled = false

    public init(interval: Duration) {
        self.interval = interval
    }

    /// Something changed at `now`.
    public mutating func request(at now: Instant) -> Decision {
        if isScheduled { return .scheduled }
        guard let lastPublish, now < lastPublish.advanced(by: interval) else { return .now }
        isScheduled = true
        return .at(lastPublish.advanced(by: interval))
    }

    /// A publish ran at `now` (at once or scheduled).
    public mutating func published(at now: Instant) {
        lastPublish = now
        isScheduled = false
    }

    /// A scheduled publish was dropped (the feed stopped): the next change decides afresh.
    public mutating func cancelScheduled() {
        isScheduled = false
    }

    /// For work that only needs to run at most once per `interval` and can be skipped otherwise (pruning): true, and
    /// counts as run, when the last run was at least `interval` before `now`.
    public mutating func runIfDue(at now: Instant) -> Bool {
        if let lastPublish, now < lastPublish.advanced(by: interval) { return false }
        lastPublish = now
        return true
    }
}
