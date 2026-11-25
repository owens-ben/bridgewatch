import Foundation

/// Text for vessel bearings, report ages and round setting distances: shown and spoken (VoiceOver) forms. Distances
/// and speeds are `Units`' (they follow the unit settings).
public enum VesselText {
    /// Between a number and its unit in the shown forms: a narrow screen (the Duo cover) must not wrap "14.2" and
    /// "kn" onto two lines.
    private static let nbsp = "\u{00A0}"

    /// A round number of miles, as a setting shows it: "½ mi", "1 mi", "10 mi" (the space is non-breaking). NaN or a
    /// negative value reads 0.
    public static func roundMiles(_ miles: Double) -> String {
        let miles = roundMilesValue(miles)
        return (miles == 0.5 ? "½" : String(format: "%g", miles)) + nbsp + "mi"
    }

    /// "half a mile", "1 mile", "10 miles".
    public static func spokenRoundMiles(_ miles: Double) -> String {
        let miles = roundMilesValue(miles)
        if miles == 0.5 { return "half a mile" }
        let text = String(format: "%g", miles)
        return text == "1" ? "1 mile" : "\(text) miles"
    }

    /// A setting's miles within 0...Earth's half circumference (NaN is 0), so "%g" never prints "nan" or "inf".
    private static func roundMilesValue(_ miles: Double) -> Double {
        Units.clamp(miles, to: Units.maxDistanceMeters / 1_609.344)
    }

    private static let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    private static let spokenPoints = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]

    /// 0-7 for N-NW, from degrees already in [0, 360).
    private static func pointIndex(_ normalized: Double) -> Int {
        Int((normalized + 22.5) / 45) % 8
    }

    /// "NW 318°"; "" for a value that isn't finite (any finite one is brought into [0, 360) first).
    public static func bearing(degrees: Double) -> String {
        guard let normalized = normalizedDegrees(degrees) else { return "" }
        let whole = Int(normalized.rounded()) % 360
        return "\(points[pointIndex(normalized)]) \(whole)°"
    }

    /// "northwest"; "" for a value that isn't finite.
    public static func spokenBearing(degrees: Double) -> String {
        guard let normalized = normalizedDegrees(degrees) else { return "" }
        return spokenPoints[pointIndex(normalized)]
    }

    /// "12 s ago", "3 min ago", "2 h ago".
    public static func age(seconds: TimeInterval) -> String {
        let s = max(0, Int(saturating: seconds))
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }

    /// "12 seconds ago", "1 minute ago", "2 hours ago".
    public static func spokenAge(seconds: TimeInterval) -> String {
        let s = max(0, Int(saturating: seconds))
        func unit(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word) ago" : "\(n) \(word)s ago" }
        if s < 60 { return unit(s, "second") }
        if s < 3600 { return unit(s / 60, "minute") }
        return unit(s / 3600, "hour")
    }

    /// "1 vessel", "4 vessels".
    public static func count(_ n: Int) -> String {
        n == 1 ? "1 vessel" : "\(n) vessels"
    }
}
