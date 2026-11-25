import Foundation

/// Every target the relay has sent and not removed (relay/PROTOCOL.md, "/v2/targets"). There is nothing to merge:
/// the relay sends each target's full state, so a newer message replaces what's held for its `id` (see `apply`).
public struct TargetRegistry: Sendable, Equatable {
    /// `prune(now:)` drops vessels whose position is older than this many seconds.
    public static let vesselMaxAge: TimeInterval = 600
    /// ... and trains older than this: the relay re-sends a train at least every 10 s.
    public static let trainMaxAge: TimeInterval = 60

    /// How far ahead of the receive time a target's timestamp is believed (see `apply`).
    public static let maxFutureLead: TimeInterval = 900

    private var byID: [String: Target] = [:]

    public init() {}

    public var count: Int { byID.count }

    public subscript(id: String) -> Target? { byID[id] }

    /// Every target held, sorted by `id`.
    public var targets: [Target] {
        byID.values.sorted { $0.id < $1.id }
    }

    /// The vessel targets as boats, one per MMSI, sorted by MMSI. The relay keeps target ids and MMSIs 1:1
    /// (`vessel:<mmsi>`), but the screens identify boats by MMSI, so two targets with one MMSI (a relay outside the
    /// contract) would give duplicate ids: the one with the newest position wins (on a tie, the lower `id`).
    public var vessels: [Vessel] {
        var byMMSI: [Int: Vessel] = [:]
        for target in byID.values.sorted(by: { $0.id < $1.id }) {
            guard let vessel = Vessel(target) else { continue }
            if let held = byMMSI[vessel.mmsi], held.lastSeen >= vessel.lastSeen { continue }
            byMMSI[vessel.mmsi] = vessel
        }
        return byMMSI.values.sorted { $0.mmsi < $1.mmsi }
    }

    /// The train targets as trains, sorted by `id`.
    public var trains: [Train] {
        byID.values.compactMap(Train.init).sorted { $0.id < $1.id }
    }

    /// A snapshot replaces everything (the relay is the source of truth after a reconnect); an update replaces the
    /// target with its `id`; a remove deletes it.
    ///
    /// Newest wins: an update timestamped before what's held for its `id` is out of date and ignored (the relay keeps
    /// the newest too, relay/src/registry.ts); one with the same timestamp applies, so a re-send with new fields
    /// lands. Within a snapshot the newest per `id` is held whatever the array order (on a tie, the later one).
    ///
    /// A target this version can't use (a kind it doesn't know, no object for its kind, or a boat or train with a
    /// position that can't be real) is never held. As an update that isn't out of date, it removes what was held for
    /// its `id`: the relay meant to replace that state, so the old state is wrong now. In a snapshot it's skipped.
    ///
    /// A target timestamped more than `maxFutureLead` after `receivedAt` (a source whose clock runs far ahead of ours)
    /// is held as if timestamped `receivedAt + maxFutureLead`, so `prune` drops it at most that long plus its max age
    /// after it arrived instead of keeping it for the whole connection. (Its age reads 0 meanwhile: the screens clamp
    /// it.) The newest-wins comparison uses these held timestamps. A smaller lead is kept as sent: clocks differ by
    /// seconds, and the UI and performance tests stamp their replayed targets 10 minutes ahead so they stay live
    /// through a long test.
    public mutating func apply(_ message: RelayMessage, receivedAt: Date = Date()) {
        switch message {
        case .snapshot(let targets):
            var fresh: [String: Target] = [:]
            for target in targets {
                let target = Self.clamped(target, receivedAt: receivedAt)
                guard Self.isUsable(target) else { continue }
                if let held = fresh[target.id], target.timestamp < held.timestamp { continue }
                fresh[target.id] = target
            }
            byID = fresh
        case .update(let target):
            let target = Self.clamped(target, receivedAt: receivedAt)
            if let held = byID[target.id], target.timestamp < held.timestamp { return }
            byID[target.id] = Self.isUsable(target) ? target : nil
        case .remove(let id):
            byID[id] = nil
        }
    }

    /// A safety net for a relay that stops sending removes: drops the targets whose `timestamp` is more than their
    /// kind's max age before `now`.
    public mutating func prune(now: Date) {
        byID = byID.filter { _, target in
            guard let maxAge = Self.maxAge(of: target) else { return false }
            return now.timeIntervalSince(target.timestamp) <= maxAge
        }
    }

    /// `target` with its timestamp held to at most `maxFutureLead` after `receivedAt`.
    private static func clamped(_ target: Target, receivedAt: Date) -> Target {
        var target = target
        let latest = receivedAt.addingTimeInterval(maxFutureLead)
        if target.timestamp > latest { target.timestamp = latest }
        return target
    }

    /// Whether this version can hold `target`: a known kind with its object, and for a boat or train a position that
    /// can be real (one that can't would never show anyway).
    private static func isUsable(_ target: Target) -> Bool {
        switch target.kind {
        case .vessel: Vessel(target) != nil
        case .train: Train(target) != nil
        case .unknown: false
        }
    }

    /// The max age of a target this version can use, or nil for any other.
    private static func maxAge(of target: Target) -> TimeInterval? {
        switch target.kind {
        case .vessel: target.vessel == nil ? nil : vesselMaxAge
        case .train: target.train == nil ? nil : trainMaxAge
        case .unknown: nil
        }
    }
}
