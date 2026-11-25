import XCTest

/// The walk-through that scripts/record-demo.sh films for the README: the list, a boat selected on the map, the camera.
/// It only drives the app (taps and pauses, about 20 seconds, animations on); the recording is made outside, by
/// `xcrun simctl io <device> recordVideo`. Opt-in with `TEST_RUNNER_BOATAR_DEMO=1`, so no normal run pays for it.
extension BoatARUITests {
    @MainActor
    func testDemoWalkthrough() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOATAR_DEMO"] == "1",
                          "Set TEST_RUNNER_BOATAR_DEMO=1 to run the demo walk-through")
        let app = launch(sensors: Self.facingNortheast, arguments: ["-nightMode", "off"], environment: ["BOATAR_FAKE_HEADING_SWEEP": "1"])
        _ = app.staticTexts["vesselCount"].waitForExistence(timeout: 20)
        sleep(4)

        // Tapping the closest card on the list opens the map with that boat selected.
        let card = app.buttons["closestCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        _ = app.buttons["mapCardTitle"].waitForExistence(timeout: 10)
        sleep(5)

        openCamera(app)
        _ = app.staticTexts["compassHeading"].waitForExistence(timeout: 10)
        sleep(7)
    }
}

/// The stills the README needs that the screenshot tours don't take: the regular-width layout (list beside the map,
/// what the iPhone Duo shows unfolded) with a boat selected, in light. The Duo simulator has only the cover screen, so
/// the layout is forced on the iPhone 18 Pro in landscape. Opt-in with the tour's switch:
///
///     UITEST_EXPORT_ATTACHMENTS=1 TEST_RUNNER_BOATAR_SCREENSHOT_TOUR=1 scripts/ui-test.sh only BoatARUITests/testReadmeStills
extension BoatARUITests {
    @MainActor
    func testReadmeStills() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOATAR_SCREENSHOT_TOUR"] == "1",
                          "Set TEST_RUNNER_BOATAR_SCREENSHOT_TOUR=1 to take the screenshots")
        try XCTSkipIf(Self.isDuo, "The Duo cover screen cannot show the unfolded layout")
        func shot(_ name: String) {
            sleep(2)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "readme-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCUIDevice.shared.appearance = .light
        addTeardownBlock { XCUIDevice.shared.appearance = .light; XCUIDevice.shared.orientation = .portrait }
        let app = launchWithTrains(regular: true, arguments: ["-nightMode", "off"],
                                   environment: ["BOATAR_MAP_REGION": "40.7062,-73.9925,1400"])
        try rotateForSideBySide(app)
        _ = app.staticTexts["vesselCount"].waitForExistence(timeout: 20)
        shot("side-by-side")
        let card = app.buttons["closestCard"]
        if card.waitForExistence(timeout: 10) {
            card.tap()
            sleep(2)
            shot("side-by-side-selected")
        }
        app.terminate()
    }
}
