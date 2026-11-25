import Foundation

/// The newest position time the app has received for each kind of target, kept apart from the targets themselves:
/// trains expire after a minute, so when the feed lags, the list can be empty while this still says how old the data is.
public struct DataFreshness: Sendable, Equatable {
    /// Boats report less often than trains (a boat at anchor every few minutes), so a boat feed is called late only
    /// after this long. The list already greys a boat after one minute and drops it after ten.
    public static let boatLateAfter: TimeInterval = 300
    /// MTA's terms ask for a notice when real-time data is more than a minute old; its feeds refresh about every
    /// 30 s, so a healthy feed is well under this.
    public static let trainLateAfter: TimeInterval = 60

    public private(set) var newestBoat: Date?
    public private(set) var newestTrain: Date?

    public init(newestBoat: Date? = nil, newestTrain: Date? = nil) {
        self.newestBoat = newestBoat
        self.newestTrain = newestTrain
    }

    /// Notes the positions in `message`. A time later than `receivedAt` (a source whose clock runs ahead) counts as
    /// `receivedAt`, so such a source can't hide a late feed.
    public mutating func observe(_ message: RelayMessage, receivedAt: Date) {
        switch message {
        case .snapshot(let targets): targets.forEach { observe($0, receivedAt: receivedAt) }
        case .update(let target): observe(target, receivedAt: receivedAt)
        case .remove: break
        }
    }

    private mutating func observe(_ target: Target, receivedAt: Date) {
        let stamp = min(target.timestamp, receivedAt)
        switch target.kind {
        case .vessel: newestBoat = max(newestBoat ?? stamp, stamp)
        case .train: newestTrain = max(newestTrain ?? stamp, stamp)
        case .unknown: break
        }
    }

    /// What to say instead of plain "Live" when connected but the data is old; nil when it is fresh, when nothing of
    /// that kind has arrived, or when the app isn't claiming to be live.
    public func notice(now: Date, isLive: Bool, showTrains: Bool = true) -> String? {
        spoken(now: now, isLive: isLive, showTrains: showTrains, speak: false)
    }

    /// The same notice for VoiceOver ("2 minutes ago" in full).
    public func spokenNotice(now: Date, isLive: Bool, showTrains: Bool = true) -> String? {
        spoken(now: now, isLive: isLive, showTrains: showTrains, speak: true)
    }

    private func spoken(now: Date, isLive: Bool, showTrains: Bool, speak: Bool) -> String? {
        guard isLive else { return nil }
        var parts: [String] = []
        if showTrains, let newestTrain, now.timeIntervalSince(newestTrain) > Self.trainLateAfter {
            parts.append(Self.sentence("Trains", age: now.timeIntervalSince(newestTrain), speak: speak))
        }
        if let newestBoat, now.timeIntervalSince(newestBoat) > Self.boatLateAfter {
            parts.append(Self.sentence("Boats", age: now.timeIntervalSince(newestBoat), speak: speak))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    private static func sentence(_ what: String, age: TimeInterval, speak: Bool) -> String {
        "\(what) last updated " + (speak ? VesselText.spokenAge(seconds: age) : VesselText.age(seconds: age))
    }
}
