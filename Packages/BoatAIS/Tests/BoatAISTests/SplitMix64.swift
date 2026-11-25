import Foundation
import Testing

/// A tiny seeded random generator (SplitMix64) so a failing chaos run can be replayed: set `BOATAR_CHAOS_SEED`.
struct SplitMix64: RandomNumberGenerator {
    /// The seed for this process: `BOATAR_CHAOS_SEED` if it parses as a UInt64, else a fixed default.
    static let defaultSeed: UInt64 = {
        if let text = ProcessInfo.processInfo.environment["BOATAR_CHAOS_SEED"], let seed = UInt64(text) { return seed }
        return 0xB0A7_A12C_4A05
    }()

    private var state: UInt64
    let seed: UInt64

    init(seed: UInt64 = SplitMix64.defaultSeed) {
        self.seed = seed
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Appended to every property test's failure message.
    var report: Comment { "(seed \(seed); replay with BOATAR_CHAOS_SEED=\(seed))" }
}
