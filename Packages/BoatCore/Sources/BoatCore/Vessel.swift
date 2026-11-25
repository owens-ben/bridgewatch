import CoreLocation
import Foundation

/// Current state of one vessel, keyed by MMSI: a vessel target from the relay (relay/PROTOCOL.md, "Vessels").
public struct Vessel: Sendable, Equatable, Identifiable {
    public let mmsi: Int
    public var name: String?
    public var shipType: Int?
    public var latitude: Double
    public var longitude: Double
    public var sog: Double?
    public var cog: Double?
    public var heading: Double?
    /// How old the report is, for its age in the list and its freshness: the time of the newest position (its
    /// target's timestamp; a newer message without a position, such as static data, doesn't make a report fresher).
    public var lastSeen: Date
    /// The time of the position (its target's timestamp), which dead reckoning extrapolates from.
    public var positionTimestamp: Date
    /// AIS details (relay/PROTOCOL.md, "Vessels"), nil when not sent. `callSign` and `destination` (like `name`) are
    /// untrusted text typed in by the crew: shown as plain text only (`VesselDetailText.plain`).
    public var imo: Int?
    public var callSign: String?
    public var destination: String?
    public var eta: VesselETA?
    /// Meters.
    public var length: Int?
    /// Meters.
    public var beam: Int?
    /// Meters.
    public var draught: Double?
    /// AIS navigational status 0-14.
    public var navStatus: Int?

    public var id: Int { mmsi }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The highest speed AIS can report, knots.
    public static let maxSpeedKnots = 102.2

    /// The vessel a vessel target describes, or nil for any other target, or for one whose position can't be real
    /// (not finite, or a latitude or longitude out of range), like `Train`. A course or heading that isn't finite is
    /// no course or heading; any other is brought into [0, 360) (the relay sends them there already).
    public init?(_ target: Target) {
        guard target.kind == .vessel, let details = target.vessel else { return nil }
        guard target.lat.isFinite, target.lon.isFinite, abs(target.lat) <= 90, abs(target.lon) <= 180 else { return nil }
        mmsi = details.mmsi
        name = target.name
        shipType = details.shipType
        latitude = target.lat
        longitude = target.lon
        // AIS speed over ground tops out at 102.2 kn; anything else (negative, not finite, more) is no speed.
        sog = target.speed.flatMap { $0.isFinite && $0 >= 0 && $0 <= Self.maxSpeedKnots ? $0 : nil }
        cog = target.course.flatMap(normalizedDegrees)
        heading = target.heading.flatMap(normalizedDegrees)
        lastSeen = target.timestamp
        positionTimestamp = target.timestamp
        imo = details.imo
        callSign = details.callSign
        destination = details.destination
        eta = details.eta
        length = details.length
        beam = details.beam
        draught = details.draught
        navStatus = details.navStatus
    }
}
