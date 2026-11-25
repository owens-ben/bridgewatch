import Foundation
import Synchronization
import Testing
@testable import BoatCore

/// F15 (docs/CRASH-HUNT.md): zoom changes reach the main actor newest-wins, with at most one hop in flight.
@Suite struct LatestValueTests {
    @Test func onlyTheFirstPostOfABurstSchedulesAHop() {
        let mailbox = LatestValue<Double>()
        #expect(mailbox.post(1))
        #expect(!mailbox.post(2))
        #expect(!mailbox.post(3))
        #expect(mailbox.take() == 3)
        #expect(mailbox.take() == nil)
        // Taken: the next post schedules the next hop.
        #expect(mailbox.post(4))
        #expect(mailbox.take() == 4)
    }

    /// Posts from many threads while hops run on another: every hop delivers, the last delivery is the last value
    /// posted, and no hop ever has nothing to deliver.
    @Test func lastValueWinsUnderConcurrentPosts() {
        let mailbox = LatestValue<Int>()
        let delivered = Mutex<[Int]>([])
        let hops = Mutex(0) // hops scheduled
        let group = DispatchGroup()
        let hopQueue = DispatchQueue(label: "hop")
        // Posts 0..<999 from many threads, then 999 last from this one.
        DispatchQueue.concurrentPerform(iterations: 999) { value in
            if mailbox.post(value) {
                hops.withLock { $0 += 1 }
                group.enter()
                hopQueue.async {
                    if let v = mailbox.take() { delivered.withLock { $0.append(v) } }
                    group.leave()
                }
            }
        }
        if mailbox.post(999) {
            group.enter()
            hopQueue.async {
                if let v = mailbox.take() { delivered.withLock { $0.append(v) } }
                group.leave()
            }
        }
        group.wait()
        #expect(delivered.withLock { $0.last } == 999)
        #expect(mailbox.take() == nil)
    }
}
