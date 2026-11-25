import CoreLocation
import Foundation
import Testing
@testable import BoatCore

private let metersPerDegree = 6_371_008.8 * Double.pi / 180
private let metersPerDegreeEast = metersPerDegree * cos(testObserver.latitude * .pi / 180)

/// A point `east`/`north` meters from the test observer.
private func offset(east: Double, north: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: testObserver.latitude + north / metersPerDegree,
                           longitude: testObserver.longitude + east / metersPerDegreeEast)
}

/// A grid of 50 m cells centered on the test observer, `halfWidth` meters each way, with each cell's top and ground
/// given by its center's offset from the observer. Sea level wherever `cell` returns nil.
private func grid(halfWidth: Double = 4_000,
                  _ cell: (_ east: Double, _ north: Double) -> (top: Float, ground: Float)?) -> SurfaceGrid {
    let size = 50.0
    let count = Int(2 * halfWidth / size)
    var tops: [Float] = [], grounds: [Float] = []
    for row in 0..<count {
        for column in 0..<count {
            let value = cell(-halfWidth + (Double(column) + 0.5) * size, -halfWidth + (Double(row) + 0.5) * size)
            tops.append(value?.top ?? 0)
            grounds.append(value?.ground ?? 0)
        }
    }
    return SurfaceGrid(south: testObserver.latitude - halfWidth / metersPerDegree,
                       west: testObserver.longitude - halfWidth / metersPerDegreeEast,
                       latitudeStep: size / metersPerDegree, longitudeStep: size / metersPerDegreeEast,
                       rows: count, columns: count, tops: tops, grounds: grounds)
}

/// A block of `top`-meter buildings from 500 m to 1 km east, as wide as the grid: a street of buildings between the
/// user and the water.
private func buildings(top: Float) -> SurfaceGrid {
    grid { east, _ in (500...1_000).contains(east) ? (top, 0) : nil }
}

/// A point `meters` due east of the test observer.
private func east(_ meters: Double) -> CLLocationCoordinate2D { offset(east: meters, north: 0) }

@Suite struct SurfaceGridTests {
    @Test func decodesRowsFromTheSouthWestCorner() throws {
        let tops = Data([0, 1, 2, 3, 4, 5]).base64EncodedString()
        let grounds = Data([0, 0, 0, 1, 1, 1]).base64EncodedString()
        let grid = try #require(SurfaceGrid(south: 0, west: 0, latitudeStep: 1, longitudeStep: 1, rows: 2, columns: 3,
                                            topsBase64: tops, topUnit: 2, groundsBase64: grounds, groundUnit: 1))
        #expect(grid.top(latitude: 0.5, longitude: 2.5) == 4)
        #expect(grid.top(latitude: 1.5, longitude: 0.5) == 6)
        #expect(grid.ground(latitude: 1.5, longitude: 0.5) == 1)
        #expect(grid.ground(latitude: 0.5, longitude: 0.5) == 0)
        #expect(grid.top(latitude: 2.5, longitude: 0.5) == nil)
        #expect(grid.top(latitude: 0.5, longitude: -0.5) == nil)
    }

    @Test func dataOfTheWrongSizeIsRejected() {
        let five = Data([0, 1, 2, 3, 4]).base64EncodedString()
        #expect(SurfaceGrid(south: 0, west: 0, latitudeStep: 1, longitudeStep: 1, rows: 2, columns: 3,
                            topsBase64: five, topUnit: 2, groundsBase64: five, groundUnit: 1) == nil)
    }
}

@Suite struct SightlinesTests {
    @Test func openWaterIsInSight() {
        #expect(Sightlines(surface: grid { _, _ in nil }).lineOfSight(from: testObserver, eye: .altitude(nil), to: east(2_000)) == .inSight)
    }

    @Test func buildingsHideTheBoatFromTheStreet() {
        let sightlines = Sightlines(surface: buildings(top: 30))
        #expect(sightlines.lineOfSight(from: testObserver, eye: .altitude(nil), to: east(3_000)) == .blocked)
        #expect(sightlines.lineOfSight(from: testObserver, eye: .altitude(10), to: east(3_000)) == .blocked)
    }

    @Test func fromHighUpYouSeeOverThem() {
        let sightlines = Sightlines(surface: buildings(top: 30))
        // From a 60 m GPS altitude, or a window 45 m up: the line clears the 30 m roofs.
        #expect(sightlines.lineOfSight(from: testObserver, eye: .altitude(60), to: east(3_000)) == .inSight)
        #expect(sightlines.lineOfSight(from: testObserver, eye: .aboveGround(45), to: east(3_000)) == .inSight)
    }

    @Test func towersBlockEvenFromHighUp() {
        let sightlines = Sightlines(surface: buildings(top: 300))
        #expect(sightlines.lineOfSight(from: testObserver, eye: .altitude(60), to: east(3_000)) == .blocked)
    }

    @Test func yourOwnBuildingDoesNotCount() {
        // A 100 m tower around the user, looking out from 30 m up; open water beyond.
        let tower = grid { east, north in abs(east) < 40 && abs(north) < 40 ? (100, 0) : nil }
        #expect(Sightlines(surface: tower).lineOfSight(from: testObserver, eye: .aboveGround(30), to: east(2_000)) == .inSight)
    }

    @Test func aBoatAgainstItsPierIsInSight() {
        // A 20 m pier shed right next to the boat.
        let shed = grid { east, _ in (1_960...2_000).contains(east) ? (20, 0) : nil }
        #expect(Sightlines(surface: shed).lineOfSight(from: testObserver, eye: .altitude(nil), to: east(2_000)) == .inSight)
    }

    @Test func eyeHeightStartsFromTheGround() {
        // On a 20 m bluff.
        let bluff = Sightlines(surface: grid { _, _ in (20, 20) })
        #expect(bluff.eyeAltitude(at: testObserver, height: .altitude(nil)) == 21.6)
        // GPS reading below the ground: standing on it is the floor.
        #expect(bluff.eyeAltitude(at: testObserver, height: .altitude(5)) == 21.6)
        #expect(bluff.eyeAltitude(at: testObserver, height: .altitude(80)) == 80)
        #expect(bluff.eyeAltitude(at: testObserver, height: .aboveGround(30)) == 50)
        #expect(bluff.eyeAltitude(at: testObserver, height: .aboveGround(0)) == 21.6)
        // At the water's edge (or placed in the river by GPS): no lower than the waterfront.
        let water = Sightlines(surface: grid { _, _ in nil })
        #expect(water.eyeAltitude(at: testObserver, height: .altitude(nil)) == 4)
        #expect(water.eyeAltitude(at: testObserver, height: .altitude(45)) == 45)
    }

    @Test func outsideTheGridNothingBlocks() {
        // Only the first kilometer has data; the rest of the line runs off the grid.
        let small = grid(halfWidth: 1_000) { _, _ in nil }
        #expect(Sightlines(surface: small).lineOfSight(from: testObserver, eye: .altitude(nil), to: east(3_000)) == .inSight)
    }

    @Test func beyondFiveKilometersIsTooFar() {
        let flat = Sightlines(surface: .flat)
        #expect(flat.lineOfSight(from: testObserver, eye: .altitude(nil), to: east(4_900)) == .inSight)
        #expect(flat.lineOfSight(from: testObserver, eye: .altitude(nil), to: east(5_100)) == .tooFar)
    }

    @Test func higherTargetsAreSeenOverLowerRoofs() {
        // The same street, but the target is 300 m up (an aircraft, say): the line climbs over the roofs.
        let sightlines = Sightlines(surface: buildings(top: 30))
        #expect(sightlines.lineOfSight(from: testObserver, eye: .altitude(nil), to: east(3_000), targetAltitude: 300) == .inSight)
    }
}

@Suite struct VesselListSightlineTests {
    let now = Date(timeIntervalSince1970: 1_794_319_200)

    func vessel(_ mmsi: Int, east meters: Double) -> Vessel {
        let c = east(meters)
        var v = testVessel(mmsi: mmsi, lat: c.latitude, lon: c.longitude, timestamp: now)
        v.lastSeen = now
        return v
    }

    @Test func splitsInSightFromOutOfSight() {
        // Buildings from 500 m to 1 km east: the boat at 2.5 km is hidden from the street, the one at 6 km too far.
        let sightlines = Sightlines(surface: buildings(top: 30))
        let vessels = [vessel(1, east: 2_500), vessel(2, east: 400), vessel(3, east: 6_000), vessel(4, east: -1_500)]
        let list = VesselList(vessels: vessels, observer: testObserver, now: now, sightlines: sightlines)
        #expect(list.rows.map(\.id) == [2, 4, 1, 3])
        #expect(list.inSight.map(\.id) == [2, 4])
        #expect(list.outOfSight.map(\.id) == [1, 3])
        #expect(list.row(mmsi: 1)?.lineOfSight == .blocked)
        #expect(list.row(mmsi: 3)?.lineOfSight == .tooFar)
        #expect(list.closest?.id == 2)
        #expect(list.others.map(\.id) == [4])
    }

    @Test func fromHighUpTheHiddenBoatComesIntoSight() {
        let sightlines = Sightlines(surface: buildings(top: 30))
        let list = VesselList(vessels: [vessel(1, east: 2_500)], observer: testObserver, eye: .aboveGround(60),
                              now: now, sightlines: sightlines)
        #expect(list.inSight.map(\.id) == [1])
    }

    @Test func closestIsTheNearestBoatInSightNotTheNearestBoat() {
        let sightlines = Sightlines(surface: buildings(top: 30))
        let list = VesselList(vessels: [vessel(1, east: 1_700), vessel(2, east: -2_000)],
                              observer: testObserver, now: now, sightlines: sightlines)
        #expect(list.closest?.id == 2)
        #expect(list.others.isEmpty)
        #expect(list.outOfSight.map(\.id) == [1])
    }

    @Test func withoutTheObserverNothingIsSortedBySight() {
        let list = VesselList(vessels: [vessel(1, east: 2_500), vessel(2, east: 800)], observer: nil, now: now)
        #expect(list.inSight.isEmpty)
        #expect(list.outOfSight.isEmpty)
        #expect(list.closest == nil)
        #expect(list.others.count == 2)
        #expect(list.rows.allSatisfy { $0.lineOfSight == nil })
    }
}

@Suite struct HeadingFilterTests {
    @Test func firstReadingIsPublishedAsIs() throws {
        var filter = HeadingFilter()
        let reading = filter.update(heading: 90, pitch: 2)
        let first = try #require(reading)
        #expect(abs(first.heading - 90) < 1e-9)
        #expect(first.pitch == 2)
    }

    @Test func jitterIsNotPublished() {
        var filter = HeadingFilter()
        _ = filter.update(heading: 90, pitch: 0)
        for reading in [90.1, 89.9, 90.15, 89.85, 90.05] {
            let published = filter.update(heading: reading, pitch: 0.05)
            #expect(published == nil)
        }
    }

    @Test func aRealTurnIsFollowedSmoothly() throws {
        var filter = HeadingFilter()
        _ = filter.update(heading: 90, pitch: 0)
        // A quarter of the way to the new reading at once, then closing in.
        let turned = filter.update(heading: 100, pitch: 0)
        let step = try #require(turned)
        #expect(abs(step.heading - 92.5) < 0.1)
        for _ in 0..<40 { _ = filter.update(heading: 100, pitch: 0) }
        let settled = try #require(filter.published)
        #expect(abs(settled.heading - 100) < 0.2)
    }

    @Test func smoothsAcrossNorth() throws {
        var filter = HeadingFilter()
        _ = filter.update(heading: 359, pitch: 0)
        let crossed = filter.update(heading: 3, pitch: 0)
        let step = try #require(crossed)
        // 359° plus a quarter of the 4° turn, through north, not back around through south.
        #expect(abs(step.heading - 0) < 0.1 || abs(step.heading - 360) < 0.1)
    }

    @Test func tiltingAloneIsPublished() {
        var filter = HeadingFilter()
        _ = filter.update(heading: 45, pitch: 0)
        let tilted = filter.update(heading: 45, pitch: 4)
        #expect(tilted != nil)
    }

    @Test func resetStartsOver() throws {
        var filter = HeadingFilter()
        _ = filter.update(heading: 10, pitch: 0)
        filter.reset()
        #expect(filter.published == nil)
        let reading = filter.update(heading: 200, pitch: 0)
        let first = try #require(reading)
        #expect(abs(first.heading - 200) < 1e-9)
    }
}
