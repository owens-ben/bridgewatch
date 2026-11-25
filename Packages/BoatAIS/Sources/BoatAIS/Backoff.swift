/// Exponential reconnect delay with jitter: `base * 2^attempt`, capped, then a random point in its upper half.
public struct Backoff: Sendable, Equatable {
    public var base: Duration
    public var cap: Duration

    public init(base: Duration = .seconds(1), cap: Duration = .seconds(60)) {
        self.base = base
        self.cap = cap
    }

    /// - Parameters:
    ///   - attempt: 0 for the first retry after a connection ends.
    ///   - unitRandom: a value in [0, 1]; 0 gives half the delay, 1 the full delay. Outside it is clamped, and NaN
    ///     gives the full delay (`Duration * NaN` would trap).
    public func delay(attempt: Int, unitRandom: Double) -> Duration {
        let exponent = min(max(attempt, 0), 30)
        let full = min(cap, base * (1 << exponent))
        let jitter = unitRandom.isNaN ? 1 : min(max(unitRandom, 0), 1)
        return full / 2 + (full / 2) * jitter
    }
}
