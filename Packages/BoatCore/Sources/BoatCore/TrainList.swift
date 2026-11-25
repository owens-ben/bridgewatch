import CoreLocation
import Foundation

/// One train as the list, map and camera show it, relative to the observer when its location is known. Everything a
/// view needs is worked out here: views add no math.
public struct TrainRow: Identifiable, Sendable, Equatable {
    public let train: Train
    /// Where the train probably is now (`DeadReckoning`): the relay's estimate carried forward along the track's
    /// course, for at most `DeadReckoning.trainMaxExtrapolationSeconds`. Distance, bearing and sightline are all
    /// measured to it.
    public var position: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: estimatedLatitude, longitude: estimatedLongitude)
    }
    private let estimatedLatitude: Double
    private let estimatedLongitude: Double
    /// Nil when the observer's location is unknown.
    public let distanceMeters: Double?
    /// Bearing from the observer to the train, degrees from true north; nil when the observer is unknown.
    public let bearingDegrees: Double?
    /// The train's rail above the observer's eye (`Sightlines.eyeAltitude(at:height:)`), meters; negative below it
    /// (every underground train, and a viaduct seen from a high window). Nil when the observer is unknown.
    public let relativeAltitudeMeters: Double?
    /// An underground train's rail below the street: the ground under its estimated position (`SurfaceGrid.ground`)
    /// less its altitude, meters. Nil above ground, where the surface grid has no cell, or when the relay sent no
    /// modelled altitude (`Train.hasModelledAltitude`). Needs no observer.
    public let depthBelowStreetMeters: Double?
    /// Seconds since the position the relay estimated (its `timestamp`).
    public let ageSeconds: TimeInterval
    /// `ReportFreshness.train(lastSeen:now:)`: live under 20 s, stale to 60 s, then expired.
    public let freshness: ReportFreshness
    /// Whether the observer could see it from where they stand (`.underground` for every train below ground); nil
    /// when the observer is unknown.
    public let lineOfSight: LineOfSight?
    /// The units every text is in (Settings > Units): a train's speed is mph or km/h by default, never knots.
    public let units: Units

    public var id: String { train.id }
    /// True only when the observer is known and the train's roof is in sight.
    public var isInSight: Bool { lineOfSight == .inSight }
    public var isUnderground: Bool { train.underground }

    /// - Parameter rangeMeters: farther than this a train above ground is `.tooFar` (the camera's radius).
    /// - Parameter units: the units for the texts.
    public init(train: Train, observer: CLLocationCoordinate2D?, eye: EyeHeight = .altitude(nil), now: Date,
                sightlines: Sightlines = .harbor, rangeMeters: Double = Sightlines.maxRangeMeters,
                units: Units = .standard) {
        self.train = train
        self.units = units
        let position = DeadReckoning.position(of: train, at: now)
        estimatedLatitude = position.latitude
        estimatedLongitude = position.longitude
        distanceMeters = observer.map { distance(from: $0, to: position) }
        bearingDegrees = observer.map { bearing(from: $0, to: position) }
        relativeAltitudeMeters = observer.map { train.altitude - sightlines.eyeAltitude(at: $0, height: eye) }
        depthBelowStreetMeters = train.underground && train.hasModelledAltitude
            ? sightlines.surface.ground(latitude: position.latitude, longitude: position.longitude)
                .map { $0 - train.altitude }
            : nil
        ageSeconds = max(0, now.timeIntervalSince(train.timestamp))
        freshness = .train(lastSeen: train.timestamp, now: now)
        lineOfSight = observer.map {
            sightlines.lineOfSight(from: $0, eye: eye, to: train, at: now, maxRangeMeters: rangeMeters)
        }
    }

    /// The route and where it's going, "Q to 96 St", wherever a train is named (rows, cards, the detail title, camera
    /// labels); "Q train" when the relay doesn't know the destination. The route bullet (`train.bullet`, `train.line`,
    /// `train.isDiamond`) goes beside it.
    public var title: String {
        train.destination.map { "\(train.bullet) to \($0)" } ?? "\(train.bullet) train"
    }

    /// "Underground" for a train below ground, else its stretch ("Manhattan Bridge"), else "Above ground".
    public var placeText: String {
        train.underground ? "Underground" : (train.stretch?.name ?? "Above ground")
    }

    /// "Manhattan Bridge · 21 mph", "Underground · Stopped", or just the place without a speed.
    public var detail: String {
        guard let speedText else { return placeText }
        return "\(placeText) · \(speedText)"
    }

    /// A list row's second line, under a group header that already says where the train is: an underground train's
    /// row drops "Underground" ("Stopped", "21 mph"); the rest are `detail`. Nil when there's nothing left to say.
    public var groupedDetail: String? {
        guard train.underground else { return detail }
        return speedText
    }

    /// "21 mph" (km/h in a metric region, or whatever Settings > Units says; the relay sends knots), or "Stopped" for
    /// a train standing at a station.
    public var speedText: String? {
        guard let speed = train.speed else { return nil }
        return speed < DeadReckoning.minimumSpeedKnots ? "Stopped" : units.speed(knots: speed, kind: .train)
    }

    public var distanceText: String? { distanceMeters.map(units.distance(meters:)) }
    public var bearingText: String? { bearingDegrees.map(VesselText.bearing(degrees:)) }
    public var courseText: String? { train.course.map(VesselText.bearing(degrees:)) }
    public var ageText: String { VesselText.age(seconds: ageSeconds) }
    /// How high the train is. Above ground, against the user's eye: "130 ft up", "30 ft down", "level" ("about 130 ft
    /// up" where the heights are estimated, the Franklin Av shuttle); nil when the observer is unknown. Underground,
    /// below the street: "about 40 ft below street", "just below street" (`TrainText.belowStreet`), never up or level;
    /// nil when there's no depth (`depthBelowStreetMeters`), where views fall back to `placeText`, "Underground".
    public var relativeHeightText: String? {
        if train.underground {
            return depthBelowStreetMeters.map {
                TrainText.belowStreet(meters: $0, estimated: train.altitudeEstimated, units: units.heightSystem)
            }
        }
        return relativeAltitudeMeters.flatMap {
            $0.isFinite ? TrainText.relativeHeight(meters: $0, estimated: train.altitudeEstimated, units: units.heightSystem) : nil
        }
    }

    /// The x-ray camera capsule's depth line: "about 40 ft deep" (`TrainText.compactDepth`) underground; "Underground"
    /// where there's no depth. Above-ground trains have none (they don't get an x-ray label).
    public var xrayDepthText: String {
        guard train.underground, let depth = depthBelowStreetMeters else { return placeText }
        return TrainText.compactDepth(meters: depth, estimated: train.altitudeEstimated, units: units.heightSystem)
    }

    /// "Manhattan Bridge · 120 ft up", "Underground · about 40 ft below street": where the train is and how high.
    /// Just the place when there's no height (`relativeHeightText`).
    public var levelText: String {
        guard let relativeHeightText else { return placeText }
        return "\(placeText) · \(relativeHeightText)"
    }

    /// A camera label's second line: "0.4 mi · 120 ft up" (underground "0.4 mi · about 40 ft below street"), plus
    /// the position's age once it's stale ("0.4 mi · 120 ft up · 40 sec ago").
    public var cameraDetail: String {
        [distanceText, relativeHeightText, freshness == .live ? nil : ageText].compactMap { $0 }
            .joined(separator: " · ")
    }

    /// "Q train", "6 express", "Shuttle": the route as the detail sheet names it beside the bullet.
    public var routeName: String {
        if train.line == .shuttle { return "Shuttle" }
        return train.isDiamond ? "\(train.bullet) express" : "\(train.bullet) train"
    }

    /// "Q train", "6 express train", "shuttle": the route as VoiceOver says it.
    public var spokenRoute: String {
        if train.line == .shuttle { return "shuttle" }
        return train.isDiamond ? "\(train.bullet) express train" : "\(train.bullet) train"
    }

    /// One VoiceOver label for the whole row: "Q train to Coney Island-Stillwell Av, on the Manhattan Bridge, 0.4
    /// miles north, 120 feet above you, 21 miles per hour"; underground "..., underground, 0.2 miles east, about 40 feet below
    /// the street, ...". Stale positions (or `includeAge`, e.g. while offline) also say how old the position is.
    public func accessibilityLabel(includeAge: Bool = false) -> String {
        var parts = [train.destination.map { "\(spokenRoute) to \($0)" } ?? spokenRoute]
        if train.underground {
            parts.append("underground")
        } else {
            parts.append(train.stretch.map { "on the \($0.name)" } ?? "above ground")
        }
        if let distanceMeters, let bearingDegrees {
            parts.append("\(units.spokenDistance(meters: distanceMeters)) \(VesselText.spokenBearing(degrees: bearingDegrees))")
        }
        if train.underground {
            if let depthBelowStreetMeters {
                parts.append(TrainText.spokenBelowStreet(meters: depthBelowStreetMeters,
                                                         estimated: train.altitudeEstimated,
                                                         units: units.heightSystem))
            }
        } else if let relativeAltitudeMeters, relativeAltitudeMeters.isFinite {
            parts.append(TrainText.spokenRelativeHeight(meters: relativeAltitudeMeters,
                                                        estimated: train.altitudeEstimated,
                                                        units: units.heightSystem))
        }
        if let speed = train.speed {
            parts.append(speed < DeadReckoning.minimumSpeedKnots ? "stopped"
                         : units.spokenSpeed(knots: speed, kind: .train))
        }
        if includeAge || freshness != .live {
            parts.append("last report \(VesselText.spokenAge(seconds: ageSeconds))")
        }
        return parts.joined(separator: ", ")
    }
}

/// Trains in three groups, each nearest first: in sight (on a bridge or viaduct with nothing in the way), out of
/// sight (above ground but hidden by land or buildings, or too far), and underground. Without the observer's
/// location there are no distances or sightlines: `inSight` and `outOfSight` are empty, `underground` still lists
/// the trains below ground, and every list is ordered by route, then destination. Expired trains are left out.
public struct TrainList: Sendable, Equatable {
    /// Every train: nearest first, or by route without the observer's location.
    public let rows: [TrainRow]
    public let hasDistances: Bool
    /// Above ground and in sight, nearest first. Empty when the observer is unknown.
    public let inSight: [TrainRow]
    /// Above ground but hidden or too far, nearest first. Empty when the observer is unknown.
    public let outOfSight: [TrainRow]
    /// Below ground, nearest first (by route when the observer is unknown).
    public let underground: [TrainRow]
    /// Above ground, in sight or not: `inSight` then `outOfSight` when the observer is known (nearest first in each),
    /// every above-ground train by route when it isn't, where there are no sightlines to split them by.
    public var aboveGround: [TrainRow] {
        hasDistances ? inSight + outOfSight : rows.filter { !$0.isUnderground }
    }
    /// The observer's eye, meters above sea level (`Sightlines.eyeAltitude(at:height:)`): what the camera projects
    /// trains from. Nil when the observer is unknown.
    public let eyeAltitude: Double?
    /// The time the list was worked out for.
    public let now: Date
    private let observerLatitude: Double?
    private let observerLongitude: Double?

    /// - Parameter eye: how high the observer's eye is, for sightlines and heights.
    /// - Parameter rangeMeters: how far sightlines reach; the camera passes its radius (`CameraRadius`).
    /// - Parameter units: the units the rows' texts are in.
    public init(trains: [Train], observer: CLLocationCoordinate2D?, eye: EyeHeight = .altitude(nil), now: Date,
                sightlines: Sightlines = .harbor, rangeMeters: Double = Sightlines.maxRangeMeters,
                units: Units = .standard) {
        hasDistances = observer != nil
        self.now = now
        observerLatitude = observer?.latitude
        observerLongitude = observer?.longitude
        eyeAltitude = observer.map { sightlines.eyeAltitude(at: $0, height: eye) }
        let live = trains
            .map {
                TrainRow(train: $0, observer: observer, eye: eye, now: now, sightlines: sightlines,
                         rangeMeters: rangeMeters, units: units)
            }
            .filter { $0.freshness != .expired }
        if observer != nil {
            rows = live.sorted { ($0.distanceMeters ?? 0, $0.id) < ($1.distanceMeters ?? 0, $1.id) }
        } else {
            rows = live.sorted {
                ($0.train.route, $0.train.destination ?? "", $0.id) < ($1.train.route, $1.train.destination ?? "", $1.id)
            }
        }
        inSight = rows.filter { $0.lineOfSight == .inSight }
        outOfSight = rows.filter { $0.lineOfSight == .blocked || $0.lineOfSight == .tooFar }
        underground = rows.filter(\.isUnderground)
    }

    /// The observer the list was worked out from; nil when unknown.
    public var observer: CLLocationCoordinate2D? {
        guard let observerLatitude, let observerLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: observerLatitude, longitude: observerLongitude)
    }

    public var isEmpty: Bool { rows.isEmpty }

    public func row(id: String) -> TrainRow? {
        rows.first { $0.id == id }
    }
}

/// A train for the camera to draw, worked out once a second like a vessel's label: between those updates its
/// estimated position goes on along its course (`placement(at:)`), so the label glides with the train.
public struct TrainARTarget: Identifiable, Sendable, Equatable {
    /// The row it was made from: the train and every text the label shows.
    public let row: TrainRow
    /// Meters east and north of the observer at `estimatedAt`.
    public let east: Double
    public let north: Double
    /// Meters per second east and north; zero for a standing train.
    public let velocityEast: Double
    public let velocityNorth: Double
    /// The rail, meters above sea level.
    public let altitude: Double
    /// The observer's eye, meters above sea level.
    public let eyeAltitude: Double
    public let estimatedAt: Date
    /// How much longer after `estimatedAt` the estimate may go on moving (`DeadReckoning.trainMaxExtrapolationSeconds`).
    public let movesFor: TimeInterval

    public var id: String { row.id }
    public var isUnderground: Bool { row.isUnderground }
    public var isMoving: Bool { movesFor > 0 && (velocityEast != 0 || velocityNorth != 0) }

    public init(row: TrainRow, observer: CLLocationCoordinate2D, eyeAltitude: Double, now: Date) {
        self.row = row
        let offset = offset(from: observer, to: row.position)
        east = offset.east
        north = offset.north
        let velocity = DeadReckoning.velocity(speedKnots: row.train.speed, courseDegrees: row.train.course)
        velocityEast = velocity?.east ?? 0
        velocityNorth = velocity?.north ?? 0
        altitude = row.train.altitude
        self.eyeAltitude = eyeAltitude
        estimatedAt = now
        movesFor = DeadReckoning.trainMaxExtrapolationSeconds - DeadReckoning.extrapolation(for: row.train, at: now)
    }

    /// Bearing (degrees from true north) and distance (meters) from the observer at `date`.
    public func placement(at date: Date) -> (bearing: Double, distance: Double) {
        let seconds = min(max(0, date.timeIntervalSince(estimatedAt)), movesFor)
        let e = east + velocityEast * seconds, n = north + velocityNorth * seconds
        let bearing = atan2(e, n) * 180 / .pi
        return (bearing < 0 ? bearing + 360 : bearing, (e * e + n * n).squareRoot())
    }

    /// Where the train's rail lands on screen at `date`: by its true elevation from the observer's eye, so a train on
    /// a bridge sits above the horizon line and one in a tunnel below it.
    public func place(at date: Date, pose: CameraPose) -> ScreenPlacement {
        let at = placement(at: date)
        return ARProjection.place(bearingDegrees: at.bearing, distanceMeters: at.distance, pose: pose,
                                  targetAltitude: altitude, eyeAltitude: eyeAltitude)
    }

    /// The trains for the camera: every train in sight, and separately the underground trains within
    /// `undergroundRadiusMeters`, nearest first, at most `undergroundLimit` of them. The focused train is added
    /// wherever it is ("Find in Camera" points the way even to a train behind buildings or out of range): to
    /// `underground` when it's below ground, else to `inSight`. Empty when the list has no observer.
    public static func targets(in list: TrainList, focus: String? = nil, undergroundRadiusMeters: Double,
                               undergroundLimit: Int) -> TrainARTargets {
        guard let observer = list.observer, let eye = list.eyeAltitude else { return TrainARTargets() }
        var inSight = list.inSight
        var underground = Array(list.underground
            .filter { ($0.distanceMeters ?? .infinity) <= undergroundRadiusMeters }
            .prefix(max(0, undergroundLimit)))
        if let focus, !inSight.contains(where: { $0.id == focus }), !underground.contains(where: { $0.id == focus }),
           let row = list.row(id: focus) {
            if row.isUnderground { underground.append(row) } else { inSight.append(row) }
        }
        func target(_ row: TrainRow) -> TrainARTarget {
            TrainARTarget(row: row, observer: observer, eyeAltitude: eye, now: list.now)
        }
        return TrainARTargets(inSight: inSight.map(target), underground: underground.map(target))
    }
}

/// The trains the camera draws, in two groups it styles differently.
public struct TrainARTargets: Sendable, Equatable {
    /// Above ground and in sight (plus a focused train that isn't), nearest first.
    public var inSight: [TrainARTarget]
    /// Below ground within the radius asked for, nearest first, capped (plus a focused one beyond either).
    public var underground: [TrainARTarget]

    public init(inSight: [TrainARTarget] = [], underground: [TrainARTarget] = []) {
        self.inSight = inSight
        self.underground = underground
    }

    public var all: [TrainARTarget] { inSight + underground }
    public var isEmpty: Bool { inSight.isEmpty && underground.isEmpty }
}
