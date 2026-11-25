import CoreLocation
import XCTest

/// Every test feeds fixture relay messages through the BOATAR_REPLAY_FEED launch environment; none touch a relay.
final class BoatARUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    // MARK: Fixtures

    struct FixtureVessel {
        let mmsi: Int
        let name: String?
        let type: Int?
        let lat: Double
        let lon: Double
        let sog: Double?
        let secondsAgo: TimeInterval
        /// Course over ground; with a speed, the app carries the boat forward between reports.
        var cog: Double? = nil
    }

    /// Positions inside the dev box; HARBOR LARK is nearest the test location.
    var vessels: [FixtureVessel] {
        Self.fixtureVessels
    }

    static let fixtureVessels = [
        FixtureVessel(mmsi: 367000001, name: "HARBOR LARK", type: 60, lat: 40.7062, lon: -73.9931, sog: 14.2, secondsAgo: 8),
        FixtureVessel(mmsi: 367000002, name: "ANNABEL K", type: 52, lat: 40.7068, lon: -73.9890, sog: 6.8, secondsAgo: 20),
        FixtureVessel(mmsi: 367000003, name: "WREN", type: 36, lat: 40.7054, lon: -73.9971, sog: 4.1, secondsAgo: 190),
        FixtureVessel(mmsi: 367000004, name: nil, type: nil, lat: 40.7083, lon: -73.9880, sog: nil, secondsAgo: 40),
    ]

    /// One vessel as a /v2/targets target (relay/PROTOCOL.md).
    func json(_ v: FixtureVessel, now: Date) -> String {
        var fields = [#""id":"vessel:\#(v.mmsi)","kind":"vessel","source":"aisstream""#]
        if let name = v.name { fields.append(#""name":"\#(name)""#) }
        fields.append(#""lat":\#(v.lat),"lon":\#(v.lon)"#)
        if let sog = v.sog { fields.append(#""speed":\#(sog)"#) }
        if let cog = v.cog { fields.append(#""course":\#(cog)"#) }
        let stamp = now.addingTimeInterval(-v.secondsAgo)
            .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        fields.append(#""timestamp":"\#(stamp)""#)
        var details = [#""mmsi":\#(v.mmsi)"#]
        if let type = v.type { details.append(#""shipType":\#(type)"#) }
        fields.append(#""vessel":{\#(details.joined(separator: ","))}"#)
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Local test location (the DUMBO waterfront), facing north, compass good to ±5°: "lat,lon,heading,pitch,accuracy".
    static let testSensors = "40.7046,-73.9913,0,0,5"

    /// True on an iPhone Duo simulator, whatever it is named (scripts/ui-test.sh runs the reserved "BW Test iPhone
    /// Duo"): the model identifier says it, and the name is the fallback.
    static var isDuo: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4" || (env["SIMULATOR_DEVICE_NAME"] ?? "").contains("Duo")
    }

    /// Animations are off for every launch except the performance tests (which build their own app) and the
    /// screenshot tours and the demo walk-through: finished-state assertions don't wait on transitions, and the CPU numbers stay honest.
    static var animationsOff: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["BOATAR_SCREENSHOT_TOUR"] != "1" && env["BOATAR_PERF"] != "1" && env["BOATAR_DEMO"] != "1"
    }

    @MainActor
    func launch(_ fixture: [FixtureVessel]? = nil, messages: [String]? = nil,
                offline: Bool = false, regular: Bool = false,
                sensors: String? = testSensors, onboardingDone: Bool = true,
                arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        let now = Date()
        let replay = messages ?? [#"{"type":"snapshot","targets":[\#((fixture ?? vessels).map { json($0, now: now) }.joined(separator: ","))]}"#]
        let app = XCUIApplication()
        app.launchEnvironment["BOATAR_REPLAY_FEED"] = "[" + replay.joined(separator: ",") + "]"
        // Every test starts with the height from (fake) GPS, whatever an earlier test left in Settings.
        app.launchEnvironment["BOATAR_RESET_EYE_HEIGHT"] = "1"
        // ... and with trains on, underground ones too.
        app.launchEnvironment["BOATAR_RESET_TRAIN_SETTINGS"] = "1"
        // ... and with the camera's filter at its defaults.
        app.launchEnvironment["BOATAR_RESET_CAMERA_FILTER"] = "1"
        // ... with units at each vehicle's standard, and the list's filter and sections at their defaults (a test
        // that checks they persist passes "0" in `environment`).
        app.launchEnvironment["BOATAR_RESET_UNITS"] = "1"
        app.launchEnvironment["BOATAR_RESET_BROWSE"] = "1"
        if Self.animationsOff { app.launchEnvironment["BOATAR_DISABLE_ANIMATIONS"] = "1" }
        if offline { app.launchEnvironment["BOATAR_REPLAY_OFFLINE"] = "1" }
        if regular { app.launchEnvironment["BOATAR_FORCE_REGULAR"] = "1" }
        if let sensors { app.launchEnvironment["BOATAR_FAKE_SENSORS"] = sensors }
        if onboardingDone {
            // Argument-domain default: skips the permissions screen without touching stored settings.
            app.launchArguments += ["-onboardingDone", "YES"]
        } else {
            // A launch argument would pin the value; clear the stored answer instead so the app can set it.
            app.launchEnvironment["BOATAR_RESET_ONBOARDING"] = "1"
        }
        app.launchArguments += arguments
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launch()
        return app
    }

    func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 20) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "expected \"\(label)\", got \"\(element.exists ? element.label : "<missing>")\"")
    }

    /// Waits for an element property, e.g. `waitUntil(error, "exists == false", "...")`.
    func waitUntil(_ element: XCUIElement, _ predicate: String, _ message: String, timeout: TimeInterval = 20) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message)
    }

    // MARK: Launch basics

    @MainActor
    func openSettings(_ app: XCUIApplication) {
        let gear = app.buttons["settingsButton"]
        XCTAssertTrue(gear.waitForExistence(timeout: 20))
        gear.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
    }

    /// Label and value of a Settings row, whatever element type it's exposed as.
    @MainActor
    func rowText(_ app: XCUIApplication, _ identifier: String) -> String {
        let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        // The About rows come last: on the short Duo cover screen they can start below the fold, where the list
        // hasn't built them yet.
        if !row.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 20), "\(identifier) missing")
        return [row.label, row.value as? String ?? ""].joined(separator: " ")
    }

    /// Replaces everything in a text field: a tap past the end of the text puts the caret there, so the deletes
    /// clear it all before the new text goes in.
    @MainActor
    func replaceText(in field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let count = (field.value as? String)?.count ?? 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + text)
    }

    @MainActor
    func testLaunchShowsNearbyTitleAndHingeState() throws {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Nearby"].waitForExistence(timeout: 20))
        openSettings(app)
        let hinge = rowText(app, "hingeLabel")
        let valid = ["Closed", "Partially open", "Fully open", "Unavailable"]
        XCTAssertTrue(valid.contains { hinge.contains($0) }, "Unexpected hinge text: \(hinge)")
    }

    @MainActor
    func testShowsBuildNumberAndGitSHA() throws {
        let app = launch()
        openSettings(app)
        let build = rowText(app, "buildLabel")
        XCTAssertFalse(build.contains("unknown"), "CFBundleVersion missing: \(build)")
        // One row: "1.0, build 17 (355e543)".
        XCTAssertNotNil(build.range(of: #"build \d+ \([0-9a-f]{7,40}\)"#, options: .regularExpression),
                        "no build number and hex SHA in \(build)")
    }

    // MARK: vesselCount

    @MainActor
    func testVesselCountMatchesFixture() throws {
        let app = launch()
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        waitForLabel(app.staticTexts["feedStatus"], "Live")
        let card = app.buttons["closestCard"]
        XCTAssertTrue(card.exists)
        XCTAssertTrue(card.label.hasPrefix("Closest: HARBOR LARK, passenger"), card.label)
    }

    /// Snapshot, replace by id and 10-minute expiry, end to end through the store.
    @MainActor
    func testVesselCountFollowsReplayedFeed() throws {
        let now = Date()
        let fresh = Array(vessels.prefix(3))
        let old = FixtureVessel(mmsi: 9, name: "GONE", type: 70, lat: 40.705, lon: -73.99, sog: 1, secondsAgo: 660)
        let newcomer = FixtureVessel(mmsi: 5, name: "LATE", type: 31, lat: 40.708, lon: -73.992, sog: 2, secondsAgo: 2)
        let app = launch(messages: [
            #"{"type":"snapshot","targets":[\#((fresh + [old]).map { json($0, now: now) }.joined(separator: ","))]}"#,
            #"{"type":"update","target":\#(json(newcomer, now: now))}"#,
            #"{"type":"update","target":\#(json(vessels[0], now: now))}"#,
        ])
        // Three fresh + the newcomer; GONE is 11 minutes old; the repeat of HARBOR LARK replaces itself.
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
    }

    // MARK: Empty state

    @MainActor
    func testEmptyStateWhenNoVessels() throws {
        let app = launch([])
        let title = app.staticTexts["emptyTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "The river's quiet")
        waitForLabel(app.staticTexts["vesselCount"], "0 vessels")
        XCTAssertFalse(app.otherElements["offlineBanner"].exists)
        XCTAssertFalse(app.buttons["closestCard"].exists)
    }

    // MARK: Offline banner

    @MainActor
    func testOfflineBannerKeepsListFrozen() throws {
        let app = launch(Array(vessels.prefix(3)), offline: true)
        let banner = app.otherElements["offlineBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 20))
        XCTAssertTrue(banner.staticTexts["Can't reach the server"].exists)
        XCTAssertTrue(banner.staticTexts["Showing the last positions. Trying again…"].exists)
        XCTAssertTrue(app.buttons["retryButton"].isHittable)
        waitForLabel(app.staticTexts["feedStatus"], "Offline")
        // The last known vessels stay listed, with their report ages.
        waitForLabel(app.staticTexts["vesselCount"], "3 vessels")
        XCTAssertTrue(app.buttons["closestCard"].exists)
        XCTAssertTrue(app.buttons["vesselRow-367000002"].label.contains("last report"))
    }

    @MainActor
    func testNoOfflineBannerWhileLive() throws {
        let app = launch()
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        XCTAssertFalse(app.otherElements["offlineBanner"].exists)
    }

    // MARK: Detail and map

    @MainActor
    func testRowOpensDetailSheet() throws {
        let app = launch()
        let row = app.buttons["vesselRow-367000002"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertEqual(row.label, "ANNABEL K, service boat, 0.2 miles northeast, 7 knots")
        row.tap()
        let title = app.staticTexts["detailTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "ANNABEL K")
        XCTAssertTrue(app.staticTexts["Distance"].exists)
        XCTAssertTrue(app.staticTexts["Last report"].exists)
        // A visible way out, not only the swipe.
        let close = app.buttons["closeDetails"]
        XCTAssertTrue(close.exists)
        // With a location there is a bearing, so the camera can show it.
        XCTAssertTrue(app.buttons["findInCamera"].isEnabled)
        close.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed, "Close dismisses the sheet")
    }

    @MainActor
    func testClosestCardShowsItOnTheMap() throws {
        let app = launch()
        let card = app.buttons["closestCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "vesselMap").firstMatch.waitForExistence(timeout: 20))
        // On the map the boat gets the map card, not a sheet (docs/DESIGN.md, Map card).
        let title = app.buttons["mapCardTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertTrue(title.label.hasPrefix("HARBOR LARK, "), title.label)
        XCTAssertFalse(app.staticTexts["detailTitle"].exists, "no sheet over the map")
        XCTAssertTrue(app.buttons["Re-center map"].exists)
    }

    /// The marker on the map is 34pt; its touch target is padded out to the 44pt minimum.
    @MainActor
    func testMapMarkersHaveA44PointTouchTarget() throws {
        let app = launch()
        let map = app.buttons["Map"].firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 20))
        map.tap()
        for name in vessels.map({ $0.name ?? "Unnamed boat" }) {
            let marker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            XCTAssertTrue(marker.waitForExistence(timeout: 20), "no marker for \(name)")
            // Rounded: on the Duo's layout grid a 44pt frame comes out as 43.99999999999999.
            XCTAssertGreaterThanOrEqual(marker.frame.width.rounded(), 44, "\(name) marker \(marker.frame) is narrower than 44pt")
            XCTAssertGreaterThanOrEqual(marker.frame.height.rounded(), 44, "\(name) marker \(marker.frame) is shorter than 44pt")
        }
    }

    // MARK: Layout

    /// No orientation lock: the list header and closest card stay on screen in landscape.
    @MainActor
    func testListFitsInLandscape() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["vesselCount"].waitForExistence(timeout: 20))
        XCUIDevice.shared.orientation = .landscapeLeft

        // Wait for the rotation to finish before measuring.
        let window = app.windows.firstMatch
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.frame.width > window.frame.height }, object: nil)
        if XCTWaiter.wait(for: [rotated], timeout: 20) != .completed {
            // The iPhone Duo simulator does not rotate its cover screen (hinge closed). Only skip there; anywhere else
            // a window that stays portrait is a real failure. Decided by the simulator, not by anything on screen:
            // the hinge state lives in Settings now, not on the list.
            let simulator = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
            if Self.isDuo {
                throw XCTSkip("\(simulator): the cover screen does not rotate in the simulator: \(window.frame.size)")
            }
            XCTFail("app did not rotate to landscape on \(simulator.isEmpty ? "this device" : simulator): \(window.frame.size)")
            return
        }
        for element in [app.staticTexts["vesselCount"], app.buttons["closestCard"]] {
            XCTAssertTrue(element.waitForExistence(timeout: 20))
            XCTAssertTrue(window.frame.intersects(element.frame), "\(element) off screen in landscape")
            XCTAssertGreaterThanOrEqual(element.frame.minX, window.frame.minX, "\(element) clipped")
            XCTAssertLessThanOrEqual(element.frame.maxX, window.frame.maxX, "\(element) clipped")
        }
    }

    /// The regular-width layout (Duo unfolded): list and map side by side, details in a floating card.
    /// Forced with BOATAR_FORCE_REGULAR because the simulator can't unfold the Duo from a test.
    @MainActor
    func testRegularWidthShowsListAndMapSideBySide() throws {
        let app = launch(regular: true)
        // Landscape on the 18 Pro (874pt) is close to the unfolded Duo (951x669); portrait is too narrow for a split.
        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.frame.width > window.frame.height }, object: nil)
        if XCTWaiter.wait(for: [rotated], timeout: 20) != .completed {
            // Only the iPhone Duo cover screen doesn't rotate in the simulator; anywhere else that's a failure.
            if Self.isDuo {
                throw XCTSkip("Duo cover screen does not rotate in the simulator: \(window.frame.size)")
            }
            XCTFail("app did not rotate to landscape: \(window.frame.size)")
            return
        }
        let count = app.staticTexts["vesselCount"]
        let map = app.descendants(matching: .any).matching(identifier: "vesselMap").firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 20))
        XCTAssertTrue(map.waitForExistence(timeout: 20))
        // Unfolded, the list and map share one tab; the camera stays its own tab.
        XCTAssertTrue(app.buttons["Camera"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Map"].exists, "the map sits beside the list, not in its own tab")
        XCTAssertLessThan(count.frame.midX, map.frame.midX, "list should sit left of the map")

        let row = app.buttons["vesselRow-367000002"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let title = app.staticTexts["detailTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "ANNABEL K")
        XCTAssertTrue(app.buttons["Close details"].exists, "details float over the map rather than in a sheet")
    }

    // MARK: Permissions

    @MainActor
    func testFirstLaunchSkipGoesStraightToTheList() throws {
        // Another test may have granted location; skipping must leave the app without it.
        XCUIApplication().resetAuthorizationStatus(for: .location)
        let app = launch(sensors: nil, onboardingDone: false)
        XCTAssertTrue(app.staticTexts["permissionsTitle"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["permissionsTitle"].label, "Bridgewatch", "the app's shown name")
        let locationReason = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Your location'"))
        XCTAssertTrue(locationReason.firstMatch.exists, "the location reason is explained")
        app.buttons["permissionsSkip"].tap()
        XCTAssertTrue(app.navigationBars["Nearby"].waitForExistence(timeout: 20))
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        // Without location there are no distances or closest card, and the list offers to turn it on.
        XCTAssertTrue(app.buttons["locationOffNote"].exists)
        XCTAssertFalse(app.buttons["closestCard"].exists)
        XCTAssertEqual(app.buttons["vesselRow-367000002"].label, "ANNABEL K, service boat, 7 knots")
    }

    @MainActor
    func testContinueAsksForLocationThenShowsTheList() throws {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        app.resetAuthorizationStatus(for: .camera)
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 40.7046, longitude: -73.9913))

        let launched = launch(sensors: nil, onboardingDone: false)
        XCTAssertTrue(launched.buttons["permissionsContinue"].waitForExistence(timeout: 20))
        launched.buttons["permissionsContinue"].tap()

        // The list comes up while the location prompt is still unanswered: waiting on system prompts left a phone
        // stuck on the first screen.
        XCTAssertTrue(launched.navigationBars["Nearby"].waitForExistence(timeout: 20))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(
            NSPredicate(format: "label IN %@", ["Allow While Using App", "Allow", "OK"])).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 20), "expected the location prompt")
        allow.tap()

        // With location granted the distances appear, so the location-off note goes away.
        let note = launched.buttons["locationOffNote"]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: note)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 15), .completed)

        // The camera isn't asked for until the Camera tab, which offers to turn it on.
        openCamera(launched)
        XCTAssertTrue(launched.buttons["enableCamera"].waitForExistence(timeout: 20))
    }

    // MARK: Camera

    /// Facing 36° from the test location: ANNABEL K (38°) and MMSI 367000004 (34°) are ahead; HARBOR LARK (320°) and
    /// WREN (280°) are behind to the left.
    static let facingNortheast = "40.7046,-73.9913,36,0,5"

    @MainActor
    func openCamera(_ app: XCUIApplication) {
        // Not app.tabBars: on the Duo cover screen the tabs are a vertical strip that isn't exposed as a tab bar.
        let tab = app.buttons["Camera"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
    }

    /// The compass strip stays inside the safe area while the preview and labels fill the screen. On a phone that is
    /// below the status bar across the top; on the Duo cover the status bar and the tabs are columns on the right (its
    /// tabs aren't a tab bar, see `openCamera`), nothing is above the strip, and it has to stay left of those columns.
    @MainActor
    func assertCompassStripInsideSafeArea(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let strip = app.descendants(matching: .any).matching(identifier: "compassStrip").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 20), "compassStrip missing", file: file, line: line)
        let window = app.windows.firstMatch.frame
        let heading = app.staticTexts["compassHeading"].frame
        let cameraTab = app.buttons["Camera"].firstMatch.frame
        XCTAssertTrue(window.contains(strip.frame), "strip \(strip.frame) is outside the window \(window)",
                      file: file, line: line)
        XCTAssertFalse(strip.frame.intersects(cameraTab), "strip \(strip.frame) overlaps the Camera tab \(cameraTab)",
                       file: file, line: line)
        if app.tabBars.firstMatch.exists {
            XCTAssertGreaterThanOrEqual(heading.minY, 44, "the heading \(heading) is under the status bar",
                                        file: file, line: line)
        } else {
            XCTAssertLessThanOrEqual(strip.frame.maxX, cameraTab.minX,
                                     "strip \(strip.frame) runs under the right-hand columns (tabs at \(cameraTab))",
                                     file: file, line: line)
        }
    }

    @MainActor
    func testCameraLabelsVesselsAtTheirBearings() throws {
        let app = launch(sensors: Self.facingNortheast)
        openCamera(app)
        waitForLabel(app.staticTexts["compassHeading"], "NE 36°")

        assertCompassStripInsideSafeArea(app)

        let tug = app.buttons["arLabel-367000002"]
        let unnamed = app.buttons["arLabel-367000004"]
        XCTAssertTrue(tug.waitForExistence(timeout: 20))
        XCTAssertTrue(unnamed.exists)
        XCTAssertFalse(app.buttons["arLabel-367000001"].exists, "HARBOR LARK is behind the camera")
        XCTAssertFalse(app.buttons["arLabel-367000003"].exists, "WREN is behind the camera")
        XCTAssertTrue(tug.label.hasPrefix("ANNABEL K, service boat"), tug.label)

        // Four degrees apart, the two labels would overlap, so they stack: the nearer tug sits lower.
        XCTAssertGreaterThan(tug.frame.midY, unnamed.frame.midY)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(tug.frame))

        waitForLabel(app.staticTexts["offscreenLeft"], "‹ 2 more")
        XCTAssertFalse(app.staticTexts["offscreenRight"].exists)
        XCTAssertFalse(app.staticTexts["accuracyPill"].exists, "a ±5° compass needs no calibration hint")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "camera-facing-northeast"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testCameraShowsAccuracyPillWhenCompassIsPoor() throws {
        let app = launch(sensors: "40.7046,-73.9913,36,0,15")
        openCamera(app)
        let pill = app.staticTexts["accuracyPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 20))
        XCTAssertEqual(pill.label, "Compass ±15° · wave in a figure 8 to improve")
        // Clear of the tabs: above a bottom tab bar, or left of the Duo cover's vertical tab strip.
        let cameraTab = app.buttons["Camera"].firstMatch.frame
        if cameraTab.minY > pill.frame.midY {
            XCTAssertLessThanOrEqual(pill.frame.maxY, cameraTab.minY + 1, "pill \(pill.frame) overlaps tab \(cameraTab)")
        } else {
            XCTAssertFalse(pill.frame.intersects(cameraTab), "pill \(pill.frame) overlaps tab \(cameraTab)")
        }
        // The strip at the top stays inside the safe area with a poor compass too.
        assertCompassStripInsideSafeArea(app)
    }

    /// Zooming narrows the view: labels spread away from the middle at 2× and close in at 0.5×. The simulator has no
    /// camera, so BOATAR_FAKE_ZOOM gives it an ultra wide/wide/5× telephoto camera's zoom.
    @MainActor
    func testZoomButtonsWidenAndNarrowTheView() throws {
        let app = launch(sensors: Self.facingNortheast, environment: ["BOATAR_FAKE_ZOOM": "1"])
        openCamera(app)
        let tug = app.buttons["arLabel-367000002"]
        XCTAssertTrue(tug.waitForExistence(timeout: 20))
        for preset in ["0.5", "1", "2", "5"] {
            XCTAssertTrue(app.buttons["zoom-\(preset)"].exists, "zoom-\(preset) missing")
        }
        XCTAssertTrue(app.buttons["zoom-1"].isSelected, "the camera starts at 1x")
        let atOne = tug.frame.midX

        // ANNABEL K is 2.4 degrees right of center: zooming in pushes her label right.
        func waitForX(_ test: @escaping (CGFloat) -> Bool, _ message: String) {
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tug.exists && test(tug.frame.midX) },
                                                  object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 20), .completed,
                           "\(message): x \(atOne) at 1x, now \(tug.exists ? tug.frame.midX : -1)")
        }
        app.buttons["zoom-2"].tap()
        waitForX({ $0 > atOne + 10 }, "the label didn't move out at 2x")
        XCTAssertTrue(app.buttons["zoom-2"].isSelected)

        app.buttons["zoom-0.5"].tap()
        waitForX({ $0 < atOne - 3 }, "the label didn't move in at 0.5x")
    }

    @MainActor
    func testFindInCameraHighlightsTheVessel() throws {
        let app = launch(sensors: Self.facingNortheast)
        let row = app.buttons["vesselRow-367000002"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let find = app.buttons["findInCamera"]
        XCTAssertTrue(find.waitForExistence(timeout: 20))
        XCTAssertTrue(find.isEnabled)
        find.tap()

        let label = app.buttons["arLabel-367000002"]
        XCTAssertTrue(label.waitForExistence(timeout: 20))
        XCTAssertTrue(label.isSelected, "the found vessel gets the accent ring")
        XCTAssertFalse(app.buttons["arLabel-367000004"].isSelected)
        XCTAssertFalse(app.staticTexts["detailTitle"].exists, "the sheet closes on the way to the camera")
    }

    @MainActor
    func testCameraWithoutLocationOffersToTurnItOn() throws {
        let app = launch(sensors: "none,none,36,0,5")
        openCamera(app)
        let guidance = app.descendants(matching: .any).matching(identifier: "cameraGuidance").firstMatch
        XCTAssertTrue(guidance.waitForExistence(timeout: 20))
        XCTAssertEqual(guidance.label, "Turn on location to place labels")
        XCTAssertTrue(guidance.isHittable, "the hint is a button, not a dead end")
        XCTAssertFalse(app.buttons["arLabel-367000002"].exists)
    }

    /// Skipped the camera at first launch: the Camera tab asks, where the reason is obvious.
    @MainActor
    func testCameraAsksForAccessWhenSkippedAtFirstLaunch() throws {
        XCUIApplication().resetAuthorizationStatus(for: .camera)
        let app = launch(sensors: nil)
        openCamera(app)
        XCTAssertTrue(app.buttons["enableCamera"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "cameraUnavailable").firstMatch.exists)
    }

    // MARK: Accessibility text sizes

    /// The largest text size, as an argument-domain default (like the screenshot tour's).
    static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    /// The name needs the full width: the badge and the close button share a row, and the name, type and MMSI sit
    /// below them instead of breaking mid-word beside the badge. (MMSI as two lines is checked by eye in the tour.)
    @MainActor
    func testDetailHeaderStacksAtAccessibilityTextSizes() throws {
        let app = launch(arguments: Self.largestText)
        let row = app.buttons["vesselRow-367000002"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let title = app.staticTexts["detailTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "ANNABEL K")
        let close = app.buttons["closeDetails"]
        XCTAssertTrue(close.exists)
        XCTAssertLessThanOrEqual(close.frame.maxY, title.frame.minY,
                                 "Close \(close.frame) shares the badge's row above the name \(title.frame)")
        // Full width: the name starts at the sheet's margin (where the buttons below do), not after the badge.
        XCTAssertEqual(title.frame.minX, app.buttons["findInCamera"].frame.minX, accuracy: 1)
    }

    /// Pinned at the top the banner would take half the screen at the largest text size, so it scrolls with the list.
    @MainActor
    func testOfflineBannerScrollsWithTheListAtAccessibilityTextSizes() throws {
        let app = launch(Array(vessels.prefix(3)), offline: true, arguments: Self.largestText)
        let banner = app.otherElements["offlineBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 20))
        let before = banner.frame.minY
        app.swipeUp()
        XCTAssertLessThan(banner.frame.minY, before, "the banner stays put instead of scrolling away with the list")
    }

    /// Pinned under the text the buttons would cover most of the screen at the largest text size: they end the scroll.
    @MainActor
    func testPermissionsButtonsEndTheScrollAtAccessibilityTextSizes() throws {
        let app = launch(sensors: nil, onboardingDone: false, arguments: Self.largestText)
        XCTAssertTrue(app.staticTexts["permissionsTitle"].waitForExistence(timeout: 20))
        let skip = app.buttons["permissionsSkip"]
        XCTAssertTrue(skip.exists)
        XCTAssertFalse(skip.isHittable, "the buttons come after the text, they are not pinned over it")
        for _ in 0..<6 where !skip.isHittable { app.swipeUp() }
        XCTAssertTrue(skip.isHittable, "scrolling to the end reaches the buttons")
        XCTAssertTrue(app.buttons["permissionsContinue"].isHittable)
    }

    // MARK: Settings

    @MainActor
    func testSettingsHeightByHand() throws {
        // Fake GPS altitude: 12 m, about 39 ft.
        let app = launch(sensors: "40.7046,-73.9913,0,0,5,12")
        openSettings(app)
        let status = app.staticTexts["heightStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        XCTAssertTrue(status.label.hasPrefix("From GPS: 39\u{00A0}ft above sea level."), status.label)

        let toggle = app.switches["heightToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        toggle.tap()
        if toggle.value as? String != "1" { toggle.switches.firstMatch.tap() }
        let stepper = app.steppers["heightStepper"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 20))
        let setByHand = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "50\u{00A0}ft above the street")).firstMatch
        XCTAssertTrue(setByHand.waitForExistence(timeout: 20))
        XCTAssertTrue(status.label.hasPrefix("Boats hidden by land or buildings"), status.label)

        // Off again: back to GPS.
        toggle.tap()
        if toggle.value as? String != "0" { toggle.switches.firstMatch.tap() }
        waitUntil(stepper, "exists == false", "the stepper goes with the switch")
        XCTAssertTrue(status.label.hasPrefix("From GPS:"), status.label)
    }

    /// Puts Settings back to the defaults the other tests assume (Automatic night mode, the built-in relay address),
    /// through the UI like the test does. It runs from addTeardownBlock, so also after a failure: every step is
    /// guarded because the test may have stopped anywhere (sheet open or closed, picker menu open, keyboard up).
    @MainActor
    func restoreSettingsDefaults(_ app: XCUIApplication) {
        guard app.state == .runningForeground else { return }
        let done = app.buttons["settingsDone"]
        if !done.exists, app.buttons["settingsButton"].exists {
            app.buttons["settingsButton"].tap()
            _ = done.waitForExistence(timeout: 5)
        }
        // A failure mid-typing leaves the keyboard up over the rows below the field. Return submits and dismisses it;
        // whatever that saves is cleared by the built-in button next.
        let field = app.textFields["relayField"]
        if app.keyboards.count > 0, field.exists { field.typeText("\n") }
        // On the short Duo cover screen the button sits below the fold, where the list hasn't built it: scroll to it,
        // and back to the top for the rows above.
        let builtIn = app.buttons["Use the Built-In Address"]
        if done.exists || app.navigationBars["Settings"].exists {
            for _ in 0..<4 where !builtIn.exists { app.swipeUp() }
            if builtIn.exists { builtIn.tap() }
            for _ in 0..<4 where !app.buttons["nightModePicker"].firstMatch.exists { app.swipeDown() }
        }
        let picker = app.buttons["nightModePicker"].firstMatch
        let automatic = app.buttons["Automatic"].firstMatch
        if picker.exists || automatic.exists {
            if !automatic.exists { picker.tap() }  // otherwise the menu is already open
            if automatic.waitForExistence(timeout: 5) { automatic.tap() }
        }
        if done.exists { done.tap() }
    }

    @MainActor
    func testSettingsNightModeAndRelayAddress() throws {
        let app = launch()
        // Registered before anything changes, and run after a failure too: a test that stops halfway must not leave
        // night mode on or a custom relay address behind for the next test.
        addTeardownBlock { self.restoreSettingsDefaults(app) }
        openSettings(app)

        // Night mode: choose On and the footer says so.
        let picker = app.buttons["nightModePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        picker.tap()
        app.buttons["On"].firstMatch.tap()
        let status = app.staticTexts["nightModeStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        XCTAssertTrue(status.label.hasSuffix("On now."), status.label)

        // Relay: a bad address is refused with a reason, a good one is kept. Each entry ends with Return, which submits
        // the field: on the short Duo cover screen the Use This Address button can sit under the keyboard.
        let field = app.textFields["relayField"]
        let error = app.staticTexts["relayError"]
        // Below the Trains and Units sections: the form builds its rows only near the screen, and the error under the
        // field has to fit above the keyboard on the short Duo cover screen, so the field goes up into the top part.
        let window = app.windows.firstMatch.frame
        for _ in 0..<8 where !(field.exists && field.isHittable && field.frame.midY < window.midY * 0.8) {
            app.swipeUp()
        }
        field.tap()
        field.typeText("relay-box:8095\n")
        XCTAssertTrue(error.waitForExistence(timeout: 5), "an address without a scheme is refused")

        replaceText(in: field, with: "ws://relay-box:8095/v2/targets\n")
        waitUntil(error, "exists == false", "a ws:// address on a local (short) name clears the error")
        waitUntil(app.buttons["relaySave"], "isEnabled == false", "saved: nothing left to save")

        // Plain ws:// is for local hosts only (short names, IPs, .local); a dotted name such as a Tailscale one needs
        // wss://. The error was gone above, so seeing it again is this entry's refusal.
        replaceText(in: field, with: "ws://relay-box.example.ts.net:8095/v2/targets\n")
        XCTAssertTrue(error.waitForExistence(timeout: 5), "ws:// to a dotted (non-local) host is refused")

        // Reopened, the field shows the address that was kept, not the refused one.
        // The Trains and Units sections above the relay field make the list scroll, and the bar with Done scrolls
        // away: back to the top first.
        let done = app.buttons["settingsDone"]
        for _ in 0..<6 where !done.exists { app.swipeDown() }
        done.tap()
        openSettings(app)
        let reopened = app.textFields["relayField"]
        for _ in 0..<6 where !reopened.exists { app.swipeUp() }
        XCTAssertEqual(reopened.value as? String, "ws://relay-box:8095/v2/targets")
    }
}
