import CoreLocation
import Foundation
import Testing
@testable import BoatCore

/// A grid of 50 m cells centered on the test observer, 4 km each way, sea level everywhere except a few north-south
/// walls one cell wide: `walls` maps the east offset of a wall's middle (meters, an odd multiple of 25 so it is a
/// cell's center) to its top.
private func walls(_ walls: [Double: Float]) -> SurfaceGrid {
    let size = 50.0, half = 4_000.0
    let count = Int(2 * half / size)
    var tops: [Float] = []
    for _ in 0..<count {
        for column in 0..<count {
            let center = -half + (Double(column) + 0.5) * size
            tops.append(walls.first { abs($0.key - center) < 1 }?.value ?? 0)
        }
    }
    let metersPerDegree = 6_371_008.8 * Double.pi / 180
    let metersPerDegreeEast = metersPerDegree * cos(testObserver.latitude * .pi / 180)
    return SurfaceGrid(south: testObserver.latitude - half / metersPerDegree,
                       west: testObserver.longitude - half / metersPerDegreeEast,
                       latitudeStep: size / metersPerDegree, longitudeStep: size / metersPerDegreeEast,
                       rows: count, columns: count, tops: tops, grounds: Array(repeating: 0, count: count * count))
}

/// `Sightlines.lineOfSight(from:eye:to:targetAltitude:)` as it was before elevated targets, kept verbatim to prove
/// boats are unchanged.
private func lineOfSightBefore(_ sightlines: Sightlines, from observer: CLLocationCoordinate2D, eye: EyeHeight,
                               to target: CLLocationCoordinate2D,
                               targetAltitude: Double = Sightlines.vesselTopMeters) -> LineOfSight {
    let meters = distance(from: observer, to: target)
    guard meters <= Sightlines.maxRangeMeters else { return .tooFar }
    let eyeAltitude = sightlines.eyeAltitude(at: observer, height: eye)
    let dLat = target.latitude - observer.latitude, dLon = target.longitude - observer.longitude
    var along = Sightlines.observerClearanceMeters
    while along < meters - Sightlines.targetClearanceMeters {
        let f = along / meters
        if let top = sightlines.surface.top(latitude: observer.latitude + f * dLat,
                                            longitude: observer.longitude + f * dLon),
           top > eyeAltitude + f * (targetAltitude - eyeAltitude) + Sightlines.toleranceMeters {
            return .blocked
        }
        along += Sightlines.stepMeters
    }
    return .inSight
}

/// `n` by `n` points evenly across the app's area.
private func spread(_ n: Int) -> [CLLocationCoordinate2D] {
    let box = devBoundingBox
    var points: [CLLocationCoordinate2D] = []
    for i in 0..<n {
        for j in 0..<n {
            let latitude = box.minLatitude + box.latitudeSpan * (Double(i) + 0.5) / Double(n)
            let longitude = box.minLongitude + box.longitudeSpan * (Double(j) + 0.5) / Double(n)
            points.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
    }
    return points
}

@Suite struct ElevatedSightlineTests {
    let now = Date(timeIntervalSince1970: 1_794_319_200)

    /// A train 2,010 m east on a bridge, rail 30 m up: its cell runs from 2,000 to 2,050 m east.
    func bridgeTrain(altitude: Double = 30) -> Train {
        testTrain("a", east: 2_010, altitude: altitude, speed: 0, timestamp: now)
    }

    @Test func roofsBesideAnElevatedTargetDoNotHideIt() {
        // A 40 m roof in the next cell toward the observer (1,950-2,000 m): it rises above the line to the roof (33 m),
        // but it's beside the bridge, not in front of it.
        let sightlines = Sightlines(surface: walls([1_975: 40]))
        let train = bridgeTrain()
        #expect(sightlines.isElevated(train.coordinate, targetAltitude: train.roofAltitude))
        #expect(lineOfSightBefore(sightlines, from: testObserver, eye: .altitude(nil), to: train.coordinate,
                                  targetAltitude: train.roofAltitude) == .blocked)
        #expect(sightlines.lineOfSight(from: testObserver, eye: .altitude(nil), to: train, at: now) == .inSight)
    }

    @Test func aTallBuildingFartherAlongStillHidesIt() {
        // The same roof two cells before the train's (1,900-1,950 m), or a tower halfway, is in front of it.
        for wall: [Double: Float] in [[1_925: 40], [1_025: 80], [1_975: 40, 1_925: 40]] {
            let sightlines = Sightlines(surface: walls(wall))
            #expect(sightlines.lineOfSight(from: testObserver, eye: .altitude(nil), to: bridgeTrain(), at: now)
                    == .blocked, "\(wall)")
        }
    }

    @Test func aTallRoofInTheRingBetweenObserverAndTargetIsAcceptedAsBeside() {
        // Accepted limitation: the cells around an elevated target are skipped whatever their height, so a 200 m
        // tower in the cell right before the bridge train's (1,950-2,000 m) can't hide it, though it stands on the
        // line of sight. Anything two cells or more before the train still does (aTallBuildingFartherAlongStillHidesIt).
        let sightlines = Sightlines(surface: walls([1_975: 200]))
        #expect(sightlines.lineOfSight(from: testObserver, eye: .altitude(nil), to: bridgeTrain(), at: now) == .inSight)
    }

    @Test func aTargetCloseToTheGroundKeepsTheExactRule() {
        // A train at grade (rail 5 m, roof 8 m: under 10 m above the ground) is hidden by the roof beside it.
        let sightlines = Sightlines(surface: walls([1_975: 40]))
        let train = bridgeTrain(altitude: 5)
        #expect(!sightlines.isElevated(train.coordinate, targetAltitude: train.roofAltitude))
        #expect(sightlines.lineOfSight(from: testObserver, eye: .altitude(nil), to: train, at: now) == .blocked)
        // So is a boat there: its upper deck is 8 m over the water.
        #expect(!sightlines.isElevated(train.coordinate, targetAltitude: Sightlines.vesselTopMeters))
        #expect(sightlines.lineOfSight(from: testObserver, eye: .altitude(nil), to: train.coordinate) == .blocked)
    }

    @Test func theThresholdIsTenMetersAboveTheGround() {
        let sightlines = Sightlines(surface: walls([:]))
        let spot = moved(testObserver, east: 500, north: 0)
        #expect(sightlines.isElevated(spot, targetAltitude: 10))
        #expect(!sightlines.isElevated(spot, targetAltitude: 9.9))
    }

    /// Every boat sightline over the real harbor grid comes out as before: observers across the area (on land and on
    /// the water, at several eye heights) to boats on every water cell of a coarse grid.
    @Test func boatsAreUnchangedOverTheHarbor() {
        let sightlines = Sightlines.harbor
        let observers = spread(9) + [testObserver]
        let targets = spread(15).filter {
            sightlines.surface.ground(latitude: $0.latitude, longitude: $0.longitude) == 0
        }
        #expect(targets.count > 50)
        var checked = 0, inSight = 0
        for observer in observers {
            for eye: EyeHeight in [.altitude(nil), .aboveGround(30)] {
                for target in targets {
                    let now = sightlines.lineOfSight(from: observer, eye: eye, to: target)
                    #expect(now == lineOfSightBefore(sightlines, from: observer, eye: eye, to: target))
                    checked += 1
                    if now == .inSight { inSight += 1 }
                }
            }
        }
        // Not a vacuous comparison: plenty of both answers.
        #expect(checked > 10_000)
        #expect(inSight > 1_000 && inSight < checked - 1_000)
    }

    /// The fixture's B on the Manhattan Bridge's Brooklyn approach (35 m up), over the real harbor grid. From the
    /// river just off DUMBO only the roofs along the approach were in the way: it's in sight now. From the DUMBO
    /// waterfront (the test observer), the line runs low past the tall buildings between Water St and the bridge
    /// (one cell 84 m, 120 m out, and more beyond): still hidden, as it was.
    @Test func theBOnTheManhattanBridgeApproach() throws {
        let b = try #require(try fixtureTrains().first { $0.id == "train:nyct:117330_B..N66R" })
        #expect(b.stretch == .manhattanBridge)
        let harbor = Sightlines.harbor
        #expect(harbor.isElevated(b.coordinate, targetAltitude: b.roofAltitude))

        let offDumbo = CLLocationCoordinate2D(latitude: 40.7062, longitude: -73.9912)
        #expect(harbor.surface.ground(latitude: offDumbo.latitude, longitude: offDumbo.longitude) == 0)
        #expect(lineOfSightBefore(harbor, from: offDumbo, eye: .altitude(nil), to: b.coordinate,
                                  targetAltitude: b.roofAltitude) == .blocked)
        #expect(harbor.lineOfSight(from: offDumbo, eye: .altitude(nil), to: b, at: fixtureTrainTime) == .inSight)

        #expect(harbor.lineOfSight(from: testObserver, eye: .altitude(nil), to: b, at: fixtureTrainTime) == .blocked)
    }
}
