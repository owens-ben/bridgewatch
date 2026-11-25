import Foundation
import XCTest

/// Performance harness for the camera, list and map tabs: the app's CPU and memory over a fixed scene of 80 vessels and
/// 80 trains (60 of them underground), in
/// the simulator, so a change to any of them can be compared before and after. Skipped unless asked for (each test
/// takes about a minute), like the screenshot tour. Use a simulator nothing else is running on:
///
///     TEST_RUNNER_BOATAR_PERF=1 xcodebuild test -scheme BoatAR \
///       -destination 'platform=iOS Simulator,id=<udid>' -collect-test-diagnostics never \
///       -resultBundlePath perf/camera.xcresult \
///       -only-testing:BoatARUITests/BoatARUITests/testCameraPerformance
///     xcrun xcresulttool get test-results metrics --path perf/camera.xcresult
///
/// The others are testListPerformance (the list sitting), testListScrollPerformance and testMapPerformance. Reading
/// the numbers:
/// - Debug build (the test hooks are DEBUG only) on the Mac's CPU: compare runs with each other, not with a phone.
/// - XCTCPUMetric counts the app's own process. What the render server draws for it (Liquid Glass, the preview) is not
///   in it; Instruments is the tool for that.
/// - The simulator has no camera, so the preview isn't measured: the labels, compass strip and glass over it are.
/// - Night mode is pinned off (Automatic follows the clock, and its red palette draws differently) and no report
///   ages across the run, so runs at different times of day are alike.
extension BoatARUITests {
    /// Fake sensors with the heading panning: the camera screen redraws 30 times a second, like a phone held up.
    @MainActor
    func testCameraPerformance() throws {
        try requirePerfRun()
        let app = launchPerf(sweep: true)
        openCamera(app)
        XCTAssertTrue(app.staticTexts["compassHeading"].waitForExistence(timeout: 30), "the camera didn't come up")
        recordCameraState(app)
        Thread.sleep(forTimeInterval: 3)  // first layout and glass setup aren't the steady state
        measurePerf(app) { Thread.sleep(forTimeInterval: 8) }
    }

    /// The list on screen and nothing moving: what it costs to sit there.
    @MainActor
    func testListPerformance() throws {
        try requirePerfRun()
        let app = launchPerf(sweep: false)
        waitForLabel(app.staticTexts["vesselCount"], "\(PerfFixture.vessels.count) vessels", timeout: 30)
        Thread.sleep(forTimeInterval: 3)
        measurePerf(app) { Thread.sleep(forTimeInterval: 8) }
    }

    @MainActor
    func testListScrollPerformance() throws {
        try requirePerfRun()
        let app = launchPerf(sweep: false)
        waitForLabel(app.staticTexts["vesselCount"], "\(PerfFixture.vessels.count) vessels", timeout: 30)
        Thread.sleep(forTimeInterval: 3)
        measurePerf(app) {
            for _ in 0..<3 { app.swipeUp() }
            for _ in 0..<3 { app.swipeDown() }
        }
    }

    @MainActor
    func testMapPerformance() throws {
        try requirePerfRun()
        let app = launchPerf(sweep: false)
        let tab = app.buttons["Map"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "vesselMap").firstMatch
            .waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 3)  // annotations and the first tiles
        measurePerf(app) { Thread.sleep(forTimeInterval: 8) }
    }

    /// Always on, and instant: the fixture is what makes runs comparable, so it must not drift.
    func testPerformanceFixtureIsValid() throws {
        let vessels = PerfFixture.vessels
        XCTAssertEqual(vessels.count, 80)
        XCTAssertEqual(Set(vessels.map(\.mmsi)).count, vessels.count, "MMSIs are unique")
        XCTAssertEqual(PerfFixture.generate(), vessels, "seeded: the same vessels on every run")
        let area = PerfFixture.area
        for vessel in vessels {
            XCTAssertTrue((area.minLat...area.maxLat).contains(vessel.lat)
                          && (area.minLon...area.maxLon).contains(vessel.lon), "\(vessel.mmsi) is outside the area")
            XCTAssertLessThanOrEqual(vessel.name?.count ?? 0, 20, "AIS names are at most 20 characters")
        }
        // Plenty of labels facing northeast, within 3 km, and through the whole sweep (36 degrees +/- 25).
        XCTAssertGreaterThanOrEqual(PerfFixture.inView(heading: PerfFixture.heading, maxDistance: 3_000).count, 25)
        for heading in stride(from: PerfFixture.heading - 25, through: PerfFixture.heading + 25, by: 5) {
            XCTAssertGreaterThanOrEqual(PerfFixture.inView(heading: heading).count, 18, "heading \(heading)")
        }
        // A mix of what the harbor carries: every display group, some stale reports, some without static data.
        let groups = Set(vessels.compactMap { $0.shipType }.map { $0 / 10 })
        XCTAssertTrue(groups.isSuperset(of: [3, 5, 6, 7, 8]), "ship types \(groups.sorted())")
        XCTAssertTrue(vessels.contains { $0.shipType == 52 })
        XCTAssertEqual(vessels.filter { $0.staleAge != nil }.count, 12)
        XCTAssertEqual(vessels.filter { $0.name == nil }.count, 6)
        // The replay feed's JSON is well-formed and complete.
        let json = Data(PerfFixture.snapshotJSON(now: Date()).utf8)
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(snapshot["type"] as? String, "snapshot")
        XCTAssertEqual((snapshot["targets"] as? [[String: Any]])?.count, 160)
        try checkTrains()
    }

    private func checkTrains() throws {
        let trains = PerfFixture.trains
        XCTAssertEqual(trains.count, PerfFixture.trainCount)
        XCTAssertEqual(trains.filter { $0.stretch == nil }.count, PerfFixture.undergroundTrainCount)
        XCTAssertEqual(Set(trains.map(\.trip)).count, trains.count, "trip IDs are unique")
        XCTAssertEqual(PerfFixture.generateTrains(), trains, "seeded: the same trains on every run")
        let area = PerfFixture.area
        for train in trains {
            XCTAssertTrue((area.minLat...area.maxLat).contains(train.lat)
                          && (area.minLon...area.maxLon).contains(train.lon), "\(train.trip) is outside the area")
        }
        // More underground trains ahead within 1.5 km than the camera labels (8).
        let ahead = trains.filter { $0.stretch == nil && PerfFixture.distance(lat: $0.lat, lon: $0.lon) <= 1_500 }
        XCTAssertGreaterThan(ahead.count, 8)
    }

    // MARK: Helpers

    private func requirePerfRun() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOATAR_PERF"] == "1",
                          "Set TEST_RUNNER_BOATAR_PERF=1 to run the performance tests")
    }

    /// Launches with the 80-vessel snapshot and the camera tests' sensors (the DUMBO waterfront facing northeast).
    /// Built here rather than with `launch`, which can't add BOATAR_FAKE_HEADING_SWEEP (DEBUG only, set per launch).
    @MainActor
    private func launchPerf(sweep: Bool) -> XCUIApplication {
        // The same look on every run, whatever the simulator was left at.
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchEnvironment["BOATAR_REPLAY_FEED"] = "[" + PerfFixture.snapshotJSON(now: Date()) + "]"
        app.launchEnvironment["BOATAR_FAKE_SENSORS"] = PerfFixture.sensors
        if sweep { app.launchEnvironment["BOATAR_FAKE_HEADING_SWEEP"] = "1" }
        app.launchEnvironment["BOATAR_RESET_EYE_HEIGHT"] = "1"
        app.launchEnvironment["BOATAR_RESET_TRAIN_SETTINGS"] = "1"
        app.launchEnvironment["BOATAR_RESET_CAMERA_FILTER"] = "1"
        app.launchEnvironment["BOATAR_RESET_UNITS"] = "1"
        app.launchEnvironment["BOATAR_RESET_BROWSE"] = "1"
        // Argument-domain defaults, as `launch` and the screenshot tour use: skip the permissions screen, pin night mode.
        app.launchArguments += ["-onboardingDone", "YES", "-nightMode", "off"]
        app.launch()
        return app
    }

    /// Five runs of `block`, each measured for the app's CPU and memory.
    @MainActor
    private func measurePerf(_ app: XCUIApplication, block: () -> Void) {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app)],
                options: options, block: block)
    }

    /// Notes how many labels the camera is drawing, and a screenshot, in the results: the numbers mean little if the
    /// scene was empty. Taken before measuring so the queries don't count.
    @MainActor
    private func recordCameraState(_ app: XCUIApplication) {
        let labels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'arLabel-'")).count
        let expected = PerfFixture.inView(heading: PerfFixture.heading).count
        let note = XCTAttachment(string: "camera labels in the view hierarchy: \(labels); "
            + "fixture vessels in view at the center heading: \(expected)")
        note.name = "camera-label-count"
        note.lifetime = .keepAlways
        add(note)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "camera-under-sweep"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

// MARK: - Fixture

/// 80 synthetic vessels, the same ones on every run (seeded), spread over the app's area:
/// - 56 "ahead": evenly spread over bearings 0-72 degrees from the observer and 250 m to 3 km out, so the camera has
///   plenty of labels at every point of its sweep. They aren't kept to the water.
/// - 24 along the harbor's channels (upper bay, Buttermilk Channel, the Hudson's mouth, the East River below the
///   Brooklyn Bridge and past the Williamsburg Bridge), so the map and list have the whole area.
/// Names, ship types, speeds and courses follow what the harbor carries: ferries and sightseeing boats, tugs,
/// freighters and tankers (some at anchor), pleasure craft, a few others, and some vessels whose static data hasn't
/// arrived yet.
private enum PerfFixture {
    struct Vessel: Equatable {
        let mmsi: Int
        let name: String?
        let shipType: Int?
        let lat: Double
        let lon: Double
        /// Knots.
        let sog: Double
        /// Course over ground and true heading, degrees.
        let cog: Double
        let heading: Double?
        /// Seconds since its last report; nil for a live vessel (see `snapshotJSON`).
        let staleAge: TimeInterval?
    }

    // MARK: Where the camera tests stand

    /// The DUMBO waterfront, facing northeast, compass good to 5 degrees. The string is BOATAR_FAKE_SENSORS
    /// ("lat,lon,heading,pitch,accuracy"), the same as `facingNortheast`.
    static let observer = (lat: 40.7046, lon: -73.9913)
    static let heading = 36.0
    static let sensors = "40.7046,-73.9913,36,0,5"
    /// The app's area: BoatCore's `devBoundingBox` (the UI tests don't link BoatCore). Keep them equal.
    static let area = (minLat: 40.675, maxLat: 40.735, minLon: -74.045, maxLon: -73.955)
    /// Half the width of what the camera screen shows on an iPhone 18 Pro held upright (a 70-degree sensor, 4:3, aspect
    /// fill: about 36 degrees); rounded down so the counts are honest.
    static let halfFieldOfView = 17.0

    // MARK: Composition

    static let aheadCount = 56
    static let aheadSpan = 72.0
    static let staleCount = 12
    /// Live vessels are stamped this far ahead of the clock, so none of them turns stale (60 s) while a run is
    /// measured. Stale ones are 75-280 s old, so none of them expires (600 s) either.
    static let liveLead: TimeInterval = 300

    private enum Kind: CaseIterable {
        case passenger, tug, cargo, pleasure, other, unknown

        var count: Int {
            switch self {
            case .passenger: 16
            case .tug: 18
            case .cargo: 16
            case .pleasure: 18
            case .other: 6
            case .unknown: 6
            }
        }

        /// Exactly `count` names, 20 characters at most like AIS.
        var names: [String] {
            switch self {
            case .passenger:
                ["EAST RIVER EXPRESS", "LADY LIBERTY BELLE", "STATEN ISL CLIPPER", "GOVERNORS ISLANDER", "DUMBO DART",
                 "BROOKLYN BELLE", "MANHATTAN SKYLINER", "WATERFRONT SPIRIT", "CITY SIGHTSEER", "SKYLINE CRUISER",
                 "NEW AMSTERDAM", "HUDSON QUEEN", "ROOSEVELT ISLANDER", "BRIDGE AND TUNNEL", "GOTHAM SEA TAXI",
                 "SUNSET CHARTER II"]
            case .tug:
                ["CAPT JOE ROURKE", "KATHLEEN B", "SEA HORSE II", "DALTON POINT", "BAYONNE", "RED HOOK", "COBBLE HILL",
                 "ATLANTIC BASIN", "LIBERTY TUG", "GOWANUS BAY", "NARROWS", "MIDLAND", "DELANCEY", "KILL VAN KULL",
                 "MARGARET ANN", "TURNING POINT", "BROOKLYN ROSE", "JAMES T NOLAN"]
            case .cargo:
                ["ATLANTIC CARRIER", "PORT NEWARK", "EVERGLADES TRADER", "NORDIC SPRING", "OCEAN TRADER",
                 "KINGSTON STAR", "HARBOR TANKER 7", "BERGEN POINT", "STELLA MARIS", "BALTIC SUN", "SOUND PIONEER",
                 "GREAT LAKES 204", "TANK BARGE 1201", "SEABOARD NAVIGATOR", "EMERALD BAY", "COASTAL VOYAGER"]
            case .pleasure:
                ["SEA BREEZE", "ODYSSEY", "WIND DANCER", "LUCKY STRIKE", "MISS BEHAVIN", "SALTY DOG", "KNOT TODAY",
                 "SECOND WIND", "ANGELINA", "BLUE HERON", "SUMMER WIND", "NAUTI BUOY", "VITAMIN SEA", "RESTLESS",
                 "HIGH TIDE", "ISLAND TIME", "SPINDRIFT", "LADY JANE"]
            case .other:
                ["TWO BROTHERS", "ISLAND HOPPER", "SURVEY LAUNCH", "WORK BOAT 12", "BLUE FIN", "HARBOR JET"]
            case .unknown:
                []
            }
        }

        /// AIS ship types to draw from; repeats weight the common ones (passenger 60-69, towing 31-32, tug 52, pilot
        /// 50, port tender 53, law enforcement 55, cargo 70-79, tanker 80-89, sailing 36, pleasure craft 37, fishing
        /// 30, high-speed craft 40, other 90-99). Nil while static data hasn't arrived.
        var shipTypes: [Int] {
            switch self {
            case .passenger: [60, 60, 61, 69, 69, 69]
            case .tug: [52, 52, 52, 52, 31, 32, 53, 55]
            case .cargo: [70, 70, 71, 72, 79, 80, 81, 89]
            case .pleasure: [37, 37, 37, 36]
            case .other: [30, 40, 90, 99]
            case .unknown: []
            }
        }

        /// MMSI prefixes (the US, plus flags of convenience for freighters).
        var maritimeIdentificationDigits: [Int] {
            switch self {
            case .cargo: [366, 367, 538, 636, 477, 563, 311, 255, 235]
            default: [366, 367, 368, 369]
            }
        }

        /// Share under way (the rest are moored or anchored) and their speeds in knots.
        var movingShare: Double {
            switch self {
            case .passenger: 0.7
            case .tug: 0.65
            case .cargo: 0.45
            case .pleasure: 0.55
            case .other: 0.7
            case .unknown: 0.5
            }
        }

        var speeds: ClosedRange<Double> {
            switch self {
            case .passenger: 7...17
            case .tug: 2...9
            case .cargo: 3...11
            case .pleasure: 2...8
            case .other: 4...15
            case .unknown: 1...9
            }
        }
    }

    /// A channel the harbor's traffic follows: a centerline with the width vessels spread over either side.
    private struct Lane {
        let points: [(lat: Double, lon: Double)]
        let halfWidthMeters: Double
        let count: Int
    }

    private static let lanes = [
        // Upper Bay, between Governors Island and the Statue of Liberty.
        Lane(points: [(40.6990, -74.0330), (40.6930, -74.0280), (40.6850, -74.0220), (40.6780, -74.0200)],
             halfWidthMeters: 450, count: 6),
        // Buttermilk Channel and Red Hook.
        Lane(points: [(40.6985, -74.0075), (40.6900, -74.0100), (40.6800, -74.0160)],
             halfWidthMeters: 250, count: 4),
        // The Hudson's mouth, off Jersey City.
        Lane(points: [(40.7080, -74.0230), (40.7200, -74.0260), (40.7340, -74.0250)],
             halfWidthMeters: 500, count: 6),
        // East River, Brooklyn Bridge to the Battery.
        Lane(points: [(40.7056, -73.9972), (40.7030, -74.0050), (40.7005, -74.0105)],
             halfWidthMeters: 200, count: 4),
        // East River, Williamsburg Bridge toward Greenpoint.
        Lane(points: [(40.7142, -73.9731), (40.7200, -73.9700), (40.7280, -73.9660), (40.7345, -73.9640)],
             halfWidthMeters: 220, count: 4),
    ]

    // MARK: Generating

    static let vessels = generate()

    /// SplitMix64 and the few draws needed, written out here rather than taken from the standard library, whose
    /// algorithms may change with the toolchain: the vessels must not.
    private struct SeededGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in [0, 1).
        mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992 }

        mutating func value(in range: ClosedRange<Double>) -> Double {
            range.lowerBound + unit() * (range.upperBound - range.lowerBound)
        }

        mutating func index(below count: Int) -> Int { Int(next() % UInt64(count)) }

        mutating func chance(_ probability: Double) -> Bool { unit() < probability }

        mutating func pick<T>(_ items: [T]) -> T { items[index(below: items.count)] }

        /// Fisher-Yates.
        mutating func shuffled<T>(_ items: [T]) -> [T] {
            var items = items
            for i in stride(from: items.count - 1, to: 0, by: -1) { items.swapAt(i, index(below: i + 1)) }
            return items
        }
    }

    private struct Placement {
        let lat: Double
        let lon: Double
        /// The course of a vessel under way here.
        let course: Double
    }

    static func generate() -> [Vessel] {
        var rng = SeededGenerator(seed: 0xB0A7_A12_2026)
        var placements: [Placement] = []

        // Ahead of the camera: bearings evenly spread (one per slot, jittered), distances nearer and farther than
        // the half-mile mark where labels fade.
        for slot in 0..<aheadCount {
            let bearing = (Double(slot) + rng.unit()) / Double(aheadCount) * aheadSpan
            let distance = rng.chance(0.35) ? rng.value(in: 250...800) : rng.value(in: 800...3_000)
            let spot = coordinate(x: distance * sin(radians(bearing)), y: distance * cos(radians(bearing)))
            // East River traffic runs along the river, northeast or southwest.
            let course = (rng.chance(0.5) ? 40.0 : 220.0) + rng.value(in: -25...25)
            placements.append(Placement(lat: spot.lat, lon: spot.lon, course: course))
        }
        for lane in lanes {
            for _ in 0..<lane.count { placements.append(place(on: lane, &rng)) }
        }

        // Who is where: exact counts per kind, shuffled onto the placements.
        let kinds = rng.shuffled(Kind.allCases.flatMap { Array(repeating: $0, count: $0.count) })
        var names = Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, rng.shuffled($0.names)) })
        let stale = Set(rng.shuffled(Array(placements.indices)).prefix(staleCount))
        var taken = Set<Int>()

        let vessels = placements.indices.map { i -> Vessel in
            let placement = placements[i]
            let kind = kinds[i]
            var mmsi: Int
            repeat {
                mmsi = rng.pick(kind.maritimeIdentificationDigits) * 1_000_000 + rng.index(below: 1_000_000)
            } while !taken.insert(mmsi).inserted
            let underway = rng.chance(kind.movingShare)
            let sog = tenths(underway ? rng.value(in: kind.speeds) : rng.value(in: 0...0.3))
            // Under way a vessel follows its lane; moored or anchored it points anywhere and its GPS course wanders.
            let cog = tenths(underway ? normalized(placement.course + rng.value(in: -10...10)) : rng.value(in: 0...359))
            // Some transponders send no heading (511).
            let heading: Double? = rng.chance(0.85)
                ? (underway ? normalized(cog + rng.value(in: -6...6)) : rng.value(in: 0...359)) : nil
            return Vessel(
                mmsi: mmsi,
                name: kind == .unknown ? nil : names[kind]?.popLast(),
                shipType: kind == .unknown ? nil : rng.pick(kind.shipTypes),
                lat: placement.lat, lon: placement.lon, sog: sog, cog: cog, heading: heading.map { $0.rounded() },
                staleAge: stale.contains(i) ? rng.value(in: 75...280).rounded() : nil)
        }
        return vessels.sorted { $0.mmsi < $1.mmsi }
    }

    /// A point along the lane's centerline, across it by up to the lane's half width, heading either way along it.
    private static func place(on lane: Lane, _ rng: inout SeededGenerator) -> Placement {
        let points = lane.points.map { meters(lat: $0.lat, lon: $0.lon) }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var along = rng.value(in: 0...lengths.reduce(0, +))
        var leg = 0
        while leg < lengths.count - 1, along > lengths[leg] {
            along -= lengths[leg]
            leg += 1
        }
        let (start, end) = (points[leg], points[leg + 1])
        let fraction = along / lengths[leg]
        let direction = (x: (end.x - start.x) / lengths[leg], y: (end.y - start.y) / lengths[leg])
        let across = rng.value(in: -lane.halfWidthMeters...lane.halfWidthMeters)
        let spot = coordinate(x: start.x + (end.x - start.x) * fraction - direction.y * across,
                              y: start.y + (end.y - start.y) * fraction + direction.x * across)
        let course = degrees(atan2(direction.x, direction.y)) + (rng.chance(0.5) ? 0 : 180)
        return Placement(lat: spot.lat, lon: spot.lon, course: course)
    }

    // MARK: Trains

    /// A subway train target: on a bridge (rail height measured) or underground (the relay's flat -10 m).
    struct Train: Equatable {
        let trip: String
        let route: String
        let destination: String
        let stretch: String?
        let lat: Double
        let lon: Double
        let altitude: Double
        let speed: Double
        let course: Double
    }

    static let trainCount = 80
    static let undergroundTrainCount = 60

    /// The bridges' tracks in the area (rail height at each end) and the routes on them.
    private static let bridges: [(stretch: String, points: [(lat: Double, lon: Double)], heights: ClosedRange<Double>,
                                  routes: [String], count: Int)] = [
        ("manhattan-bridge", [(40.7010, -73.9850), (40.7032, -73.9882), (40.7056, -73.9916), (40.7110, -73.9938),
                              (40.7150, -73.9945)], 25...41, ["B", "D", "N", "Q"], 12),
        ("williamsburg-bridge", [(40.7180, -73.9870), (40.7141, -73.9739), (40.7105, -73.9625)], 28...42,
         ["J", "M", "Z"], 8),
    ]

    private static let undergroundRoutes = ["1", "2", "3", "4", "5", "6", "6X", "A", "C", "E", "F", "FX", "G", "R", "W",
                                            "L", "FS"]
    private static let destinations = ["Coney Island-Stillwell Av", "Jamaica-179 St", "Inwood-207 St", "Far Rockaway",
                                       "Pelham Bay Park", "Van Cortlandt Park-242 St", "Flatbush Av-Brooklyn College",
                                       "Bay Ridge-95 St", "Court Sq", "8 Av", "Prospect Park", "Astoria-Ditmars Blvd"]

    static let trains = generateTrains()

    /// 20 on the bridges, 30 underground ahead of the camera (bearings 0-72 degrees, 200 m to 1.5 km: more than the
    /// camera's 8 x-ray labels) and 30 underground anywhere in the area. Their own seed: the vessels stay as they were.
    static func generateTrains() -> [Train] {
        var rng = SeededGenerator(seed: 0x7A1_2026)
        var trains: [Train] = []
        func add(stretch: String?, lat: Double, lon: Double, altitude: Double, route: String, course: Double,
                 _ rng: inout SeededGenerator) {
            let standing = rng.chance(0.25)
            trains.append(Train(trip: String(format: "%06d_%@..%@", trains.count * 137 + 100_000, route,
                                             rng.chance(0.5) ? "N" : "S"),
                                route: route, destination: rng.pick(destinations), stretch: stretch,
                                lat: lat, lon: lon, altitude: tenths(altitude),
                                speed: standing ? 0 : tenths(rng.value(in: 12...30)), course: tenths(course)))
        }
        for bridge in bridges {
            let lane = Lane(points: bridge.points, halfWidthMeters: 0, count: bridge.count)
            for _ in 0..<bridge.count {
                let spot = place(on: lane, &rng)
                add(stretch: bridge.stretch, lat: spot.lat, lon: spot.lon, altitude: rng.value(in: bridge.heights),
                    route: rng.pick(bridge.routes), course: spot.course, &rng)
            }
        }
        for _ in 0..<(undergroundTrainCount / 2) {
            let bearing = rng.value(in: 0...aheadSpan), distance = rng.value(in: 200...1_500)
            let spot = coordinate(x: distance * sin(radians(bearing)), y: distance * cos(radians(bearing)))
            add(stretch: nil, lat: spot.lat, lon: spot.lon, altitude: -10, route: rng.pick(undergroundRoutes),
                course: rng.value(in: 0...359), &rng)
        }
        for _ in 0..<(undergroundTrainCount / 2) {
            add(stretch: nil, lat: rng.value(in: area.minLat + 0.001...area.maxLat - 0.001),
                lon: rng.value(in: area.minLon + 0.001...area.maxLon - 0.001), altitude: -10,
                route: rng.pick(undergroundRoutes), course: rng.value(in: 0...359), &rng)
        }
        return trains
    }

    // MARK: Replay feed

    /// The relay's /v2/targets snapshot message (relay/PROTOCOL.md) for BOATAR_REPLAY_FEED, report times relative to
    /// `now`. Live vessels are stamped `liveLead` ahead of it: the app clamps their age to zero, and they stay live
    /// for the whole run instead of going stale at some point depending on how long the run took.
    static func snapshotJSON(now: Date) -> String {
        let targets = vessels.map { vessel -> String in
            var fields = [#""id":"vessel:\#(vessel.mmsi)","kind":"vessel","source":"aisstream""#]
            if let name = vessel.name { fields.append(#""name":"\#(name)""#) }
            fields.append(#""lat":\#(vessel.lat),"lon":\#(vessel.lon),"speed":\#(vessel.sog),"course":\#(vessel.cog)"#)
            if let heading = vessel.heading { fields.append(#""heading":\#(Int(heading))"#) }
            let stamp = now.addingTimeInterval(vessel.staleAge.map { -$0 } ?? liveLead)
                .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            fields.append(#""timestamp":"\#(stamp)""#)
            var details = [#""mmsi":\#(vessel.mmsi)"#]
            if let type = vessel.shipType { details.append(#""shipType":\#(type)"#) }
            fields.append(#""vessel":{\#(details.joined(separator: ","))}"#)
            return "{" + fields.joined(separator: ",") + "}"
        }
        let stamp = now.addingTimeInterval(liveLead).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let trainTargets = trains.map { train -> String in
            var details = [#""route":"\#(train.route)","direction":"N","destination":"\#(train.destination)""#]
            if let stretch = train.stretch { details.append(#""stretch":"\#(stretch)""#) }
            details.append(#""underground":\#(train.stretch == nil)"#)
            return #"{"id":"train:nyct:\#(train.trip)","kind":"train","source":"mta-subway","#
                + #""lat":\#(train.lat),"lon":\#(train.lon),"altitude":\#(train.altitude),"speed":\#(train.speed),"#
                + #""course":\#(train.course),"timestamp":"\#(stamp)","train":{\#(details.joined(separator: ","))}}"#
        }
        return #"{"type":"snapshot","targets":[\#((targets + trainTargets).joined(separator: ","))]}"#
    }

    // MARK: Geometry

    /// The vessels within the camera's field of view (and `maxDistance` meters) when it points at `heading`.
    static func inView(heading: Double, maxDistance: Double = .infinity) -> [Vessel] {
        vessels.filter {
            abs(relativeBearing(bearing(of: $0), heading: heading)) <= halfFieldOfView
                && distance(of: $0) <= maxDistance
        }
    }

    /// Initial great-circle bearing from the observer, degrees clockwise from true north (BoatCore's `bearing`).
    static func bearing(of vessel: Vessel) -> Double {
        let lat1 = radians(observer.lat), lat2 = radians(vessel.lat)
        let dLon = radians(vessel.lon - observer.lon)
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return normalized(degrees(atan2(y, x)))
    }

    /// Great-circle distance from the observer in meters (haversine, BoatCore's `distance`).
    static func distance(of vessel: Vessel) -> Double {
        distance(lat: vessel.lat, lon: vessel.lon)
    }

    static func distance(lat: Double, lon: Double) -> Double {
        let lat1 = radians(observer.lat), lat2 = radians(lat)
        let dLat = lat2 - lat1
        let dLon = radians(lon - observer.lon)
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6_371_008.8 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// In (-180, 180]: negative is left of the camera's axis.
    private static func relativeBearing(_ bearing: Double, heading: Double) -> Double {
        var relative = (bearing - heading).truncatingRemainder(dividingBy: 360)
        if relative > 180 { relative -= 360 }
        if relative <= -180 { relative += 360 }
        return relative
    }

    private static let metersPerDegreeOfLatitude = 111_320.0

    /// Meters east and north of the observer (flat Earth: the area is 8 km across).
    private static func meters(lat: Double, lon: Double) -> (x: Double, y: Double) {
        ((lon - observer.lon) * metersPerDegreeOfLatitude * cos(radians(observer.lat)),
         (lat - observer.lat) * metersPerDegreeOfLatitude)
    }

    /// The point `x` meters east and `y` north of the observer, kept just inside the area.
    private static func coordinate(x: Double, y: Double) -> (lat: Double, lon: Double) {
        let lat = observer.lat + y / metersPerDegreeOfLatitude
        let lon = observer.lon + x / (metersPerDegreeOfLatitude * cos(radians(observer.lat)))
        let margin = 0.0005
        return (min(max(lat, area.minLat + margin), area.maxLat - margin),
                min(max(lon, area.minLon + margin), area.maxLon - margin))
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    private static func normalized(_ degrees: Double) -> Double {
        let remainder = degrees.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    private static func tenths(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
