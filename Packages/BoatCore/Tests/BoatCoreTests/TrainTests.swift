import CoreLocation
import Foundation
import Testing
@testable import BoatCore

/// The trains in the relay's generated snapshot (relay/PROTOCOL.md, "Fixtures"), and the time the relay estimated
/// them for (the last synthetic subway round's, the end of the AIS sample's window). The scenario they come from is
/// relay/src/tools/subway-scenario.ts.
func fixtureTrains() throws -> [Train] {
    let url = try #require(Bundle.module.url(forResource: "relay-v2-snapshot", withExtension: "json",
                                             subdirectory: "Fixtures"))
    guard case .snapshot(let targets) = try RelayMessage.decode(Data(contentsOf: url)) else {
        Issue.record("relay-v2-snapshot.json is not a snapshot")
        return []
    }
    return targets.compactMap(Train.init)
}

let fixtureTrainTime = try! date("2026-11-10T14:12:00.000Z")

/// A train `east`/`north` meters from the test observer.
func testTrain(
    _ trip: String, east: Double = 0, north: Double = 0, route: String = "Q", stretch: String? = "manhattan-bridge",
    altitude: Double? = nil, speed: Double = 15, course: Double = 90, destination: String? = nil, timestamp: Date
) -> Train {
    let c = moved(testObserver, east: east, north: north)
    return Train(trainTarget(trip, route: route, destination: destination, stretch: stretch, lat: c.latitude,
                             lon: c.longitude, altitude: altitude, speed: speed, course: course,
                             timestamp: timestamp))!
}

@Suite struct TrainModelTests {
    @Test func fixtureTrainsAreAllTrains() throws {
        let trains = try fixtureTrains()
        #expect(trains.count == 68)
        #expect(trains.filter(\.underground).count == 54)
        #expect(trains.filter { !$0.underground }.count == 14)
        for train in trains {
            #expect(train.id.hasPrefix("train:nyct:"))
            #expect(train.timestamp == fixtureTrainTime)
            #expect(train.course != nil && train.speed != nil)
            if train.underground {
                #expect(train.stretch == nil, "\(train.id)")
                // The relay's depth model: every underground altitude is modelled and estimated.
                #expect(train.altitude.isFinite && (-45...35).contains(train.altitude), "\(train.id)")
                #expect(train.altitudeEstimated, "\(train.id)")
                #expect(train.hasModelledAltitude, "\(train.id)")
            } else {
                let stretch = try #require(train.stretch, "\(train.id)")
                #expect([TrainStretch.manhattanBridge, .williamsburgBridge, .culverViaduct, .franklinAv].contains(stretch))
                #expect(train.altitude > 0, "\(train.id)")
                // Measured on the bridges and the viaduct, estimated on the Franklin Av shuttle's embankment.
                #expect(train.altitudeEstimated == (stretch == .franklinAv), "\(train.id)")
            }
            #expect(train.roofAltitude == train.altitude + 3)
        }
    }

    @Test func fieldsComeFromTheTarget() throws {
        let trains = try fixtureTrains()
        let b = try #require(trains.first { $0.id == "train:nyct:117330_B..N66R" })
        #expect(b.route == "B")
        #expect(b.direction == .north)
        #expect(b.destination == "145 St")
        #expect(b.stretch == .manhattanBridge)
        #expect(b.stretch?.name == "Manhattan Bridge")
        #expect(!b.underground)
        // The scenario has it leave DeKalb Av 60 s before the first round, due at Grand St 205 s after it: 3304 m of
        // track in 265 s is 24.2 knots, and at the last round (60 s in) it is 45% of the way, on the bridge.
        #expect(b.latitude == 40.703181 && b.longitude == -73.988208)
        #expect(b.altitude == 34.8)
        #expect(b.speed == 24.2)
        #expect(b.course == 337.2)
        #expect(b.line == .sixthAvenue)
        #expect(b.bullet == "B")
    }

    @Test func onlyTrainTargetsAreTrains() throws {
        let now = Date(timeIntervalSince1970: 0)
        #expect(Train(vesselTarget(1, timestamp: now)) == nil)
        var noDetails = trainTarget("a", timestamp: now)
        noDetails.train = nil
        #expect(Train(noDetails) == nil)
    }

    @Test func missingAltitudeFallsBack() throws {
        let now = Date(timeIntervalSince1970: 0)
        var underground = trainTarget("a", stretch: nil, timestamp: now)
        underground.altitude = nil
        #expect(Train(underground)?.altitude == Train.fallbackUndergroundAltitude)
        #expect(Train(underground)?.hasModelledAltitude == false)
        var above = trainTarget("b", timestamp: now)
        above.altitude = nil
        #expect(Train(above)?.altitude == 0)
    }

    @Test func altitudeEstimatedComesFromTheTargetAndAMissingKeyReadsAsFalse() throws {
        let now = Date(timeIntervalSince1970: 0)
        var target = trainTarget("a", stretch: nil, altitude: -22.4, timestamp: now)
        target.train?.altitudeEstimated = true
        #expect(Train(target)?.altitudeEstimated == true)
        #expect(Train(target)?.hasModelledAltitude == true)
        target.train?.altitudeEstimated = false
        #expect(Train(target)?.altitudeEstimated == false)
        #expect(Train(target)?.hasModelledAltitude == true)
        // An older relay doesn't send the key: not estimated, and its flat altitude isn't a modelled one.
        target.train?.altitudeEstimated = nil
        #expect(Train(target)?.altitudeEstimated == false)
        #expect(Train(target)?.hasModelledAltitude == false)
        #expect(Train(target)?.altitude == -22.4)
    }

    @Test func theFranklinAvShuttleIsOnItsStretch() throws {
        let trains = try fixtureTrains()
        let shuttles = trains.filter { $0.route == "FS" }
        #expect(!shuttles.isEmpty)
        for train in shuttles {
            #expect(train.stretch == .franklinAv, "\(train.id)")
            #expect(train.stretch?.name == "Franklin Av Shuttle")
            #expect(!train.underground)
            #expect(train.altitudeEstimated)
            #expect((25...42).contains(train.altitude), "\(train.id)")
        }
    }

    @Test func stretchIDsRoundTrip() {
        for id in ["manhattan-bridge", "williamsburg-bridge", "culver-viaduct", "franklin-av", "brighton-embankment"] {
            #expect(TrainStretch(id: id).id == id)
        }
        #expect(TrainStretch(id: "franklin-av") == .franklinAv)
        #expect(TrainStretch.franklinAv.name == "Franklin Av Shuttle")
        #expect(TrainStretch(id: "brighton-embankment") == .other("brighton-embankment"))
        #expect(TrainStretch(id: "brighton-embankment").name == "Brighton Embankment")
    }

    @Test func registryTrainsAreTrainsSortedByID() throws {
        let now = Date(timeIntervalSince1970: 0)
        var registry = TargetRegistry()
        registry.apply(.snapshot([trainTarget("b", timestamp: now), vesselTarget(1, timestamp: now),
                                  trainTarget("a", stretch: nil, timestamp: now)]))
        #expect(registry.trains.map(\.id) == ["train:nyct:a", "train:nyct:b"])
        #expect(registry.trains.first?.underground == true)
    }
}

@Suite struct SubwayLineTests {
    @Test(arguments: [
        ("1", SubwayLine.broadwaySeventhAvenue, "1", false), ("2", .broadwaySeventhAvenue, "2", false),
        ("3", .broadwaySeventhAvenue, "3", false),
        ("4", .lexingtonAvenue, "4", false), ("5", .lexingtonAvenue, "5", false), ("6", .lexingtonAvenue, "6", false),
        ("6X", .lexingtonAvenue, "6", true),
        ("7", .flushing, "7", false), ("7X", .flushing, "7", true),
        ("A", .eighthAvenue, "A", false), ("C", .eighthAvenue, "C", false), ("E", .eighthAvenue, "E", false),
        ("B", .sixthAvenue, "B", false), ("D", .sixthAvenue, "D", false), ("F", .sixthAvenue, "F", false),
        ("FX", .sixthAvenue, "F", true), ("M", .sixthAvenue, "M", false),
        ("G", .crosstown, "G", false),
        ("J", .nassau, "J", false), ("Z", .nassau, "Z", false),
        ("L", .canarsie, "L", false),
        ("N", .broadway, "N", false), ("Q", .broadway, "Q", false), ("R", .broadway, "R", false),
        ("W", .broadway, "W", false),
        ("S", .shuttle, "S", false), ("GS", .shuttle, "S", false), ("FS", .shuttle, "S", false),
        ("H", .shuttle, "S", false),
    ])
    func routes(route: String, line: SubwayLine, bullet: String, diamond: Bool) {
        #expect(SubwayLine(route: route) == line)
        #expect(SubwayLine.bullet(route: route) == bullet)
        #expect(SubwayLine.isDiamond(route: route) == diamond)
    }

    @Test func unknownRoutesKeepTheirID() {
        #expect(SubwayLine(route: "SI") == .unknown)
        #expect(SubwayLine.bullet(route: "SI") == "SI")
        #expect(SubwayLine(route: "") == .unknown)
    }

    @Test func everyRouteInTheFixtureIsKnown() throws {
        for train in try fixtureTrains() {
            #expect(train.line != .unknown, "\(train.route)")
        }
    }

    /// Every route PROTOCOL lists as having track in the area.
    @Test func everyRouteInTheProtocolIsKnown() {
        let routes = ["1", "2", "3", "4", "5", "6", "6X", "A", "B", "C", "D", "E", "F", "FS", "FX", "G", "J", "L", "M",
                      "N", "Q", "R", "W", "Z"]
        for route in routes {
            #expect(SubwayLine(route: route) != .unknown, "\(route)")
        }
    }
}

@Suite struct TrainDeadReckoningTests {
    let reported = Date(timeIntervalSince1970: 1_794_319_200)

    func moved(_ train: Train, after seconds: TimeInterval) -> (east: Double, north: Double) {
        offset(from: testObserver, to: DeadReckoning.position(of: train, at: reported.addingTimeInterval(seconds)))
    }

    @Test func carriedForwardAtMostFifteenSeconds() {
        // 20 knots due east: 10.29 m/s.
        let train = testTrain("a", speed: 20, course: 90, timestamp: reported)
        #expect(abs(moved(train, after: 10).east - 102.9) < 0.5)
        #expect(abs(moved(train, after: 15).east - 154.3) < 0.5)
        #expect(abs(moved(train, after: 120).east - moved(train, after: 15).east) < 1e-6)
        #expect(DeadReckoning.extrapolation(for: train, at: reported.addingTimeInterval(120)) == 15)
        #expect(DeadReckoning.trainMaxExtrapolationSeconds == 15)
    }

    @Test func aTwentySecondOldTrainIsNotMovedPastItsHorizon() {
        let train = testTrain("a", speed: 20, course: 90, timestamp: reported)
        let atHorizon = moved(train, after: 15), stale = moved(train, after: 20)
        #expect(stale.east == atHorizon.east && stale.north == atHorizon.north)
        // The camera's label stops there too: no movement left after the horizon.
        let list = TrainList(trains: [train], observer: testObserver, now: reported.addingTimeInterval(20))
        let target = TrainARTarget(row: list.rows[0], observer: testObserver, eyeAltitude: 2, now: reported.addingTimeInterval(20))
        #expect(target.movesFor == 0 && !target.isMoving)
    }

    @Test func standingTrainsStayPut() {
        let standing = testTrain("a", speed: 0, course: 90, timestamp: reported)
        let offset = moved(standing, after: 20)
        #expect(offset.east == 0 && offset.north == 0)
    }

    @Test func neverBackwards() {
        let offset = moved(testTrain("a", speed: 20, course: 90, timestamp: reported), after: -5)
        #expect(offset.east == 0 && offset.north == 0)
    }

    @Test func undergroundTrainsMoveToo() {
        let train = testTrain("a", stretch: nil, speed: 20, course: 0, timestamp: reported)
        #expect(abs(moved(train, after: 10).north - 102.9) < 0.5)
    }

    /// The shared function with the vessel limit is exactly what vessels got before.
    @Test func vesselsUseTheSharedFunctionWithTheirLimit() {
        let vessel = testVessel(mmsi: 1, lat: testObserver.latitude, lon: testObserver.longitude, sog: 10, cog: 45,
                                timestamp: reported)
        for seconds in [0.0, 30, 119, 600] {
            let now = reported.addingTimeInterval(seconds)
            let shared = DeadReckoning.position(from: vessel.coordinate, speedKnots: 10, courseDegrees: 45,
                                                reportedAt: reported, at: now, limit: 120)
            let p = DeadReckoning.position(of: vessel, at: now)
            #expect(p.latitude == shared.latitude && p.longitude == shared.longitude)
        }
    }
}

/// A grid of 50 m cells centered on the test observer, 4 km each way, with a single north-south wall of cells
/// `top` meters high centered 975 m east of the observer; sea level elsewhere.
private func wall(top: Float) -> SurfaceGrid {
    let size = 50.0, half = 4_000.0
    let count = Int(2 * half / size)
    var tops: [Float] = []
    for _ in 0..<count {
        for column in 0..<count {
            tops.append(abs(-half + (Double(column) + 0.5) * size - 975) < 1 ? top : 0)
        }
    }
    let metersPerDegree = 6_371_008.8 * Double.pi / 180
    let metersPerDegreeEast = metersPerDegree * cos(testObserver.latitude * .pi / 180)
    return SurfaceGrid(south: testObserver.latitude - half / metersPerDegree,
                       west: testObserver.longitude - half / metersPerDegreeEast,
                       latitudeStep: size / metersPerDegree, longitudeStep: size / metersPerDegreeEast,
                       rows: count, columns: count, tops: tops, grounds: Array(repeating: 0, count: count * count))
}

@Suite struct TrainSightlineTests {
    let now = Date(timeIntervalSince1970: 1_794_319_200)

    @Test func undergroundTrainsAreNeverInSight() {
        // Nothing in the way, a hundred meters off, from high up: still underground.
        let open = Sightlines(surface: .flat)
        let train = testTrain("a", east: 100, stretch: nil, timestamp: now)
        #expect(open.lineOfSight(from: testObserver, eye: .altitude(80), to: train, at: now) == .underground)
    }

    @Test func aboveGroundTrainsAreCheckedLikeAnyTarget() {
        let open = Sightlines(surface: .flat)
        #expect(open.lineOfSight(from: testObserver, eye: .altitude(nil), to: testTrain("a", east: 2_000, timestamp: now),
                                 at: now) == .inSight)
        #expect(open.lineOfSight(from: testObserver, eye: .altitude(nil), to: testTrain("b", east: 5_100, timestamp: now),
                                 at: now) == .tooFar)
    }

    @Test func theLineGoesToTheRoofNotTheRail() {
        // From the waterfront (eye 4 m) to a train 2 km east with its rail 20 m up, past a 13.2 m wall halfway: the
        // wall hides the rail but not the roof 3 m above it.
        let sightlines = Sightlines(surface: wall(top: 13.2))
        let train = testTrain("a", east: 2_000, altitude: 20, speed: 0, timestamp: now)
        #expect(sightlines.lineOfSight(from: testObserver, eye: .altitude(nil), to: train.coordinate,
                                       targetAltitude: train.altitude) == .blocked)
        #expect(sightlines.lineOfSight(from: testObserver, eye: .altitude(nil), to: train, at: now) == .inSight)
        // A higher wall hides the whole train.
        let higher = Sightlines(surface: wall(top: 20))
        #expect(higher.lineOfSight(from: testObserver, eye: .altitude(nil), to: train, at: now) == .blocked)
    }

    @Test func checkedAtTheEstimatedPosition() {
        // 4.9 km east and heading east at 30 knots: in range when reported, past 5 km 20 s later.
        let open = Sightlines(surface: .flat)
        let train = testTrain("a", east: 4_900, speed: 30, course: 90, timestamp: now)
        #expect(open.lineOfSight(from: testObserver, eye: .altitude(nil), to: train, at: now) == .inSight)
        #expect(open.lineOfSight(from: testObserver, eye: .altitude(nil), to: train, at: now.addingTimeInterval(20))
                == .tooFar)
    }

    /// Over the real harbor grid: from the DUMBO waterfront the M on the Williamsburg Bridge, 1.8 km up the river and
    /// 37 m up, is in sight; the trains on the Culver Viaduct, 3 km and more inland, are behind Brooklyn.
    @Test func fromDumboTheWilliamsburgBridgeIsInSightAndTheCulverViaductIsNot() throws {
        let trains = try fixtureTrains()
        let m = try #require(trains.first { $0.id == "train:nyct:122250_M..S24R" })
        #expect(Sightlines.harbor.lineOfSight(from: testObserver, eye: .altitude(nil), to: m, at: fixtureTrainTime)
                == .inSight)
        let culver = trains.filter { $0.stretch == .culverViaduct }
        #expect(culver.count == 4) // two G and two F in the scenario
        for train in culver {
            #expect(Sightlines.harbor.lineOfSight(from: testObserver, eye: .altitude(nil), to: train,
                                                  at: fixtureTrainTime) == .blocked, "\(train.id)")
        }
    }
}

@Suite struct TrainProjectionTests {
    let pose = CameraPose(headingDegrees: 0, pitchDegrees: 0, horizontalFOVDegrees: 60, viewWidth: 400, viewHeight: 800)

    func y(_ placement: ScreenPlacement) -> Double? {
        if case .onScreen(_, let y) = placement { return y }
        return nil
    }

    /// `ARProjection.place` as it was before targets had a height, kept verbatim to prove the default-argument path
    /// (a waterline seen from a fixed 1.6 m eye) is unchanged. The camera no longer uses that path for boats: it passes
    /// the same eye it gives trains (`VesselARTarget`, see SharedEyeTests).
    func placeBefore(bearingDegrees: Double, distanceMeters: Double, pose: CameraPose) -> ScreenPlacement {
        func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
        func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
        let relative = ARProjection.relativeBearing(bearingDegrees, heading: pose.headingDegrees)
        let halfH = pose.horizontalFOVDegrees / 2
        guard abs(relative) <= halfH, halfH > 0, halfH < 90 else {
            return .offScreen(relative < 0 ? .left : .right)
        }
        let w = pose.viewWidth, h = pose.viewHeight
        let x = w / 2 + (w / 2) * tan(radians(relative)) / tan(radians(halfH))
        let elevation = -degrees(atan(ARProjection.observerHeightMeters / max(distanceMeters, 1)))
        let offAxis = elevation - pose.pitchDegrees
        let halfV = pose.verticalFOVDegrees / 2
        let y = h / 2 - (h / 2) * tan(radians(offAxis)) / tan(radians(halfV))
        return .onScreen(x: x, y: y)
    }

    @Test func boatsLandExactlyWhereTheyDidBefore() {
        var count = 0
        for heading in [0.0, 47.5, 180, 318, 359.9] {
            for pitch in [-30.0, -5, 0, 2.5, 20] {
                for (fov, w, h) in [(60.0, 400.0, 800.0), (64, 951, 669), (40, 466, 678), (75, 120, 40)] {
                    let p = CameraPose(headingDegrees: heading, pitchDegrees: pitch, horizontalFOVDegrees: fov,
                                       viewWidth: w, viewHeight: h)
                    for bearing in stride(from: 0.0, to: 360, by: 7.5) {
                        for distance in [0.0, 0.5, 1, 50, 300, 1_234.5, 5_000] {
                            let before = placeBefore(bearingDegrees: bearing, distanceMeters: distance, pose: p)
                            #expect(ARProjection.place(bearingDegrees: bearing, distanceMeters: distance, pose: p) == before)
                            #expect(ARProjection.place(bearingDegrees: bearing, distanceMeters: distance, pose: p,
                                                       targetAltitude: 0,
                                                       eyeAltitude: ARProjection.observerHeightMeters) == before)
                            count += 1
                        }
                    }
                }
            }
        }
        #expect(count == 5 * 5 * 4 * 48 * 7)
    }

    @Test func aBridgeTrainSitsAboveTheHorizonAndATunnelTrainBelow() {
        let horizon = ARProjection.horizonY(pose: pose)
        let bridge = y(ARProjection.place(bearingDegrees: 0, distanceMeters: 500, pose: pose, targetAltitude: 45,
                                          eyeAltitude: 10))!
        let tunnel = y(ARProjection.place(bearingDegrees: 0, distanceMeters: 500, pose: pose, targetAltitude: -10,
                                          eyeAltitude: 10))!
        let level = y(ARProjection.place(bearingDegrees: 0, distanceMeters: 500, pose: pose, targetAltitude: 10,
                                         eyeAltitude: 10))!
        #expect(bridge < horizon)
        #expect(tunnel > horizon)
        #expect(abs(level - horizon) < 1e-9)
    }

    @Test func higherIsAlwaysHigherOnScreen() {
        for pitch in [-20.0, 0, 15] {
            var p = pose
            p.pitchDegrees = pitch
            var last = Double.infinity
            for altitude in stride(from: -30.0, through: 120, by: 5) {
                let next = y(ARProjection.place(bearingDegrees: 0, distanceMeters: 800, pose: p,
                                                targetAltitude: altitude, eyeAltitude: 10))!
                #expect(next < last)
                last = next
            }
        }
    }

    @Test func elevationIsTheTrueAngle() {
        #expect(abs(ARProjection.elevationDegrees(distanceMeters: 100, targetAltitude: 110, eyeAltitude: 10) - 45) < 1e-9)
        #expect(abs(ARProjection.elevationDegrees(distanceMeters: 100, targetAltitude: -90, eyeAltitude: 10) + 45) < 1e-9)
        // A point 45° up lands at the center of a view tilted 45° up.
        var up = pose
        up.pitchDegrees = 45
        #expect(abs(y(ARProjection.place(bearingDegrees: 0, distanceMeters: 100, pose: up, targetAltitude: 110,
                                         eyeAltitude: 10))! - 400) < 1e-9)
    }

    @Test func nearerBridgeTrainsAreHigherOnScreen() {
        // Looking up at a bridge: the angle shrinks with distance.
        let near = y(ARProjection.place(bearingDegrees: 0, distanceMeters: 200, pose: pose, targetAltitude: 40,
                                        eyeAltitude: 4))!
        let far = y(ARProjection.place(bearingDegrees: 0, distanceMeters: 2_000, pose: pose, targetAltitude: 40,
                                       eyeAltitude: 4))!
        #expect(near < far && far < ARProjection.horizonY(pose: pose))
    }
}

@Suite struct TrainValidationTests {
    let t = Date(timeIntervalSince1970: 1_794_319_200)

    func make(lat: Double = 40.7, lon: Double = -74, speed: Double? = 10, course: Double? = 90,
              altitude: Double? = 30) -> Train? {
        Train(Target(id: "train:nyct:x", kind: .train, source: "mta-subway", lat: lat, lon: lon, altitude: altitude,
                     speed: speed, course: course, timestamp: t,
                     train: TrainDetails(route: "Q", direction: .south, stretch: "manhattan-bridge", underground: false)))
    }

    @Test func aGoodTargetIsATrain() {
        #expect(make() != nil)
        #expect(make(speed: nil, course: nil) != nil)  // missing course and speed are allowed
        #expect(make(speed: 0) != nil)
        #expect(make(lat: 90, lon: -180) != nil)
    }

    @Test func impossiblePositionsSpeedsAndCoursesAreRefused() {
        for lat in [999.0, -90.5, .nan, .infinity] { #expect(make(lat: lat) == nil, "lat \(lat)") }
        for lon in [181.0, -999, .nan, -.infinity] { #expect(make(lon: lon) == nil, "lon \(lon)") }
        for speed in [-1.0, .nan, .infinity] { #expect(make(speed: speed) == nil, "speed \(speed)") }
        for course in [Double.nan, .infinity] { #expect(make(course: course) == nil, "course \(course)") }
        #expect(make(altitude: .nan) == nil)
    }

    @Test func theRegistryDoesNotHoldSuchATrain() {
        var registry = TargetRegistry()
        registry.apply(.update(trainTarget("bad", lat: 999, lon: -74, timestamp: t)))
        registry.apply(.snapshot([trainTarget("nan", lat: .nan, lon: -74, timestamp: t), trainTarget("ok", timestamp: t)]))
        #expect(registry.count == 1)
        #expect(registry.trains.map(\.id) == ["train:nyct:ok"])
    }

    @Test func undergroundFlagDecidesTheWordsNotTheStretch() {
        // Underground = false with no stretch: above ground, not "Underground".
        let grade = Train(Target(id: "train:nyct:g", kind: .train, source: "mta-subway", lat: 40.7, lon: -74, altitude: 5, speed: 10, course: 90,
                                 timestamp: t,
                                 train: TrainDetails(route: "Q", direction: .north, underground: false)))!
        #expect(!grade.underground && grade.stretch == nil)
        let row = TrainRow(train: grade, observer: nil, now: t)
        #expect(row.placeText == "Above ground" && row.detail == "Above ground · 12\u{00A0}mph")
        #expect(row.accessibilityLabel().contains("above ground") && !row.accessibilityLabel().contains("nderground"))
        // Underground = true with a stretch (a relay quirk): kept as sent, but it is underground.
        let odd = Train(Target(id: "train:nyct:u", kind: .train, source: "mta-subway", lat: 40.7, lon: -74, altitude: -10, speed: 10, course: 90,
                               timestamp: t,
                               train: TrainDetails(route: "Q", direction: .north, stretch: "manhattan-bridge",
                                                   underground: true)))!
        #expect(odd.underground && odd.stretch == .manhattanBridge)
        let oddRow = TrainRow(train: odd, observer: nil, now: t)
        #expect(oddRow.placeText == "Underground" && oddRow.accessibilityLabel().contains("underground"))
    }
}
