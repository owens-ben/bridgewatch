import XCTest

/// The map card (docs/DESIGN.md, Map card): selecting a boat or train on the map shows a card that never covers its
/// marker or the map's buttons, docked at the edge that leaves the marker clear; "More info" opens the full details
/// with the AIS details; the Key explains the markers. Runs on the iPhone 18 Pro and the Duo cover screen (CLAUDE.md,
/// Tests), so both compact frames are covered.
extension BoatARUITests {
    /// A boat with every AIS detail, as the relay sends it (relay/PROTOCOL.md, "Vessels"). The destination holds
    /// markdown, which must show as typed. Stamped ahead of the clock so it never goes stale (the age clamps to 0).
    func detailsVesselJSON(now: Date) -> String {
        let stamp = now.addingTimeInterval(600).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        return #"{"id":"vessel:367000010","kind":"vessel","source":"aisstream","name":"EAST RIVER QUEEN","#
            + #""lat":40.7011,"lon":-73.9899,"speed":3,"course":90,"heading":91,"timestamp":"\#(stamp)","#
            + #""vessel":{"mmsi":367000010,"shipType":69,"imo":9123453,"callSign":"WDB1234","#
            + #""destination":"PIER 11 *WALL ST*","eta":{"month":11,"day":10,"hour":18,"minute":45},"#
            + #""length":158,"beam":28,"draught":6.4,"navStatus":5}}"#
    }

    @MainActor
    func openMap(_ app: XCUIApplication) {
        let tab = app.buttons["Map"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "vesselMap").firstMatch
            .waitForExistence(timeout: 20))
    }

    @MainActor
    func vesselMarker(_ app: XCUIApplication, _ mmsi: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "vesselMarker-\(mmsi)").firstMatch
    }

    @MainActor
    func mapCard(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "mapCard").firstMatch
    }

    /// The labels VoiceOver can reach, in order (`AccessibilityProbe`, launched with BOATAR_ACCESSIBILITY_PROBE=1),
    /// once `until` holds for them or after 20 s.
    @MainActor
    func voiceOverLabels(_ app: XCUIApplication, until: @escaping ([String]) -> Bool) -> [String] {
        let probe = app.descendants(matching: .any).matching(identifier: "accessibilityProbe").firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 20), "no accessibility probe")
        func labels() -> [String] { (probe.value as? String ?? "").components(separatedBy: " | ") }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in until(labels()) }, object: nil)
        _ = XCTWaiter.wait(for: [ready], timeout: 20)
        return labels()
    }

    /// Waits for the card, then for the map to stop panning the marker into place (its frame holds still), and checks
    /// the card leaves the marker and the map buttons clear.
    @MainActor
    func assertCardClear(_ card: XCUIElement, of marker: XCUIElement, in app: XCUIApplication,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no card", file: file, line: line)
        var last = marker.frame
        for _ in 0..<10 {
            sleep(1)
            let now = marker.frame
            if now == last { break }
            last = now
        }
        // The marker and the type label under it (`VesselMarker.labelAllowance`, 20 pt; the label is hidden from
        // accessibility, so it's the room kept for it).
        let target = CGRect(x: marker.frame.minX, y: marker.frame.minY, width: marker.frame.width,
                            height: marker.frame.height + 20)
        XCTAssertFalse(card.frame.intersects(target),
                       "card \(card.frame) covers the marker or its label \(target)", file: file, line: line)
        for button in ["Re-center map", "Map key"] {
            let control = app.buttons[button]
            if control.exists {
                XCTAssertFalse(card.frame.intersects(control.frame),
                               "card \(card.frame) covers \(button) \(control.frame)", file: file, line: line)
            }
        }
        XCTAssertTrue(app.windows.firstMatch.frame.contains(card.frame), "card \(card.frame) off screen",
                      file: file, line: line)
    }

    // MARK: Compact

    @MainActor
    func testMapCardLeavesTheSelectedBoatClear() throws {
        let app = launch(environment: region(on: Self.fixtureVessels[0]))
        openMap(app)
        let marker = vesselMarker(app, 367000001)
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        marker.tap()
        let title = app.buttons["mapCardTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertTrue(title.label.hasPrefix("HARBOR LARK, passenger"), title.label)
        XCTAssertFalse(app.staticTexts["detailTitle"].exists, "the map shows a card, not a sheet")
        XCTAssertTrue(marker.isSelected)
        assertCardClear(mapCard(app), of: marker, in: app)
        // The close button deselects.
        app.buttons["closeDetails"].tap()
        waitUntil(mapCard(app), "exists == false", "Close takes the card away")
    }

    @MainActor
    func testMapCardLeavesTheMarkerClearAtAccessibilityTextSizes() throws {
        let app = launch(arguments: Self.largestText, environment: region(on: Self.fixtureVessels[1]))
        openMap(app)
        let marker = vesselMarker(app, 367000002)
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        marker.tap()
        let card = mapCard(app)
        assertCardClear(card, of: marker, in: app)
        // Capped: the card never takes most of the map.
        let map = app.descendants(matching: .any).matching(identifier: "vesselMap").firstMatch
        XCTAssertLessThan(card.frame.height, map.frame.height * 0.5, "card \(card.frame) in map \(map.frame)")
        // The title row still opens More info.
        let title = app.buttons["mapCardTitle"]
        XCTAssertTrue(title.isHittable)
        title.tap()
        let detail = app.staticTexts["detailTitle"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20))
        XCTAssertEqual(detail.label, "ANNABEL K")
    }

    /// The map zoomed in on a 1.2 km square around a boat. At the whole-area zoom the fixture boats' markers overlap,
    /// and MapKit then decides which one a tap on any of them selects.
    func region(on vessel: FixtureVessel) -> [String: String] {
        ["BOATAR_MAP_REGION": "\(vessel.lat),\(vessel.lon),1200"]
    }

    /// The map zoomed in on a 1.2 km square around a point 450 m south or north of HARBOR LARK, so its marker starts
    /// near the top or near the bottom of the map.
    func region(boatOffsetMeters: Double) -> [String: String] {
        let boat = (lat: 40.7062, lon: -73.9931)
        let lat = boat.lat - boatOffsetMeters / 111_320
        return ["BOATAR_MAP_REGION": "\(lat),\(boat.lon),1200"]
    }

    @MainActor
    func testMarkersNearTheBottomAndTopGetCardsOnOppositeEdges() throws {
        // Near the top: the card docks below it (the bottom is preferred and clear).
        var app = launch([Self.fixtureVessels[0]], environment: region(boatOffsetMeters: 450))
        openMap(app)
        var marker = vesselMarker(app, 367000001)
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        marker.tap()
        var card = mapCard(app)
        assertCardClear(card, of: marker, in: app)
        XCTAssertGreaterThan(card.frame.minY, marker.frame.maxY, "a marker near the top gets the card at the bottom")
        app.terminate()

        // Near the bottom: a bottom card would cover it, so the card docks at the top.
        app = launch([Self.fixtureVessels[0]], environment: region(boatOffsetMeters: -450))
        openMap(app)
        marker = vesselMarker(app, 367000001)
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        marker.tap()
        card = mapCard(app)
        assertCardClear(card, of: marker, in: app)
        XCTAssertLessThan(card.frame.maxY, marker.frame.minY, "a marker near the bottom gets the card at the top")
    }

    @MainActor
    func testSelectingATrainOnTheMapShowsTheCard() throws {
        let app = launchWithTrains()
        openMap(app)
        let marker = trainMarker(app, "M1", "M train to")
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        marker.tap()
        let title = app.buttons["mapCardTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertTrue(title.label.hasPrefix("M train to Middle Village-Metropolitan Av"), title.label)
        XCTAssertFalse(app.staticTexts["detailTitle"].exists)
        assertCardClear(mapCard(app), of: marker, in: app)
        // The header is the More info button for VoiceOver (the visible "More info" capsule is hidden from it).
        title.tap()
        let detail = app.staticTexts["detailTitle"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20))
        XCTAssertEqual(detail.label, "M to Middle Village-Metropolitan Av")
    }

    /// A tap on the open map still deselects (the D3 fix drops only MapKit's deselects that come without one).
    @MainActor
    func testTappingTheOpenMapDeselects() throws {
        let app = launch(environment: ["BOATAR_MAP_REGION": "40.7065,-73.9910,1500"])
        openMap(app)
        let marker = vesselMarker(app, 367000002)
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        marker.tap()
        let card = mapCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        sleep(2)
        // Left of the middle, a little below it: open water or land, away from the boats, the buttons and the card.
        let window = app.windows.firstMatch.frame
        var point = CGVector(dx: window.width * 0.2, dy: window.height * 0.45)
        if card.frame.contains(CGPoint(x: point.dx, y: point.dy)) { point.dy = window.height * 0.3 }
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
        waitUntil(card, "exists == false", "a tap on the open map didn't deselect")
    }

    /// Dogfood 13: XCUITest (and agent-device) list each map marker twice, once as a bare "NAME, NAME" element and once
    /// as the marker's button. This asks the app what VoiceOver reaches (`AccessibilityProbe`): each boat's name should
    /// start exactly one label on the map.
    @MainActor
    func testMapMarkersReachVoiceOverOnce() throws {
        let app = launch(environment: ["BOATAR_ACCESSIBILITY_PROBE": "1"])
        openMap(app)
        XCTAssertTrue(vesselMarker(app, 367000001).waitForExistence(timeout: 20))
        let spoken = voiceOverLabels(app, until: { $0.contains { $0.hasPrefix("HARBOR LARK") } })
        print("VOICEOVER map labels: \(spoken)")
        for name in ["HARBOR LARK", "ANNABEL K"] {
            XCTAssertEqual(spoken.filter { $0.hasPrefix(name) }.count, 1, "\(name) reached \(spoken.filter { $0.hasPrefix(name) })")
        }
    }

    /// More info: the full sheet with the MMSI, the finer type, every AIS detail of a boat that sends them, and the
    /// MarineTraffic link (not tapped). Crew text shows as typed (no markdown).
    @MainActor
    func testMoreInfoShowsTheAISDetails() throws {
        let app = launch(messages: [#"{"type":"snapshot","targets":[\#(detailsVesselJSON(now: Date()))]}"#],
                         environment: ["BOATAR_ACCESSIBILITY_PROBE": "1"])
        openMap(app)
        let marker = vesselMarker(app, 367000010)
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        marker.tap()
        // The status line is read once, in the header's label.
        let header = app.buttons["mapCardTitle"]
        XCTAssertTrue(header.waitForExistence(timeout: 20))
        XCTAssertTrue(header.label.contains("Moored · to PIER 11 *WALL ST*"), header.label)
        // VoiceOver reads the card as its header (one element, the status in its label, More info its hint) and Close:
        // not the "More info" capsule a second time, nor the status or distance on their own. XCUITest lists those
        // hidden views too, so this asks the app what an assistive technology reaches (`AccessibilityProbe`).
        let spoken = voiceOverLabels(app, until: { $0.contains { $0.hasPrefix("EAST RIVER QUEEN, passenger, Moored") } })
        XCTAssertEqual(spoken.filter { $0.hasPrefix("EAST RIVER QUEEN, passenger, Moored") }.count, 1, "\(spoken)")
        // The probe sees what VoiceOver sees: the header's parts are inside its one element, unlike in XCUITest's tree.
        XCTAssertTrue(app.staticTexts["EAST RIVER QUEEN"].exists, "XCUITest lists the header's parts")
        XCTAssertFalse(spoken.contains("EAST RIVER QUEEN"), "\(spoken)")
        XCTAssertFalse(spoken.contains("More info"), "the capsule is a second More info button: \(spoken)")
        XCTAssertFalse(spoken.contains { $0.hasPrefix("Moored") }, "the status is read twice: \(spoken)")
        XCTAssertTrue(spoken.contains("Close details"), "\(spoken)")
        header.tap()

        let title = app.staticTexts["detailTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "EAST RIVER QUEEN")
        XCTAssertEqual(app.staticTexts["detailType"].label, "Passenger")
        XCTAssertTrue(app.staticTexts["detailMMSI"].label.contains("367000010"), app.staticTexts["detailMMSI"].label)
        let expected: [(String, String)] = [
            ("status", "Moored"), ("destination", "PIER 11 *WALL ST*"), ("eta", "18:45 UTC"),
            ("size", "518 × 92"), ("draught", "21"), ("heading", "E 91°"), ("position", "40.70110° N, 73.98990° W"),
            ("imo", "9123453"), ("callSign", "WDB1234"),
        ]
        for (id, text) in expected {
            let row = app.descendants(matching: .any).matching(identifier: "detailRow-\(id)").firstMatch
            XCTAssertTrue(reveal(row, in: app), "no \(id) row")
            XCTAssertTrue(row.label.contains(text), "\(id): \(row.label)")
        }
        let lookup = app.links["lookUpVessel"]
        XCTAssertTrue(reveal(lookup, in: app), "no MarineTraffic link")
        XCTAssertTrue(lookup.label.contains("MarineTraffic"), lookup.label)
        // Closing the full details goes back to the map card.
        // The sheet's own close button (the card under it has one too).
        let sheet = app.descendants(matching: .any).matching(identifier: "vesselDetail").firstMatch
        let close = sheet.buttons["closeDetails"]
        for _ in 0..<5 where sheet.exists && !close.isHittable { app.swipeDown() }
        if close.exists, close.isHittable { close.tap() }
        XCTAssertTrue(app.buttons["mapCardTitle"].waitForExistence(timeout: 20), "the card stays under More info")
    }

    /// The key names the six boat groups and the train bullets, with no slash anywhere on the sheet.
    @MainActor
    func testMapKeyListsEveryCategory() throws {
        let app = launchWithTrains()
        openMap(app)
        let key = app.buttons["mapKeyButton"]
        XCTAssertTrue(key.waitForExistence(timeout: 20))
        key.tap()
        let sheet = app.descendants(matching: .any).matching(identifier: "mapKey").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 20))
        let names = [("passenger", "Passenger"), ("cargo", "Cargo"), ("tug", "Service"),
                     ("firstResponder", "First responder"), ("pleasure", "Pleasure"), ("other", "Other"),
                     ("trainAboveGround", "Above ground"), ("trainUnderground", "Underground")]
        for (id, name) in names {
            let row = app.descendants(matching: .any).matching(identifier: "mapKey-\(id)").firstMatch
            XCTAssertTrue(reveal(row, in: app), "no key row for \(id)")
            XCTAssertTrue(row.label.hasPrefix(name), "\(id): \(row.label)")
            XCTAssertFalse(row.label.contains("/"), "\(id): \(row.label)")
        }
        let texts = sheet.descendants(matching: .any).allElementsBoundByIndex.map(\.label)
        XCTAssertFalse(texts.isEmpty)
        for text in texts { XCTAssertFalse(text.contains("/"), text) }
    }

    /// A boat sending AIS type 55 (law enforcement) is a First responder: the list row and the marker say so (to
    /// VoiceOver too), the marker keeps its 44 pt touch target, and the card gives the finer type.
    static let police = FixtureVessel(mmsi: 367000055, name: "NYPD HARBOR 1", type: 55, lat: 40.7060, lon: -73.9950,
                                      sog: 8.4, secondsAgo: 6, cog: 200)

    @MainActor
    func testFirstResponderBoatIsNamedAsOne() throws {
        let app = launch(Self.fixtureVessels + [Self.police], environment: region(on: Self.police))
        let row = app.buttons["vesselRow-367000055"]
        XCTAssertTrue(reveal(row, in: app))
        XCTAssertTrue(row.label.hasPrefix("NYPD HARBOR 1, first responder"), row.label)
        openMap(app)
        let marker = vesselMarker(app, 367000055)
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        XCTAssertTrue(marker.label.hasPrefix("NYPD HARBOR 1, first responder"), marker.label)
        XCTAssertGreaterThanOrEqual(marker.frame.width, 44)
        XCTAssertGreaterThanOrEqual(marker.frame.height, 44)
        marker.tap()
        let title = app.buttons["mapCardTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        // The card gives the finer type, as for every boat.
        XCTAssertTrue(title.label.hasPrefix("NYPD HARBOR 1, law enforcement"), title.label)
    }

    /// "Show on map" from the list (the closest card) lands on the map with the card, and no sheet.
    @MainActor
    func testShowOnMapFromTheListShowsTheCard() throws {
        let app = launch(environment: region(on: Self.fixtureVessels[0]))
        let closest = app.buttons["closestCard"]
        XCTAssertTrue(closest.waitForExistence(timeout: 20))
        closest.tap()
        let title = app.buttons["mapCardTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertTrue(title.label.hasPrefix("HARBOR LARK"), title.label)
        XCTAssertFalse(app.staticTexts["detailTitle"].exists)
        assertCardClear(mapCard(app), of: vesselMarker(app, 367000001), in: app)
        // A row in the list still opens its sheet.
        app.buttons["Nearby"].firstMatch.tap()
        let row = app.buttons["vesselRow-367000002"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 20))
    }

    // MARK: Regular width

    /// Unfolded (forced regular width, landscape): the floating card picks a corner clear of the selected marker.
    @MainActor
    func testRegularWidthFloatingCardLeavesTheMarkerClear() throws {
        let app = launch(regular: true, environment: region(on: Self.fixtureVessels[0]))
        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.frame.width > window.frame.height }, object: nil)
        if XCTWaiter.wait(for: [rotated], timeout: 20) != .completed {
            if BoatARUITests.isDuo {
                throw XCTSkip("Duo cover screen does not rotate in the simulator: \(window.frame.size)")
            }
            XCTFail("app did not rotate to landscape: \(window.frame.size)")
            return
        }
        let marker = vesselMarker(app, 367000001)
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        marker.tap()
        // The floating card as it shows (its details scroll inside it on a short map).
        assertCardClear(mapCard(app), of: marker, in: app)
        XCTAssertEqual(app.staticTexts["detailTitle"].label, "HARBOR LARK")
        // More info opens the full sheet over the split view.
        app.buttons["moreInfo"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "vesselAISDetails").firstMatch
            .waitForExistence(timeout: 20))
    }
}
