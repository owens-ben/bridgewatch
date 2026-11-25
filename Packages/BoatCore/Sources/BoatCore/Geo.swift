import CoreLocation

/// Initial great-circle bearing from one coordinate to another,
/// in degrees clockwise from true north, normalized to [0, 360).
public func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
    let lat1 = from.latitude * .pi / 180
    let lat2 = to.latitude * .pi / 180
    let dLon = (to.longitude - from.longitude) * .pi / 180
    let y = sin(dLon) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
    let degrees = atan2(y, x) * 180 / .pi
    let normalized = degrees.truncatingRemainder(dividingBy: 360)
    let result = normalized < 0 ? normalized + 360 : normalized
    // Guard against -tiny + 360 rounding up to exactly 360.
    return result >= 360 ? 0 : result
}

/// Great-circle distance in meters (haversine, mean Earth radius).
public func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
    let earthRadius = 6_371_008.8
    let lat1 = from.latitude * .pi / 180
    let lat2 = to.latitude * .pi / 180
    let dLat = lat2 - lat1
    let dLon = (to.longitude - from.longitude) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
}

private let metersPerDegree = 6_371_008.8 * Double.pi / 180

/// Meters east and north from one coordinate to another, on a flat local plane: fine across a few kilometers.
public func offset(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> (east: Double, north: Double) {
    ((to.longitude - from.longitude) * metersPerDegree * cos(from.latitude * .pi / 180),
     (to.latitude - from.latitude) * metersPerDegree)
}

/// `coordinate` moved `east` and `north` meters, on a flat local plane: fine across a few kilometers.
public func moved(_ coordinate: CLLocationCoordinate2D, east: Double, north: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
        latitude: coordinate.latitude + north / metersPerDegree,
        longitude: coordinate.longitude + east / (metersPerDegree * cos(coordinate.latitude * .pi / 180)))
}
