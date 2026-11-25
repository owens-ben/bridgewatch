import CoreLocation
import Foundation

/// A vessel for the camera to draw, worked out once a second rather than on every compass reading. A moving boat
/// keeps moving between those updates: its estimated position (dead reckoning) goes on along its course
/// (`placement(at:)`), so the label glides with the boat instead of jumping once a second or waiting for the next AIS
/// report.
public struct VesselARTarget: Identifiable, Sendable, Equatable {
    public let id: Int
    public let category: VesselCategory
    /// Meters east and north of the observer at `estimatedAt`.
    public let east: Double
    public let north: Double
    /// Meters per second east and north; zero for a stopped boat.
    public let velocityEast: Double
    public let velocityNorth: Double
    /// The observer's eye, meters above sea level: the same eye trains are placed from (`TrainARTarget`), so boats
    /// and trains share one horizon.
    public let eyeAltitude: Double
    public let estimatedAt: Date
    /// How much longer after `estimatedAt` the estimate may go on moving (`DeadReckoning.maxExtrapolationSeconds`).
    public let movesFor: TimeInterval
    public let title: String
    /// "14.2 kn · 0.2 mi", plus the report's age once it's a minute old (`VesselRow.cameraDetail`).
    public let detail: String
    public let accessibilityLabel: String

    public var isMoving: Bool { movesFor > 0 && (velocityEast != 0 || velocityNorth != 0) }

    /// - Parameter eyeAltitude: the observer's eye, meters above sea level (`VesselList.eyeAltitude`).
    public init(row: VesselRow, observer: CLLocationCoordinate2D, eyeAltitude: Double, now: Date) {
        id = row.id
        category = row.category
        let offset = offset(from: observer, to: row.position)
        east = offset.east
        north = offset.north
        let velocity = DeadReckoning.velocity(speedKnots: row.vessel.sog, courseDegrees: row.vessel.cog)
        velocityEast = velocity?.east ?? 0
        velocityNorth = velocity?.north ?? 0
        self.eyeAltitude = eyeAltitude
        estimatedAt = now
        movesFor = DeadReckoning.maxExtrapolationSeconds - DeadReckoning.extrapolation(for: row.vessel, at: now)
        title = row.title
        detail = row.cameraDetail
        accessibilityLabel = row.accessibilityLabel()
    }

    /// The vessels in sight, plus the focused one wherever it is: "Find in Camera" points the way even to a boat
    /// behind land. Empty when the list has no observer.
    public static func targets(in list: VesselList, focus: Int? = nil) -> [VesselARTarget] {
        guard let observer = list.observer, let eye = list.eyeAltitude else { return [] }
        var rows = list.inSight
        if let focus, !rows.contains(where: { $0.id == focus }), let row = list.row(mmsi: focus) {
            rows.append(row)
        }
        return rows.map { VesselARTarget(row: $0, observer: observer, eyeAltitude: eye, now: list.now) }
    }

    /// Bearing (degrees from true north) and distance (meters) from the observer at `date`.
    public func placement(at date: Date) -> (bearing: Double, distance: Double) {
        let seconds = min(max(0, date.timeIntervalSince(estimatedAt)), movesFor)
        let e = east + velocityEast * seconds, n = north + velocityNorth * seconds
        let bearing = atan2(e, n) * 180 / .pi
        return (bearing < 0 ? bearing + 360 : bearing, (e * e + n * n).squareRoot())
    }

    /// Where the boat's waterline lands on screen at `date`, seen from the observer's eye.
    public func place(at date: Date, pose: CameraPose) -> ScreenPlacement {
        let at = placement(at: date)
        return ARProjection.place(bearingDegrees: at.bearing, distanceMeters: at.distance, pose: pose,
                                  targetAltitude: 0, eyeAltitude: eyeAltitude)
    }
}
