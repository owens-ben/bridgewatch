import CoreLocation
import Foundation

/// Where a moving target probably is now: its last reported position carried forward along its course at its
/// speed. AIS reports reach the relay every few seconds at best, and around DUMBO often only every minute or two:
/// long enough for a ferry to cover hundreds of meters, so drawing the last report leaves the label behind the boat.
/// Trains get a fresh estimate every 10 s and are carried forward for a shorter time (relay/PROTOCOL.md, "Trains").
public enum DeadReckoning {
    /// A vessel report is carried forward at most this long: past that the boat may well have turned, slowed or
    /// docked.
    public static let maxExtrapolationSeconds: TimeInterval = 120
    /// A train is carried forward at most this long: the relay re-sends every train every 10 s, so 15 s covers one
    /// missed update. Longer, the track curves, trains stop at stations, and the track changes level where a tunnel
    /// meets a stretch: 30 s carried a stale train about 450 m past a bridge portal, still drawn as elevated.
    public static let trainMaxExtrapolationSeconds: TimeInterval = 15
    /// Slower than this, in knots, the target counts as stopped: a moored boat's GPS wanders at about a knot, and a
    /// train standing at a station reports 0.
    public static let minimumSpeedKnots = 0.5
    static let metersPerSecondPerKnot = 1_852.0 / 3_600

    /// Whether a boat or train at this speed counts as moving (`minimumSpeedKnots` or faster); an unknown speed
    /// doesn't. The camera's "Moving only" filter uses the same floor.
    public static func isMoving(speedKnots: Double?) -> Bool {
        guard let speedKnots else { return false }
        return speedKnots >= minimumSpeedKnots
    }

    /// Velocity over ground in meters per second, east and north; nil when stopped, or when the speed or course
    /// is unknown.
    public static func velocity(speedKnots: Double?, courseDegrees: Double?) -> (east: Double, north: Double)? {
        guard let speedKnots, let courseDegrees, isMoving(speedKnots: speedKnots) else { return nil }
        let speed = speedKnots * metersPerSecondPerKnot
        let course = courseDegrees * .pi / 180
        return (speed * sin(course), speed * cos(course))
    }

    /// How far a position reported at `timestamp` is carried forward at `now`: the time since, at most `limit` (and
    /// never backwards, should the report's clock run ahead of ours).
    public static func extrapolation(since timestamp: Date, at now: Date, limit: TimeInterval) -> TimeInterval {
        min(max(0, now.timeIntervalSince(timestamp)), limit)
    }

    /// A position reported at `timestamp`, carried forward to `now` along `courseDegrees` at `speedKnots` for at most
    /// `limit` seconds. Stopped, or without a speed or course, it stays put.
    public static func position(
        from coordinate: CLLocationCoordinate2D, speedKnots: Double?, courseDegrees: Double?, reportedAt timestamp: Date,
        at now: Date, limit: TimeInterval
    ) -> CLLocationCoordinate2D {
        guard let velocity = velocity(speedKnots: speedKnots, courseDegrees: courseDegrees) else { return coordinate }
        let seconds = extrapolation(since: timestamp, at: now, limit: limit)
        return moved(coordinate, east: velocity.east * seconds, north: velocity.north * seconds)
    }

    // MARK: Vessels

    /// How far the vessel's last position is carried forward at `now`, at most `maxExtrapolationSeconds`.
    public static func extrapolation(for vessel: Vessel, at now: Date) -> TimeInterval {
        extrapolation(since: vessel.positionTimestamp, at: now, limit: maxExtrapolationSeconds)
    }

    /// The vessel's estimated position at `now`.
    public static func position(of vessel: Vessel, at now: Date) -> CLLocationCoordinate2D {
        position(from: vessel.coordinate, speedKnots: vessel.sog, courseDegrees: vessel.cog,
                 reportedAt: vessel.positionTimestamp, at: now, limit: maxExtrapolationSeconds)
    }

    // MARK: Trains

    /// How far the train's estimate is carried forward at `now`, at most `trainMaxExtrapolationSeconds`.
    public static func extrapolation(for train: Train, at now: Date) -> TimeInterval {
        extrapolation(since: train.timestamp, at: now, limit: trainMaxExtrapolationSeconds)
    }

    /// The train's estimated position at `now`. A train standing at a station (speed 0) stays there.
    public static func position(of train: Train, at now: Date) -> CLLocationCoordinate2D {
        position(from: train.coordinate, speedKnots: train.speed, courseDegrees: train.course,
                 reportedAt: train.timestamp, at: now, limit: trainMaxExtrapolationSeconds)
    }
}
