/// Conversions that can't trap on values from outside the app (the relay, sensors, AVFoundation).

/// `degrees` in [0, 360), or nil when it isn't finite.
public func normalizedDegrees(_ degrees: Double) -> Double? {
    guard degrees.isFinite else { return nil }
    let remainder = degrees.truncatingRemainder(dividingBy: 360)
    let result = remainder < 0 ? remainder + 360 : remainder
    // -tiny + 360 rounds up to exactly 360.
    return result >= 360 ? 0 : result
}

extension Int {
    /// The nearest whole number toward zero, saturating: NaN is 0 and anything past ±2^53 is ±2^53. `Int(_:)` traps
    /// on NaN, infinity and anything past ±2^63; this never does.
    public init(saturating value: Double) {
        let limit = 9_007_199_254_740_992.0 // 2^53: every Int up to it is exact in a Double
        guard !value.isNaN else {
            self = 0
            return
        }
        self = Int(Swift.min(Swift.max(value, -limit), limit))
    }
}
