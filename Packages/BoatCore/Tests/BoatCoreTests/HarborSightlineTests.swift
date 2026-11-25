import CoreLocation
import Testing
@testable import BoatCore

/// Sightlines over the real harbor grid (`HarborSurface`): places people would stand, boats they would or wouldn't see.
@Suite struct HarborSightlineTests {
    let harbor = Sightlines.harbor
    let dumbo = testObserver
    let brooklynBridgeDeck = CLLocationCoordinate2D(latitude: 40.7058, longitude: -73.9965)
    let parkSlope = CLLocationCoordinate2D(latitude: 40.6710, longitude: -73.9800)

    let eastRiverByManhattanBridge = CLLocationCoordinate2D(latitude: 40.7085, longitude: -73.9870)
    let hudsonOffBatteryParkCity = CLLocationCoordinate2D(latitude: 40.7130, longitude: -74.0250)
    /// Off the Statue of Liberty's east side.
    let upperBay = CLLocationCoordinate2D(latitude: 40.6900, longitude: -74.0400)

    @Test func theGridIsLoaded() {
        #expect(harbor.surface.rows == 222 && harbor.surface.columns == 250)
        // One World Trade Center's roof, and the East River under the Brooklyn Bridge.
        #expect((harbor.surface.top(latitude: 40.71274, longitude: -74.01338) ?? 0) > 400)
        #expect(harbor.surface.top(latitude: 40.7058, longitude: -73.9965) == 0)
    }

    @Test func fromTheDumboWaterfrontTheEastRiverIsInSight() {
        #expect(harbor.lineOfSight(from: dumbo, eye: .altitude(nil), to: eastRiverByManhattanBridge) == .inSight)
    }

    @Test func theHudsonIsBehindLowerManhattanEvenFromTheBridge() {
        #expect(harbor.lineOfSight(from: dumbo, eye: .altitude(nil), to: hudsonOffBatteryParkCity) == .blocked)
        #expect(harbor.lineOfSight(from: brooklynBridgeDeck, eye: .altitude(45), to: hudsonOffBatteryParkCity) == .blocked)
    }

    @Test func fromTheBridgeDeckTheUpperBayIsInSight() {
        // 45 m up the line clears Governors Island and the Battery; from the water below it doesn't.
        #expect(harbor.lineOfSight(from: brooklynBridgeDeck, eye: .altitude(45), to: upperBay) == .inSight)
        #expect(harbor.lineOfSight(from: brooklynBridgeDeck, eye: .altitude(nil), to: upperBay) == .blocked)
    }

    @Test func inlandAtStreetLevelTheRiverIsHidden() {
        #expect(harbor.lineOfSight(from: parkSlope, eye: .altitude(nil), to: eastRiverByManhattanBridge) == .blocked)
    }

    /// The UI tests' fixture (BoatARUITests) assumes these from the DUMBO test location at street level.
    @Test(arguments: [
        (40.7062, -73.9931, LineOfSight.inSight),   // HARBOR LARK
        (40.7068, -73.9890, LineOfSight.inSight),   // ANNABEL K
        (40.7054, -73.9971, LineOfSight.inSight),   // WREN
        (40.7083, -73.9880, LineOfSight.inSight),   // unnamed
        (40.7130, -74.0250, LineOfSight.blocked),   // HUDSON PILOT
        (40.6760, -74.0420, LineOfSight.tooFar),    // FAR BARGE
    ])
    func uiTestFixture(latitude: Double, longitude: Double, expected: LineOfSight) {
        let vessel = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        #expect(harbor.lineOfSight(from: dumbo, eye: .altitude(nil), to: vessel) == expected)
    }

    @Test(arguments: [(40.7062, -73.9931), (40.7068, -73.9890), (40.7054, -73.9971), (40.7083, -73.9880)])
    func uiTestFixtureIsHiddenFromParkSlope(latitude: Double, longitude: Double) {
        let vessel = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        #expect(harbor.lineOfSight(from: parkSlope, eye: .altitude(nil), to: vessel) == .blocked)
    }

    /// The camera filter UI tests (CameraFilterUITests) stand on a Hudson ferry off the West Village facing 192°, down
    /// the river: boats at 0.5, 2, 4 and 5.8 km ahead and two 700 m behind, all over water with nothing in the way at
    /// any radius up to 10 mi. Only the 5.8 km one is beyond the default 5 km.
    static let hudsonFerry = CLLocationCoordinate2D(latitude: 40.7270, longitude: -74.0175)

    @Test(arguments: [
        (40.72251, -74.01771, 500.0), (40.71032, -74.02639, 2_000), (40.69122, -74.02246, 4_000),
        (40.67799, -74.04104, 5_800), (40.73196, -74.02261, 700), (40.73228, -74.02202, 700),
    ])
    func cameraFilterUITestFixture(latitude: Double, longitude: Double, meters: Double) {
        let vessel = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        #expect(abs(distance(from: Self.hudsonFerry, to: vessel) - meters) < 60)
        #expect(harbor.surface.top(latitude: latitude, longitude: longitude) == 0, "on the water")
        #expect(harbor.lineOfSight(from: Self.hudsonFerry, eye: .altitude(nil), to: vessel,
                                   maxRangeMeters: CameraRadius.tenMiles.meters) == .inSight)
        #expect(harbor.lineOfSight(from: Self.hudsonFerry, eye: .altitude(nil), to: vessel)
                == (meters > Sightlines.maxRangeMeters ? .tooFar : .inSight))
    }
}
