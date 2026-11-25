import CoreLocation
import Foundation
import Testing
@testable import BoatCore

/// The camera places boats and trains from one eye: the eye `Sightlines.eyeAltitude(at:height:)` works out, which
/// `VesselList` and `TrainList` both carry.
@Suite struct SharedEyeTests {
    let now = Date(timeIntervalSince1970: 1_794_319_200)
    let open = Sightlines(surface: .flat)
    let pose = CameraPose(headingDegrees: 0, pitchDegrees: 0, horizontalFOVDegrees: 60, viewWidth: 400, viewHeight: 800)

    func boat(_ mmsi: Int, east: Double = 0, north: Double, sog: Double? = nil, cog: Double? = nil,
              age: TimeInterval = 5) -> Vessel {
        let c = moved(testObserver, east: east, north: north)
        return testVessel(mmsi: mmsi, name: "BOAT \(mmsi)", shipType: 60, lat: c.latitude, lon: c.longitude, sog: sog,
                          cog: cog, timestamp: now.addingTimeInterval(-age))
    }

    func y(_ placement: ScreenPlacement) -> Double? {
        if case .onScreen(_, let y) = placement { return y }
        return nil
    }

    @Test func vesselsAndTrainsCarryTheSameEye() {
        for eye: EyeHeight in [.altitude(nil), .altitude(2), .altitude(60), .aboveGround(30)] {
            let vessels = VesselList(vessels: [], observer: testObserver, eye: eye, now: now, sightlines: .harbor)
            let trains = TrainList(trains: [], observer: testObserver, eye: eye, now: now, sightlines: .harbor)
            #expect(vessels.eyeAltitude != nil)
            #expect(vessels.eyeAltitude == trains.eyeAltitude, "\(eye)")
            #expect(vessels.eyeAltitude == Sightlines.harbor.eyeAltitude(at: testObserver, height: eye))
        }
        let nowhere = VesselList(vessels: [boat(1, north: 300)], observer: nil, now: now)
        #expect(nowhere.eyeAltitude == nil)
        #expect(nowhere.observer == nil)
        #expect(VesselARTarget.targets(in: nowhere).isEmpty)
    }

    @Test func boatsAreProjectedFromTheListsEye() throws {
        let list = VesselList(vessels: [boat(1, east: 50, north: 400)], observer: testObserver, eye: .altitude(60),
                              now: now, sightlines: open)
        #expect(list.eyeAltitude == 60)
        #expect(list.observer?.latitude == testObserver.latitude)
        let target = try #require(VesselARTarget.targets(in: list).first)
        #expect(target.eyeAltitude == 60)
        let at = target.placement(at: now)
        #expect(target.place(at: now, pose: pose) == ARProjection.place(
            bearingDegrees: at.bearing, distanceMeters: at.distance, pose: pose, targetAltitude: 0, eyeAltitude: 60))
        // From 60 m up the waterline is well below where the old fixed 1.6 m eye put it.
        let old = try #require(y(ARProjection.place(bearingDegrees: at.bearing, distanceMeters: at.distance, pose: pose)))
        let shared = try #require(y(target.place(at: now, pose: pose)))
        #expect(shared > old + 50)
    }

    @Test func aBoatAndATrainAtTheSameSpotAndHeightLandTogether() throws {
        // A train at sea level beside a boat: the same eye puts both on the same screen point.
        for eye: EyeHeight in [.altitude(nil), .altitude(25)] {
            let vessels = VesselList(vessels: [boat(1, east: 120, north: 700)], observer: testObserver, eye: eye,
                                     now: now, sightlines: open)
            let train = testTrain("level", east: 120, north: 700, altitude: 0, speed: 0, timestamp: now)
            let trains = TrainList(trains: [train], observer: testObserver, eye: eye, now: now, sightlines: open)
            let boatTarget = try #require(VesselARTarget.targets(in: vessels).first)
            let trainTarget = try #require(TrainARTarget.targets(in: trains, undergroundRadiusMeters: 0,
                                                                 undergroundLimit: 0).inSight.first)
            let b = boatTarget.place(at: now, pose: pose), t = trainTarget.place(at: now, pose: pose)
            guard case .onScreen(let bx, let by) = b, case .onScreen(let tx, let ty) = t else {
                Issue.record("both are ahead")
                return
            }
            #expect(abs(bx - tx) < 1e-6 && abs(by - ty) < 1e-6)
        }
    }

    @Test func targetsAreTheBoatsInSightPlusTheFocusedOne() {
        // A 20 m wall 975 m east hides the boat behind it.
        let size = 50.0, half = 2_000.0
        let count = Int(2 * half / size)
        var tops: [Float] = []
        for _ in 0..<count {
            for column in 0..<count { tops.append(abs(-half + (Double(column) + 0.5) * size - 975) < 1 ? 20 : 0) }
        }
        let metersPerDegree = 6_371_008.8 * Double.pi / 180
        let metersPerDegreeEast = metersPerDegree * cos(testObserver.latitude * .pi / 180)
        let wall = Sightlines(surface: SurfaceGrid(
            south: testObserver.latitude - half / metersPerDegree, west: testObserver.longitude - half / metersPerDegreeEast,
            latitudeStep: size / metersPerDegree, longitudeStep: size / metersPerDegreeEast, rows: count, columns: count,
            tops: tops, grounds: Array(repeating: 0, count: count * count)))
        let list = VesselList(vessels: [boat(1, north: 300), boat(2, east: 1_500, north: 0)], observer: testObserver,
                              now: now, sightlines: wall)
        #expect(VesselARTarget.targets(in: list).map(\.id) == [1])
        #expect(VesselARTarget.targets(in: list, focus: 2).map(\.id) == [1, 2])
        #expect(VesselARTarget.targets(in: list, focus: 1).map(\.id) == [1])
    }

    @Test func movingBoatsGlideForAtMostTwoMinutes() throws {
        // 10 knots east, reported 100 s ago: 20 s left to move.
        let list = VesselList(vessels: [boat(1, north: 500, sog: 10, cog: 90, age: 100)], observer: testObserver,
                              now: now, sightlines: open)
        let target = try #require(VesselARTarget.targets(in: list).first)
        #expect(target.isMoving)
        #expect(target.movesFor == 20)
        let start = target.placement(at: now), later = target.placement(at: now.addingTimeInterval(20))
        let past = target.placement(at: now.addingTimeInterval(80))
        #expect(later.bearing > start.bearing)
        #expect(abs(past.distance - later.distance) < 1e-9)
    }

    @Test func cameraDetailText() throws {
        let list = VesselList(vessels: [boat(1, north: 400, sog: 14.2, cog: 0), boat(2, north: 900, sog: 6.1, age: 130)],
                              observer: testObserver, now: now, sightlines: open)
        let live = try #require(list.row(mmsi: 1)), stale = try #require(list.row(mmsi: 2))
        #expect(live.cameraDetail == "14.2\u{00A0}kn · 0.3\u{00A0}mi")
        #expect(stale.cameraDetail == "6.1\u{00A0}kn · 0.6\u{00A0}mi · 2 min ago")
        let target = try #require(VesselARTarget.targets(in: list).first)
        #expect(target.detail == live.cameraDetail)
        #expect(target.title == "BOAT 1")
        #expect(target.accessibilityLabel == live.accessibilityLabel())
    }
}

@Suite struct TrainDisplayTextTests {
    let now = Date(timeIntervalSince1970: 1_794_319_200)
    let open = Sightlines(surface: .flat)

    @Test func levelSaysWhereAndHowHigh() throws {
        let list = TrainList(trains: [
            testTrain("bridge", north: 400, altitude: 40.6, timestamp: now),
            testTrain("tunnel", east: 300, stretch: nil, timestamp: now),
        ], observer: testObserver, now: now, sightlines: open)
        // Eye 4 m: the bridge's rail 36.6 m above it. The tunnel's depth needs the ground under it, which a flat
        // surface doesn't have: just the place, never "down" against the eye.
        #expect(list.row(id: "train:nyct:bridge")?.levelText == "Manhattan Bridge · 120\u{00A0}ft up")
        #expect(list.row(id: "train:nyct:tunnel")?.levelText == "Underground")
        // With ground (12 m) under it, the depth below the street: 12 - (-10) = 22 m, about 70 ft (estimated).
        let ground = Sightlines(surface: groundOnly(12))
        let deep = TrainList(trains: [testTrain("tunnel", east: 300, stretch: nil, timestamp: now)],
                             observer: testObserver, now: now, sightlines: ground)
        #expect(deep.rows.first?.levelText == "Underground · about 70\u{00A0}ft below street")
        // The depth doesn't depend on the observer.
        let nowhere = TrainList(trains: [testTrain("tunnel", east: 300, stretch: nil, timestamp: now)], observer: nil,
                                now: now, sightlines: ground)
        #expect(nowhere.rows.first?.levelText == "Underground · about 70\u{00A0}ft below street")
        let flatNowhere = TrainList(trains: [testTrain("tunnel", east: 300, stretch: nil, timestamp: now)],
                                    observer: nil, now: now, sightlines: open)
        #expect(flatNowhere.rows.first?.levelText == "Underground")
    }

    @Test func cameraDetailIsDistanceAndHeight() throws {
        let list = TrainList(trains: [
            testTrain("live", north: 640, altitude: 40.6, timestamp: now),
            testTrain("stale", north: 1_300, altitude: 40.6, speed: 0, timestamp: now.addingTimeInterval(-40)),
        ], observer: testObserver, now: now, sightlines: open)
        #expect(list.row(id: "train:nyct:live")?.cameraDetail == "0.4\u{00A0}mi · 120\u{00A0}ft up")
        #expect(list.row(id: "train:nyct:stale")?.cameraDetail == "0.8\u{00A0}mi · 120\u{00A0}ft up · 40 s ago")
        let nowhere = TrainList(trains: [testTrain("a", timestamp: now)], observer: nil, now: now)
        #expect(nowhere.rows.first?.cameraDetail == "")
    }

    @Test(arguments: [("Q", "Q train"), ("6X", "6 express"), ("FX", "F express"), ("FS", "Shuttle"), ("GS", "Shuttle"),
                      ("7", "7 train")])
    func routeName(route: String, expected: String) {
        let train = testTrain("a", route: route, timestamp: now)
        #expect(TrainRow(train: train, observer: nil, now: now).routeName == expected)
    }

    @Test func aboveGroundWithAndWithoutLocation() {
        let trains = [
            testTrain("near", north: 300, timestamp: now),
            testTrain("far", north: 6_000, timestamp: now),
            testTrain("tunnel", north: 100, stretch: nil, timestamp: now),
        ]
        let located = TrainList(trains: trains, observer: testObserver, now: now, sightlines: open)
        #expect(located.aboveGround.map(\.id) == ["train:nyct:near", "train:nyct:far"])
        #expect(located.aboveGround == located.inSight + located.outOfSight)
        // Without a location there are no sightlines, but the trains above ground are still listed.
        let nowhere = TrainList(trains: trains, observer: nil, now: now)
        #expect(nowhere.inSight.isEmpty && nowhere.outOfSight.isEmpty)
        #expect(Set(nowhere.aboveGround.map(\.id)) == ["train:nyct:near", "train:nyct:far"])
        #expect(nowhere.underground.map(\.id) == ["train:nyct:tunnel"])
    }
}
