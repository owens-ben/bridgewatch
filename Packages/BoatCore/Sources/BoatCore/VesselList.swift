import CoreLocation
import Foundation

/// One vessel as the list, map and detail screens show it, relative to the observer when its location is known.
public struct VesselRow: Identifiable, Sendable, Equatable {
    public let vessel: Vessel
    public let category: VesselCategory
    /// Where the vessel probably is now (`DeadReckoning`): the last report carried forward along its course.
    /// Distance, bearing and sightline are all measured to it.
    public var position: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: estimatedLatitude, longitude: estimatedLongitude)
    }
    private let estimatedLatitude: Double
    private let estimatedLongitude: Double
    /// Nil when the observer's location is unknown.
    public let distanceMeters: Double?
    /// Bearing from the observer to the vessel, degrees from true north; nil when the observer is unknown.
    public let bearingDegrees: Double?
    public let ageSeconds: TimeInterval
    public let freshness: ReportFreshness
    /// Whether the observer could see it from where they stand; nil when the observer is unknown.
    public let lineOfSight: LineOfSight?
    /// The units every text is in (Settings > Units).
    public let units: Units

    public var id: Int { vessel.mmsi }

    /// - Parameter rangeMeters: farther than this the vessel is `.tooFar` (the camera's radius).
    /// - Parameter units: the units for the texts.
    public init(vessel: Vessel, observer: CLLocationCoordinate2D?, eye: EyeHeight = .altitude(nil), now: Date,
                sightlines: Sightlines = .harbor, rangeMeters: Double = Sightlines.maxRangeMeters,
                units: Units = .standard) {
        self.vessel = vessel
        self.units = units
        category = VesselCategory(aisShipType: vessel.shipType)
        let position = DeadReckoning.position(of: vessel, at: now)
        estimatedLatitude = position.latitude
        estimatedLongitude = position.longitude
        distanceMeters = observer.map { distance(from: $0, to: position) }
        bearingDegrees = observer.map { bearing(from: $0, to: position) }
        ageSeconds = max(0, now.timeIntervalSince(vessel.lastSeen))
        freshness = ReportFreshness(lastSeen: vessel.lastSeen, now: now)
        lineOfSight = observer.map {
            sightlines.lineOfSight(from: $0, eye: eye, to: position, maxRangeMeters: rangeMeters)
        }
    }

    /// The vessel's name (plain text: the crew types it in, `VesselDetailText.plain`), or "Unnamed boat" until its
    /// name arrives (the detail sheet still shows its MMSI, the number it broadcasts).
    public var title: String {
        VesselDetailText.plain(vessel.name) ?? Self.unnamed
    }

    /// The title of a boat that hasn't sent its name.
    public static let unnamed = "Unnamed boat"

    /// "Passenger · 14.2 kn", or just the category without a speed.
    public var detail: String {
        guard let sog = vessel.sog else { return category.detailName }
        return "\(category.detailName) · \(units.speed(knots: sog, kind: .vessel))"
    }

    /// The finer type ("Pilot", "Tanker") from the AIS ship type; the `category` is its group.
    public var typeName: String { AISShipType.name(vessel.shipType) }

    public var distanceText: String? { distanceMeters.map(units.distance(meters:)) }
    public var bearingText: String? { bearingDegrees.map(VesselText.bearing(degrees:)) }
    public var speedText: String? { vessel.sog.map { units.speed(knots: $0, kind: .vessel) } }
    public var courseText: String? { vessel.cog.map(VesselText.bearing(degrees:)) }
    public var ageText: String { VesselText.age(seconds: ageSeconds) }

    /// A camera label's second line: "14.2 kn · 0.2 mi", plus the report's age once it's a minute old ("6.1 kn · 0.4
    /// mi · 2 min ago").
    public var cameraDetail: String {
        [speedText, distanceText, freshness == .live ? nil : ageText].compactMap { $0 }.joined(separator: " · ")
    }

    /// One VoiceOver label for the whole row: "HARBOR LARK, passenger, 0.2 miles northwest, 14 knots".
    /// Stale reports (or `includeAge`, e.g. while offline) also say how old the report is.
    public func accessibilityLabel(includeAge: Bool = false) -> String {
        var parts = [title, category.spokenName]
        if let distanceMeters, let bearingDegrees {
            parts.append("\(units.spokenDistance(meters: distanceMeters)) \(VesselText.spokenBearing(degrees: bearingDegrees))")
        }
        if let sog = vessel.sog { parts.append(units.spokenSpeed(knots: sog, kind: .vessel)) }
        if includeAge || freshness != .live {
            parts.append("last report \(VesselText.spokenAge(seconds: ageSeconds))")
        }
        return parts.joined(separator: ", ")
    }
}

/// Vessels nearest first. With the observer's location known they split into those in sight (the closest one is
/// the card, then the rest) and those out of sight: hidden by land or buildings, or too far. Without it there are no
/// distances or sightlines: every row is listed, by name, and there is no closest vessel.
public struct VesselList: Sendable, Equatable {
    public let rows: [VesselRow]
    public let hasDistances: Bool
    /// In sight, nearest first. Empty when the observer is unknown.
    public let inSight: [VesselRow]
    /// Hidden or too far, nearest first. Empty when the observer is unknown.
    public let outOfSight: [VesselRow]
    /// The observer's eye, meters above sea level (`Sightlines.eyeAltitude(at:height:)`): what the camera projects
    /// boats from, the same eye `TrainList` gives trains, so both share one horizon. Nil when the observer is unknown.
    public let eyeAltitude: Double?
    /// The time the list was worked out for.
    public let now: Date
    private let observerLatitude: Double?
    private let observerLongitude: Double?

    /// - Parameter eye: how high the observer's eye is, for sightlines.
    /// - Parameter rangeMeters: how far sightlines reach; the camera passes its radius (`CameraRadius`).
    /// - Parameter units: the units the rows' texts are in.
    public init(vessels: [Vessel], observer: CLLocationCoordinate2D?, eye: EyeHeight = .altitude(nil), now: Date,
                sightlines: Sightlines = .harbor, rangeMeters: Double = Sightlines.maxRangeMeters,
                units: Units = .standard) {
        hasDistances = observer != nil
        self.now = now
        observerLatitude = observer?.latitude
        observerLongitude = observer?.longitude
        eyeAltitude = observer.map { sightlines.eyeAltitude(at: $0, height: eye) }
        let live = vessels
            .map {
                VesselRow(vessel: $0, observer: observer, eye: eye, now: now, sightlines: sightlines,
                          rangeMeters: rangeMeters, units: units)
            }
            .filter { $0.freshness != .expired }
        if observer != nil {
            rows = live.sorted { ($0.distanceMeters ?? 0, $0.vessel.mmsi) < ($1.distanceMeters ?? 0, $1.vessel.mmsi) }
        } else {
            rows = live.sorted {
                let order = $0.title.localizedCaseInsensitiveCompare($1.title)
                return order == .orderedSame ? $0.vessel.mmsi < $1.vessel.mmsi : order == .orderedAscending
            }
        }
        inSight = rows.filter { $0.lineOfSight == .inSight }
        outOfSight = rows.filter { $0.lineOfSight != nil && $0.lineOfSight != .inSight }
    }

    /// The observer the list was worked out from; nil when unknown.
    public var observer: CLLocationCoordinate2D? {
        guard let observerLatitude, let observerLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: observerLatitude, longitude: observerLongitude)
    }

    /// The nearest vessel in sight.
    public var closest: VesselRow? { inSight.first }
    /// The rest of the main list: in sight after the closest, or every row when the observer is unknown.
    public var others: ArraySlice<VesselRow> { hasDistances ? inSight.dropFirst() : rows[...] }
    public var isEmpty: Bool { rows.isEmpty }

    public func row(mmsi: Int) -> VesselRow? {
        rows.first { $0.vessel.mmsi == mmsi }
    }
}
