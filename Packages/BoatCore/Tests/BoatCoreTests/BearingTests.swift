import CoreLocation
import Testing
@testable import BoatCore

@Suite struct BearingTests {
    @Test func dueNorth() {
        let result = bearing(
            from: CLLocationCoordinate2D(latitude: 40, longitude: -74),
            to: CLLocationCoordinate2D(latitude: 41, longitude: -74)
        )
        #expect(abs(result - 0) < 0.001)
    }

    @Test func dueEastOnEquator() {
        let result = bearing(
            from: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            to: CLLocationCoordinate2D(latitude: 0, longitude: 1)
        )
        #expect(abs(result - 90) < 0.001)
    }

    @Test func dumboToManhattanBridgeMidspan() {
        // Expected value computed independently (Python atan2 forward-azimuth formula).
        let result = bearing(
            from: CLLocationCoordinate2D(latitude: 40.7033, longitude: -73.9881),
            to: CLLocationCoordinate2D(latitude: 40.7075, longitude: -73.9903)
        )
        #expect(abs(result - 338.3434) < 0.01)
    }

    @Test func resultIsNormalizedForWestwardBearing() {
        let result = bearing(
            from: CLLocationCoordinate2D(latitude: 0, longitude: 1),
            to: CLLocationCoordinate2D(latitude: 0, longitude: 0)
        )
        #expect(abs(result - 270) < 0.001)
        #expect(result >= 0 && result < 360)
    }

    @Test func devBoundingBoxMatchesProjectSpec() {
        #expect(devBoundingBox.minLatitude == 40.675)
        #expect(devBoundingBox.maxLatitude == 40.735)
        #expect(devBoundingBox.minLongitude == -74.045)
        #expect(devBoundingBox.maxLongitude == -73.955)
    }
}
