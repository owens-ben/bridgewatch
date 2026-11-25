import Foundation

/// What a boat's map marker shows besides its type disc: a wedge pointing the way it's going, and its finer type name
/// under it once the map is zoomed in.
public enum VesselMap {
    /// The course wedge shows above this speed: slower, a reported course is mostly noise (and dead reckoning keeps
    /// the boat still, `DeadReckoning.minimumSpeedKnots`).
    public static let courseMinimumKnots = 0.5
    /// Type labels show under markers while the visible span is at most this many meters (about DUMBO to the
    /// Williamsburg Bridge): wider, the labels of a busy stretch run into each other.
    public static let typeLabelMaxSpanMeters = 2_500.0

    /// The course wedge's rotation on screen, degrees clockwise from straight up: the course over ground less the
    /// map's own heading (a rotated map turns the water under the marker, not the marker). Nil, so no wedge, when
    /// the boat is at most `courseMinimumKnots`, or its speed or course is unknown or not a number.
    public static func courseArrowDegrees(speedKnots: Double?, courseDegrees: Double?, mapHeading: Double = 0) -> Double? {
        guard let speedKnots, let courseDegrees, speedKnots.isFinite, courseDegrees.isFinite, mapHeading.isFinite,
              speedKnots > courseMinimumKnots else { return nil }
        let degrees = (courseDegrees - mapHeading).truncatingRemainder(dividingBy: 360)
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// True when a marker's type label shows: always for the selected boat, for the others once zoomed in.
    public static func showsTypeLabel(visibleSpanMeters: Double, selected: Bool) -> Bool {
        selected || visibleSpanMeters <= typeLabelMaxSpanMeters
    }
}

/// The text of the map's summary card for the selected boat or train (compact width).
public struct MapCardText: Sendable, Equatable {
    /// Name (plain text) or destination.
    public let title: String
    /// "Pilot · 6.8 kn", "Q train · Manhattan Bridge · 18.4 kn".
    public let subtitle: String
    /// "Moored · to PIER 11 WALL ST"; nil when there's nothing to say.
    public let status: String?
    /// "0.2 mi · NE 41°"; nil without the user's location.
    public let distance: String?
    /// The whole card for VoiceOver.
    public let accessibilityLabel: String
}

/// The order the map draws its markers in: later ones on top.
public enum MapMarkerOrder {
    /// `items` with the selected one moved to the end, so it's drawn last, on top; the rest keep their order. The
    /// markers keep their identities, so moving one in the order doesn't rebuild it (its selection animation runs).
    public static func selectedLast<T>(_ items: [T], isSelected: (T) -> Bool) -> [T] {
        items.filter { !isSelected($0) } + items.filter(isSelected)
    }
}

/// Whether a selected boat or train is still there to show: it ages out as everywhere else (a boat after
/// `TargetRegistry.vesselMaxAge`, a train after `TargetRegistry.trainMaxAge`) or leaves what the app shows (a train
/// hidden in Settings isn't in the list passed in). A selection whose target is gone is cleared.
public enum SelectionCheck {
    public static func vesselIsShown(mmsi: Int, in vessels: [Vessel], now: Date) -> Bool {
        vessels.contains { $0.mmsi == mmsi && ReportFreshness(lastSeen: $0.lastSeen, now: now) != .expired }
    }

    /// - Parameter trains: the trains shown (after the Settings toggles).
    public static func trainIsShown(id: String, in trains: [Train], now: Date) -> Bool {
        trains.contains { $0.id == id && ReportFreshness.train(lastSeen: $0.timestamp, now: now) != .expired }
    }
}

extension VesselRow {
    /// The map card: name, finer type and speed, status and destination when sent, distance and bearing. The
    /// VoiceOver label carries all of it (the card's status line and "More info" button aren't read separately).
    public var mapCard: MapCardText {
        let subtitle = speedText.map { "\(typeName) · \($0)" } ?? typeName
        let distance = distanceText.map { distance in bearingText.map { "\(distance) · \($0)" } ?? distance }
        var spoken = [title, typeName.lowercased()]
        if let cardStatus { spoken.append(cardStatus) }
        if let distanceMeters, let bearingDegrees {
            spoken.append("\(units.spokenDistance(meters: distanceMeters)) \(VesselText.spokenBearing(degrees: bearingDegrees))")
        }
        if let sog = vessel.sog { spoken.append(units.spokenSpeed(knots: sog, kind: .vessel)) }
        return MapCardText(title: title, subtitle: subtitle, status: cardStatus, distance: distance,
                           accessibilityLabel: spoken.joined(separator: ", "))
    }
}

extension TrainRow {
    /// The map card: destination, route, where it runs and its speed, distance and height against the user.
    public var mapCard: MapCardText {
        let distance = [distanceText, bearingText, relativeHeightText].compactMap { $0 }
        return MapCardText(title: title, subtitle: routeName, status: detail,
                           distance: distance.isEmpty ? nil : distance.joined(separator: " · "),
                           accessibilityLabel: accessibilityLabel())
    }
}

/// The map key: what each marker means.
public enum MapKey {
    /// The boat groups, in the key's order.
    public static let categories = VesselCategory.allCases

    /// A train to draw the key's route bullets with: a Q (the line through DUMBO), above ground or underground.
    public static func sampleTrain(underground: Bool) -> Train {
        Train(Target(
            id: "train:key:\(underground ? "underground" : "above")", kind: .train, source: "key",
            lat: devBoundingBox.center.latitude, lon: devBoundingBox.center.longitude,
            altitude: underground ? Train.fallbackUndergroundAltitude : 40, timestamp: Date(timeIntervalSince1970: 0),
            train: TrainDetails(route: "Q", direction: .north, stretch: underground ? nil : "manhattan-bridge",
                                underground: underground)))!
    }

    public static let trainAboveGround = "On bridges, viaducts and open track. Solid bullet."
    public static let trainUnderground = "In tunnels. Outlined, shown when zoomed in."
    /// "The wedge on a boat's marker points the way it's going (over 0.5 kn)", the speed in the user's unit.
    public static func courseWedge(units: Units) -> String {
        "The wedge on a boat's marker points the way it's going "
            + "(over \(units.speed(knots: DeadReckoning.minimumSpeedKnots, kind: .vessel)))"
    }
}
