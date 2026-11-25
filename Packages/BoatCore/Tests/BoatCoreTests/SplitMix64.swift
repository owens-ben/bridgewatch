import Foundation

/// A tiny seeded generator (SplitMix64) for the chaos tests: the same seed gives the same inputs, so a failure
/// replays. Set `BOATAR_CHAOS_SEED` (decimal or 0x-hex) to try other inputs; every failure message names the seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Chaos {
    static let defaultSeed: UInt64 = 0xB0A7_AC1D_2026_1118

    /// The run's seed: `BOATAR_CHAOS_SEED` when set and readable, else a fixed default.
    static let seed: UInt64 = {
        guard let text = ProcessInfo.processInfo.environment["BOATAR_CHAOS_SEED"] else { return defaultSeed }
        if text.hasPrefix("0x"), let value = UInt64(text.dropFirst(2), radix: 16) { return value }
        return UInt64(text) ?? defaultSeed
    }()

    /// A generator for one test: the run's seed mixed with the test's name, so tests don't share a stream.
    static func rng(_ name: String) -> SplitMix64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return SplitMix64(seed: seed ^ hash)
    }

    /// The text every property failure carries: the seed, the iteration and the input.
    static func context(_ name: String, iteration: Int, _ input: @autoclosure () -> String) -> Comment {
        "seed=\(seed) test=\(name) iteration=\(iteration) input=\(input().prefix(600))"
    }
}

import Testing

extension SplitMix64 {
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func double(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &self) }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
    mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &self)] }
}
