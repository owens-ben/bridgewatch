import CoreLocation

/// A latitude/longitude rectangle.
public struct GeoBoundingBox: Sendable, Equatable {
    public let minLatitude: Double
    public let maxLatitude: Double
    public let minLongitude: Double
    public let maxLongitude: Double

    public init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
    }

    public var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2)
    }

    public var latitudeSpan: Double { maxLatitude - minLatitude }
    public var longitudeSpan: Double { maxLongitude - minLongitude }
}

/// Dev bounding box: the Upper Bay and lower East River, Statue of Liberty to the Williamsburg Bridge. Widened from
/// the DUMBO stretch alone, where aisstream's receivers pick up too few vessels to be useful.
public let devBoundingBox = GeoBoundingBox(
    minLatitude: 40.675,
    maxLatitude: 40.735,
    minLongitude: -74.045,
    maxLongitude: -73.955
)
