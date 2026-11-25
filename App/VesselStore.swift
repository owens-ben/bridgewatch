import BoatAIS
import BoatCore
import Foundation
import Observation

/// Vessels and trains currently in view, fed by a `VesselFeed`. Applying relay messages and expiry live in BoatCore's
/// `TargetRegistry`.
@MainActor
@Observable
final class VesselStore {
    enum Status: Equatable {
        /// No relay configured.
        case idle
        case connecting
        case live
        /// The relay dropped or can't be reached; the list is frozen until it comes back.
        case offline
    }

    /// Published at most once every `vesselPublishInterval` (docs/CRASH-HUNT.md, F6): each publish rebuilds every
    /// screen that shows boats (a line-of-sight walk per boat), and AIS messages come in bursts. The first change
    /// after a quiet spell, such as the snapshot, is published at once.
    private(set) var vessels: [Vessel] = []
    /// Published at most once every `trainPublishInterval`: the relay re-sends every train every 10 s, about 80 of
    /// them in a burst, and each message republished on its own would redraw every screen that shows trains 80 times.
    private(set) var trains: [Train] = []
    private(set) var status: Status = .idle
    /// Why the store is offline: the server can't be reached, or it turned the app away (the banner's words).
    private(set) var problem: FeedText.Problem = .unreachable
    /// When each kind's newest position is from. Not observed: the list reads it on its own 5 second clock, so a
    /// message never redraws a screen for this.
    @ObservationIgnored private(set) var freshness = DataFreshness()

    static let vesselPublishInterval = Duration.milliseconds(250)
    static let trainPublishInterval = Duration.seconds(1)
    /// Pruning on a message (it copies the whole registry) runs at most this often; the 30 s loop prunes a quiet feed.
    static let pruneInterval = Duration.seconds(1)
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var vesselThrottle = PublishThrottle<ContinuousClock.Instant>(
        interval: VesselStore.vesselPublishInterval)
    @ObservationIgnored private var trainThrottle = PublishThrottle<ContinuousClock.Instant>(
        interval: VesselStore.trainPublishInterval)
    @ObservationIgnored private var pruneGate = PublishThrottle<ContinuousClock.Instant>(
        interval: VesselStore.pruneInterval)
    @ObservationIgnored private var vesselFlush: Task<Void, Never>?
    @ObservationIgnored private var trainFlush: Task<Void, Never>?

    @ObservationIgnored private var registry = TargetRegistry()
    @ObservationIgnored private var feed: (any VesselFeed)?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Starts consuming `feed`; a nil feed (no relay configured) leaves the store empty and idle.
    func start(feed: (any VesselFeed)?) {
        stop()
        self.feed = feed
        guard let feed else {
            status = .idle
            return
        }
        status = .connecting
        // Both loops end when the store goes away (F9), not only when cancelled: each holds the store weakly and
        // stops at the first turn it's gone, and deinit cancels them.
        tasks.append(Task { [weak self] in
            for await event in feed.events() {
                // stop() cancels this task, but events already buffered in the old stream still arrive; they must
                // not touch the state of the feed that replaced it.
                guard !Task.isCancelled, let self else { break }
                handle(event)
            }
        })
        // Vessels also expire while the feed is quiet.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { break }
                prune()
            }
        })
    }

    isolated deinit {
        stop()
    }

    /// Reconnects now instead of waiting out the feed's backoff.
    func retry() {
        start(feed: feed)
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        vesselFlush?.cancel()
        vesselFlush = nil
        vesselThrottle.cancelScheduled()
        trainFlush?.cancel()
        trainFlush = nil
        trainThrottle.cancelScheduled()
    }

    private func handle(_ event: FeedEvent) {
        switch event {
        case .connecting:
            // Keep showing "offline" through reconnect attempts so the banner doesn't flicker.
            if status != .offline { status = .connecting }
        case .connected:
            launchMark("feed connected")
            problem = .unreachable
            status = .live
        case .disconnected:
            problem = .unreachable
            status = .offline
        case .rejected:
            // The server turned the app away (S3): its own banner text, not "can't reach".
            problem = .rejected
            status = .offline
        case .message(let message):
            let kind = kind(of: message)
            registry.apply(message, receivedAt: now())
            freshness.observe(message, receivedAt: now())
            guard status != .offline else { return }
            if pruneGate.runIfDue(at: clock.now) { registry.prune(now: now()) }
            if kind != .train { scheduleVessels() }
            if kind != .vessel { scheduleTrains() }
        }
    }

    /// Which kind a message changes; nil for a snapshot (both) or a target this store doesn't hold.
    private func kind(of message: RelayMessage) -> TargetKind? {
        switch message {
        case .snapshot: nil
        case .update(let target): target.kind
        case .remove(let id): registry[id]?.kind
        }
    }

    private func prune() {
        // Offline, the list stays frozen (with report ages) rather than emptying itself.
        guard status != .offline else { return }
        registry.prune(now: now())
        scheduleVessels()
        scheduleTrains()
    }

    /// Publishes the vessels now, or once `vesselPublishInterval` after the last publish if that's sooner than now.
    private func scheduleVessels() {
        switch vesselThrottle.request(at: clock.now) {
        case .now:
            publishVessels()
        case .at(let deadline):
            vesselFlush = Task { [weak self, clock] in
                try? await clock.sleep(until: deadline)
                guard !Task.isCancelled, let self else { return }
                vesselFlush = nil
                publishVessels()
            }
        case .scheduled:
            break
        }
    }

    private func publishVessels() {
        vesselThrottle.published(at: clock.now)
        // Don't republish an equal list: observers would redraw for nothing.
        let current = registry.vessels
        if current != vessels { vessels = current }
        launchMark("first vessels published")
    }

    /// Publishes the trains now, or once `trainPublishInterval` after the last publish if that's sooner than now.
    private func scheduleTrains() {
        switch trainThrottle.request(at: clock.now) {
        case .now:
            publishTrains()
        case .at(let deadline):
            trainFlush = Task { [weak self, clock] in
                try? await clock.sleep(until: deadline)
                guard !Task.isCancelled, let self else { return }
                trainFlush = nil
                publishTrains()
            }
        case .scheduled:
            break
        }
    }

    private func publishTrains() {
        trainThrottle.published(at: clock.now)
        let current = registry.trains
        if current != trains { trains = current }
    }
}
