import Foundation

/// Text for trains that vessels don't need: height above or below the user (depth below the street underground), and
/// counts. Distances, bearings, speeds
/// and ages use `VesselText`, so both read alike.
public enum TrainText {
    /// Closer than this to the eye's height, in meters, a train counts as level with the user.
    public static let levelMeters = 3.0
    private static let nbsp = "\u{00A0}"

    /// Rail depths below the street shallower than this read "just below street": the relay's depth model never puts
    /// the rail closer to the street than 3 m (its cover rule), so less, or a negative depth, is the ground data and
    /// the model disagreeing, not a real figure.
    public static let shallowMeters = 3.0

    /// Above-ground trains only (an underground train gets `belowStreet`): "130 ft up", "60 ft down", or "level"
    /// within `levelMeters` (the space is non-breaking); "about 130 ft up" when the height is `estimated`; metric
    /// "40 m up". "" when `meters` isn't finite (a NaN eye altitude): no made-up "0 ft down".
    /// - Parameter meters: the train's rail above the user's eye; negative below it.
    public static func relativeHeight(meters: Double, estimated: Bool = false,
                                      units: MeasurementUnits) -> String {
        guard meters.isFinite else { return "" }
        if abs(meters) < levelMeters { return "level" }
        return "\(estimated ? "about " : "")\(depthFigure(abs(meters), units: units, spoken: false)) \(meters > 0 ? "up" : "down")"
    }

    /// "130 feet above you", "60 feet below you", "level with you"; "about 130 feet above you" when `estimated`; ""
    /// when `meters` isn't finite.
    public static func spokenRelativeHeight(meters: Double, estimated: Bool = false,
                                            units: MeasurementUnits) -> String {
        guard meters.isFinite else { return "" }
        if abs(meters) < levelMeters { return "level with you" }
        return "\(estimated ? "about " : "")\(depthFigure(abs(meters), units: units, spoken: true)) \(meters > 0 ? "above" : "below") you"
    }

    /// An underground train's depth: "40 ft below street", "about 40 ft below street" when `estimated`, "just below
    /// street" under `shallowMeters` (the spaces in the figure are non-breaking). Metric: "about 12 m below street".
    /// - Parameter meters: the ground under the train less its rail altitude.
    public static func belowStreet(meters: Double, estimated: Bool,
                                   units: MeasurementUnits) -> String {
        guard meters >= shallowMeters else { return "just below street" }
        return "\(estimated ? "about " : "")\(depthFigure(meters, units: units, spoken: false)) below street"
    }

    /// The camera x-ray capsule's short form of `belowStreet`: "about 40 ft deep", "40 ft deep" when not `estimated`,
    /// "under 10 ft deep" under `shallowMeters` ("under 3 m deep" metric). "Deep", not "below street", also reads right
    /// for a train in a river tube. The list, sheet and VoiceOver keep the long wording.
    public static func compactDepth(meters: Double, estimated: Bool,
                                    units: MeasurementUnits) -> String {
        guard meters >= shallowMeters else {
            let limit = units == .imperial ? "10\(nbsp)ft" : "3\(nbsp)m"
            return "under \(limit) deep"
        }
        return "\(estimated ? "about " : "")\(depthFigure(meters, units: units, spoken: false)) deep"
    }

    /// "about 40 feet below the street", "40 feet below the street", "just below the street".
    public static func spokenBelowStreet(meters: Double, estimated: Bool,
                                         units: MeasurementUnits) -> String {
        guard meters >= shallowMeters else { return "just below the street" }
        return "\(estimated ? "about " : "")\(depthFigure(meters, units: units, spoken: true)) below the street"
    }

    /// "40 ft" / "40 feet" to the nearest 10 ft, or "12 m" / "12 meters" to the nearest meter (`Units.height`).
    private static func depthFigure(_ meters: Double, units: MeasurementUnits, spoken: Bool) -> String {
        Units(preferences: UnitPreferences(height: units == .imperial ? .feet : .meters))
            .height(meters: meters, spoken: spoken)
    }

    /// "1 train", "4 trains".
    public static func count(_ n: Int) -> String {
        n == 1 ? "1 train" : "\(n) trains"
    }

    /// What the Trains section says when it has no trains: "No trains in the area right now.", or while the relay
    /// connection is down "Trains need a live connection." (a train moves about 15 m/s, so its last position is
    /// worth nothing after a minute and trains, unlike boats, are dropped then, offline too).
    public static func emptyNote(offline: Bool) -> String {
        offline ? "Trains need a live connection." : "No trains in the area right now."
    }
}
