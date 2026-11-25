import XCTest

/// The list beside the map follows it ("Only what's on the map"), the list and map's filter menu, collapsible list
/// groups, units (trains in mph, Settings > Units) and the map buttons clear of the Duo's status column.
///
/// The simulator can't unfold the Duo: side by side is forced with BOATAR_FORCE_REGULAR on the iPhone 18 Pro in
/// landscape (those tests skip on the Duo, whose cover screen doesn't rotate), and the Duo runs the cover screen,
/// where the same status column sits down the right-hand side.
extension BoatARUITests {
    /// The map on a 100 m square around HARBOR LARK: the other three fixture boats (340-450 m away) are off it.
    /// MapKit fits the square to the whole map view, under the sidebar too, and turning to landscape keeps the zoom
    /// of the portrait map, so what's visible is wider than this, but not 340 m wide.
    static let zoomedOnHarborLark = ["BOATAR_MAP_REGION": "40.7062,-73.9931,100"]
    /// Open water in the Upper Bay with no boat on it.
    static let emptyWater = ["BOATAR_MAP_REGION": "40.6800,-74.0300,300"]
    /// Keeps what an earlier launch stored for the list's filter and sections.
    static let keepBrowse = ["BOATAR_RESET_BROWSE": "0"]

    /// Turns to landscape for the forced side-by-side layout; skips on the Duo, whose cover screen can't turn.
    @MainActor
    func rotateForSideBySide(_ app: XCUIApplication) throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.frame.width > window.frame.height }, object: nil)
        if XCTWaiter.wait(for: [rotated], timeout: 20) != .completed {
            if Self.isDuo { throw XCTSkip("Duo cover screen does not rotate in the simulator: \(window.frame.size)") }
            XCTFail("app did not rotate to landscape: \(window.frame.size)")
        }
    }

    @MainActor
    func listFilterButton(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "listFilterButton").firstMatch
    }

    @MainActor
    func openListFilter(_ app: XCUIApplication) {
        let button = listFilterButton(app)
        XCTAssertTrue(button.waitForExistence(timeout: 20), "listFilterButton missing")
        button.tap()
        XCTAssertTrue(filterMenuMarker(app).cells.firstMatch.waitForExistence(timeout: 20), "the filter menu didn't open")
    }

    /// Closes the list's menu (it opens down from the toolbar) with a tap on the count line, or the window's left edge
    /// when the menu covers it.
    @MainActor
    func closeListFilter(_ app: XCUIApplication) {
        let menu = filterMenuMarker(app).frame
        let count = app.staticTexts["feedStatus"]
        if count.exists, !menu.intersects(count.frame) {
            count.tap()
        } else {
            let window = app.windows.firstMatch.frame
            app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 4, dy: window.height * 0.5)).tap()
        }
        waitUntil(filterMenuMarker(app), "exists == false", "the filter menu didn't close")
    }

    @MainActor
    func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 20) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "\(element) value \(element.value as? String ?? "<none>"), expected \(value)")
    }

    // MARK: Side by side

    @MainActor
    func testSideBySideListFollowsTheMap() throws {
        let app = launch(regular: true, environment: Self.zoomedOnHarborLark)
        try rotateForSideBySide(app)
        // Only HARBOR LARK is on this part of the map.
        waitForLabel(app.staticTexts["vesselCount"], "1 of 4 vessels")
        waitForLabel(app.staticTexts["listScope"], "On the map:")
        XCTAssertTrue(app.buttons["closestCard"].label.hasPrefix("Closest: HARBOR LARK"), app.buttons["closestCard"].label)
        XCTAssertFalse(app.buttons["vesselRow-367000002"].exists, "ANNABEL K is off the map")

        // Zoomed out, everything is on the map again: the plain count, no scope.
        let map = app.descendants(matching: .any).matching(identifier: "vesselMap").firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 20))
        map.pinch(withScale: 0.15, velocity: -3)
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        XCTAssertTrue(app.buttons["vesselRow-367000002"].waitForExistence(timeout: 20))
        waitUntil(app.staticTexts["listScope"], "exists == false", "no scope note with everything listed")
    }

    @MainActor
    func testOnlyWhatsOnTheMapToggleIsKept() throws {
        var app = launch(regular: true, environment: Self.zoomedOnHarborLark)
        try rotateForSideBySide(app)
        waitForLabel(app.staticTexts["vesselCount"], "1 of 4 vessels")
        waitForValue(listFilterButton(app), "No filters on, only what's on the map")
        openListFilter(app)
        let toggle = menuItem(app, "listOnlyOnMap", "Only what's on the map")
        toggle.tap()
        closeListFilter(app)
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        waitForValue(listFilterButton(app), "No filters on")

        // Kept across launches.
        app.terminate()
        app = launch(regular: true, environment: Self.zoomedOnHarborLark.merging(Self.keepBrowse) { $1 })
        try rotateForSideBySide(app)
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        XCTAssertTrue(app.buttons["vesselRow-367000002"].waitForExistence(timeout: 20))
    }

    @MainActor
    func testNothingOnThisPartOfTheMapOffersEverything() throws {
        let app = launch(regular: true, environment: Self.emptyWater)
        try rotateForSideBySide(app)
        let title = app.staticTexts["browseEmptyTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "Nothing on this part of the map")
        waitForLabel(app.staticTexts["vesselCount"], "0 of 4 vessels")
        let everything = app.buttons["browseEmptyAction"]
        XCTAssertEqual(everything.label, "Show the whole list")
        everything.tap()
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        XCTAssertTrue(app.buttons["closestCard"].waitForExistence(timeout: 20))
    }

    // MARK: Sections

    @MainActor
    func testListSectionsCollapseAndStaySo() throws {
        var app = launch()
        let inSight = app.buttons["boatsInSightToggle"]
        XCTAssertTrue(inSight.waitForExistence(timeout: 20))
        XCTAssertTrue(inSight.label.hasPrefix("In sight, "), inSight.label)
        XCTAssertEqual(inSight.value as? String, "Expanded")
        XCTAssertTrue(app.buttons["closestCard"].exists)
        inSight.tap()
        waitForValue(inSight, "Collapsed")
        waitUntil(app.buttons["closestCard"], "exists == false", "collapsed, the closest card goes with its group")

        app.terminate()
        app = launch(environment: Self.keepBrowse)
        let again = app.buttons["boatsInSightToggle"]
        XCTAssertTrue(again.waitForExistence(timeout: 20))
        XCTAssertEqual(again.value as? String, "Collapsed", "kept across launches")
        XCTAssertFalse(app.buttons["closestCard"].exists)
        again.tap()
        waitForValue(again, "Expanded")
        XCTAssertTrue(app.buttons["closestCard"].waitForExistence(timeout: 20))
    }

    @MainActor
    func testTrainGroupsCollapseToo() throws {
        let app = launchWithTrains()
        let inSight = app.buttons["trainsInSightToggle"]
        XCTAssertTrue(reveal(inSight, in: app))
        XCTAssertTrue(inSight.label.hasPrefix("In sight, 2"), inSight.label)
        XCTAssertTrue(reveal(row(app, "Q1"), in: app))
        inSight.tap()
        waitForValue(inSight, "Collapsed")
        waitUntil(row(app, "Q1"), "exists == false", "the trains in sight collapse")
        XCTAssertEqual(app.buttons["undergroundToggle"].value as? String, "Collapsed", "underground starts collapsed")
    }

    /// VoiceOver: the status line is one element without middle dots, and a group header reads "In sight, 4".
    @MainActor
    func testStatusLineAndHeadersReadWellToVoiceOver() throws {
        let app = launch(environment: ["BOATAR_ACCESSIBILITY_PROBE": "1"])
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        let labels = voiceOverLabels(app) { $0.contains("Live, 4 vessels, 0 trains") }
        XCTAssertTrue(labels.contains("Live, 4 vessels, 0 trains"), "\(labels)")
        XCTAssertFalse(labels.contains("4 vessels"), "the count isn't a separate stop: \(labels)")
        XCTAssertFalse(labels.contains { $0.contains("·") }, "no middle dots read out: \(labels)")
        XCTAssertTrue(labels.contains { $0.hasPrefix("In sight, ") }, "\(labels)")
    }

    // MARK: Type filter

    @MainActor
    func testTypeFilterHidesRowsAndMarkersUntilReset() throws {
        let app = launch()
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        openListFilter(app)
        menuItem(app, "listType-vessel.tug", "Service").tap()
        closeListFilter(app)
        waitForLabel(app.staticTexts["vesselCount"], "3 of 4 vessels")
        waitForLabel(app.staticTexts["listScope"], "With filters on:")
        waitForValue(listFilterButton(app), "1 filter on")
        XCTAssertFalse(app.buttons["vesselRow-367000002"].exists, "ANNABEL K, a service boat, is hidden")

        // The map shows the same.
        app.buttons["Map"].firstMatch.tap()
        XCTAssertTrue(vesselMarker(app, 367000001).waitForExistence(timeout: 20))
        XCTAssertFalse(vesselMarker(app, 367000002).exists, "the filter hides the marker too")

        app.buttons["Nearby"].firstMatch.tap()
        openListFilter(app)
        menuItem(app, "listFilterReset", "Reset").tap()
        closeListFilter(app)
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        waitForValue(listFilterButton(app), "No filters on")
        XCTAssertTrue(app.buttons["vesselRow-367000002"].waitForExistence(timeout: 20))
    }

    /// Compact width: the map's own filter button shows the list's filter (filled while filtering) and changes it, and
    /// the taller button stack still fits at the largest text size, with the card clear of it.
    @MainActor
    func testMapTabHasTheFilterButton() throws {
        let app = launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons["Map"].firstMatch.tap()
        let button = app.descendants(matching: .any).matching(identifier: "mapFilterButton").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        waitForValue(button, "No filters on")
        let stack = app.descendants(matching: .any).matching(identifier: "mapButtons").firstMatch
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(stack.frame), "the button stack \(stack.frame) doesn't fit in \(window)")
        XCTAssertTrue(stack.frame.contains(button.frame), "the filter button is part of the stack")
        button.tap()
        XCTAssertTrue(filterMenuMarker(app).cells.firstMatch.waitForExistence(timeout: 20), "the filter menu didn't open")
        menuItem(app, "listType-vessel.tug", "Service").tap()
        closeListFilter(app)
        waitForValue(button, "1 filter on")
        XCTAssertFalse(vesselMarker(app, 367000002).exists, "the filtered boat is off the map")
        let marker = vesselMarker(app, 367000001)
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        marker.tap()
        let card = mapCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertFalse(card.frame.intersects(stack.frame), "card \(card.frame) over the buttons \(stack.frame)")
    }

    @MainActor
    func testFilteringEverythingOffersReset() throws {
        let app = launch()
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        openListFilter(app)
        for (key, title) in [("vessel.passenger", "Passenger"), ("vessel.tug", "Service"), ("vessel.pleasure", "Pleasure"),
                             ("vessel.other", "Other")] {
            menuItem(app, "listType-\(key)", title).tap()
        }
        // Trains off too, through the shared switch: nothing at all is left.
        menuItem(app, "listType-trains", "Trains").tap()
        closeListFilter(app)
        let title = app.staticTexts["browseEmptyTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "Nothing matches your filters")
        app.buttons["browseEmptyAction"].tap()
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        XCTAssertFalse(app.staticTexts["trainCount"].exists, "Reset leaves Settings' train switch as it was")
    }

    // MARK: Units

    @MainActor
    func testTrainSpeedsAreInMph() throws {
        let app = launchWithTrains()
        let q = row(app, "Q1")
        XCTAssertTrue(reveal(q, in: app))
        // 18 knots on the wire.
        XCTAssertTrue(q.label.hasSuffix("21 miles per hour"), q.label)
        XCTAssertFalse(q.label.contains("knot"), q.label)
        q.tap()
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["21\u{00A0}mph"].waitForExistence(timeout: 20), "the Speed tile")
    }

    @MainActor
    func chooseUnit(_ app: XCUIApplication, picker identifier: String, _ title: String) {
        openSettings(app)
        let picker = app.buttons[identifier].firstMatch
        for _ in 0..<6 where !(picker.exists && picker.isHittable) { app.swipeUp() }
        XCTAssertTrue(picker.isHittable, "\(identifier) not reachable")
        picker.tap()
        let item = app.buttons[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 20), "no \(title) in the menu")
        item.tap()
        app.buttons["settingsDone"].tap()
    }

    @MainActor
    func testSpeedUnitsCanBeChosen() throws {
        let app = launchWithTrains()
        let boat = app.buttons["vesselRow-367000002"]
        XCTAssertTrue(boat.waitForExistence(timeout: 20))
        XCTAssertTrue(boat.label.hasSuffix("7 knots"), boat.label)

        chooseUnit(app, picker: "unitsSpeedPicker", "Kilometers per hour")
        // 6.8 kn and 18 kn.
        waitUntil(boat, "label ENDSWITH '13 kilometers per hour'", "the boat in km/h: \(boat.label)")
        let q = row(app, "Q1")
        XCTAssertTrue(reveal(q, in: app))
        XCTAssertTrue(q.label.hasSuffix("33 kilometers per hour"), q.label)

        chooseUnit(app, picker: "unitsSpeedPicker", "Standard for each vehicle")
        XCTAssertTrue(reveal(q, in: app))
        waitUntil(q, "label ENDSWITH '21 miles per hour'", "the train back in mph: \(q.label)")
        for _ in 0..<4 where !boat.exists { app.swipeDown() }
        waitUntil(boat, "label ENDSWITH '7 knots'", "the boat back in knots: \(boat.label)")
    }

    /// The largest text size: each Units choice is its own row (a menu's "Standard for each vehicle" wrapped and was
    /// cut off), every row inside the screen (the Duo cover is the narrowest), and choosing one works.
    @MainActor
    func testUnitsSettingsFitAtTheLargestTextSize() throws {
        let app = launchWithTrains(arguments: ["-UIPreferredContentSizeCategoryName",
                                               "UICTContentSizeCategoryAccessibilityXXXL"])
        openSettings(app)
        let window = app.windows.firstMatch.frame
        for title in ["Standard for each vehicle", "Kilometers per hour", "Nautical miles", "Meters"] {
            let option = app.buttons[title].firstMatch
            for _ in 0..<12 where !(option.exists && option.isHittable) { app.swipeUp() }
            XCTAssertTrue(option.isHittable, "\(title) not reachable")
            XCTAssertGreaterThanOrEqual(option.frame.minX, window.minX, "\(title) \(option.frame) clipped")
            XCTAssertLessThanOrEqual(option.frame.maxX, window.maxX + 0.5, "\(title) \(option.frame) clipped")
            XCTAssertGreaterThanOrEqual(option.frame.height.rounded(), 44, "\(title) shorter than a touch target")
        }
        let footer = app.staticTexts["unitsFooter"]
        for _ in 0..<4 where !(footer.exists && footer.isHittable) { app.swipeUp() }
        XCTAssertTrue(footer.exists)
        XCTAssertLessThanOrEqual(footer.frame.maxX, window.maxX + 0.5, "footer \(footer.frame) clipped")
        // Choosing one still works at this size: km/h (VoiceOver and XCUITest read "Kilometers per hour").
        let kmh = app.buttons["Kilometers per hour"].firstMatch
        for _ in 0..<12 where !(kmh.exists && kmh.isHittable) { app.swipeDown() }
        kmh.tap()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "settings-units-axxxl"
        shot.lifetime = .keepAlways
        add(shot)
        let done = app.buttons["settingsDone"]
        for _ in 0..<12 where !done.exists { app.swipeDown() }
        done.tap()
        let q = row(app, "Q1")
        XCTAssertTrue(reveal(q, in: app))
        XCTAssertTrue(q.label.hasSuffix("33 kilometers per hour"), q.label)
    }

    // MARK: Map buttons

    /// The map's buttons never sit by the system's status column: on the Duo (cover screen here, and unfolded) they
    /// go top leading, clear of the right-hand column; on a phone they stay top trailing below the status bar.
    @MainActor
    func testMapButtonsClearTheStatusColumn() throws {
        let app = launch()
        app.buttons["Map"].firstMatch.tap()
        let buttons = app.descendants(matching: .any).matching(identifier: "mapButtons").firstMatch
        XCTAssertTrue(buttons.waitForExistence(timeout: 20))
        let window = app.windows.firstMatch.frame
        let frame = buttons.frame
        XCTAssertTrue(window.contains(frame), "buttons \(frame) outside the window \(window)")
        if Self.isDuo {
            // The status column and the tabs are a column down the right-hand side; the Camera tab marks its edge.
            let column = app.buttons["Camera"].firstMatch.frame
            XCTAssertLessThan(frame.maxX, column.minX, "buttons \(frame) run into the right-hand column at \(column)")
            XCTAssertLessThan(frame.midX, window.midX, "beside the status column the buttons go top leading: \(frame)")
            let statusColumn = CGRect(x: column.minX, y: window.minY, width: window.maxX - column.minX,
                                      height: window.height)
            XCTAssertFalse(frame.intersects(statusColumn))
        } else {
            XCTAssertGreaterThan(frame.midX, window.midX, "top trailing on a phone: \(frame)")
            XCTAssertGreaterThanOrEqual(frame.minY, 44, "under the status bar: \(frame)")
        }
        // The card still keeps clear of them.
        let marker = vesselMarker(app, 367000001)
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        marker.tap()
        let card = mapCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertFalse(card.frame.intersects(buttons.frame), "card \(card.frame) over the buttons \(buttons.frame)")
    }

    /// Side by side beside a trailing system column (simulated with BOATAR_FAKE_TRAILING_COLUMN: the simulator can't
    /// unfold the Duo): the buttons go top leading on the map, clear of the list's column and its sidebar button, and
    /// the offline banner stays clear of the column.
    @MainActor
    func testSideBySideButtonsBesideATrailingColumn() throws {
        let app = launch(offline: true, regular: true, environment: ["BOATAR_FAKE_TRAILING_COLUMN": "84"])
        try rotateForSideBySide(app)
        let map = app.descendants(matching: .any).matching(identifier: "vesselMap").firstMatch
        let buttons = app.descendants(matching: .any).matching(identifier: "mapButtons").firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 20))
        XCTAssertTrue(buttons.waitForExistence(timeout: 20))
        let window = app.windows.firstMatch.frame
        let column = CGRect(x: window.maxX - 84, y: window.minY, width: 84, height: window.height)
        XCTAssertLessThan(buttons.frame.midX, map.frame.midX, "top leading on the map: \(buttons.frame) in \(map.frame)")
        XCTAssertGreaterThanOrEqual(buttons.frame.minX, map.frame.minX, "inside the map, right of the list")
        XCTAssertFalse(buttons.frame.intersects(column), "buttons \(buttons.frame) in the column \(column)")
        let count = app.staticTexts["vesselCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 20))
        XCTAssertGreaterThan(buttons.frame.minX, count.frame.maxX, "clear of the list's column")
        for sidebar in app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).allElementsBoundByIndex {
            XCTAssertFalse(buttons.frame.intersects(sidebar.frame), "buttons over the sidebar button \(sidebar.frame)")
        }
        // The list has its own banner; the map's is the one over the map.
        XCTAssertTrue(app.otherElements["offlineBanner"].waitForExistence(timeout: 20))
        let banners = app.otherElements.matching(identifier: "offlineBanner").allElementsBoundByIndex
            .filter { $0.frame.midX > map.frame.minX }
        XCTAssertFalse(banners.isEmpty, "no banner over the map")
        for banner in banners {
            // The fake column sits inside the phone's own landscape inset, so its exact place isn't known here: the
            // banner must end at least the column's width short of the window's edge.
            XCTAssertLessThanOrEqual(banner.frame.maxX, window.maxX - 84, "banner \(banner.frame) in the column")
            XCTAssertFalse(banner.frame.intersects(buttons.frame), "banner over the buttons")
        }
    }

    /// The offline banner on the map stays inside the safe area: on the Duo cover, left of the status column.
    @MainActor
    func testOfflineBannerOnTheMapClearsTheStatusColumn() throws {
        let app = launch(offline: true)
        app.buttons["Map"].firstMatch.tap()
        let buttons = app.descendants(matching: .any).matching(identifier: "mapButtons").firstMatch
        XCTAssertTrue(buttons.waitForExistence(timeout: 20))
        let banner = app.otherElements["offlineBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 20))
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(banner.frame))
        XCTAssertFalse(banner.frame.intersects(buttons.frame), "banner \(banner.frame) over the buttons \(buttons.frame)")
        if Self.isDuo {
            let column = app.buttons["Camera"].firstMatch.frame
            XCTAssertLessThanOrEqual(banner.frame.maxX, column.minX, "banner \(banner.frame) runs into the column")
        }
    }

    // MARK: Screenshots

    /// Screenshots for review (TEST_RUNNER_BOATAR_SCREENSHOT_TOUR=1, `scripts/ui-test.sh only ... --both` with
    /// UITEST_EXPORT_ATTACHMENTS=1): side by side with the list on the map, the filter menu, collapsed groups, a
    /// train in mph, the map's buttons (on the Duo cover, beside the status column).
    @MainActor
    func testListAndMapScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOATAR_SCREENSHOT_TOUR"] == "1",
                          "Set TEST_RUNNER_BOATAR_SCREENSHOT_TOUR=1 to take the screenshots")
        let device = (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "device")
            .replacingOccurrences(of: " ", with: "")
        addTeardownBlock { XCUIDevice.shared.appearance = .light }
        XCUIDevice.shared.appearance = .dark
        func shot(_ app: XCUIApplication, _ name: String) {
            sleep(2)
            // The whole screen: the app's own screenshot of a landscape window came out half black.
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "\(device)-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let night = ["-nightMode", "off"]

        var app = launchWithTrains(arguments: night)
        _ = app.staticTexts["vesselCount"].waitForExistence(timeout: 10)
        app.buttons["Map"].firstMatch.tap()
        _ = app.descendants(matching: .any).matching(identifier: "mapButtons").firstMatch.waitForExistence(timeout: 10)
        sleep(2)
        shot(app, "map-buttons")
        app.buttons["Nearby"].firstMatch.tap()
        openListFilter(app)
        shot(app, "list-filter-menu")
        closeListFilter(app)
        app.buttons["boatsInSightToggle"].tap()
        shot(app, "list-collapsed-boats")
        let q = row(app, "Q1")
        if reveal(q, in: app) {
            shot(app, "train-row-mph")
            q.tap()
            _ = app.staticTexts["detailTitle"].waitForExistence(timeout: 10)
            shot(app, "train-detail-mph")
        }
        app.terminate()

        app = launch(arguments: night + ["-UIPreferredContentSizeCategoryName",
                                         "UICTContentSizeCategoryAccessibilityXXXL"])
        openSettings(app)
        let units = app.buttons["Standard for each vehicle"].firstMatch
        for _ in 0..<10 where !(units.exists && units.isHittable) { app.swipeUp() }
        shot(app, "settings-units-AX5")
        app.terminate()

        if !Self.isDuo {
            app = launchWithTrains(regular: true, arguments: night, environment: Self.zoomedOnHarborLark)
            try rotateForSideBySide(app)
            _ = app.staticTexts["listScope"].waitForExistence(timeout: 10)
            sleep(2)
            shot(app, "side-by-side-on-the-map")
            openListFilter(app)
            shot(app, "side-by-side-filter-menu")
            closeListFilter(app)
            app.terminate()
            app = launch(regular: true, arguments: night, environment: Self.emptyWater)
            try rotateForSideBySide(app)
            _ = app.staticTexts["browseEmptyTitle"].waitForExistence(timeout: 10)
            shot(app, "side-by-side-nothing-here")
            app.terminate()
        }
    }
}
