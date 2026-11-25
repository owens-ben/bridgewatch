import XCTest

/// Trains: in the list under the boats (in sight, then a collapsed underground group), on the map, in the camera
/// (labels for trains in sight, x-ray labels for the nearest underground ones) and in their own details. The fixture
/// stands on the DUMBO waterfront facing north (`testSensors`): the Q on the Manhattan Bridge's river span is ahead
/// and in sight, the M on the Williamsburg Bridge is in sight off to the right, and four trains run underground, three
/// of them within the camera's 1.5 km x-ray radius.
extension BoatARUITests {
    struct FixtureTrain {
        let trip: String
        let route: String
        let destination: String
        /// Nil underground.
        let stretch: String?
        let lat: Double
        let lon: Double
        /// Rail height, meters above sea level.
        let altitude: Double
        let speed: Double
        let course: Double
    }

    static let fixtureTrains = [
        FixtureTrain(trip: "Q1", route: "Q", destination: "96 St", stretch: "manhattan-bridge",
                     lat: 40.7075, lon: -73.9905, altitude: 41, speed: 18, course: 340),
        FixtureTrain(trip: "M1", route: "M", destination: "Middle Village-Metropolitan Av",
                     stretch: "williamsburg-bridge", lat: 40.7141, lon: -73.9739, altitude: 42, speed: 15, course: 112),
        // Underground, ahead: 0.5 km at 348°, 0.7 km at 9°, 1.2 km at 353°.
        FixtureTrain(trip: "F1", route: "F", destination: "Jamaica-179 St", stretch: nil,
                     lat: 40.7090, lon: -73.9925, altitude: -10, speed: 0, course: 300),
        FixtureTrain(trip: "A1", route: "A", destination: "Inwood-207 St", stretch: nil,
                     lat: 40.7110, lon: -73.9900, altitude: -10, speed: 20, course: 10),
        FixtureTrain(trip: "6X1", route: "6X", destination: "Pelham Bay Park", stretch: nil,
                     lat: 40.7150, lon: -73.9930, altitude: -10, speed: 22, course: 20),
        // Underground, behind and beyond the x-ray radius (1.7 km south).
        FixtureTrain(trip: "G1", route: "G", destination: "Church Av", stretch: nil,
                     lat: 40.6900, lon: -73.9850, altitude: -10, speed: 12, course: 200),
    ]

    static func trainID(_ trip: String) -> String { "train:nyct:\(trip)" }

    /// One train as a /v2/targets target (relay/PROTOCOL.md, "Trains"). Stamped 10 minutes ahead of the clock: the app
    /// clamps the age to zero, so no train goes stale or expires (60 s) however slowly the simulator runs a test, and
    /// none moves (dead reckoning runs from the timestamp).
    func json(_ t: FixtureTrain, now: Date) -> String {
        let stamp = now.addingTimeInterval(600).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        var details = [#""route":"\#(t.route)","direction":"N","destination":"\#(t.destination)""#]
        if let stretch = t.stretch { details.append(#""stretch":"\#(stretch)""#) }
        details.append(#""underground":\#(t.stretch == nil)"#)
        // As the relay with the depth model sends it: every underground altitude estimated, the bridges measured.
        details.append(#""altitudeEstimated":\#(t.stretch == nil)"#)
        return #"{"id":"\#(Self.trainID(t.trip))","kind":"train","source":"mta-subway","lat":\#(t.lat),"lon":\#(t.lon),"#
            + #""altitude":\#(t.altitude),"speed":\#(t.speed),"course":\#(t.course),"timestamp":"\#(stamp)","#
            + #""train":{\#(details.joined(separator: ","))}}"#
    }

    /// The boat fixture and the trains in one snapshot.
    @MainActor
    func launchWithTrains(_ trains: [FixtureTrain] = fixtureTrains, sensors: String? = testSensors,
                          regular: Bool = false, arguments: [String] = [],
                          environment: [String: String] = [:]) -> XCUIApplication {
        let now = Date()
        let targets = vessels.map { json($0, now: now) } + trains.map { json($0, now: now) }
        return launch(messages: [#"{"type":"snapshot","targets":[\#(targets.joined(separator: ","))]}"#],
                      regular: regular, sensors: sensors, arguments: arguments, environment: environment)
    }

    /// The map zoomed in on the Manhattan Bridge's river span, 1.2 km across: underground trains show there.
    static let zoomedOnTheBridge = ["BOATAR_MAP_REGION": "40.7075,-73.9905,1200"]

    /// An F underground 30 m from the Q on the bridge: zoomed in, their markers overlap.
    static let underTheBridge = FixtureTrain(trip: "F2", route: "F", destination: "Coney Island-Stillwell Av",
                                             stretch: nil, lat: 40.7077, lon: -73.9903, altitude: -10, speed: 0,
                                             course: 160)

    func row(_ app: XCUIApplication, _ trip: String) -> XCUIElement {
        app.buttons["trainRow-\(Self.trainID(trip))"]
    }

    // MARK: List

    @MainActor
    func testListShowsTrainsUnderTheBoats() throws {
        let app = launchWithTrains()
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        waitForLabel(app.staticTexts["trainCount"], "6 trains")

        // Both bridges are in sight from the waterfront, nearest first.
        let q = row(app, "Q1")
        XCTAssertTrue(reveal(q, in: app))
        XCTAssertTrue(q.label.hasPrefix("Q train to 96 St, on the Manhattan Bridge, "), q.label)
        XCTAssertTrue(q.label.contains("feet above you"), q.label)
        XCTAssertTrue(reveal(row(app, "M1"), in: app))
        XCTAssertLessThan(q.frame.minY, row(app, "M1").frame.minY, "nearest first")
        XCTAssertFalse(app.buttons["trainsOutOfSightToggle"].exists)

        // Underground: collapsed under its count until asked for.
        let toggle = app.buttons["undergroundToggle"]
        XCTAssertTrue(reveal(toggle, in: app))
        XCTAssertTrue(toggle.label.hasPrefix("Underground, 4"), toggle.label)
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        XCTAssertFalse(row(app, "F1").exists, "underground rows start collapsed")
        toggle.tap()
        let f = row(app, "F1")
        XCTAssertTrue(reveal(f, in: app))
        XCTAssertTrue(f.label.hasPrefix("F train to Jamaica-179 St, underground, "), f.label)
        // Its depth below the street (the ground under it less its rail), never against the user's eye.
        XCTAssertTrue(f.label.contains("below the street"), f.label)
        XCTAssertFalse(f.label.contains("below you"), f.label)
        XCTAssertTrue(reveal(row(app, "6X1"), in: app))
        XCTAssertTrue(row(app, "6X1").label.hasPrefix("6 express train to Pelham Bay Park"), row(app, "6X1").label)
    }

    /// No location, no sightlines: the trains above ground are listed together, and the underground group is still
    /// there.
    @MainActor
    func testTrainsAreListedWithoutLocation() throws {
        let app = launchWithTrains(sensors: "none,none,0,0,5")
        waitForLabel(app.staticTexts["trainCount"], "6 trains")
        XCTAssertTrue(reveal(row(app, "Q1"), in: app))
        XCTAssertEqual(row(app, "Q1").label, "Q train to 96 St, on the Manhattan Bridge, 21 miles per hour")
        let toggle = app.buttons["undergroundToggle"]
        XCTAssertTrue(reveal(toggle, in: app))
        XCTAssertTrue(toggle.label.hasPrefix("Underground, 4"), toggle.label)
    }

    // MARK: Detail

    @MainActor
    func testTrainDetailFindsItInTheCamera() throws {
        let app = launchWithTrains()
        let q = row(app, "Q1")
        XCTAssertTrue(reveal(q, in: app))
        q.tap()
        let title = app.staticTexts["detailTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "Q to 96 St")
        let level = app.staticTexts["trainLevel"]
        XCTAssertTrue(level.label.hasPrefix("Manhattan Bridge · "), level.label)
        XCTAssertTrue(level.label.hasSuffix("ft up"), level.label)
        XCTAssertTrue(app.staticTexts["trainEstimateNote"].exists)
        XCTAssertTrue(app.staticTexts["Last report"].exists)
        XCTAssertTrue(app.buttons["closeDetails"].exists)

        let find = app.buttons["findInCamera"]
        XCTAssertTrue(find.isEnabled)
        find.tap()
        let label = app.buttons["arLabel-\(Self.trainID("Q1"))"]
        XCTAssertTrue(label.waitForExistence(timeout: 20))
        XCTAssertTrue(label.isSelected, "the found train gets the accent ring")
        XCTAssertFalse(app.staticTexts["detailTitle"].exists, "the sheet closes on the way to the camera")
    }

    /// Unfolded, a train's details float over the map beside the list, like a boat's.
    @MainActor
    func testRegularWidthShowsATrainsDetailsBesideTheList() throws {
        let app = launchWithTrains(regular: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.frame.width > window.frame.height }, object: nil)
        if XCTWaiter.wait(for: [rotated], timeout: 20) != .completed {
            if Self.isDuo {
                throw XCTSkip("Duo cover screen does not rotate in the simulator: \(window.frame.size)")
            }
            XCTFail("app did not rotate to landscape: \(window.frame.size)")
            return
        }
        waitForLabel(app.staticTexts["trainCount"], "6 trains")
        let q = row(app, "Q1")
        // Scrolled in the list's column: a swipe in the middle of the window would move the map instead.
        for _ in 0..<6 where !(q.exists && q.isHittable) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.3)))
        }
        XCTAssertTrue(q.isHittable, "Q1 not reached in the list")
        let map = app.descendants(matching: .any).matching(identifier: "vesselMap").firstMatch
        XCTAssertTrue(map.exists)
        XCTAssertLessThan(q.frame.midX, map.frame.midX, "the trains are in the list, left of the map")
        q.tap()
        let title = app.staticTexts["detailTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "Q to 96 St")
        XCTAssertGreaterThan(title.frame.midX, q.frame.maxX, "details float over the map, not in a sheet")
    }

    // MARK: Map

    @MainActor
    func trainMarker(_ app: XCUIApplication, _ trip: String, _ label: String) -> XCUIElement {
        let byID = app.descendants(matching: .any).matching(identifier: "trainMarker-\(Self.trainID(trip))").firstMatch
        if byID.waitForExistence(timeout: 5) { return byID }
        return app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    @MainActor
    func testMapHasTrainMarkers() throws {
        let app = launchWithTrains()
        let tab = app.buttons["Map"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        // Zoomed out (the whole area): the trains above ground, and a note instead of the underground ones.
        for (trip, label) in [("Q1", "Q train to 96 St"), ("M1", "M train to")] {
            let marker = trainMarker(app, trip, label)
            XCTAssertTrue(marker.waitForExistence(timeout: 20), "no marker for \(trip)")
            XCTAssertGreaterThanOrEqual(marker.frame.width.rounded(), 44, "\(trip) marker \(marker.frame) is under 44pt")
        }
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "trainMarker-\(Self.trainID("F1"))").firstMatch.exists)
        let note = app.descendants(matching: .any).matching(identifier: "undergroundMapNote").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        XCTAssertEqual(note.label, "4 trains underground · zoom in to see them")
        trainMarker(app, "M1", "M train to").tap()
        // Selected on the map: the map card, not a sheet.
        let title = app.buttons["mapCardTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertTrue(title.label.hasPrefix("M train to Middle Village-Metropolitan Av"), title.label)
    }

    /// Zoomed in, the underground trains show, smaller. One whose marker would overlap a train above ground isn't drawn
    /// (MapKit doesn't keep a marker under another from taking the tap), so the train on the bridge always wins.
    @MainActor
    func testZoomedInMapShowsUndergroundTrainsUnderTheBridge() throws {
        let app = launchWithTrains(Self.fixtureTrains + [Self.underTheBridge], environment: Self.zoomedOnTheBridge)
        let tab = app.buttons["Map"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        let q = trainMarker(app, "Q1", "Q train to 96 St")
        XCTAssertTrue(q.waitForExistence(timeout: 20))
        let f1 = trainMarker(app, "F1", "F train to Jamaica")
        XCTAssertTrue(f1.waitForExistence(timeout: 20), "zoomed in, underground trains show")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "undergroundMapNote").firstMatch.exists)
        XCTAssertGreaterThanOrEqual(q.frame.width.rounded(), 44)
        XCTAssertLessThan(f1.frame.width, 30, "an underground marker's touch target is its size plus a margin")
        XCTAssertFalse(trainMarker(app, "F2", "F train to Coney Island").exists,
                       "an underground train under the Q's marker isn't drawn")
        q.tap()
        let title = app.buttons["mapCardTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertTrue(title.label.hasPrefix("Q train to 96 St"), "the train on the bridge wins the tap: \(title.label)")
    }

    // MARK: Camera

    @MainActor
    func testCameraLabelsTrainsInSightAndUnderground() throws {
        let app = launchWithTrains()
        openCamera(app)

        let q = app.buttons["arLabel-\(Self.trainID("Q1"))"]
        XCTAssertTrue(q.waitForExistence(timeout: 20))
        XCTAssertTrue(q.label.hasPrefix("Q train to 96 St, on the Manhattan Bridge"), q.label)
        // The three underground trains ahead within 1.5 km get x-ray labels; the one 1.7 km behind doesn't.
        for trip in ["F1", "A1", "6X1"] {
            let xray = app.buttons["xrayLabel-\(Self.trainID(trip))"]
            XCTAssertTrue(xray.waitForExistence(timeout: 20), "no x-ray label for \(trip)")
            XCTAssertTrue(xray.label.contains("underground"), xray.label)
            // Below the horizon, under the labels of what's in sight.
            XCTAssertGreaterThan(xray.frame.minY, q.frame.maxY, "\(trip) x-ray \(xray.frame) vs Q \(q.frame)")
        }
        XCTAssertFalse(app.buttons["xrayLabel-\(Self.trainID("G1"))"].exists)
        XCTAssertFalse(app.buttons["arLabel-\(Self.trainID("F1"))"].exists, "underground is never in sight")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "noBoatsInSight").firstMatch.exists)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "camera-trains"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: Settings

    @MainActor
    func testUndergroundToggleHidesUndergroundTrains() throws {
        let app = launchWithTrains(environment: Self.zoomedOnTheBridge)
        waitForLabel(app.staticTexts["trainCount"], "6 trains")
        openSettings(app)
        let toggle = app.switches["undergroundTrainsToggle"]
        if !toggle.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        XCTAssertEqual(toggle.value as? String, "1", "on by default")
        toggle.tap()
        if toggle.value as? String != "0" { toggle.switches.firstMatch.tap() }
        waitUntil(toggle, "value == '0'", "the switch turns off")
        app.buttons["settingsDone"].tap()

        // The list: only the trains above ground, no underground group.
        waitForLabel(app.staticTexts["trainCount"], "2 trains")
        XCTAssertTrue(reveal(row(app, "M1"), in: app))
        XCTAssertFalse(app.buttons["undergroundToggle"].exists)

        // The camera: the Q still, no x-ray labels.
        openCamera(app)
        XCTAssertTrue(app.buttons["arLabel-\(Self.trainID("Q1"))"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["xrayLabel-\(Self.trainID("F1"))"].exists)
        XCTAssertFalse(app.buttons["xrayLabel-\(Self.trainID("A1"))"].exists)

        // The map, zoomed in: no underground markers.
        app.buttons["Map"].firstMatch.tap()
        XCTAssertTrue(trainMarker(app, "Q1", "Q train to 96 St").waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "trainMarker-\(Self.trainID("F1"))").firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "F train to")).firstMatch.exists)
    }
}
