import Foundation

/// Smooths the camera's heading and pitch and decides when a change is worth redrawing for. The raw compass jitters
/// by a degree or so even with the phone held still, and every published change moves every label on screen.
public struct HeadingFilter: Sendable {
    /// Weight of each new reading (exponential smoothing at ~30 readings a second: about 0.1 s of lag).
    public static let smoothing = 0.25
    /// Changes smaller than this, in degrees, aren't published (about a point on screen).
    public static let threshold = 0.2

    /// The smoothed heading as a unit vector (east, north), so 359° and 1° average to 0°, not 180°.
    private var east: Double?
    private var north: Double?
    private var pitch: Double?
    public private(set) var published: (heading: Double, pitch: Double)?

    public init() {}

    /// Feeds one reading. Returns the smoothed heading and pitch when either moved enough since the last one
    /// returned, nil otherwise.
    public mutating func update(heading: Double, pitch: Double) -> (heading: Double, pitch: Double)? {
        let radians = heading * .pi / 180
        let a = Self.smoothing
        let e = east.map { $0 + a * (sin(radians) - $0) } ?? sin(radians)
        let n = north.map { $0 + a * (cos(radians) - $0) } ?? cos(radians)
        let p = self.pitch.map { $0 + a * (pitch - $0) } ?? pitch
        east = e
        north = n
        self.pitch = p
        var smoothed = atan2(e, n) * 180 / .pi
        if smoothed < 0 { smoothed += 360 }
        if smoothed >= 360 { smoothed = 0 }
        if let last = published {
            var turn = abs(smoothed - last.heading).truncatingRemainder(dividingBy: 360)
            if turn > 180 { turn = 360 - turn }
            guard turn >= Self.threshold || abs(p - last.pitch) >= Self.threshold else { return nil }
        }
        published = (smoothed, p)
        return (smoothed, p)
    }

    /// Starts over, e.g. after the heading was lost (phone pointed at the ground).
    public mutating func reset() {
        east = nil
        north = nil
        pitch = nil
        published = nil
    }
}
