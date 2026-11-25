import XCTest

/// Sightlines: from the DUMBO waterfront, a boat in the Hudson is behind Lower Manhattan and one off the far corner of
/// the area is too far to see. Neither gets a camera label or a place in the main list.
extension BoatARUITests {
    static let outOfSightVessels = [
        FixtureVessel(mmsi: 367000005, name: "HUDSON PILOT", type: 52, lat: 40.7130, lon: -74.0250, sog: 5.0, secondsAgo: 15),
        FixtureVessel(mmsi: 367000006, name: "FAR BARGE", type: 70, lat: 40.6760, lon: -74.0420, sog: 2.0, secondsAgo: 15),
    ]

    /// Pointing west-northwest from DUMBO, straight at the Hudson boat through Lower Manhattan.
    static let facingTheHudson = "40.7046,-73.9913,288,0,5"
    /// Inland in Park Slope, well away from the water.
    static let inland = "40.6710,-73.9800,300,0,5"

    /// Scrolls the list until `element` exists: a lazy stack only builds what's near the screen, and on the short Duo
    /// cover the out-of-sight section starts below the fold.
    @MainActor
    func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<4 {
            if element.waitForExistence(timeout: 3) { return true }
            app.swipeUp()
        }
        return element.waitForExistence(timeout: 5)
    }

    @MainActor
    func testListPutsBoatsOutOfSightUnderTheirOwnHeading() throws {
        let app = launch(vessels + Self.outOfSightVessels)
        waitForLabel(app.staticTexts["vesselCount"], "6 vessels")
        XCTAssertTrue(app.buttons["closestCard"].label.hasPrefix("Closest: HARBOR LARK"), app.buttons["closestCard"].label)
        XCTAssertTrue(app.buttons["vesselRow-367000002"].exists)

        let toggle = app.buttons["outOfSightToggle"]
        XCTAssertTrue(reveal(toggle, in: app))
        XCTAssertTrue(toggle.label.hasPrefix("Out of sight, 2"), toggle.label)
        XCTAssertFalse(app.buttons["vesselRow-367000005"].exists, "out-of-sight rows start collapsed")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "nothingInSight").firstMatch.exists)

        toggle.tap()
        XCTAssertTrue(reveal(app.buttons["vesselRow-367000005"], in: app))
        XCTAssertTrue(reveal(app.buttons["vesselRow-367000006"], in: app))
    }

    @MainActor
    func testCameraLeavesOutBoatsBehindLandAndOutOfRange() throws {
        let app = launch(vessels + Self.outOfSightVessels, sensors: Self.facingTheHudson)
        openCamera(app)
        waitForLabel(app.staticTexts["compassHeading"], "W 288°")

        // WREN, 8° left of center, is in sight; HUDSON PILOT, dead ahead, is behind Lower Manhattan.
        XCTAssertTrue(app.buttons["arLabel-367000003"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["arLabel-367000005"].exists, "HUDSON PILOT is behind Lower Manhattan")
        // Only boats in sight count toward the edge hints: HARBOR LARK, ANNABEL K and the unnamed boat to the right.
        // FAR BARGE, off to the left beyond 3 miles, doesn't count, so there's no left hint at all.
        waitForLabel(app.staticTexts["offscreenRight"], "3 more ›")
        XCTAssertFalse(app.staticTexts["offscreenLeft"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "noBoatsInSight").firstMatch.exists)
    }

    @MainActor
    func testFindInCameraStillShowsABoatBehindLand() throws {
        let app = launch(vessels + Self.outOfSightVessels, sensors: Self.facingTheHudson)
        let toggle = app.buttons["outOfSightToggle"]
        XCTAssertTrue(reveal(toggle, in: app))
        toggle.tap()
        let row = app.buttons["vesselRow-367000005"]
        XCTAssertTrue(reveal(row, in: app))
        row.tap()
        let find = app.buttons["findInCamera"]
        XCTAssertTrue(find.waitForExistence(timeout: 20))
        find.tap()

        let label = app.buttons["arLabel-367000005"]
        XCTAssertTrue(label.waitForExistence(timeout: 20), "the boat you asked for is labelled even behind land")
        XCTAssertTrue(label.isSelected)
    }

    /// Between AIS reports a moving boat keeps moving: its label glides along with it while the phone holds still.
    @MainActor
    func testMovingBoatsLabelFollowsItBetweenReports() throws {
        // 450 m north of the test location and 120 m west, heading east at 6 knots (about 3 m/s), last reported 5 s
        // ago. Slow on purpose: however long the simulator takes to open the camera (10-50 s), the boat is in view and
        // its label isn't yet held at the screen edge, where labels stop moving.
        let ferry = FixtureVessel(mmsi: 367000007, name: "CROSSING FERRY", type: 60, lat: 40.70865, lon: -73.99272,
                                  sog: 6, secondsAgo: 5, cog: 90)
        let app = launch([ferry], sensors: "40.7046,-73.9913,0,0,5")
        openCamera(app)
        let label = app.buttons["arLabel-367000007"]
        XCTAssertTrue(label.waitForExistence(timeout: 20))
        let start = label.frame.midX
        // No new report arrives; it keeps moving east, so its label keeps moving right.
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in label.exists && label.frame.midX > start + 15 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 15), .completed,
                       "label stayed at x \(start), now \(label.exists ? label.frame.midX : -1)")
    }

    @MainActor
    func testInlandNothingIsInSight() throws {
        let app = launch(sensors: Self.inland)
        let note = app.descendants(matching: .any).matching(identifier: "nothingInSight").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["closestCard"].exists)
        // With nothing in sight the rest is all there is, so it's listed without a tap.
        let heading = app.descendants(matching: .any).matching(identifier: "outOfSightToggle").firstMatch
        XCTAssertTrue(reveal(heading, in: app))
        XCTAssertTrue(heading.label.hasPrefix("Out of sight, 4"), heading.label)
        XCTAssertTrue(reveal(app.buttons["vesselRow-367000001"], in: app))

        openCamera(app)
        let empty = app.descendants(matching: .any).matching(identifier: "noBoatsInSight").firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["arLabel-367000001"].exists)
    }
}
