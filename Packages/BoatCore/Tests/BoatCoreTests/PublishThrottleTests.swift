import Testing
@testable import BoatCore

/// F6 (docs/CRASH-HUNT.md): vessel and train publishing is coalesced; these drive the throttle with made-up instants.
@Suite struct PublishThrottleTests {
    let t0 = ContinuousClock.now
    func at(_ milliseconds: Int) -> ContinuousClock.Instant { t0.advanced(by: .milliseconds(milliseconds)) }

    @Test func firstChangePublishesAtOnce() {
        var throttle = PublishThrottle<ContinuousClock.Instant>(interval: .milliseconds(250))
        do { let decision = throttle.request(at: at(0)); #expect(decision == .now) }
    }

    @Test func burstIsGatheredIntoOnePublishAtTheEndOfTheInterval() {
        var throttle = PublishThrottle<ContinuousClock.Instant>(interval: .milliseconds(250))
        do { let decision = throttle.request(at: at(0)); #expect(decision == .now) }
        throttle.published(at: at(0))
        // 80 messages in the next 100 ms: one publish, at 250 ms.
        do { let decision = throttle.request(at: at(10)); #expect(decision == .at(at(250))) }
        for ms in stride(from: 11, to: 100, by: 1) {
            do { let decision = throttle.request(at: at(ms)); #expect(decision == .scheduled) }
        }
        throttle.published(at: at(250))
        // A change right after the scheduled publish waits for the next interval end.
        do { let decision = throttle.request(at: at(260)); #expect(decision == .at(at(500))) }
        throttle.published(at: at(500))
        // After a quiet spell, at once again.
        do { let decision = throttle.request(at: at(2_000)); #expect(decision == .now) }
    }

    @Test func steadyStreamPublishesAtMostOncePerInterval() {
        var throttle = PublishThrottle<ContinuousClock.Instant>(interval: .milliseconds(250))
        var publishes: [Int] = []
        var due: Int?
        // A message every 20 ms for 2 s; a scheduled publish runs when its time comes.
        for ms in stride(from: 0, through: 2_000, by: 20) {
            if let d = due, ms >= d {
                throttle.published(at: at(d))
                publishes.append(d)
                due = nil
            }
            switch throttle.request(at: at(ms)) {
            case .now:
                throttle.published(at: at(ms))
                publishes.append(ms)
            case .at(let instant):
                due = Int((instant - t0) / .milliseconds(1))
            case .scheduled:
                break
            }
        }
        #expect(publishes.first == 0)
        #expect(zip(publishes, publishes.dropFirst()).allSatisfy { $1 - $0 >= 250 })
        #expect(publishes.count == 9) // 0, 250, ..., 2000
    }

    @Test func cancelledScheduleDecidesAfresh() {
        var throttle = PublishThrottle<ContinuousClock.Instant>(interval: .seconds(1))
        throttle.published(at: at(0))
        do { let decision = throttle.request(at: at(100)); #expect(decision == .at(at(1_000))) }
        throttle.cancelScheduled()
        do { let decision = throttle.request(at: at(200)); #expect(decision == .at(at(1_000))) }
    }

    @Test func pruneRunsAtMostOncePerInterval() {
        var gate = PublishThrottle<ContinuousClock.Instant>(interval: .seconds(1))
        do { let ran = gate.runIfDue(at: at(0)); #expect(ran) }
        do { let ran = gate.runIfDue(at: at(500)); #expect(!ran) }
        do { let ran = gate.runIfDue(at: at(999)); #expect(!ran) }
        do { let ran = gate.runIfDue(at: at(1_000)); #expect(ran) }
        do { let ran = gate.runIfDue(at: at(1_500)); #expect(!ran) }
    }
}
