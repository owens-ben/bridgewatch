import XCTest

/// Settings > Data and credits, the one line on the first screen, and the status line saying so when train data is old.
extension BoatARUITests {
    @MainActor
    func testSettingsShowsDataAndCredits() throws {
        let app = launch()
        openSettings(app)
        let row = app.buttons["dataCreditsRow"]
        for _ in 0..<6 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Settings has a Data and credits row")
        XCTAssertEqual(row.label, "Data and credits")
        row.tap()
        XCTAssertTrue(app.navigationBars["Data and credits"].waitForExistence(timeout: 10))

        let mta = app.staticTexts["credits-trains-1"]
        XCTAssertTrue(mta.waitForExistence(timeout: 10))
        XCTAssertEqual(mta.label, "Transit data: MTA. Not affiliated with or endorsed by the MTA. "
                       + "Data provided as is and may be inaccurate, incomplete or delayed.")
        XCTAssertEqual(app.staticTexts["credits-boats-0"].label,
                       "Boat positions come from AIS, the radio signal boats broadcast, by way of aisstream.io.")
        XCTAssertEqual(app.staticTexts["credits-trains-0"].label,
                       "Train positions are estimated from the MTA's real-time arrival predictions.")
        for id in ["creditsLink-boats", "creditsLink-trains"] {
            let link = app.links[id]
            XCTAssertTrue(link.exists || app.buttons[id].exists || app.scrollViews.links[id].exists,
                          "a link with identifier \(id)")
        }
        // The warning is at the end of the page.
        let warning = app.staticTexts["credits-general-0"]
        for _ in 0..<4 where !warning.isHittable { app.swipeUp() }
        XCTAssertEqual(warning.label, "Positions can be late or wrong. Don't use this app for navigation or safety.")
    }

    @MainActor
    func testFirstScreenSaysWhereTheDataComesFrom() throws {
        let app = launch(sensors: nil, onboardingDone: false)
        let line = app.staticTexts["permissionsDataLine"]
        XCTAssertTrue(line.waitForExistence(timeout: 20))
        XCTAssertEqual(line.label, "Positions come from public feeds and can be late or wrong.")
    }

    /// A train stamped `secondsAgo` seconds before `now`, the boats as in the fixture.
    func messages(trainSecondsAgo: TimeInterval) -> [String] {
        let now = Date()
        let stamp = now.addingTimeInterval(-trainSecondsAgo)
            .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let train = #"{"id":"train:nyct:Q1","kind":"train","source":"mta-subway","lat":40.7075,"lon":-73.9905,"#
            + #""altitude":41,"speed":18,"course":340,"timestamp":"\#(stamp)","#
            + #""train":{"route":"Q","direction":"N","destination":"96 St","stretch":"manhattan-bridge","underground":false}}"#
        let targets = (vessels.map { json($0, now: now) } + [train]).joined(separator: ",")
        return [#"{"type":"snapshot","targets":[\#(targets)]}"#]
    }

    @MainActor
    func testStaleTrainDataReplacesLive() throws {
        let app = launch(messages: messages(trainSecondsAgo: 120))
        let status = app.staticTexts["feedStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        waitUntil(status, "label BEGINSWITH 'Trains last updated 2 min ago'", "the status line says the trains are late")
        XCTAssertFalse(status.label.contains("Boats"), "the boats are fresh: \(status.label)")
    }

    @MainActor
    func testFreshTrainDataStaysLive() throws {
        let app = launch(messages: messages(trainSecondsAgo: 10))
        waitForLabel(app.staticTexts["feedStatus"], "Live")
    }
}

/// Screenshots of Data and credits (light, dark, largest text, night) and of the late-data notice, for the design
/// review. Opt-in with the screenshot tour's switch (TEST_RUNNER_BOATAR_SCREENSHOT_TOUR=1).
extension BoatARUITests {
    @MainActor
    func testCreditsScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOATAR_SCREENSHOT_TOUR"] == "1",
                          "Set TEST_RUNNER_BOATAR_SCREENSHOT_TOUR=1 to take the screenshots")
        let device = (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "device")
            .replacingOccurrences(of: " ", with: "")
        addTeardownBlock { XCUIDevice.shared.appearance = .light }
        let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        let looks: [(String, XCUIDevice.Appearance, [String])] = [
            ("light", .light, ["-nightMode", "off"]),
            ("dark", .dark, ["-nightMode", "off"]),
            ("dark-AX5", .dark, ["-nightMode", "off"] + largestText),
            ("night", .dark, ["-nightMode", "on"]),
        ]
        for (name, appearance, arguments) in looks {
            XCUIDevice.shared.appearance = appearance
            let app = launch(arguments: arguments)
            openSettings(app)
            let row = app.buttons["dataCreditsRow"]
            for _ in 0..<8 where !row.isHittable { app.swipeUp() }
            row.tap()
            _ = app.staticTexts["credits-trains-1"].waitForExistence(timeout: 10)
            sleep(1)
            attach(app, "\(device)-credits-\(name)")
            app.swipeUp()
            sleep(1)
            attach(app, "\(device)-credits-\(name)-end")
            app.terminate()
        }
        XCUIDevice.shared.appearance = .light
        let app = launch(messages: messages(trainSecondsAgo: 120), arguments: ["-nightMode", "off"])
        _ = app.staticTexts["feedStatus"].waitForExistence(timeout: 20)
        waitUntil(app.staticTexts["feedStatus"], "label BEGINSWITH 'Trains last updated'", "late notice")
        sleep(1)
        attach(app, "\(device)-stale-notice")
        app.terminate()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
