import XCTest

/// Screenshots of every screen the beta fixes changed (docs/CHAOS-FINDINGS.md and the dogfood report), in light, dark,
/// night and the largest accessibility text size: the closest card on an unnamed boat of type Other and on a long
/// name, the offline banner and the camera's offline notice, the camera filter menu, Settings (night mode Off,
/// Version, Server), the train list and a train's sheet, the compass on a lettered mark, the map card at the largest
/// size, and side by side in landscape (iPhone 18 Pro only). Opt-in with the tour's switch:
///
///     TEST_RUNNER_BOATAR_SCREENSHOT_TOUR=1 UITEST_EXPORT_ATTACHMENTS=1 \
///       scripts/ui-test.sh only BoatARUITests/testBetaFixesScreenshotTour --both
extension BoatARUITests {
    /// The closest boat in sight is unnamed, of no type (Other's grey card), and not moving.
    static let unnamedClosest = [
        FixtureVessel(mmsi: 367000013, name: nil, type: nil, lat: 40.7055, lon: -73.9905, sog: 0, secondsAgo: 5),
    ] + fixtureVessels
    /// A moving boat with a long name, closest.
    static let longNameClosest = [
        FixtureVessel(mmsi: 367000014, name: "NEW YORK WATER TAXI CAPTAIN ELEANOR ROOSEVELT THE SECOND", type: 70,
                      lat: 40.7055, lon: -73.9905, sog: 6, secondsAgo: 5),
    ] + fixtureVessels

    @MainActor
    func testBetaFixesScreenshotTour() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOATAR_SCREENSHOT_TOUR"] == "1",
                          "Set TEST_RUNNER_BOATAR_SCREENSHOT_TOUR=1 to run the screenshot tour")
        let device = (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "device")
            .replacingOccurrences(of: " ", with: "")
        let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        addTeardownBlock {
            XCUIDevice.shared.appearance = .light
            XCUIDevice.shared.orientation = .portrait
        }
        XCUIDevice.shared.appearance = .light
        betaTour("\(device)-light", arguments: ["-nightMode", "off"])
        betaTour("\(device)-light-AX5", arguments: ["-nightMode", "off"] + largestText, short: true)
        XCUIDevice.shared.appearance = .dark
        betaTour("\(device)-dark", arguments: ["-nightMode", "off"])
        betaTour("\(device)-night", arguments: ["-nightMode", "on"], short: true)
        XCUIDevice.shared.appearance = .light
        sideBySideShot("\(device)-light")
    }

    @MainActor
    private func betaTour(_ prefix: String, arguments: [String], short: Bool = false) {
        func shot(_ app: XCUIApplication, _ name: String) {
            sleep(1)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(prefix)-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        var app = launch(Self.unnamedClosest, sensors: Self.facingNortheast, arguments: arguments)
        _ = app.buttons["closestCard"].waitForExistence(timeout: 10)
        shot(app, "b01-closest-unnamed-other")
        app.terminate()

        app = launch(Self.longNameClosest, sensors: Self.facingNortheast, arguments: arguments)
        _ = app.buttons["closestCard"].waitForExistence(timeout: 10)
        shot(app, "b02-closest-long-name")
        app.terminate()

        app = launch(Array(vessels.prefix(3)), offline: true, sensors: Self.facingNortheast, arguments: arguments)
        _ = app.otherElements["offlineBanner"].waitForExistence(timeout: 10)
        shot(app, "b03-offline-list")
        openCamera(app)
        _ = app.descendants(matching: .any).matching(identifier: "cameraOffline").firstMatch.waitForExistence(timeout: 10)
        shot(app, "b04-offline-camera")
        app.terminate()

        // The compass on a lettered mark (NE 45°): the needle above the letter.
        app = launch(sensors: "40.7046,-73.9913,45,0,5", arguments: arguments)
        openCamera(app)
        _ = app.staticTexts["compassHeading"].waitForExistence(timeout: 10)
        shot(app, "b05-camera-compass-NE")
        let filter = app.descendants(matching: .any).matching(identifier: "cameraFilterButton").firstMatch
        if filter.waitForExistence(timeout: 10) {
            filter.tap()
            sleep(1)
            shot(app, "b06-camera-filter-menu")
        }
        app.terminate()

        // A selected boat's map card (at the largest size, More info in the header).
        app = launch(sensors: Self.facingNortheast, arguments: arguments)
        openMap(app)
        let marker = vesselMarker(app, 367000001)
        if marker.waitForExistence(timeout: 10) {
            marker.tap()
            _ = app.buttons["mapCardTitle"].waitForExistence(timeout: 10)
            shot(app, "b07-map-card")
        }
        app.terminate()

        if !short {
            app = launch(sensors: Self.facingNortheast, arguments: arguments + ["-nightMode", "off"])
            let gear = app.buttons["settingsButton"]
            if gear.waitForExistence(timeout: 10) {
                gear.tap()
                _ = app.navigationBars["Settings"].waitForExistence(timeout: 10)
                shot(app, "b08-settings-top")
                for _ in 0..<3 { app.swipeUp() }
                shot(app, "b09-settings-server")
                for _ in 0..<3 { app.swipeUp() }
                shot(app, "b10-settings-about")
            }
            app.terminate()
        }

        app = launchWithTrains(arguments: arguments)
        let toggle = app.buttons["undergroundToggle"]
        if reveal(toggle, in: app) {
            if (toggle.value as? String) != "Expanded" { toggle.tap() }
            app.swipeUp()
            shot(app, "b11-trains-underground")
        }
        app.terminate()

        app = launchWithTrains(arguments: arguments)
        let row = app.buttons["trainRow-\(Self.trainID("Q1"))"]
        if reveal(row, in: app) {
            row.tap()
            _ = app.staticTexts["detailTitle"].waitForExistence(timeout: 10)
            shot(app, "b12-train-detail")
        }
        app.terminate()
    }

    /// Side by side in landscape (forced regular width): the tabs at the list column's foot, the map's legal link clear.
    @MainActor
    private func sideBySideShot(_ prefix: String) {
        guard !Self.isDuo else { return }  // the Duo cover doesn't turn in the simulator
        let app = launch(regular: true, sensors: Self.facingNortheast, arguments: ["-nightMode", "off"])
        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.frame.width > window.frame.height }, object: nil)
        _ = XCTWaiter.wait(for: [rotated], timeout: 20)
        sleep(4)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(prefix)-b13-side-by-side-landscape"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Camera"].firstMatch.tap()
        sleep(2)
        let camera = XCTAttachment(screenshot: app.screenshot())
        camera.name = "\(prefix)-b14-side-by-side-camera"
        camera.lifetime = .keepAlways
        add(camera)
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }
}
