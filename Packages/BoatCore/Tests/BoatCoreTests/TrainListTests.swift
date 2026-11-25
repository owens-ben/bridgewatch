import CoreLocation
import Foundation
import Testing
@testable import BoatCore

@Suite struct TrainListTests {
    let now = Date(timeIntervalSince1970: 1_794_319_200)
    /// Nothing in the way: these tests are about grouping and ordering, not sightlines (see TrainSightlineTests).
    let open = Sightlines(surface: .flat)

    func train(_ trip: String, east: Double = 0, north: Double = 0, route: String = "Q",
               stretch: String? = "manhattan-bridge", altitude: Double? = nil, speed: Double = 0,
               destination: String? = nil, age: TimeInterval = 5) -> Train {
        testTrain(trip, east: east, north: north, route: route, stretch: stretch, altitude: altitude, speed: speed,
                  destination: destination, timestamp: now.addingTimeInterval(-age))
    }

    @Test func groupsInSightOutOfSightAndUndergroundNearestFirst() {
        let list = TrainList(trains: [
            train("far-bridge", north: 5_500),
            train("tunnel-far", east: 900, stretch: nil),
            train("bridge", east: 700),
            train("tunnel-near", north: 200, stretch: nil),
            train("bridge-near", east: -300),
        ], observer: testObserver, now: now, sightlines: open)
        #expect(list.hasDistances)
        let ids = { (rows: [TrainRow]) in rows.map { $0.id.replacingOccurrences(of: "train:nyct:", with: "") } }
        #expect(ids(list.rows) == ["tunnel-near", "bridge-near", "bridge", "tunnel-far", "far-bridge"])
        #expect(ids(list.inSight) == ["bridge-near", "bridge"])
        #expect(ids(list.outOfSight) == ["far-bridge"])
        #expect(ids(list.underground) == ["tunnel-near", "tunnel-far"])
        #expect(list.outOfSight.first?.lineOfSight == .tooFar)
        #expect(list.underground.allSatisfy { $0.lineOfSight == .underground && !$0.isInSight })
    }

    @Test func equalDistancesBreakTiesByID() {
        let list = TrainList(trains: [train("b", north: 500), train("a", north: 500)], observer: testObserver, now: now,
                             sightlines: open)
        #expect(list.rows.map(\.id) == ["train:nyct:a", "train:nyct:b"])
    }

    @Test func hiddenBridgeTrainsAreOutOfSight() {
        // A 30 m wall of buildings between the user and a train 20 m up.
        let size = 50.0, half = 2_000.0, count = Int(2 * half / size)
        let metersPerDegree = 6_371_008.8 * Double.pi / 180
        let metersPerDegreeEast = metersPerDegree * cos(testObserver.latitude * .pi / 180)
        var tops: [Float] = []
        for _ in 0..<count {
            for column in 0..<count {
                let east = -half + (Double(column) + 0.5) * size
                tops.append((300...600).contains(east) ? 30 : 0)
            }
        }
        let grid = SurfaceGrid(south: testObserver.latitude - half / metersPerDegree,
                               west: testObserver.longitude - half / metersPerDegreeEast,
                               latitudeStep: size / metersPerDegree, longitudeStep: size / metersPerDegreeEast,
                               rows: count, columns: count, tops: tops, grounds: Array(repeating: 0, count: count * count))
        let list = TrainList(trains: [train("a", east: 1_000), train("b", east: -1_000)], observer: testObserver,
                             now: now, sightlines: Sightlines(surface: grid))
        #expect(list.inSight.map(\.id) == ["train:nyct:b"])
        #expect(list.outOfSight.map(\.id) == ["train:nyct:a"])
        #expect(list.outOfSight.first?.lineOfSight == .blocked)
    }

    @Test func theFixtureSplitsIntoTheThreeGroups() throws {
        let trains = try fixtureTrains()
        for sightlines in [open, Sightlines.harbor] {
            let list = TrainList(trains: trains, observer: testObserver, now: fixtureTrainTime, sightlines: sightlines)
            #expect(list.rows.count == 68)
            #expect(list.underground.count == 54)
            #expect(list.inSight.count + list.outOfSight.count == 14)
            #expect(Set((list.inSight + list.outOfSight + list.underground).map(\.id)) == Set(list.rows.map(\.id)))
            for group in [list.rows, list.inSight, list.outOfSight, list.underground] {
                let distances = group.map { $0.distanceMeters ?? -1 }
                #expect(distances == distances.sorted())
            }
        }
        // With nothing in the way, every above-ground train within range of DUMBO is in sight: the twelve on the
        // bridges and the viaduct (the scenario has five on the Manhattan Bridge, three on the Williamsburg Bridge and
        // four on the viaduct), and the two Franklin Av shuttles if they are within range (worked out, not assumed).
        let openList = TrainList(trains: trains, observer: testObserver, now: fixtureTrainTime, sightlines: open)
        let shuttles = openList.rows.filter { $0.train.stretch == .franklinAv }
        #expect(shuttles.count == 2)
        for shuttle in shuttles {
            let inRange = (shuttle.distanceMeters ?? .infinity) <= Sightlines.maxRangeMeters
            #expect(shuttle.lineOfSight == (inRange ? .inSight : .tooFar))
        }
        let shuttlesInRange = shuttles.filter { ($0.distanceMeters ?? .infinity) <= Sightlines.maxRangeMeters }.count
        #expect(openList.inSight.count == 12 + shuttlesInRange)
        #expect(openList.inSight.filter { $0.train.stretch != .franklinAv }.count == 12)
    }

    @Test func rowsCarryDistanceBearingAndHeight() throws {
        // The user's eye on the waterfront is 4 m up (the lowest it's taken to be).
        let list = TrainList(trains: [train("bridge", north: 400, altitude: 40), train("tunnel", east: 300, stretch: nil)],
                             observer: testObserver, now: now, sightlines: open)
        #expect(list.eyeAltitude == 4)
        let bridge = try #require(list.row(id: "train:nyct:bridge"))
        #expect(abs((bridge.distanceMeters ?? 0) - 400) < 0.5)
        #expect(abs((bridge.bearingDegrees ?? -1) - 0) < 0.1 || abs((bridge.bearingDegrees ?? -1) - 360) < 0.1)
        #expect(bridge.relativeAltitudeMeters == 36)
        #expect(bridge.relativeHeightText == "120\u{00A0}ft up")
        let tunnel = try #require(list.row(id: "train:nyct:tunnel"))
        #expect(tunnel.relativeAltitudeMeters == -14)
        // Underground the height is the depth below the street, which needs ground under the train: none here.
        #expect(tunnel.depthBelowStreetMeters == nil)
        #expect(tunnel.relativeHeightText == nil)
        #expect(abs((tunnel.bearingDegrees ?? 0) - 90) < 0.1)
        // A set eye height moves the comparison.
        let high = TrainList(trains: [train("bridge", north: 400, altitude: 40)], observer: testObserver,
                             eye: .altitude(60), now: now, sightlines: open)
        #expect(high.rows.first?.relativeAltitudeMeters == -20)
    }

    @Test func rowsMeasureToTheEstimatedPosition() throws {
        // 20 knots due east from the observer: 10 s later it's ~103 m off; past 15 s it stops moving.
        let moving = testTrain("a", speed: 20, course: 90, timestamp: now)
        let later = TrainRow(train: moving, observer: testObserver, now: now.addingTimeInterval(10), sightlines: open)
        #expect(abs((later.distanceMeters ?? 0) - 102.9) < 0.5)
        let much = TrainRow(train: moving, observer: testObserver, now: now.addingTimeInterval(50), sightlines: open)
        #expect(abs((much.distanceMeters ?? 0) - 154.3) < 0.5)
        // The relay's estimate itself is untouched.
        #expect(much.train.longitude == testObserver.longitude)
    }

    @Test func freshnessAndExpiry() throws {
        let list = TrainList(trains: [train("live", north: 100, age: 12), train("stale", north: 200, age: 25),
                                      train("gone", north: 300, age: 61)],
                             observer: testObserver, now: now, sightlines: open)
        #expect(list.rows.map(\.id) == ["train:nyct:live", "train:nyct:stale"])
        let live = try #require(list.row(id: "train:nyct:live"))
        #expect(live.freshness == .live)
        #expect(live.ageSeconds == 12)
        #expect(live.ageText == "12 s ago")
        let stale = try #require(list.row(id: "train:nyct:stale"))
        #expect(stale.freshness == .stale)
        #expect(stale.accessibilityLabel().hasSuffix(", last report 25 seconds ago"))
        #expect(!live.accessibilityLabel().contains("last report"))
        #expect(live.accessibilityLabel(includeAge: true).hasSuffix(", last report 12 seconds ago"))
    }

    @Test(arguments: [(0.0, ReportFreshness.live), (19.9, .live), (20, .stale), (60, .stale), (60.1, .expired)])
    func trainFreshnessBoundaries(age: TimeInterval, expected: ReportFreshness) {
        #expect(ReportFreshness.train(lastSeen: now.addingTimeInterval(-age), now: now) == expected)
    }

    @Test func withoutObserverLocationThereAreNoDistances() throws {
        let list = TrainList(trains: [
            train("q2", route: "Q", destination: "Coney Island-Stillwell Av"),
            train("b1", route: "B", stretch: nil),
            train("q1", route: "Q", stretch: nil, destination: "96 St"),
            train("2", route: "2", stretch: nil),
        ], observer: nil, now: now)
        #expect(!list.hasDistances)
        #expect(list.eyeAltitude == nil)
        #expect(list.observer == nil)
        #expect(list.rows.map(\.id) == ["train:nyct:2", "train:nyct:b1", "train:nyct:q1", "train:nyct:q2"])
        #expect(list.inSight.isEmpty && list.outOfSight.isEmpty)
        #expect(list.underground.map(\.id) == ["train:nyct:2", "train:nyct:b1", "train:nyct:q1"])
        let row = try #require(list.row(id: "train:nyct:q2"))
        #expect(row.distanceMeters == nil && row.bearingDegrees == nil && row.relativeAltitudeMeters == nil)
        #expect(row.lineOfSight == nil && !row.isInSight)
        #expect(row.distanceText == nil && row.relativeHeightText == nil)
        #expect(row.accessibilityLabel() == "Q train to Coney Island-Stillwell Av, on the Manhattan Bridge, stopped")
        #expect(TrainARTarget.targets(in: list, undergroundRadiusMeters: 10_000, undergroundLimit: 10).isEmpty)
    }

    @Test func emptyList() {
        let list = TrainList(trains: [], observer: testObserver, now: now, sightlines: open)
        #expect(list.isEmpty)
        #expect(list.inSight.isEmpty && list.outOfSight.isEmpty && list.underground.isEmpty)
        #expect(list.row(id: "train:nyct:a") == nil)
        #expect(TrainARTarget.targets(in: list, undergroundRadiusMeters: 1_000, undergroundLimit: 5).isEmpty)
    }

    @Test func rowText() throws {
        let list = TrainList(trains: [
            train("b", north: 300, route: "B", altitude: 34.8, speed: 13.1, destination: "145 St"),
            train("6x", east: 300, route: "6X", stretch: nil),
            train("fs", east: -300, route: "FS", stretch: nil, speed: 12),
        ], observer: testObserver, now: now, sightlines: open)
        let b = try #require(list.row(id: "train:nyct:b"))
        #expect(b.title == "B to 145 St")
        #expect(b.groupedDetail == b.detail)
        #expect(b.placeText == "Manhattan Bridge")
        #expect(b.detail == "Manhattan Bridge · 15\u{00A0}mph")
        #expect(b.distanceText == "0.2\u{00A0}mi")
        #expect(b.bearingText?.hasPrefix("N ") == true)
        #expect(b.courseText == "E 90°")
        #expect(b.accessibilityLabel() == "B train to 145 St, on the Manhattan Bridge, 0.2 miles north, 100 feet above you, 15 miles per hour")
        let express = try #require(list.row(id: "train:nyct:6x"))
        #expect(express.title == "6 train")
        #expect(express.detail == "Underground · Stopped")
        // Under the "Underground" group header the row doesn't say it again.
        #expect(express.groupedDetail == "Stopped")
        #expect(express.speedText == "Stopped")
        // No ground under it on a flat surface: no depth, and never "below you".
        #expect(express.accessibilityLabel() == "6 express train, underground, 0.2 miles east, stopped")
        let shuttle = try #require(list.row(id: "train:nyct:fs"))
        #expect(shuttle.title == "S train")
        #expect(shuttle.spokenRoute == "shuttle")
    }

    @Test func heightText() {
        #expect(TrainText.relativeHeight(meters: 36, units: .imperial) == "120\u{00A0}ft up")
        #expect(TrainText.relativeHeight(meters: -14, units: .imperial) == "50\u{00A0}ft down")
        #expect(TrainText.relativeHeight(meters: 2.9, units: .imperial) == "level")
        #expect(TrainText.relativeHeight(meters: -2.9, units: .imperial) == "level")
        #expect(TrainText.spokenRelativeHeight(meters: 36, units: .imperial) == "120 feet above you")
        #expect(TrainText.spokenRelativeHeight(meters: -14, units: .imperial) == "50 feet below you")
        #expect(TrainText.spokenRelativeHeight(meters: 1, units: .imperial) == "level with you")
        #expect(TrainText.relativeHeight(meters: 36, estimated: true, units: .imperial) == "about 120\u{00A0}ft up")
        #expect(TrainText.relativeHeight(meters: 1, estimated: true, units: .imperial) == "level")
        #expect(TrainText.spokenRelativeHeight(meters: 36, estimated: true, units: .imperial) == "about 120 feet above you")
        #expect(TrainText.count(1) == "1 train")
        #expect(TrainText.count(3) == "3 trains")
    }
}

@Suite struct TrainARTargetTests {
    let now = Date(timeIntervalSince1970: 1_794_319_200)
    let open = Sightlines(surface: .flat)

    func train(_ trip: String, east: Double = 0, north: Double = 0, stretch: String? = nil, altitude: Double? = nil,
               speed: Double = 0, course: Double = 90, age: TimeInterval = 0) -> Train {
        testTrain(trip, east: east, north: north, stretch: stretch, altitude: altitude, speed: speed, course: course,
                  timestamp: now.addingTimeInterval(-age))
    }

    func list(_ trains: [Train], eye: EyeHeight = .altitude(nil)) -> TrainList {
        TrainList(trains: trains, observer: testObserver, eye: eye, now: now, sightlines: open)
    }

    func ids(_ targets: [TrainARTarget]) -> [String] {
        targets.map { $0.id.replacingOccurrences(of: "train:nyct:", with: "") }
    }

    @Test func undergroundWithinTheRadiusNearestFirstUpToTheCap() {
        let trains = zip(1..., [800.0, 200, 1_400, 600, 1_200, 400]).map { train("u\($0)", north: $1) }
            + [train("bridge", east: 3_000, stretch: "manhattan-bridge"),
               train("hidden", north: 6_000, stretch: "manhattan-bridge")]
        let targets = TrainARTarget.targets(in: list(trains), undergroundRadiusMeters: 1_000, undergroundLimit: 3)
        #expect(ids(targets.inSight) == ["bridge"])
        #expect(ids(targets.underground) == ["u2", "u6", "u4"])
        let wide = TrainARTarget.targets(in: list(trains), undergroundRadiusMeters: 1_000, undergroundLimit: 10)
        #expect(ids(wide.underground) == ["u2", "u6", "u4", "u1"])
        let none = TrainARTarget.targets(in: list(trains), undergroundRadiusMeters: 1_000, undergroundLimit: 0)
        #expect(none.underground.isEmpty)
        #expect(ids(none.all) == ["bridge"])
    }

    @Test func theFixtureUndergroundIsCappedNearestFirst() throws {
        let trains = TrainList(trains: try fixtureTrains(), observer: testObserver, now: fixtureTrainTime,
                               sightlines: open)
        let targets = TrainARTarget.targets(in: trains, undergroundRadiusMeters: 2_000, undergroundLimit: 5)
        let within = trains.underground.filter { ($0.distanceMeters ?? .infinity) <= 2_000 }
        #expect(targets.underground.count == min(5, within.count))
        #expect(targets.underground.map(\.id) == within.prefix(5).map(\.id))
        // Every above-ground train in sight on an open surface: the list's own in-sight group, the Franklin Av
        // shuttles in it only when they are within range.
        #expect(targets.inSight.map(\.id) == trains.inSight.map(\.id))
        #expect(targets.inSight.filter { $0.row.train.stretch != .franklinAv }.count == 12)
        #expect(targets.underground.allSatisfy { $0.isUnderground })
    }

    @Test func theFocusedTrainIsAddedWhereverItIs() {
        let trains = [train("u-near", north: 100), train("u-far", north: 3_000),
                      train("hidden", north: 6_000, stretch: "manhattan-bridge")]
        let far = TrainARTarget.targets(in: list(trains), focus: "train:nyct:u-far", undergroundRadiusMeters: 500,
                                        undergroundLimit: 5)
        #expect(ids(far.underground) == ["u-near", "u-far"])
        let hidden = TrainARTarget.targets(in: list(trains), focus: "train:nyct:hidden", undergroundRadiusMeters: 500,
                                           undergroundLimit: 5)
        #expect(ids(hidden.inSight) == ["hidden"])
        // Already there: not twice.
        let near = TrainARTarget.targets(in: list(trains), focus: "train:nyct:u-near", undergroundRadiusMeters: 500,
                                         undergroundLimit: 5)
        #expect(ids(near.all) == ["u-near"])
    }

    @Test func targetsGlideForAtMostFifteenSeconds() {
        // 20 knots north from 1 km east, reported 10 s before the list: 5 s left to move.
        let moving = train("a", east: 1_000, stretch: "manhattan-bridge", speed: 20, course: 0, age: 10)
        let target = TrainARTarget.targets(in: list([moving]), undergroundRadiusMeters: 0, undergroundLimit: 0)
            .inSight[0]
        #expect(target.isMoving)
        #expect(target.movesFor == 5)
        let start = target.placement(at: now)
        #expect(abs(start.distance - (1_000 * 1_000 + 102.9 * 102.9).squareRoot()) < 1)
        let later = target.placement(at: now.addingTimeInterval(5))
        let past = target.placement(at: now.addingTimeInterval(60))
        #expect(later.bearing < start.bearing)
        #expect(abs(past.distance - later.distance) < 1e-9)

        let standing = TrainARTarget.targets(in: list([train("s", east: 500)]), undergroundRadiusMeters: 1_000,
                                             undergroundLimit: 1).underground[0]
        #expect(!standing.isMoving)
        let first = standing.placement(at: now), second = standing.placement(at: now.addingTimeInterval(5))
        #expect(first.bearing == second.bearing && first.distance == second.distance)
    }

    @Test func placedByHeightAgainstTheEye() throws {
        let pose = CameraPose(headingDegrees: 0, pitchDegrees: 0, horizontalFOVDegrees: 60, viewWidth: 400,
                              viewHeight: 800)
        let horizon = ARProjection.horizonY(pose: pose)
        let targets = TrainARTarget.targets(
            in: list([train("bridge", north: 500, stretch: "manhattan-bridge", altitude: 45), train("tunnel", north: 400)],
                     eye: .altitude(10)),
            undergroundRadiusMeters: 1_000, undergroundLimit: 5)
        let bridge = try #require(targets.inSight.first)
        let tunnel = try #require(targets.underground.first)
        #expect(bridge.eyeAltitude == 10 && bridge.altitude == 45)
        #expect(tunnel.altitude == -10)
        guard case .onScreen(_, let bridgeY) = bridge.place(at: now, pose: pose),
              case .onScreen(_, let tunnelY) = tunnel.place(at: now, pose: pose) else {
            Issue.record("both trains are straight ahead")
            return
        }
        #expect(bridgeY < horizon)
        #expect(tunnelY > horizon)
        // The same as projecting by hand.
        let at = bridge.placement(at: now)
        #expect(bridge.place(at: now, pose: pose) == ARProjection.place(
            bearingDegrees: at.bearing, distanceMeters: at.distance, pose: pose, targetAltitude: 45, eyeAltitude: 10))
    }

    @Test func expiredTrainsLeaveEvenWhenTheStoreIsFrozen() {
        // Offline the store keeps its last trains; the list is worked out for the clock's now, so they age out: live
        // under 20 s, stale to 60 s, gone after, however long the connection has been down.
        let held = [train("a", north: 100, age: 0)]
        func list(after seconds: TimeInterval) -> TrainList {
            TrainList(trains: held, observer: testObserver, now: now.addingTimeInterval(seconds), sightlines: open)
        }
        #expect(list(after: 19).rows.first?.freshness == .live)
        #expect(list(after: 59).rows.first?.freshness == .stale)
        #expect(list(after: 61).isEmpty)
        #expect(list(after: 3_600).isEmpty)
        #expect(list(after: 61).row(id: "train:nyct:a") == nil)
    }

    @Test func theEmptyNoteSaysWhyWhenOffline() {
        #expect(TrainText.emptyNote(offline: true) == "Trains need a live connection.")
        #expect(TrainText.emptyNote(offline: false) == "No trains in the area right now.")
    }
}

/// A surface with the same ground everywhere around the test observer and nothing on it.
func groundOnly(_ ground: Float) -> SurfaceGrid {
    let size = 100.0, half = 3_000.0, count = Int(2 * half / size)
    let metersPerDegree = 6_371_008.8 * Double.pi / 180
    let metersPerDegreeEast = metersPerDegree * cos(testObserver.latitude * .pi / 180)
    return SurfaceGrid(south: testObserver.latitude - half / metersPerDegree,
                       west: testObserver.longitude - half / metersPerDegreeEast,
                       latitudeStep: size / metersPerDegree, longitudeStep: size / metersPerDegreeEast,
                       rows: count, columns: count, tops: Array(repeating: ground, count: count * count),
                       grounds: Array(repeating: ground, count: count * count))
}

@Suite struct TrainDepthTextTests {
    let now = Date(timeIntervalSince1970: 1_794_319_200)

    func row(altitude: Double, estimated: Bool? = true, stretch: String? = nil, ground: Float? = 12,
             observer: CLLocationCoordinate2D? = testObserver) -> TrainRow {
        var target = trainTarget("a", stretch: stretch, lat: moved(testObserver, east: 300, north: 0).latitude,
                                 lon: moved(testObserver, east: 300, north: 0).longitude, altitude: altitude,
                                 speed: 0, timestamp: now)
        target.train?.altitudeEstimated = estimated
        let surface = ground.map(groundOnly) ?? .flat
        return TrainRow(train: Train(target)!, observer: observer, now: now, sightlines: Sightlines(surface: surface))
    }

    @Test func compactDepthText() {
        #expect(TrainText.compactDepth(meters: 9.1, estimated: true, units: .imperial) == "about 30\u{00A0}ft deep")
        #expect(TrainText.compactDepth(meters: 9.1, estimated: false, units: .imperial) == "30\u{00A0}ft deep")
        #expect(TrainText.compactDepth(meters: 9.1, estimated: true, units: .metric) == "about 9\u{00A0}m deep")
        #expect(TrainText.compactDepth(meters: 9.1, estimated: false, units: .metric) == "9\u{00A0}m deep")
        for meters in [2.9, 0, -4.0] {
            #expect(TrainText.compactDepth(meters: meters, estimated: true, units: .imperial) == "under 10\u{00A0}ft deep")
            #expect(TrainText.compactDepth(meters: meters, estimated: false, units: .metric) == "under 3\u{00A0}m deep")
        }
        #expect(TrainText.compactDepth(meters: 3, estimated: false, units: .imperial) == "10\u{00A0}ft deep")
    }

    @Test func belowStreetText() {
        #expect(TrainText.belowStreet(meters: 12.2, estimated: true, units: .imperial) == "about 40\u{00A0}ft below street")
        #expect(TrainText.belowStreet(meters: 12.2, estimated: false, units: .imperial) == "40\u{00A0}ft below street")
        #expect(TrainText.spokenBelowStreet(meters: 12.2, estimated: true, units: .imperial) == "about 40 feet below the street")
        #expect(TrainText.spokenBelowStreet(meters: 12.2, estimated: false, units: .imperial) == "40 feet below the street")
        #expect(TrainText.belowStreet(meters: 12.2, estimated: true, units: .metric) == "about 12\u{00A0}m below street")
        #expect(TrainText.spokenBelowStreet(meters: 12.2, estimated: false, units: .metric) == "12 meters below the street")
        #expect(TrainText.belowStreet(meters: 30.5, estimated: true, units: .imperial) == "about 100\u{00A0}ft below street")
    }

    @Test func nonsenseDepthsAreJustBelowTheStreet() {
        for meters in [-6.0, -0.1, 0, 1, 2.9] {
            #expect(TrainText.belowStreet(meters: meters, estimated: true, units: .imperial) == "just below street")
            #expect(TrainText.spokenBelowStreet(meters: meters, estimated: false, units: .imperial) == "just below the street")
        }
        #expect(TrainText.belowStreet(meters: 3, estimated: false, units: .imperial) == "10\u{00A0}ft below street")
    }

    @Test func anUndergroundTrainSaysHowFarBelowTheStreet() throws {
        // Ground 12 m, rail at -12.4 m: 24.4 m, about 80 ft (Clark St's depth).
        let deep = row(altitude: -12.4)
        #expect(deep.depthBelowStreetMeters.map { abs($0 - 24.4) < 1e-6 } == true)
        #expect(deep.relativeHeightText == "about 80\u{00A0}ft below street")
        #expect(deep.levelText == "Underground · about 80\u{00A0}ft below street")
        #expect(deep.xrayDepthText == "about 80\u{00A0}ft deep")
        #expect(row(altitude: 15, ground: 12).xrayDepthText == "under 10\u{00A0}ft deep")
        #expect(deep.cameraDetail == "0.2\u{00A0}mi · about 80\u{00A0}ft below street")
        #expect(deep.accessibilityLabel() == "Q train, underground, 0.2 miles east, about 80 feet below the street, stopped")
        // Published figures at both ends would make it exact.
        #expect(row(altitude: -12.4, estimated: false).relativeHeightText == "80\u{00A0}ft below street")
    }

    @Test func undergroundTextNeverSaysUpOrLevel() {
        // A rail above the user's eye (a shallow station up a hill) or level with it is still below the street.
        for altitude in [-20.0, -2, 4, 8, 11] {
            let text = row(altitude: altitude, ground: 14).relativeHeightText ?? ""
            #expect(text.hasSuffix("below street"), "\(altitude): \(text)")
            #expect(!text.contains("up") && !text.contains("level"), "\(altitude): \(text)")
            let spoken = row(altitude: altitude, ground: 14).accessibilityLabel()
            #expect(!spoken.contains("above you") && !spoken.contains("level with you") && !spoken.contains("below you"))
        }
        // Rail above the ground data: clamped.
        #expect(row(altitude: 15, ground: 12).relativeHeightText == "just below street")
    }

    @Test func noGroundFallsBackToUnderground() {
        let flat = row(altitude: -12.4, ground: nil)
        #expect(flat.depthBelowStreetMeters == nil)
        #expect(flat.relativeHeightText == nil)
        #expect(flat.levelText == "Underground")
        #expect(flat.accessibilityLabel() == "Q train, underground, 0.2 miles east, stopped")
    }

    @Test func anOlderRelaysPlaceholderAltitudeGivesNoDepth() {
        let older = row(altitude: -10, estimated: nil)
        #expect(older.depthBelowStreetMeters == nil)
        #expect(older.levelText == "Underground")
    }

    @Test func estimatedHeightsAboveGroundSayAbout() {
        // The Franklin Av shuttle: estimated heights, eye-relative like every train above ground.
        let shuttle = row(altitude: 34, stretch: "franklin-av")
        #expect(shuttle.depthBelowStreetMeters == nil)
        #expect(shuttle.placeText == "Franklin Av Shuttle")
        // Eye: ground 12 m plus the waterfront's eye height.
        let above = (shuttle.relativeAltitudeMeters ?? 0)
        #expect(shuttle.relativeHeightText == TrainText.relativeHeight(meters: above, estimated: true, units: .imperial))
        #expect(shuttle.relativeHeightText?.hasPrefix("about ") == true)
        #expect(shuttle.relativeHeightText?.hasSuffix("ft up") == true)
        let bridge = row(altitude: 40, estimated: false, stretch: "manhattan-bridge")
        #expect(bridge.relativeHeightText?.hasPrefix("about") == false)
    }
}
