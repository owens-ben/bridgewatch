import XCTest

/// Design-review tour: every screen and state (Settings included) in light, dark, the largest accessibility text size
/// and night mode, saved as screenshots in the test results. Night mode is pinned per variant (off for the first
/// three, on for the last): Automatic follows the clock, so after sunset the day shots would come out red. Skipped
/// unless asked for, so CI doesn't pay for it:
///
///     TEST_RUNNER_BOATAR_SCREENSHOT_TOUR=1 xcodebuild test -scheme BoatAR \
///       -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
///       -only-testing:BoatARUITests/BoatARUITests/testScreenshotTour
///     xcrun xcresulttool export attachments --path <result.xcresult> --output-path tour/
extension BoatARUITests {
    @MainActor
    func testScreenshotTour() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOATAR_SCREENSHOT_TOUR"] == "1",
                          "Set TEST_RUNNER_BOATAR_SCREENSHOT_TOUR=1 to run the screenshot tour")
        let device = (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "device")
            .replacingOccurrences(of: " ", with: "")
        let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        // Argument-domain defaults: they pin Night mode for the launch without touching what Settings stored.
        let nightOff = ["-nightMode", "off"]
        let nightOn = ["-nightMode", "on"]

        // The simulator keeps its appearance after the run, so put it back to light at the end, failure or not.
        addTeardownBlock { XCUIDevice.shared.appearance = .light }

        XCUIDevice.shared.appearance = .light
        tour("\(device)-light", arguments: nightOff)
        XCUIDevice.shared.appearance = .dark
        tour("\(device)-dark", arguments: nightOff)
        tour("\(device)-dark-AX5", arguments: nightOff + largestText)
        tour("\(device)-night", arguments: nightOn)
    }

    @MainActor
    private func tour(_ prefix: String, arguments: [String]) {
        func shot(_ app: XCUIApplication, _ name: String) {
            sleep(1)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(prefix)-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        var app = launch(sensors: nil, onboardingDone: false, arguments: arguments)
        _ = app.staticTexts["permissionsTitle"].waitForExistence(timeout: 10)
        shot(app, "01-permissions")
        app.terminate()

        app = launch(sensors: Self.facingNortheast, arguments: arguments)
        _ = app.staticTexts["vesselCount"].waitForExistence(timeout: 10)
        shot(app, "02-list")
        app.swipeUp()
        shot(app, "03-list-scrolled")
        app.terminate()

        app = launch(sensors: Self.facingNortheast, arguments: arguments)
        let row = app.buttons["vesselRow-367000002"]
        if row.waitForExistence(timeout: 10) {
            row.tap()
            _ = app.staticTexts["detailTitle"].waitForExistence(timeout: 10)
            shot(app, "04-detail")
        }
        app.terminate()

        app = launch(sensors: Self.facingNortheast, arguments: arguments)
        let map = app.buttons["Map"].firstMatch
        if map.waitForExistence(timeout: 10) {
            map.tap()
            sleep(2)
            shot(app, "05-map")
        }
        app.terminate()

        app = launch(sensors: Self.facingNortheast, arguments: arguments)
        let card = app.buttons["closestCard"]
        if card.waitForExistence(timeout: 10) {
            card.tap()
            _ = app.buttons["mapCardTitle"].waitForExistence(timeout: 10)
            sleep(1)
            shot(app, "06-map-selected")
        }
        app.terminate()

        app = launch(sensors: Self.facingNortheast, arguments: arguments)
        openCamera(app)
        _ = app.staticTexts["compassHeading"].waitForExistence(timeout: 10)
        shot(app, "07-camera")
        app.terminate()

        app = launch(sensors: "40.7046,-73.9913,36,0,15", arguments: arguments)
        openCamera(app)
        _ = app.staticTexts["accuracyPill"].waitForExistence(timeout: 10)
        shot(app, "08-camera-accuracy")
        app.terminate()

        app = launch(Array(vessels.prefix(3)), offline: true, sensors: Self.facingNortheast, arguments: arguments)
        _ = app.otherElements["offlineBanner"].waitForExistence(timeout: 10)
        shot(app, "09-offline")
        app.terminate()

        app = launch([], sensors: Self.facingNortheast, arguments: arguments)
        _ = app.staticTexts["emptyTitle"].waitForExistence(timeout: 10)
        shot(app, "10-empty")
        app.terminate()

        XCUIApplication().resetAuthorizationStatus(for: .location)
        app = launch(sensors: "none,none,36,0,5", arguments: arguments)
        _ = app.staticTexts["vesselCount"].waitForExistence(timeout: 10)
        shot(app, "11-no-location")
        openCamera(app)
        sleep(1)
        shot(app, "12-camera-no-location")
        app.terminate()

        app = launch(sensors: Self.facingNortheast, arguments: arguments)
        let gear = app.buttons["settingsButton"]
        if gear.waitForExistence(timeout: 10) {
            gear.tap()
            _ = app.navigationBars["Settings"].waitForExistence(timeout: 10)
            shot(app, "13-settings")
        }
        app.terminate()
    }
}

/// The trains' screens for the design review, in the same four looks as the tour: the list scrolled to the trains
/// (underground group open), a train's details, the map, and the camera facing the Manhattan Bridge with x-ray labels
/// below. Opt-in with the tour's switch, and runnable on its own:
///
///     TEST_RUNNER_BOATAR_SCREENSHOT_TOUR=1 xcodebuild test -scheme BoatAR \
///       -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
///       -only-testing:BoatARUITests/BoatARUITests/testTrainScreenshotTour
extension BoatARUITests {
    @MainActor
    func testTrainScreenshotTour() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOATAR_SCREENSHOT_TOUR"] == "1",
                          "Set TEST_RUNNER_BOATAR_SCREENSHOT_TOUR=1 to run the screenshot tour")
        let device = (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "device")
            .replacingOccurrences(of: " ", with: "")
        let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        addTeardownBlock { XCUIDevice.shared.appearance = .light }

        XCUIDevice.shared.appearance = .light
        trainTour("\(device)-light", arguments: ["-nightMode", "off"])
        XCUIDevice.shared.appearance = .dark
        trainTour("\(device)-dark", arguments: ["-nightMode", "off"])
        trainTour("\(device)-dark-AX5", arguments: ["-nightMode", "off"] + largestText)
        trainTour("\(device)-night", arguments: ["-nightMode", "on"])
    }

    @MainActor
    private func trainTour(_ prefix: String, arguments: [String]) {
        func shot(_ app: XCUIApplication, _ name: String) {
            sleep(1)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(prefix)-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        var app = launchWithTrains(arguments: arguments)
        let toggle = app.buttons["undergroundToggle"]
        if reveal(toggle, in: app) {
            toggle.tap()
            app.swipeUp()
            shot(app, "t1-list-trains")
            app.swipeUp()
            shot(app, "t2-list-underground")
        }
        app.terminate()

        app = launchWithTrains(arguments: arguments)
        let row = app.buttons["trainRow-\(Self.trainID("Q1"))"]
        if reveal(row, in: app) {
            row.tap()
            _ = app.staticTexts["detailTitle"].waitForExistence(timeout: 10)
            shot(app, "t3-train-detail")
        }
        app.terminate()

        app = launchWithTrains(arguments: arguments)
        let map = app.buttons["Map"].firstMatch
        if map.waitForExistence(timeout: 10) {
            map.tap()
            sleep(2)
            shot(app, "t4-map")
        }
        app.terminate()

        app = launchWithTrains(Self.fixtureTrains + [Self.underTheBridge], arguments: arguments,
                               environment: Self.zoomedOnTheBridge)
        let zoomed = app.buttons["Map"].firstMatch
        if zoomed.waitForExistence(timeout: 10) {
            zoomed.tap()
            sleep(3)
            shot(app, "t4b-map-zoomed")
        }
        app.terminate()

        app = launchWithTrains(arguments: arguments)
        openCamera(app)
        _ = app.buttons["arLabel-\(Self.trainID("Q1"))"].waitForExistence(timeout: 20)
        shot(app, "t5-camera")
        app.terminate()
    }
}

/// The map key and a First responder marker for the design review, in light, dark, night and (the key only) the
/// largest accessibility text size: the key sheet top and bottom, and the map zoomed in on the boats with the
/// First responder marker unselected and selected. Opt-in with the tour's switch:
///
///     TEST_RUNNER_BOATAR_SCREENSHOT_TOUR=1 UITEST_EXPORT_ATTACHMENTS=1 \
///       scripts/ui-test.sh only BoatARUITests/testMapKeyScreenshotTour --both
extension BoatARUITests {
    @MainActor
    func testMapKeyScreenshotTour() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOATAR_SCREENSHOT_TOUR"] == "1",
                          "Set TEST_RUNNER_BOATAR_SCREENSHOT_TOUR=1 to run the screenshot tour")
        let device = (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "device")
            .replacingOccurrences(of: " ", with: "")
        let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        addTeardownBlock { XCUIDevice.shared.appearance = .light }

        XCUIDevice.shared.appearance = .light
        mapKeyTour("\(device)-light", arguments: ["-nightMode", "off"])
        mapKeyTour("\(device)-light-AX5", arguments: ["-nightMode", "off"] + largestText, keyOnly: true)
        XCUIDevice.shared.appearance = .dark
        mapKeyTour("\(device)-dark", arguments: ["-nightMode", "off"])
        mapKeyTour("\(device)-night", arguments: ["-nightMode", "on"])
    }

    @MainActor
    private func mapKeyTour(_ prefix: String, arguments: [String], keyOnly: Bool = false) {
        func shot(_ app: XCUIApplication, _ name: String) {
            sleep(1)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(prefix)-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let app = launch(Self.fixtureVessels + [Self.police], arguments: arguments,
                         environment: ["BOATAR_MAP_REGION": "\(Self.police.lat),\(Self.police.lon),600"])
        openMap(app)
        if !keyOnly {
            sleep(2)
            shot(app, "map-responder")
            let marker = vesselMarker(app, Self.police.mmsi)
            if marker.waitForExistence(timeout: 10) {
                marker.tap()
                _ = app.buttons["mapCardTitle"].waitForExistence(timeout: 10)
                shot(app, "map-responder-selected")
            }
        }
        let key = app.buttons["mapKeyButton"]
        if key.waitForExistence(timeout: 10) {
            key.tap()
            _ = app.descendants(matching: .any).matching(identifier: "mapKey").firstMatch.waitForExistence(timeout: 10)
            shot(app, "key-top")
            // The key opens at medium height: pull it up, then scroll to its end.
            app.descendants(matching: .any).matching(identifier: "mapKey").firstMatch.swipeUp()
            shot(app, "key-large")
            for _ in 0..<3 { app.descendants(matching: .any).matching(identifier: "mapKey").firstMatch.swipeUp() }
            shot(app, "key-bottom")
        }
        app.terminate()
    }
}
