import XCTest

/// The camera's filter menu: radius, boat types, moving only, reset, the empty message, the train switches it shares
/// with Settings, and keeping the choice across launches. The fixture stands on a Hudson ferry off the West Village
/// facing 192°, down the river (`onTheHudson`): four boats ahead at 0.5, 2, 4 and 5.8 km, 6-10° either side of
/// center, and two 700 m behind to the right. Every one is over water in a clear sight line (BoatCore's
/// `HarborSightlineTests.cameraFilterUITestFixture` checks them on the harbor grid).
extension BoatARUITests {
    static let onTheHudson = "40.7270,-74.0175,192,0,5"

    /// Moving boats carry no course, so dead reckoning leaves them where they are; their speed is what "Moving only"
    /// reads.
    static let filterVessels = [
        FixtureVessel(mmsi: 367100001, name: "LIBERTY CLIPPER", type: 60, lat: 40.72251, lon: -74.01771, sog: 8,
                      secondsAgo: 5),
        FixtureVessel(mmsi: 367100002, name: "KATE MCALLISTER", type: 52, lat: 40.71032, lon: -74.02639, sog: 0,
                      secondsAgo: 5),
        FixtureVessel(mmsi: 367100003, name: "ATLANTIC STAR", type: 70, lat: 40.69122, lon: -74.02246, sog: 10,
                      secondsAgo: 5),
        // 5.8 km: beyond the default 3 mi (5 km).
        FixtureVessel(mmsi: 367100004, name: "SEA BREEZE", type: 36, lat: 40.67799, lon: -74.04104, sog: 0.2,
                      secondsAgo: 5),
        // Behind, off to the right: the "2 more ›" hint.
        FixtureVessel(mmsi: 367100005, name: "HUDSON BARGE", type: 70, lat: 40.73196, lon: -74.02261, sog: 6,
                      secondsAgo: 5),
        FixtureVessel(mmsi: 367100006, name: "WATER TAXI", type: 60, lat: 40.73228, lon: -74.02202, sog: 0,
                      secondsAgo: 5),
    ]

    @MainActor
    func filterLabel(_ app: XCUIApplication, _ mmsi: Int) -> XCUIElement {
        app.buttons["arLabel-\(mmsi)"]
    }

    @MainActor
    func launchOnTheHudson(regular: Bool = false, environment: [String: String] = [:]) -> XCUIApplication {
        let app = launch(Self.filterVessels, regular: regular, sensors: Self.onTheHudson, environment: environment)
        openCamera(app)
        XCTAssertTrue(filterLabel(app, 367100001).waitForExistence(timeout: 20), "LIBERTY CLIPPER, 0.5 km ahead")
        return app
    }

    var filterButtonID: String { "cameraFilterButton" }

    @MainActor
    func filterButton(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: filterButtonID).firstMatch
    }

    /// The open menu. UIKit draws a menu as a collection view of cells, one button per item (no identifiers, no
    /// section headers), and the camera screen has no collection view of its own. Opened upward from the button, the
    /// items run in reverse (the radius nearest the button, Reset at the far end), and when they don't all fit (most
    /// text sizes) the menu scrolls and keeps only the cells near the visible ones.
    @MainActor
    func filterMenuMarker(_ app: XCUIApplication) -> XCUIElement {
        app.collectionViews.firstMatch
    }

    /// Taps the filter button and waits for the menu to be up (its first cell).
    @MainActor
    func openFilterMenu(_ app: XCUIApplication) {
        let button = filterButton(app)
        XCTAssertTrue(button.waitForExistence(timeout: 20), "cameraFilterButton missing")
        button.tap()
        XCTAssertTrue(filterMenuMarker(app).cells.firstMatch.waitForExistence(timeout: 20),
                      "the filter menu didn't open")
    }

    /// An item of the open menu, by its identifier or any of its titles, scrolled into view: a cell the menu has
    /// scrolled off is either missing or there but clipped (not hittable), so the menu is scrolled toward the far
    /// end (Reset, Moving only, the trains) first, then back.
    @MainActor
    func menuItem(_ app: XCUIApplication, _ identifier: String, _ titles: String...) -> XCUIElement {
        menuItem(app, identifier, titles: titles)
    }

    @MainActor
    func menuItem(_ app: XCUIApplication, _ identifier: String, titles: [String]) -> XCUIElement {
        let menu = filterMenuMarker(app)
        XCTAssertTrue(menu.cells.firstMatch.waitForExistence(timeout: 20), "the filter menu isn't open")
        let item = menu.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR (elementType == %d AND label IN %@)", identifier,
                                  XCUIElement.ElementType.button.rawValue, titles)).firstMatch
        func onScreen() -> Bool {
            guard item.exists else { return false }
            if item.isHittable { return true }
            // A disabled item (Reset at the defaults) may not count as hittable: then it's enough to be in view.
            let view = menu.frame.intersection(app.windows.firstMatch.frame)
            return !item.isEnabled && view.contains(item.frame)
        }
        for direction in [true, false] {
            for _ in 0..<8 where !onScreen() {
                if direction { menu.swipeDown(velocity: .slow) } else { menu.swipeUp(velocity: .slow) }
            }
        }
        XCTAssertTrue(onScreen(), "menu item \(identifier) (\(titles)) not found in the menu")
        return item
    }

    /// Opens the menu, taps one item, and closes the menu again (it stays open while switches are flipped).
    @MainActor
    func chooseInFilterMenu(_ app: XCUIApplication, _ identifier: String, _ titles: String...) {
        openFilterMenu(app)
        // The distances are in the Radius row's own submenu.
        if identifier.hasPrefix("cameraRadius-") { menuItem(app, "cameraRadiusMenu", titles: ["Radius"]).tap() }
        menuItem(app, identifier, titles: titles).tap()
        closeFilterMenu(app)
    }

    /// Closes the open menu with a tap outside it, then waits until it's gone. The menu opens up from the filter
    /// button at the bottom right; the tap goes to the left edge below the horizon, where these fixtures put nothing
    /// (boats' dots sit on the horizon, labels above it, the controls row lower down), so even a tap the menu let
    /// through would land on the bare preview. At the largest text sizes the menu is nearly as wide as the screen:
    /// the tap then goes into the gutter left of it, never onto one of its items.
    @MainActor
    func closeFilterMenu(_ app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let menu = filterMenuMarker(app).frame
        let y = window.height * 0.72
        var x = window.width * 0.05
        if menu.minX - 2 <= x, menu.minY <= y, y <= menu.maxY { x = max(2, menu.minX / 2) }
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
        waitUntil(filterMenuMarker(app), "exists == false", "the filter menu didn't close")
    }

    @MainActor
    func waitForFilterValue(_ app: XCUIApplication, _ value: String) {
        let button = filterButton(app)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value),
                                                    object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed,
                       "filter button value \(button.value as? String ?? "<none>"), expected \(value)")
    }

    @MainActor
    func waitForLabelGone(_ app: XCUIApplication, _ mmsi: Int, _ message: String) {
        waitUntil(filterLabel(app, mmsi), "exists == false", message)
    }

    /// The button sits inside the safe area, clear of the compass strip, the zoom buttons, the warnings and the tabs
    /// (a bottom tab bar, or the Duo cover's right-hand column).
    @MainActor
    func assertFilterButtonPlacement(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = filterButton(app)
        XCTAssertTrue(button.waitForExistence(timeout: 20), file: file, line: line)
        let frame = button.frame
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(frame), "button \(frame) outside the window \(window)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.width, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, 44, file: file, line: line)
        XCTAssertTrue(button.isHittable, file: file, line: line)
        let others = ["compassStrip", "zoomControl", "accuracyPill", "preciseLocationPill"]
            .map { app.descendants(matching: .any).matching(identifier: $0).firstMatch }
            + [app.buttons["Camera"].firstMatch, app.buttons["Nearby"].firstMatch, app.buttons["Map"].firstMatch]
        for other in others where other.exists {
            XCTAssertFalse(frame.intersects(other.frame), "button \(frame) overlaps \(other.identifier) \(other.frame)",
                           file: file, line: line)
        }
    }

    // MARK: Tests

    @MainActor
    func testCameraFilterRadius() throws {
        let app = launchOnTheHudson()
        assertFilterButtonPlacement(app)
        waitForFilterValue(app, "Radius 3 miles, no filters on")
        // The default is the old 5 km: the boats at 2 and 4 km are labelled, the one at 5.8 km isn't.
        XCTAssertTrue(filterLabel(app, 367100002).waitForExistence(timeout: 20))
        XCTAssertTrue(filterLabel(app, 367100003).exists)
        XCTAssertFalse(filterLabel(app, 367100004).exists, "SEA BREEZE is beyond 3 mi")
        waitForLabel(app.staticTexts["offscreenRight"], "2 more ›")

        chooseInFilterMenu(app, "cameraRadius-1600", "1 mile", "1\u{00A0}mi")
        waitForFilterValue(app, "Radius 1 mile, no filters on")
        waitForLabelGone(app, 367100002, "KATE MCALLISTER, 2 km, is beyond 1 mi")
        waitForLabelGone(app, 367100003, "ATLANTIC STAR, 4 km, is beyond 1 mi")
        XCTAssertTrue(filterLabel(app, 367100001).exists)
        // The two 700 m behind still count.
        waitForLabel(app.staticTexts["offscreenRight"], "2 more ›")

        chooseInFilterMenu(app, "cameraRadius-16000", "10 miles", "10\u{00A0}mi")
        waitForFilterValue(app, "Radius 10 miles, no filters on")
        XCTAssertTrue(filterLabel(app, 367100004).waitForExistence(timeout: 20), "SEA BREEZE, 5.8 km, within 10 mi")
        XCTAssertTrue(filterLabel(app, 367100003).exists)
    }

    @MainActor
    func testCameraFilterHidesABoatType() throws {
        let app = launchOnTheHudson()
        XCTAssertTrue(filterLabel(app, 367100003).waitForExistence(timeout: 20))
        waitForLabel(app.staticTexts["offscreenRight"], "2 more ›")

        chooseInFilterMenu(app, "cameraType-vessel.cargo", "Cargo")
        waitForFilterValue(app, "Radius 3 miles, 1 filter on")
        waitForLabelGone(app, 367100003, "ATLANTIC STAR is cargo")
        XCTAssertTrue(filterLabel(app, 367100001).exists)
        XCTAssertTrue(filterLabel(app, 367100002).exists)
        // HUDSON BARGE, behind, is cargo too: only WATER TAXI is left to hint at.
        waitForLabel(app.staticTexts["offscreenRight"], "1 more ›")

        chooseInFilterMenu(app, "cameraType-vessel.cargo", "Cargo")
        XCTAssertTrue(filterLabel(app, 367100003).waitForExistence(timeout: 20))
        waitForLabel(app.staticTexts["offscreenRight"], "2 more ›")
    }

    @MainActor
    func testCameraFilterMovingOnly() throws {
        let app = launchOnTheHudson()
        XCTAssertTrue(filterLabel(app, 367100002).waitForExistence(timeout: 20))

        chooseInFilterMenu(app, "cameraMovingOnly", "Moving only")
        waitForFilterValue(app, "Radius 3 miles, 1 filter on")
        waitForLabelGone(app, 367100002, "KATE MCALLISTER is stopped")
        XCTAssertTrue(filterLabel(app, 367100001).exists, "8 knots")
        XCTAssertTrue(filterLabel(app, 367100003).exists, "10 knots")
        // WATER TAXI, behind, is stopped; HUDSON BARGE isn't.
        waitForLabel(app.staticTexts["offscreenRight"], "1 more ›")
    }

    @MainActor
    func testCameraFilterEmptyMessageAndReset() throws {
        let app = launchOnTheHudson()
        let empty = app.descendants(matching: .any).matching(identifier: "noBoatsInSight").firstMatch
        XCTAssertFalse(empty.exists)

        // Half a mile, no passenger or cargo boats: within 800 m are LIBERTY CLIPPER (passenger) ahead, and HUDSON
        // BARGE (cargo) and WATER TAXI (passenger) behind.
        chooseInFilterMenu(app, "cameraRadius-800", "half a mile", "½\u{00A0}mi")
        chooseInFilterMenu(app, "cameraType-vessel.passenger", "Passenger")
        chooseInFilterMenu(app, "cameraType-vessel.cargo", "Cargo")
        waitForFilterValue(app, "Radius half a mile, 1 filter on")
        XCTAssertTrue(empty.waitForExistence(timeout: 20))
        // Trains are shown by default, so it says "Nothing" (VoiceOver reads the spoken radius).
        XCTAssertEqual(empty.label, "Nothing matches your filters within half a mile")
        XCTAssertFalse(app.staticTexts["offscreenRight"].exists, "the hints count only what's shown")

        openFilterMenu(app)
        let reset = menuItem(app, "cameraFilterReset", "Reset")
        XCTAssertTrue(reset.isEnabled)
        reset.tap()
        closeFilterMenu(app)
        waitForFilterValue(app, "Radius 3 miles, no filters on")
        XCTAssertTrue(filterLabel(app, 367100001).waitForExistence(timeout: 20))
        XCTAssertTrue(filterLabel(app, 367100003).waitForExistence(timeout: 20))
        waitUntil(empty, "exists == false", "the empty message goes once boats are labelled again")

        openFilterMenu(app)
        XCTAssertFalse(menuItem(app, "cameraFilterReset", "Reset").isEnabled, "nothing to reset at the defaults")
        closeFilterMenu(app)
    }

    /// "Find in Camera" labels a boat that the filter hides and that's beyond the radius.
    @MainActor
    func testCameraFilterStillShowsTheFocusedBoat() throws {
        let app = launchOnTheHudson()
        chooseInFilterMenu(app, "cameraRadius-1600", "1 mile", "1\u{00A0}mi")
        chooseInFilterMenu(app, "cameraType-vessel.cargo", "Cargo")
        waitForLabelGone(app, 367100003, "ATLANTIC STAR is cargo and 4 km away")

        // Find it from the list (the list isn't filtered).
        app.buttons["Nearby"].firstMatch.tap()
        let row = app.buttons["vesselRow-367100003"]
        XCTAssertTrue(reveal(row, in: app))
        row.tap()
        let find = app.buttons["findInCamera"]
        XCTAssertTrue(find.waitForExistence(timeout: 20))
        find.tap()
        let label = filterLabel(app, 367100003)
        XCTAssertTrue(label.waitForExistence(timeout: 20), "the boat asked for is labelled whatever the filter")
        XCTAssertTrue(label.isSelected)
    }

    @MainActor
    func testCameraFilterSurvivesARelaunch() throws {
        let app = launchOnTheHudson()
        chooseInFilterMenu(app, "cameraRadius-1600", "1 mile", "1\u{00A0}mi")
        chooseInFilterMenu(app, "cameraType-vessel.tug", "Service")
        waitForFilterValue(app, "Radius 1 mile, 1 filter on")
        app.terminate()

        // Without the reset hook this time.
        let again = launchOnTheHudson(environment: ["BOATAR_RESET_CAMERA_FILTER": "0"])
        waitForFilterValue(again, "Radius 1 mile, 1 filter on")
        XCTAssertFalse(filterLabel(again, 367100003).exists, "still 1 mi")
        openFilterMenu(again)
        XCTAssertTrue(menuItem(again, "cameraFilterReset", "Reset").isEnabled)
        closeFilterMenu(again)
    }

    /// The menu's train switches are Settings > Trains' own: turning trains off in the camera turns them off there.
    /// They're Settings' state, not camera filters: no "filter on", no dot, and Reset leaves them alone.
    @MainActor
    func testCameraFilterTrainSwitchesAreTheSettings() throws {
        let app = launchOnTheHudson()
        openFilterMenu(app)
        let switchOff = menuItem(app, "cameraType-trains", "Trains")
        XCTAssertTrue(switchOff.isSelected, "trains start on")
        switchOff.tap()
        // The menu stays open while switches are flipped: the item shows the change at once.
        waitUntil(switchOff, "selected == false", "the menu's Trains switch turns off")
        closeFilterMenu(app)
        chooseInFilterMenu(app, "cameraRadius-1600", "1 mile", "1\u{00A0}mi")
        waitForFilterValue(app, "Radius 1 mile, no filters on")

        openFilterMenu(app)
        menuItem(app, "cameraFilterReset", "Reset").tap()
        closeFilterMenu(app)
        waitForFilterValue(app, "Radius 3 miles, no filters on")
        openFilterMenu(app)
        XCTAssertFalse(menuItem(app, "cameraFilterReset", "Reset").isEnabled, "trains off alone isn't a filter")
        closeFilterMenu(app)

        app.buttons["Nearby"].firstMatch.tap()
        openSettings(app)
        let toggle = app.switches["trainsToggle"]
        if !toggle.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        XCTAssertEqual(toggle.value as? String, "0", "the camera menu turned trains off, and Reset left them off")
        // The switch itself sits at the row's trailing end.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        waitUntil(toggle, "value == '1'", "the switch turns back on")
        app.buttons["settingsDone"].tap()

        openCamera(app)
        waitForFilterValue(app, "Radius 3 miles, no filters on")
        openFilterMenu(app)
        // A menu toggle reads as checked either as a value or as selected, depending on how UIKit exposes it.
        let trains = menuItem(app, "cameraType-trains", "Trains")
        XCTAssertTrue(trains.value as? String == "1" || trains.isSelected, "Settings turned trains back on")
        closeFilterMenu(app)
    }

    /// Unfolded (forced regular width): the button sits clear of everything there too, and works.
    @MainActor
    func testCameraFilterInRegularWidth() throws {
        let app = launchOnTheHudson(regular: true)
        assertFilterButtonPlacement(app)
        chooseInFilterMenu(app, "cameraRadius-1600", "1 mile", "1\u{00A0}mi")
        waitForLabelGone(app, 367100003, "ATLANTIC STAR is beyond 1 mi")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "camera-filter-regular"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The largest text size: the button keeps its place, capped like the other camera controls.
    @MainActor
    func testCameraFilterButtonAtAccessibilityTextSizes() throws {
        let app = launch(Self.filterVessels, sensors: Self.onTheHudson, arguments: Self.largestText)
        openCamera(app)
        assertFilterButtonPlacement(app)
        openFilterMenu(app)
        let item = menuItem(app, "cameraMovingOnly", "Moving only")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "camera-filter-menu-axxxl"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(item.exists)
        closeFilterMenu(app)
    }
}
