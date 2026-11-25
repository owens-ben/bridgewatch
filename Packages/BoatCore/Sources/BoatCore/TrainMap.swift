import CoreLocation
import Foundation

/// What the map shows of the trains at a given zoom. Dozens of trains run underground in the area: zoomed out their
/// markers pile up into a blob over Downtown Brooklyn and Lower Manhattan, burying the boats and the trains on the
/// bridges, so underground trains only show once the map is zoomed in. Trains above ground always show.
public enum TrainMap {
    /// Underground markers show while the map's visible span is at most this many meters: about the stretch from
    /// DUMBO to the Williamsburg Bridge, where the tunnels' markers are tens of points apart.
    public static let undergroundMaxSpanMeters = 3_000.0

    private static let metersPerDegreeOfLatitude = 111_320.0

    /// The narrower side of the visible map, meters: east-west from `longitudeDelta` at `latitude`, north-south from
    /// `latitudeDelta` (a map's span in degrees, e.g. `MKCoordinateRegion.span`).
    public static func visibleSpanMeters(latitudeDelta: Double, longitudeDelta: Double, latitude: Double) -> Double {
        let northSouth = abs(latitudeDelta) * metersPerDegreeOfLatitude
        let eastWest = abs(longitudeDelta) * metersPerDegreeOfLatitude * cos(latitude * .pi / 180)
        return min(northSouth, eastWest)
    }

    /// True when the map is zoomed in far enough for underground trains' markers.
    public static func showsUnderground(visibleSpanMeters: Double) -> Bool {
        visibleSpanMeters <= undergroundMaxSpanMeters
    }

    /// The note over a zoomed-out map: "6 trains underground · zoom in to see them"; nil when there are none.
    public static func undergroundNote(count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 train underground · zoom in to see it"
        default: "\(count) trains underground · zoom in to see them"
        }
    }

    /// Which underground markers must not take taps: those whose touch target overlaps one above ground (a train on a
    /// bridge, a boat). MapKit decides which of two overlapping markers a tap selects and doesn't say how, so the
    /// underground one steps out of hit-testing and the one above ground always wins. Underground trains stay
    /// reachable from the list, and from the map wherever nothing above ground is within `overlapRadiusPoints`.
    ///
    /// - Parameters:
    ///   - visibleSpanMeters: the narrower side of the visible map (`visibleSpanMeters(latitudeDelta:...)`).
    ///   - viewSidePoints: the same side of the map view, in points.
    ///   - overlapRadiusPoints: how close, center to center, two touch targets must be to overlap (the two radii).
    public static func undergroundBlockedFromTaps<ID: Hashable>(
        underground: [(id: ID, coordinate: CLLocationCoordinate2D)],
        aboveGround: [CLLocationCoordinate2D],
        visibleSpanMeters: Double, viewSidePoints: Double, overlapRadiusPoints: Double
    ) -> Set<ID> {
        guard visibleSpanMeters > 0, viewSidePoints > 0, overlapRadiusPoints > 0 else { return [] }
        let radiusMeters = overlapRadiusPoints * visibleSpanMeters / viewSidePoints
        var blocked = Set<ID>()
        for train in underground where aboveGround.contains(where: { distance(from: train.coordinate, to: $0) < radiusMeters }) {
            blocked.insert(train.id)
        }
        return blocked
    }
}
