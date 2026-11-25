import Foundation
#if DEBUG
import os
import Synchronization
import SwiftUI

/// Chaos tests (docs/CHAOS-FINDINGS.md), debug builds only. With BOATAR_HANG_WATCHDOG=1 a background thread pings the
/// main thread five times a second; a ping that waits more than `threshold` seconds is a hang. Each hang is logged
/// (`BOATAR_HANG <seconds>`, subsystem com.bsowens.BoatAR, category chaos) and counted, and the `hangWatchdog`
/// element's value says "hangs=<count> max=<longest seconds> at=<seconds after launch each began, comma-separated>"
/// so a UI test can read it (and tell a stall during launch from one mid-session).
final class HangWatchdog: Sendable {
    static let shared = HangWatchdog()
    static let threshold: TimeInterval = 2

    private struct State {
        var started = false
        var hangs = 0
        var longest: TimeInterval = 0
        /// When the last counted hang's ping was answered: pings sent before it belong to that same hang.
        var lastHangEnd = Date.distantPast
        /// Seconds after the watchdog started at which each counted hang began.
        var starts: [TimeInterval] = []
        var launched = Date()
    }

    private let state = Mutex(State())
    private let firstAnswered = Atomic<Bool>(false)
    private static let log = Logger(subsystem: "com.bsowens.BoatAR", category: "chaos")

    var summary: String {
        state.withLock { state in
            let starts = state.starts.map { String(format: "%.1f", $0) }.joined(separator: ",")
            return "hangs=\(state.hangs) max=\(String(format: "%.1f", state.longest)) at=\(starts)"
        }
    }

    func start() {
        let alreadyStarted = state.withLock { state in
            defer { state.started = true; state.launched = Date() }
            return state.started
        }
        guard !alreadyStarted else { return }
        let thread = Thread { [self] in
            while true {
                let sent = Date()
                DispatchQueue.main.async { [self] in answered(sent: sent) }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        thread.name = "BoatAR hang watchdog"
        thread.start()
    }

    private func answered(sent: Date) {
        let now = Date()
        let wait = now.timeIntervalSince(sent)
        if !firstAnswered.exchange(true, ordering: .relaxed) {
            launchMark("watchdog ping 1 answered after \(String(format: "%.2f", wait)) s")
        }
        guard wait > Self.threshold else { return }
        let counted = state.withLock { state -> Bool in
            state.longest = max(state.longest, wait)
            guard sent > state.lastHangEnd else { return false }
            state.hangs += 1
            state.lastHangEnd = now
            state.starts.append(sent.timeIntervalSince(state.launched))
            return true
        }
        if counted {
            Self.log.error("BOATAR_HANG \(wait, format: .fixed(precision: 2), privacy: .public) s on the main thread")
        }
    }
}

/// Where the first seconds after launch go (docs/CHAOS-FINDINGS.md, H1), debug builds with BOATAR_HANG_WATCHDOG=1.
/// `launchMark(_:)` records named moments since the process started (from the kernel's start time, so the time
/// before `main` counts too); a main run loop observer records every run loop turn over 100 ms in the first 20 s with
/// the marks that fell inside it. Logged (`BOATAR_LAUNCH`) and shown as the `launchTimeline` element's value.
final class LaunchTimeline: Sendable {
    static let shared = LaunchTimeline()

    private struct State {
        var marks: [(String, TimeInterval)] = []
        var slowTurns: [(start: TimeInterval, length: TimeInterval, marks: [String])] = []
        var turnStart: TimeInterval?
        var marksInTurn: [String] = []
        var observing = false
    }

    private let state = Mutex(State())
    private static let log = Logger(subsystem: "com.bsowens.BoatAR", category: "chaos")
    /// The process's start, from the kernel.
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }()

    static var sinceStart: TimeInterval { Date().timeIntervalSince(processStart) }

    func mark(_ name: String) {
        let t = Self.sinceStart
        let first = state.withLock { state -> Bool in
            guard !state.marks.contains(where: { $0.0 == name }) else { return false }
            state.marks.append((name, t))
            if state.turnStart != nil { state.marksInTurn.append(name) }
            return true
        }
        if first { Self.log.info("BOATAR_LAUNCH \(name, privacy: .public) at \(t, format: .fixed(precision: 3), privacy: .public) s") }
    }

    /// Times each turn of the main run loop for the first 20 s.
    func observeMainRunLoop() {
        let start = state.withLock { state -> Bool in
            defer { state.observing = true }
            return !state.observing
        }
        guard start else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            | CFRunLoopActivity.entry.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [self] _, activity in
            let now = Self.sinceStart
            guard now < 90 else { return }
            state.withLock { state in
                if activity == .afterWaiting || activity == .entry {
                    if state.turnStart == nil { state.turnStart = now; state.marksInTurn = [] }
                } else if let begun = state.turnStart {
                    if now - begun > 0.1 { state.slowTurns.append((begun, now - begun, state.marksInTurn)) }
                    state.turnStart = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        // The turn we're in now (launch) counts from here.
        state.withLock { state in state.turnStart = Self.sinceStart; state.marksInTurn = [] }
    }

    var summary: String {
        state.withLock { state in
            let marks = state.marks.map { "\($0.0)=\(String(format: "%.2f", $0.1))" }.joined(separator: " ")
            let turns = state.slowTurns.map { turn in
                "[\(String(format: "%.2f", turn.start))+\(String(format: "%.2f", turn.length))s: \(turn.marks.joined(separator: ","))]"
            }.joined(separator: " ")
            return "marks: \(marks) | slow turns: \(turns)"
        }
    }
}

/// Chaos tests (D3): who changed the selection, newest last, as the `selectionLog` element's value. Shown with
/// BOATAR_CHAOS_PROBE=1.
@MainActor
@Observable
final class SelectionLog {
    static let shared = SelectionLog()
    private(set) var entries: [String] = []
    private let launched = Date()

    func record(_ entry: String) {
        entries.append(String(format: "%.1f ", Date().timeIntervalSince(launched)) + entry)
        if entries.count > 16 { entries.removeFirst(entries.count - 16) }
    }
}

struct SelectionLogProbe: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("Selection log")
            .accessibilityValue(SelectionLog.shared.entries.joined(separator: " | "))
            .accessibilityIdentifier("selectionLog")
            .allowsHitTesting(false)
    }
}

/// The `launchTimeline` element (see `LaunchTimeline`), refreshed every second.
struct LaunchTimelineProbe: View {
    @State private var summary = LaunchTimeline.shared.summary

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("Launch timeline")
            .accessibilityValue(summary)
            .accessibilityIdentifier("launchTimeline")
            .allowsHitTesting(false)
            .task {
                while !Task.isCancelled {
                    summary = LaunchTimeline.shared.summary
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
}

/// A 1×1 element whose value is the watchdog's summary, refreshed every second.
struct HangWatchdogProbe: View {
    @State private var summary = HangWatchdog.shared.summary

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("Hang watchdog")
            .accessibilityValue(summary)
            .accessibilityIdentifier("hangWatchdog")
            .allowsHitTesting(false)
            .task {
                while !Task.isCancelled {
                    summary = HangWatchdog.shared.summary
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
}

/// Chaos tests: whether night mode is on right now (the root's decision), as the `nightModeProbe` element's value
/// "on" / "off". Shown with BOATAR_CHAOS_PROBE=1.
struct NightModeProbe: View {
    let night: Bool

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("Night mode probe")
            .accessibilityValue(night ? "on" : "off")
            .accessibilityIdentifier("nightModeProbe")
            .allowsHitTesting(false)
    }
}
#endif

/// Records a named launch moment (`LaunchTimeline`); nothing in a release build.
@inline(__always)
func launchMark(_ name: @autoclosure () -> String) {
    #if DEBUG
    LaunchTimeline.shared.mark(name())
    #endif
}

/// Night mode's clock. In debug builds BOATAR_NIGHT_CLOCK_START=<ISO 8601 time> starts it at that moment and checks it
/// every second (at real speed), so a chaos test can cross sunset mid-session; otherwise it is the time now, checked
/// every minute.
enum NightClock {
    #if DEBUG
    private static let launched = Date()
    private static let start: Date? = ProcessInfo.processInfo.environment["BOATAR_NIGHT_CLOCK_START"]
        .flatMap { try? Date($0, strategy: .iso8601) }
    #endif

    static func now() -> Date {
        #if DEBUG
        if let start { return start.addingTimeInterval(Date().timeIntervalSince(launched)) }
        #endif
        return Date()
    }

    static var tick: Duration {
        #if DEBUG
        if start != nil { return .seconds(1) }
        #endif
        return .seconds(60)
    }
}
