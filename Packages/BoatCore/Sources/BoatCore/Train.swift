import CoreLocation
import Foundation

/// The named above-ground stretch a train is on (relay/PROTOCOL.md, "Levels").
public enum TrainStretch: Sendable, Hashable {
    case manhattanBridge
    case williamsburgBridge
    case culverViaduct
    /// The Franklin Av shuttle's embankment, south of Franklin Av (estimated heights).
    case franklinAv
    /// A stretch from a newer relay, with its ID as sent.
    case other(String)

    /// The stretch with the relay's ID: `manhattan-bridge`, `williamsburg-bridge`, `culver-viaduct`, `franklin-av`.
    public init(id: String) {
        switch id {
        case "manhattan-bridge": self = .manhattanBridge
        case "williamsburg-bridge": self = .williamsburgBridge
        case "culver-viaduct": self = .culverViaduct
        case "franklin-av": self = .franklinAv
        default: self = .other(id)
        }
    }

    /// The relay's ID.
    public var id: String {
        switch self {
        case .manhattanBridge: "manhattan-bridge"
        case .williamsburgBridge: "williamsburg-bridge"
        case .culverViaduct: "culver-viaduct"
        case .franklinAv: "franklin-av"
        case .other(let id): id
        }
    }

    /// "Manhattan Bridge"; an unknown stretch's ID with its words capitalized.
    public var name: String {
        switch self {
        case .manhattanBridge: "Manhattan Bridge"
        case .williamsburgBridge: "Williamsburg Bridge"
        case .culverViaduct: "Culver Viaduct"
        case .franklinAv: "Franklin Av Shuttle"
        case .other(let id): id.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
        }
    }
}

/// Current state of one subway train: a train target from the relay (relay/PROTOCOL.md, "Trains"). Its position is
/// the relay's estimate along the track: MTA's feeds carry no GPS.
public struct Train: Sendable, Equatable, Identifiable {
    /// Rail height for an underground train whose target has no `altitude` (the relay always sends one): the flat
    /// figure relays sent for every underground train before the depth model. Only a fallback; a train placed at it
    /// has no depth to show (`hasModelledAltitude` is false).
    public static let fallbackUndergroundAltitude = -10.0
    /// Car roofs above the rail (about 3.7 m; PROTOCOL says check the sightline to the rail height + 3).
    public static let roofAboveRailMeters = 3.0
    /// A position newer than this many seconds is live: the relay re-sends every train at least every 10 s, so a
    /// live train has missed at most one update. Older ones are stale until `TargetRegistry.trainMaxAge`.
    public static let liveSeconds: TimeInterval = 20

    /// The target's `id`, `train:nyct:<trip ID>`.
    public let id: String
    /// Route ID from the feed: `B`, `6X`, `FS`, ... (see `line` and `bullet`).
    public var route: String
    public var direction: TrainDirection
    /// Name of the trip's last stop, e.g. `Coney Island-Stillwell Av`.
    public var destination: String?
    /// The above-ground stretch the relay says the train is on; nil for most underground trains. `underground` (not a
    /// missing stretch) says whether it is below ground.
    public var stretch: TrainStretch?
    /// True for every train not on a stretch: in a tunnel, or at a station below ground.
    public var underground: Bool
    public var latitude: Double
    public var longitude: Double
    /// Rail height, meters above sea level: measured (or estimated, on `franklin-av`) on a stretch, modelled from
    /// station depths and river tube low points underground (relay/PROTOCOL.md, "Levels").
    public var altitude: Double
    /// True when `altitude` follows rule-based figures, so the app says "about": every underground train today, and
    /// the Franklin Av shuttle. False when the relay doesn't say (an older relay).
    public var altitudeEstimated: Bool
    /// True when `altitude` is the relay's model of this train's height: the target had an `altitude` and came from a
    /// relay that sends `altitudeEstimated`. An older relay's underground altitude was a flat placeholder, so it
    /// gives no depth below the street.
    public var hasModelledAltitude: Bool
    /// Direction of travel along the track, degrees true.
    public var course: Double?
    /// Knots: the average speed of the run between two stations, 0 while standing at one.
    public var speed: Double?
    /// The time the position is estimated for: dead reckoning extrapolates from it, and the age is measured to it.
    public var timestamp: Date

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The top of the cars, meters above sea level: what has to be visible to see the train.
    public var roofAltitude: Double { altitude + Self.roofAboveRailMeters }

    /// The route's trunk line.
    public var line: SubwayLine { SubwayLine(route: route) }
    /// The route's bullet text: `6` for `6X`, `S` for a shuttle.
    public var bullet: String { SubwayLine.bullet(route: route) }
    /// True for an express variant drawn in a diamond (`6X`, `FX`).
    public var isDiamond: Bool { SubwayLine.isDiamond(route: route) }

    /// The train a train target describes, or nil for any other target, or for one with a position, speed or course
    /// that can't be real (not finite, or a latitude or longitude out of range, or a negative speed: a missing course
    /// or speed is fine). A target without an `altitude` (the relay always sends one) is put at
    /// `fallbackUndergroundAltitude` when underground, else at sea level.
    /// Faster than this (about 230 mph) a train's speed is treated as unknown.
    public static let maxSpeedKnots = 200.0

    public init?(_ target: Target) {
        guard target.kind == .train, let details = target.train else { return nil }
        guard target.lat.isFinite, target.lon.isFinite, abs(target.lat) <= 90, abs(target.lon) <= 180 else { return nil }
        if let speed = target.speed, !(speed.isFinite && speed >= 0) { return nil }
        if let course = target.course, !course.isFinite { return nil }
        if let altitude = target.altitude, !altitude.isFinite { return nil }
        id = target.id
        route = details.route
        direction = details.direction
        destination = details.destination
        stretch = details.stretch.map(TrainStretch.init(id:))
        underground = details.underground
        latitude = target.lat
        longitude = target.lon
        altitude = target.altitude ?? (details.underground ? Self.fallbackUndergroundAltitude : 0)
        altitudeEstimated = details.altitudeEstimated ?? false
        hasModelledAltitude = target.altitude != nil && details.altitudeEstimated != nil
        // In [0, 360) as the protocol says, so the course text can't trap on a huge value.
        course = target.course.flatMap(normalizedDegrees)
        // Faster than any train runs is a bad estimate: no speed, rather than one.
        speed = target.speed.flatMap { $0 <= Self.maxSpeedKnots ? $0 : nil }
        timestamp = target.timestamp
    }
}
