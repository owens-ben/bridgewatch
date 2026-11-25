import CoreLocation

/// How high the user's eye is.
public enum EyeHeight: Sendable, Equatable {
    /// Measured altitude above sea level (GPS). Nil when unknown: the user is taken to be standing on the ground.
    case altitude(Double?)
    /// Set by the user: this far above the ground under them, e.g. about 3 m a floor at an apartment window.
    case aboveGround(Double)
}

/// Whether the user could plausibly see a target from where they stand.
public enum LineOfSight: Sendable, Equatable {
    case inSight
    /// Land or buildings rise above the line between the user's eye and the target.
    case blocked
    /// Farther than the range checked (`Sightlines.maxRangeMeters` unless the camera's radius says otherwise): a
    /// speck, even with nothing in the way.
    case tooFar
    /// Below ground (a train in a tunnel or an underground station): never in sight, wherever the user stands.
    case underground
}

/// A rough line-of-sight check over a `SurfaceGrid`: is anything (ground or roof) higher than the straight line from
/// the user's eye to the target? Rough on purpose: the grid is ~50 m and holds each cell's highest point, and trees,
/// bridges, the Earth's curve and refraction are ignored (under half a meter at 5 km). Targets are anything with a
/// position and a height, not only boats.
public struct Sightlines: Sendable {
    /// The default range: beyond it a boat is `.tooFar`. The camera's radius (`CameraRadius`) can change it.
    public static let maxRangeMeters = 5_000.0
    /// Eye above the ground when the user's height isn't known, or is set lower than this.
    public static let standingEyeMeters = 1.6
    /// The eye is never taken to be lower than this above sea level: the waterfront's bulkheads and piers stand a few
    /// meters above the water, and GPS often puts someone at the river's edge in the river.
    public static let lowestEyeMeters = 4.0
    /// A boat's wheelhouse and upper deck above the water: the part that has to be visible to spot it.
    public static let vesselTopMeters = 8.0
    /// The user's own building and street don't count: GPS puts them tens of meters off, and they look out of a
    /// window or past a corner, not through their own walls.
    public static let observerClearanceMeters = 75.0
    /// A boat's own pier or slip doesn't count.
    public static let targetClearanceMeters = 50.0
    /// A target whose top stands at least this many meters above the ground under it is elevated: a train on a
    /// bridge or a viaduct (the Manhattan Bridge's rail is 30-40 m up). A boat's upper deck (`vesselTopMeters` over the
    /// water) never is, so boats keep the exact rule.
    public static let elevatedTargetMeters = 10.0
    /// The line is checked every this many meters (the grid is ~50 m).
    static let stepMeters = 20.0
    /// How far a cell must rise above the line to block it: the grid's heights are rough.
    static let toleranceMeters = 1.0

    public let surface: SurfaceGrid

    public init(surface: SurfaceGrid) {
        self.surface = surface
    }

    public static let harbor = Sightlines(surface: .harbor)

    /// The user's eye, meters above sea level.
    public func eyeAltitude(at observer: CLLocationCoordinate2D, height: EyeHeight) -> Double {
        let ground = surface.ground(latitude: observer.latitude, longitude: observer.longitude) ?? 0
        let eye = switch height {
        case .altitude(let altitude):
            // GPS altitude can come out below the ground: never lower than standing on it.
            max(altitude ?? -.infinity, ground + Self.standingEyeMeters)
        case .aboveGround(let meters):
            ground + max(meters, Self.standingEyeMeters)
        }
        return max(eye, Self.lowestEyeMeters)
    }

    /// True when a target `targetAltitude` meters above sea level stands at least `elevatedTargetMeters` above the
    /// ground under it.
    public func isElevated(_ target: CLLocationCoordinate2D, targetAltitude: Double) -> Bool {
        let ground = surface.ground(latitude: target.latitude, longitude: target.longitude) ?? 0
        return targetAltitude - ground >= Self.elevatedTargetMeters
    }

    /// - Parameter targetAltitude: the top of what has to be visible, meters above sea level: a boat's upper deck by
    ///   default.
    ///
    /// An elevated target (`isElevated`, a train on a bridge or viaduct) stands clear of the roofs beside it, but each
    /// ~50 m cell holds the tallest roof anywhere in it, so the cells around a bridge hold the buildings along it, and
    /// the bridge (not in the grid) would read as hidden behind its own neighbors. For an elevated target its own cell
    /// and the eight around it (about one cell diagonal, ~70 m) don't count. Anything farther along the line still
    /// does, and for every other target (every boat) the rule is unchanged.
    /// - Parameter maxRangeMeters: farther than this the target is `.tooFar`, whatever is in the way.
    public func lineOfSight(from observer: CLLocationCoordinate2D, eye: EyeHeight, to target: CLLocationCoordinate2D,
                            targetAltitude: Double = vesselTopMeters,
                            maxRangeMeters: Double = Sightlines.maxRangeMeters) -> LineOfSight {
        let meters = distance(from: observer, to: target)
        guard meters <= maxRangeMeters else { return .tooFar }
        let eyeAltitude = eyeAltitude(at: observer, height: eye)
        let targetCell = isElevated(target, targetAltitude: targetAltitude)
            ? surface.cell(latitude: target.latitude, longitude: target.longitude) : nil
        let dLat = target.latitude - observer.latitude, dLon = target.longitude - observer.longitude
        var along = Self.observerClearanceMeters
        while along < meters - Self.targetClearanceMeters {
            let f = along / meters
            let latitude = observer.latitude + f * dLat, longitude = observer.longitude + f * dLon
            along += Self.stepMeters
            if let targetCell, let cell = surface.cell(latitude: latitude, longitude: longitude),
               abs(cell.row - targetCell.row) <= 1, abs(cell.column - targetCell.column) <= 1 {
                continue
            }
            if let top = surface.top(latitude: latitude, longitude: longitude),
               top > eyeAltitude + f * (targetAltitude - eyeAltitude) + Self.toleranceMeters {
                return .blocked
            }
        }
        return .inSight
    }

    /// Whether the user could see the train at `now`: `.underground` for a train below ground (no check runs),
    /// otherwise the line to its roof (`Train.roofAltitude`) at its estimated position (`DeadReckoning`).
    public func lineOfSight(from observer: CLLocationCoordinate2D, eye: EyeHeight, to train: Train,
                            at now: Date, maxRangeMeters: Double = Sightlines.maxRangeMeters) -> LineOfSight {
        guard !train.underground else { return .underground }
        return lineOfSight(from: observer, eye: eye, to: DeadReckoning.position(of: train, at: now),
                           targetAltitude: train.roofAltitude, maxRangeMeters: maxRangeMeters)
    }
}
