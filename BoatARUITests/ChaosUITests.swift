import XCTest

/// Chaos tests (docs/CHAOS-FINDINGS.md): a seeded monkey and scripted scenarios that try to break the app the way the
/// river, the relay and impatient hands will. Opt-in: they skip unless BOATAR_CHAOS=1, which `scripts/ui-test.sh chaos`
/// (or `--chaos`) sets. Every launch here plays a scripted feed (`ScriptedVesselFeed`, BOATAR_SCRIPTED_FEED), counts
/// main-thread hangs over 2 s (BOATAR_HANG_WATCHDOG) and resets the settings a chaos run may change.
extension BoatARUITests {
    static var chaosEnabled: Bool { ProcessInfo.processInfo.environment["BOATAR_CHAOS"] == "1" }

    func requireChaos() throws {
        try XCTSkipUnless(Self.chaosEnabled, "chaos tests are opt-in: scripts/ui-test.sh chaos (BOATAR_CHAOS=1)")
    }

    // MARK: Script

    /// A `ScriptedVesselFeed` timeline, built step by step.
    struct ChaosScript {
        var steps: [String] = []
        /// Seconds from launch at which the last step runs (approximately: the app starts the feed after launch).
        private(set) var elapsed: Double = 0

        static func string(_ text: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed])
            return String(decoding: data, as: UTF8.self)
        }

        private mutating func add(_ after: Double, _ body: String, repeating: Int = 1) {
            steps.append(#"{"after":\#(after)\#(body.isEmpty ? "" : ",")\#(body)\#(repeating > 1 ? #","repeat":\#(repeating)"# : "")}"#)
            elapsed += after * Double(max(1, repeating))
        }

        mutating func connect(after: Double = 0) { add(after, #""event":"connect""#) }
        mutating func disconnect(after: Double) { add(after, #""event":"disconnect""#) }
        /// The server refuses the app (401/403): the feed's `.rejected`.
        mutating func reject(after: Double = 0) { add(after, #""event":"reject""#) }
        mutating func wait(_ seconds: Double) { add(seconds, "") }
        /// A relay message (JSON); with `age`, its targets are restamped that many seconds before it is sent.
        mutating func message(_ json: String, after: Double = 0, age: Double? = nil, repeating: Int = 1) {
            add(after, #""message":\#(json)\#(age.map { #","age":\#($0)"# } ?? "")"#, repeating: repeating)
        }
        /// A raw frame, decoded like the relay's (skipped when it doesn't decode).
        mutating func frame(_ raw: String, after: Double = 0, age: Double? = nil) {
            add(after, #""frame":\#(Self.string(raw))\#(age.map { #","age":\#($0)"# } ?? "")"#)
        }
        mutating func crowd(vessels: Int, trains: Int, nameLength: Int = 0, seed: Int = 1, after: Double = 0) {
            add(after, #""synthetic":{"vessels":\#(vessels),"trains":\#(trains),"nameLength":\#(nameLength),"seed":\#(seed)}"#)
        }

        var json: String { "[" + steps.joined(separator: ",") + "]" }
    }

    static let placeholderStamp = "2026-01-01T00:00:00.000Z"

    /// A vessel target with a placeholder timestamp (scripts restamp it with `age`).
    func chaosVessel(_ mmsi: Int, name: String?, lat: Double, lon: Double, sog: Double? = nil, cog: Double? = nil,
                     type: Int? = 60, id: String? = nil, stamp: String = placeholderStamp) -> String {
        var fields = [#""id":"\#(id ?? "vessel:\(mmsi)")","kind":"vessel","source":"aisstream""#]
        if let name { fields.append(#""name":\#(ChaosScript.string(name))"#) }
        fields.append(#""lat":\#(lat),"lon":\#(lon)"#)
        if let sog { fields.append(#""speed":\#(sog)"#) }
        if let cog { fields.append(#""course":\#(cog)"#) }
        fields.append(#""timestamp":"\#(stamp)""#)
        fields.append(#""vessel":{"mmsi":\#(mmsi)\#(type.map { #","shipType":\#($0)"# } ?? "")}"#)
        return "{" + fields.joined(separator: ",") + "}"
    }

    func snapshotJSON(_ targets: [String]) -> String { #"{"type":"snapshot","targets":[\#(targets.joined(separator: ","))]}"# }
    func updateJSON(_ target: String) -> String { #"{"type":"update","target":\#(target)}"# }
    func removeJSON(_ id: String) -> String { #"{"type":"remove","id":"\#(id)"}"# }

    /// The fixture boats as targets, each with its own age (only right at launch: later steps restamp with `age`).
    func fixtureTargets(_ fixture: [FixtureVessel]? = nil) -> [String] {
        (fixture ?? vessels).map { json($0, now: Date()) }
    }

    func fixtureTrainTargets(_ trains: [FixtureTrain] = fixtureTrains) -> [String] {
        trains.map { json($0, now: Date()) }
    }

    /// Hooks every chaos launch gets: the hang watchdog and probes, and the resets for what the monkey may change.
    static let chaosEnvironment = [
        "BOATAR_HANG_WATCHDOG": "1", "BOATAR_CHAOS_PROBE": "1",
        "BOATAR_RESET_NIGHT_MODE": "1", "BOATAR_RESET_RELAY_URL": "1",
    ]

    @MainActor
    func launchChaos(_ script: ChaosScript, sensors: String? = testSensors, regular: Bool = false,
                     arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        var env = Self.chaosEnvironment
        env["BOATAR_SCRIPTED_FEED"] = script.json
        env.merge(environment) { _, new in new }
        return launch(messages: [], regular: regular, sensors: sensors, arguments: arguments, environment: env)
    }

    // MARK: Checks

    /// Waits up to `timeout` for `condition`.
    @discardableResult
    func eventually(_ timeout: TimeInterval = 20, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// The watchdog's count of main-thread hangs over 2 s, or nil when its element can't be read (a sheet covers it).
    @MainActor
    func hangSummary(_ app: XCUIApplication) -> String? {
        let probe = app.descendants(matching: .any).matching(identifier: "hangWatchdog").firstMatch
        guard probe.exists else { return nil }
        return probe.value as? String
    }

    /// The app is still up in the foreground and the watchdog saw no hang.
    @MainActor
    func assertChaosHealthy(_ app: XCUIApplication, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground,
                       "the app isn't running in the foreground (crashed? see the run's crashes/) \(context)",
                       file: file, line: line)
        if let timeline = probeValue(app, "launchTimeline") { print("CHAOS launch timeline: \(timeline)") }
        if let summary = hangSummary(app), let problem = Self.midSessionHang(summary) {
            XCTFail("BOATAR_HANG main thread blocked over 2 s mid-session: \(problem) \(context)", file: file, line: line)
        }
    }

    /// Hangs that began this many seconds after launch or later count; earlier ones are the launch itself (the
    /// simulator's first frame, MapKit's start-up), logged but not failed: see docs/CHAOS-FINDINGS.md.
    static let launchGraceSeconds = 6.0

    /// The watchdog's summary ("hangs=2 max=3.1 at=0.4,12.5") when a hang began after the launch grace; else nil.
    static func midSessionHang(_ summary: String) -> String? {
        guard let at = summary.components(separatedBy: " at=").last, summary.contains(" at=") else {
            return summary.hasPrefix("hangs=0 ") ? nil : summary
        }
        let starts = at.split(separator: ",").compactMap { Double($0) }
        if starts.contains(where: { $0 < launchGraceSeconds }) { print("CHAOS launch stall: \(summary)") }
        return starts.contains { $0 >= launchGraceSeconds } ? summary : nil
    }

    /// A probe element's value (ChaosProbe.swift), or nil when it can't be read.
    @MainActor
    func probeValue(_ app: XCUIApplication, _ identifier: String) -> String? {
        let probe = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        return probe.exists ? probe.value as? String : nil
    }

    @MainActor
    func nightProbe(_ app: XCUIApplication) -> String? {
        let probe = app.descendants(matching: .any).matching(identifier: "nightModeProbe").firstMatch
        return probe.exists ? probe.value as? String : nil
    }

    /// Back to light, portrait and every setting's default, so the next test (or another agent's tool) finds the
    /// simulator as the suite found it.
    @MainActor
    func restoreAfterChaos() {
        XCUIDevice.shared.appearance = .light
        XCUIDevice.shared.orientation = .portrait
        let app = launchChaos(ChaosScript())
        _ = app.wait(for: .runningForeground, timeout: 20)
        app.terminate()
    }

    /// Scrolls the list until `element` exists and is hittable (up, then back down).
    @MainActor
    @discardableResult
    func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for up in [true, false] {
            for _ in 0..<8 where !(element.exists && element.isHittable) {
                if up { app.swipeUp() } else { app.swipeDown() }
            }
        }
        return element.exists && element.isHittable
    }

    /// Closes the detail sheet: its close button, not the map card's under it (both are `closeDetails`).
    @MainActor
    func closeDetailSheet(_ app: XCUIApplication) {
        let buttons = app.buttons.matching(identifier: "closeDetails").allElementsBoundByIndex.filter(\.isHittable)
        let title = app.staticTexts["detailTitle"]
        // The sheet's button sits beside its title.
        let sheet = buttons.min { abs($0.frame.midY - title.frame.midY) < abs($1.frame.midY - title.frame.midY) }
        (sheet ?? app.buttons["closeDetails"].firstMatch).tap()
    }

    // MARK: Hostile frames

    /// Garbage, wrong shapes, unknown kinds, removes of unknown ids, ids that switch kind and huge names: the app keeps
    /// the good data and skips the rest.
    @MainActor
    func testChaosHostileFramesKeepTheAppUp() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets()))
        let stamp = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let hostile = [
            "not json", "{", #"{"type":"snapshot","targets":[{"id":"vessel:1","kind":"vessel""#, "", "null", "[]",
            #"{"type":"bogus"}"#, #"{"type":"snapshot","vessels":[{"mmsi":1,"lat":40.7,"lon":-73.99}]}"#,
            #"{"type":"update","target":{"id":"plane:1","kind":"aircraft","source":"adsb","lat":40.7,"lon":-73.99,"timestamp":"\#(stamp)"}}"#,
            #"{"type":"update","target":{"id":"vessel:5","kind":"vessel","source":"aisstream","lat":"40.7","lon":-73.99,"timestamp":"\#(stamp)","vessel":{"mmsi":5}}}"#,
            #"{"type":"update","target":{"id":"vessel:6","kind":"vessel","source":"aisstream","lat":40.7,"lon":-73.99,"timestamp":"yesterday","vessel":{"mmsi":6}}}"#,
            removeJSON("vessel:999999999"), removeJSON(""),
            // WREN's id comes back as a train target without a train object, then as an unknown kind.
            #"{"type":"update","target":{"id":"vessel:367000003","kind":"train","source":"x","lat":40.7,"lon":-73.99,"timestamp":"\#(stamp)"}}"#,
        ]
        for frame in hostile { script.frame(frame, after: 0.3) }
        // A 10,000-character name full of controls, bidi overrides, zero-width characters, emoji and newlines.
        let nasty = String(repeating: "A\u{202E}B\u{200B}\n\t\u{0007}🚢مركب", count: 1_000)
        script.message(updateJSON(chaosVessel(367000020, name: nasty, lat: 40.7060, lon: -73.9950, sog: 3, cog: 90)),
                       after: 0.3, age: 1)
        script.message(updateJSON(chaosVessel(367000021, name: "LAST GOOD", lat: 40.7058, lon: -73.9960, sog: 2,
                                              cog: 45)), after: 0.5, age: 1)
        let app = launchChaos(script)
        defer { restoreAfterChaos() }

        let lastGood = app.buttons["vesselRow-367000021"]
        XCTAssertTrue(eventually(30) { lastGood.exists }, "the good update after the garbage never arrived")
        // HARBOR LARK, ANNABEL K, MMSI 367000004, the long-named boat and LAST GOOD: WREN's id was taken by the train
        // update (which didn't decode as a train) or kept, depending on how the registry treats an id switching kind.
        let count = app.staticTexts["vesselCount"]
        XCTAssertTrue(["5 vessels", "6 vessels"].contains(count.label), "count after hostile frames: \(count.label)")
        XCTAssertEqual(app.staticTexts["feedStatus"].label, "Live", "a bad frame must not drop the connection")
        // The long name shows cleaned: one line, no controls, inside the screen.
        let long = app.buttons["vesselRow-367000020"]
        XCTAssertTrue(scrollTo(long, in: app), "the long-named boat isn't listed")
        XCTAssertFalse(long.label.contains("\u{202E}") || long.label.contains("\n"), "untrusted text not cleaned")
        XCTAssertLessThanOrEqual(long.frame.width, app.windows.firstMatch.frame.width + 0.5, "row wider than screen")
        long.tap()
        let title = app.staticTexts["detailTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertLessThanOrEqual(title.frame.maxX, app.windows.firstMatch.frame.maxX + 0.5, "title runs off screen")
        app.buttons["closeDetails"].tap()
        assertChaosHealthy(app, "after hostile frames")
    }

    /// A course the relay can send (any finite JSON number) but no compass has: the detail sheet formats it.
    @MainActor
    func testChaosHugeCourseInTheDetailSheet() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets() + [
            chaosVessel(367000030, name: "HUGE COURSE", lat: 40.7071, lon: -73.9893, sog: 0.2, cog: 1e300),
        ]), age: 5)
        let app = launchChaos(script)
        defer { restoreAfterChaos() }
        let row = app.buttons["vesselRow-367000030"]
        XCTAssertTrue(scrollTo(row, in: app), "HUGE COURSE isn't listed")
        row.tap()
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 20), "no detail sheet (crashed?)")
        assertChaosHealthy(app, "after opening a boat with course 1e300")
    }

    /// Positions no AIS receiver near DUMBO can report: north pole, 181° east, latitude and longitude swapped. The
    /// app keeps running and doesn't list them as nearby boats.
    @MainActor
    func testChaosOutOfRangeCoordinates() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets() + [
            chaosVessel(367000040, name: "NORTH POLE", lat: 91, lon: -73.99),
            chaosVessel(367000041, name: "DATE LINE", lat: 40.70, lon: 181),
            chaosVessel(367000042, name: "SWAPPED", lat: -73.99, lon: 40.70),
            chaosVessel(367000043, name: "FAR AWAY", lat: 1e300, lon: -1e300),
        ]), age: 5)
        let app = launchChaos(script)
        defer { restoreAfterChaos() }
        XCTAssertTrue(app.staticTexts["vesselCount"].waitForExistence(timeout: 20))
        sleep(2)
        assertChaosHealthy(app, "with out-of-range positions in the list")
        openMap(app)
        sleep(3)
        assertChaosHealthy(app, "with out-of-range positions on the map")
        app.buttons["Nearby"].firstMatch.tap()
        // The impossible three are rejected (D2, F2). SWAPPED is a real place (Antarctic waters): the app can't tell it
        // from a real boat and lists it out of sight; the relay no longer sends anything outside the area (D7).
        waitForLabel(app.staticTexts["vesselCount"], "5 vessels")
    }

    /// Two relay ids carrying the same MMSI (a boat re-keyed by a newer relay, or a spoofed MMSI): one row, one marker.
    @MainActor
    func testChaosDuplicateMMSIUnderTwoIDs() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets() + [
            chaosVessel(367000050, name: "TWIN A", lat: 40.7060, lon: -73.9945, sog: 1, cog: 10, id: "vessel:twinA"),
            chaosVessel(367000050, name: "TWIN B", lat: 40.7072, lon: -73.9925, sog: 1, cog: 10, id: "vessel:twinB"),
        ]), age: 2)
        // The twins move, so the list and the map diff their rows by id every update.
        for step in 0..<10 {
            script.message(updateJSON(chaosVessel(367000050, name: "TWIN A", lat: 40.7060 + Double(step) * 0.0002,
                                                  lon: -73.9945, sog: 1, cog: 10, id: "vessel:twinA")),
                           after: 1, age: 0)
        }
        let app = launchChaos(script)
        defer { restoreAfterChaos() }
        XCTAssertTrue(app.staticTexts["vesselCount"].waitForExistence(timeout: 20))
        sleep(4)
        let rows = app.buttons.matching(identifier: "vesselRow-367000050")
        XCTAssertEqual(rows.count, 1, "one MMSI, \(rows.count) rows: \(rows.allElementsBoundByIndex.map(\.label))")
        openMap(app)
        sleep(6)
        let markers = app.descendants(matching: .any).matching(identifier: "vesselMarker-367000050")
        XCTAssertEqual(markers.count, 1, "one MMSI, \(markers.count) markers")
        assertChaosHealthy(app, "with two ids for one MMSI")
    }

    // MARK: The relay drops

    @MainActor
    func testChaosRelayDropsForFiveSecondsAndReturns() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets()))
        script.disconnect(after: 8)
        script.connect(after: 5)
        script.message(snapshotJSON(fixtureTargets()), age: 5)
        let app = launchChaos(script)
        defer { restoreAfterChaos() }
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        let banner = app.otherElements["offlineBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "no offline banner when the relay dropped")
        waitForLabel(app.staticTexts["feedStatus"], "Offline")
        XCTAssertEqual(app.staticTexts["vesselCount"].label, "4 vessels", "the list stays frozen while offline")
        waitUntil(banner, "exists == false", "the banner stays after the relay came back", timeout: 30)
        waitForLabel(app.staticTexts["feedStatus"], "Live")
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        assertChaosHealthy(app, "after a 5 s drop")
    }

    /// Gone for a minute, back with different boats: the old ones go, and a sheet open on one that's gone closes.
    @MainActor
    func testChaosRelayReturnsDifferentDataAfterAMinute() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets()))
        script.disconnect(after: 8)
        script.connect(after: 60)
        script.message(snapshotJSON([
            chaosVessel(367000060, name: "NEW ARRIVAL", lat: 40.7060, lon: -73.9940, sog: 4, cog: 200),
            chaosVessel(367000061, name: "SECOND NEW", lat: 40.7064, lon: -73.9920, sog: 0),
        ]), age: 2)
        let app = launchChaos(script)
        defer { restoreAfterChaos() }
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        XCTAssertTrue(app.otherElements["offlineBanner"].waitForExistence(timeout: 30))
        // While offline, open ANNABEL K's sheet: the frozen list still has it (HARBOR LARK is the closest card,
        // which goes to the map instead).
        let row = app.buttons["vesselRow-367000002"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let title = app.staticTexts["detailTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "can't open a frozen boat's sheet")
        // After the return (about 68 s after launch) ANNABEL K is gone: its sheet must not stay up showing it.
        waitUntil(title, "exists == false", "ANNABEL K's sheet stays open after the relay came back without it",
                  timeout: 90)
        waitForLabel(app.staticTexts["vesselCount"], "2 vessels", timeout: 30)
        XCTAssertFalse(app.buttons["vesselRow-367000002"].exists, "a boat the relay no longer has is still listed")
        XCTAssertFalse(app.buttons["closestCard"].label.contains("HARBOR LARK"), "a boat the relay no longer has is closest")
        XCTAssertTrue(app.buttons["vesselRow-367000060"].exists || app.buttons["closestCard"].label.contains("NEW ARRIVAL"))
        XCTAssertFalse(app.otherElements["offlineBanner"].exists)
        assertChaosHealthy(app, "after a minute's drop")
    }

    // MARK: One source stale, the other live

    /// Boats stop reporting (aisstream quiet) while trains keep coming: the boats show as stale, the trains live.
    @MainActor
    func testChaosBoatsStaleWhileTrainsStayLive() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets(vessels.map {
            FixtureVessel(mmsi: $0.mmsi, name: $0.name, type: $0.type, lat: $0.lat, lon: $0.lon, sog: $0.sog,
                          secondsAgo: 30)
        }) + fixtureTrainTargets()))
        for _ in 0..<12 {
            for train in Self.fixtureTrains {
                script.message(updateJSON(json(train, now: Date())), age: 0)
            }
            script.wait(5)
        }
        let app = launchChaos(script)
        defer { restoreAfterChaos() }
        waitForLabel(app.staticTexts["trainCount"], "6 trains")
        // Boats stamped 30 s old turn stale (a minute) about 30 s in.
        let annabel = app.buttons["vesselRow-367000002"]
        XCTAssertTrue(annabel.waitForExistence(timeout: 20))
        XCTAssertTrue(eventually(60) { annabel.label.contains("last report") }, "boats never marked stale: \(annabel.label)")
        XCTAssertEqual(app.staticTexts["feedStatus"].label, "Live", "trains are live, so the feed is")
        waitForLabel(app.staticTexts["trainCount"], "6 trains")
        let q = app.buttons["trainRow-\(Self.trainID("Q1"))"]
        if scrollTo(q, in: app) { XCTAssertFalse(q.label.contains("last position"), "a live train reads stale: \(q.label)") }
        assertChaosHealthy(app, "boats stale, trains live")
    }

    /// The subway source stops (MTA feed down) while boats keep reporting: trains leave after a minute, the status line
    /// says the train data is late, boats stay live.
    @MainActor
    func testChaosTrainsVanishWhileBoatsStayLive() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets() + fixtureTrainTargets().map {
            // Live now (not the fixture's 10 minutes ahead), so they age out.
            $0.replacingOccurrences(of: #""timestamp":"[^"]+""#, with: #""timestamp":"\#(Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))""#,
                                    options: .regularExpression)
        }))
        for _ in 0..<20 {
            script.message(updateJSON(json(vessels[1], now: Date())), age: 2)
            script.wait(5)
        }
        let app = launchChaos(script)
        defer { restoreAfterChaos() }
        waitForLabel(app.staticTexts["trainCount"], "6 trains")
        // Trains are dropped 60 s after their last position.
        XCTAssertTrue(eventually(100) { !app.staticTexts["trainCount"].exists || app.staticTexts["trainCount"].label == "0 trains" },
                      "trains still counted after their source went quiet: \(app.staticTexts["trainCount"].label)")
        XCTAssertFalse(app.buttons["trainRow-\(Self.trainID("Q1"))"].exists, "a train with no position for a minute is listed")
        let annabel = app.buttons["vesselRow-367000002"]
        XCTAssertTrue(annabel.exists)
        XCTAssertFalse(annabel.label.contains("last report"), "a live boat reads stale: \(annabel.label)")
        // The connection is up, but the newest train data is over a minute old: the status line says so (the late-data
        // notice) and says nothing about boats, which are still reporting.
        let status = app.staticTexts["feedStatus"].label
        XCTAssertTrue(status.hasPrefix("Trains last updated"), "no late-data notice with the subway source quiet: \(status)")
        XCTAssertFalse(status.contains("Boats"), "live boats are called late: \(status)")
        assertChaosHealthy(app, "trains gone, boats live")
    }

    // MARK: The selected one disappears

    /// Script: everything at launch, then `vanish` removed `at` seconds in.
    func vanishScript(_ id: String, at seconds: Double, trains: Bool = false) -> ChaosScript {
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets() + (trains ? fixtureTrainTargets() : [])))
        script.message(removeJSON(id), after: seconds)
        return script
    }

    static let vanishAfter: Double = 25

    @MainActor
    func testChaosSelectedBoatVanishesWithItsSheetOpen() throws {
        try requireChaos()
        let app = launchChaos(vanishScript("vessel:367000002", at: Self.vanishAfter))
        defer { restoreAfterChaos() }
        let launched = Date()
        let row = app.buttons["vesselRow-367000002"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let title = app.staticTexts["detailTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertLessThan(Date().timeIntervalSince(launched), Self.vanishAfter - 2, "too slow to open the sheet first")
        waitUntil(title, "exists == false", "ANNABEL K's sheet stays open after the relay removed it", timeout: 40)
        XCTAssertFalse(app.buttons["vesselRow-367000002"].exists)
        waitForLabel(app.staticTexts["vesselCount"], "3 vessels")
        assertChaosHealthy(app, "after the selected boat vanished under its sheet")
    }

    @MainActor
    func testChaosSelectedBoatVanishesWithItsMapCardOpen() throws {
        try requireChaos()
        // Zoomed in: on the whole area the Duo cover's markers overlap, and the tap meant for ANNABEL K selected
        // HARBOR LARK, whose card rightly stayed (the one failure once marked "F?").
        let app = launchChaos(vanishScript("vessel:367000002", at: Self.vanishAfter),
                              environment: ["BOATAR_MAP_REGION": "40.7065,-73.9910,1500"])
        defer { restoreAfterChaos() }
        let launched = Date()
        openMap(app)
        let marker = vesselMarker(app, 367000002)
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        marker.tap()
        let card = mapCard(app)
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["mapCardTitle"].label.hasPrefix("ANNABEL K"), "the tap selected another boat: \(app.buttons["mapCardTitle"].label)")
        XCTAssertLessThan(Date().timeIntervalSince(launched), Self.vanishAfter - 2, "too slow to open the card first")
        waitUntil(card, "exists == false", "the map card stays after its boat vanished", timeout: 40)
        XCTAssertFalse(marker.exists, "the vanished boat's marker is still drawn")
        // The map still selects: a stale selection would leave the next tap doing nothing.
        let other = vesselMarker(app, 367000001)
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        other.tap()
        XCTAssertTrue(mapCard(app).waitForExistence(timeout: 20), "selecting another boat after the vanish shows no card")
        assertChaosHealthy(app, "after the selected boat vanished under its map card")
    }

    @MainActor
    func testChaosSelectedTrainVanishesWithItsSheetOpen() throws {
        try requireChaos()
        let app = launchChaos(vanishScript(Self.trainID("Q1"), at: Self.vanishAfter, trains: true))
        defer { restoreAfterChaos() }
        let launched = Date()
        let row = app.buttons["trainRow-\(Self.trainID("Q1"))"]
        XCTAssertTrue(scrollTo(row, in: app), "the Q isn't listed")
        row.tap()
        let detail = app.descendants(matching: .any).matching(identifier: "trainDetail").firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 20) || app.staticTexts["detailTitle"].exists)
        XCTAssertLessThan(Date().timeIntervalSince(launched), Self.vanishAfter - 2, "too slow to open the sheet first")
        XCTAssertTrue(eventually(40) { !detail.exists && !app.staticTexts["detailTitle"].exists },
                      "the Q's sheet stays open after the relay removed it")
        XCTAssertFalse(row.exists)
        assertChaosHealthy(app, "after the selected train vanished under its sheet")
    }

    @MainActor
    func testChaosFocusedBoatVanishesInTheCamera() throws {
        try requireChaos()
        let app = launchChaos(vanishScript("vessel:367000002", at: Self.vanishAfter),
                              sensors: Self.facingNortheast)
        defer { restoreAfterChaos() }
        let launched = Date()
        let row = app.buttons["vesselRow-367000002"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let find = app.buttons["findInCamera"]
        XCTAssertTrue(find.waitForExistence(timeout: 20))
        find.tap()
        let label = app.descendants(matching: .any).matching(identifier: "arLabel-367000002").firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 20), "the focused boat isn't labelled")
        XCTAssertLessThan(Date().timeIntervalSince(launched), Self.vanishAfter - 2, "too slow to focus first")
        waitUntil(label, "exists == false", "the vanished boat is still labelled in the camera", timeout: 40)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "cameraScreen").firstMatch.exists)
        // The other boat ahead still gets its label.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "arLabel-367000004").firstMatch.exists)
        assertChaosHealthy(app, "after the focused boat vanished in the camera")
    }

    // MARK: Churn

    /// Two boats leapfrog every second: the Closest card follows, and stays a real boat.
    @MainActor
    func testChaosClosestBoatChangesEverySecond() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets()))
        let near = (lat: 40.7050, lon: -73.9925)
        let far = (lat: 40.7066, lon: -73.9950)
        for i in 0..<40 {
            let a = i % 2 == 0 ? near : far
            let b = i % 2 == 0 ? far : near
            script.message(updateJSON(chaosVessel(367000070, name: "LEAP A", lat: a.lat, lon: a.lon, sog: 0)),
                           after: 1, age: 0)
            script.message(updateJSON(chaosVessel(367000071, name: "LEAP B", lat: b.lat, lon: b.lon, sog: 0)), age: 0)
        }
        let app = launchChaos(script)
        defer { restoreAfterChaos() }
        let card = app.buttons["closestCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        var seen = Set<String>()
        let end = Date().addingTimeInterval(25)
        while Date() < end {
            if card.exists {
                let label = card.label
                XCTAssertTrue(label.hasPrefix("Closest: "), "closest card label \(label)")
                if label.hasPrefix("Closest: LEAP A") { seen.insert("A") }
                if label.hasPrefix("Closest: LEAP B") { seen.insert("B") }
            }
            usleep(400_000)
        }
        XCTAssertEqual(seen, ["A", "B"], "the closest card didn't follow the leapfrogging boats")
        // Tapping the card while it changes goes to one of them, never to nothing.
        card.tap()
        let title = app.buttons["mapCardTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the closest card's tap showed no map card")
        XCTAssertTrue(title.label.hasPrefix("LEAP"), title.label)
        assertChaosHealthy(app, "with the closest boat changing every second")
    }

    /// 500 boats and 500 trains at once, then nothing: the list, the map and the camera cope, and end empty.
    @MainActor
    func testChaosThousandTargetsArriveThenVanish() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets()))
        script.crowd(vessels: 500, trains: 500, seed: 3, after: 3)
        script.message(snapshotJSON([]), after: 45)
        let app = launchChaos(script)
        defer { restoreAfterChaos() }
        waitForLabel(app.staticTexts["vesselCount"], "500 vessels", timeout: 30)
        for _ in 0..<3 { app.swipeUp() }
        for _ in 0..<3 { app.swipeDown() }
        openMap(app)
        sleep(3)
        assertChaosHealthy(app, "on the map with 1,000 targets")
        openCamera(app)
        sleep(3)
        assertChaosHealthy(app, "in the camera with 1,000 targets")
        app.buttons["Nearby"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["emptyTitle"].waitForExistence(timeout: 60), "the list didn't empty after the crowd left")
        XCTAssertFalse(app.buttons["closestCard"].exists)
        XCTAssertFalse(app.staticTexts["trainCount"].exists && app.staticTexts["trainCount"].label != "0 trains")
        assertChaosHealthy(app, "after 1,000 targets vanished")
    }

    /// 200-character names with emoji and right-to-left text in rows, cards, sheets and camera labels at the largest
    /// text size: nothing runs off the screen.
    @MainActor
    func testChaosLongNamesAtTheLargestTextSize() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        let long = "VERY LONG NAME " + String(repeating: "🚢 مركب النهر 東河 ", count: 12)
        let name = String(long.prefix(200))
        script.message(snapshotJSON([
            chaosVessel(367000080, name: name, lat: 40.7062, lon: -73.9931, sog: 14.2, cog: 0),
            chaosVessel(367000081, name: name + " 2", lat: 40.7068, lon: -73.9890, sog: 6.8, cog: 90),
        ]), age: 2)
        let app = launchChaos(script, sensors: Self.facingNortheast, arguments: Self.largestText)
        defer { restoreAfterChaos() }
        let window = app.windows.firstMatch.frame
        let card = app.buttons["closestCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(window.insetBy(dx: -0.5, dy: -0.5).contains(CGRect(x: card.frame.minX, y: card.frame.minY,
                                                                         width: card.frame.width, height: 1)),
                      "closest card \(card.frame) wider than the window \(window)")
        card.tap()
        let cardTitle = app.buttons["mapCardTitle"]
        XCTAssertTrue(cardTitle.waitForExistence(timeout: 20))
        let mapCardFrame = mapCard(app).frame
        XCTAssertTrue(window.contains(mapCardFrame), "map card \(mapCardFrame) off screen")
        // At this size "More info" is pinned in the card's header, beside Close (L3): never scrolled out of reach.
        let moreInfo = mapCard(app).buttons["moreInfo"].firstMatch
        XCTAssertTrue(moreInfo.waitForExistence(timeout: 10) && moreInfo.isHittable,
                      "More info isn't reachable in the card at the largest text size (exists: \(moreInfo.exists))")
        if moreInfo.isHittable { moreInfo.tap() } else { cardTitle.tap() }
        let title = app.staticTexts["detailTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(title.frame.minX, window.minX - 0.5)
        XCTAssertLessThanOrEqual(title.frame.maxX, window.maxX + 0.5, "title \(title.frame) runs off \(window)")
        closeDetailSheet(app)
        openCamera(app)
        let label = app.descendants(matching: .any).matching(identifier: "arLabel-367000081").firstMatch
        if label.waitForExistence(timeout: 20) {
            XCTAssertLessThanOrEqual(label.frame.width, window.width, "camera label \(label.frame) wider than the screen")
        }
        assertChaosHealthy(app, "with 200-character names at the largest text size")
    }

    // MARK: Location and compass

    @MainActor
    func testChaosLocationDenied() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets()))
        let app = launchChaos(script, sensors: "none,none,0,0,5")
        defer { restoreAfterChaos() }
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        XCTAssertFalse(app.buttons["closestCard"].exists, "a closest boat without knowing where you are")
        let row = app.buttons["vesselRow-367000002"]
        XCTAssertTrue(scrollTo(row, in: app))
        XCTAssertFalse(row.label.contains("mile") || row.label.contains("feet"), "a distance without a location: \(row.label)")
        openCamera(app)
        sleep(2)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'arLabel-'")).count, 0,
                       "camera labels without a location")
        assertChaosHealthy(app, "with location denied")
    }

    /// The fix jumps 5 km north mid-session (a bad GPS fix, or a train ride): distances and the closest boat follow.
    @MainActor
    func testChaosLocationJumpsFiveKilometers() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets()))
        let app = launchChaos(script, environment: ["BOATAR_FAKE_LOCATION_JUMP": "15,40.7496,-73.9913"])
        defer { restoreAfterChaos() }
        let card = app.buttons["closestCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        let before = card.label
        XCTAssertTrue(eventually(40) { !card.exists || card.label != before },
                      "the closest card didn't change after the location jumped 5 km: \(card.label)")
        if card.exists {
            XCTAssertFalse(card.label.contains("feet"), "still a few feet away after a 5 km jump: \(card.label)")
        }
        assertChaosHealthy(app, "after a 5 km location jump")
    }

    @MainActor
    func testChaosReducedAccuracy() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets()))
        let app = launchChaos(script, environment: ["BOATAR_FAKE_REDUCED_ACCURACY": "1"])
        defer { restoreAfterChaos() }
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        openCamera(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "preciseLocationPill").firstMatch
            .waitForExistence(timeout: 20), "no precise-location pill with approximate location")
        assertChaosHealthy(app, "with approximate location")
    }

    @MainActor
    func testChaosNoCompassHeading() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets()))
        let app = launchChaos(script, sensors: "40.7046,-73.9913,none,0,5")
        defer { restoreAfterChaos() }
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        openCamera(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "cameraScreen").firstMatch.waitForExistence(timeout: 20))
        sleep(2)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'arLabel-'")).count, 0,
                       "labels placed without a heading")
        let guidance = app.descendants(matching: .any).matching(identifier: "cameraGuidance").firstMatch
        XCTAssertTrue(guidance.exists, "nothing tells the user the compass has no heading")
        assertChaosHealthy(app, "with no compass heading")
    }

    @MainActor
    func testChaosHeadingSpinsFast() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets() + fixtureTrainTargets()))
        let app = launchChaos(script, environment: ["BOATAR_FAKE_HEADING_SPIN": "720"])
        defer { restoreAfterChaos() }
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        openCamera(app)
        let heading = app.descendants(matching: .any).matching(identifier: "compassHeading").firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 20))
        var readings = Set<String>()
        for _ in 0..<10 {
            readings.insert(heading.label)
            usleep(700_000)
        }
        XCTAssertGreaterThan(readings.count, 3, "the heading didn't follow the spin: \(readings)")
        sleep(5)
        assertChaosHealthy(app, "with the heading spinning at 720°/s")
    }

    // MARK: Time

    /// Report ages are durations: a time zone 14 hours ahead doesn't change "3 minutes ago".
    @MainActor
    func testChaosTimeZoneDoesNotChangeAges() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets()))
        let app = launchChaos(script, environment: ["TZ": "Pacific/Kiritimati"])
        defer { restoreAfterChaos() }
        // WREN reported 190 s ago: stale, so its row says how old.
        let wren = app.buttons["vesselRow-367000003"]
        XCTAssertTrue(scrollTo(wren, in: app))
        XCTAssertTrue(wren.label.contains("last report 3 minutes ago"), wren.label)
        let harbor = app.buttons["vesselRow-367000001"]
        if harbor.exists { XCTAssertFalse(harbor.label.contains("hour"), harbor.label) }
        assertChaosHealthy(app, "in UTC+14")
    }

    /// Automatic night mode turns on at sunset while the app is open, with a sheet up, and nothing breaks. The clock
    /// starts 20 s before the app's own sunset for the test location on 2026-11-18 (21:35:35 UTC, `SunPosition`).
    @MainActor
    func testChaosNightModeTurnsOnAtSunsetMidSession() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets()))
        let app = launchChaos(script, environment: ["BOATAR_NIGHT_CLOCK_START": "2026-11-18T21:35:15Z"])
        defer { restoreAfterChaos() }
        waitForLabel(app.staticTexts["vesselCount"], "4 vessels")
        XCTAssertEqual(nightProbe(app), "off", "night mode on before sunset")
        let row = app.buttons["vesselRow-367000002"]
        row.tap()
        let title = app.staticTexts["detailTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        sleep(25)
        XCTAssertTrue(title.exists, "the sheet closed when night mode came on")
        app.buttons["closeDetails"].tap()
        XCTAssertTrue(eventually(30) { self.nightProbe(app) == "on" }, "night mode didn't come on at sunset: \(nightProbe(app) ?? "nil")")
        assertChaosHealthy(app, "across sunset")
    }

    // MARK: Map

    /// 20 taps on markers in about 3 s: the card ends on the last one tapped, clear of its marker.
    @MainActor
    func testChaosRapidSelectionOnTheMap() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets()))
        let app = launchChaos(script)
        defer { restoreAfterChaos() }
        openMap(app)
        let mmsis = [367000001, 367000002, 367000004, 367000003]
        for mmsi in mmsis { XCTAssertTrue(vesselMarker(app, mmsi).waitForExistence(timeout: 20)) }
        let window = app.windows.firstMatch
        let points = mmsis.map { mmsi -> CGPoint in
            let frame = vesselMarker(app, mmsi).frame
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        let start = Date()
        for i in 0..<20 {
            let point = points[i % points.count]
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        }
        print("CHAOS 20 marker taps took \(Date().timeIntervalSince(start)) s")
        if app.staticTexts["detailTitle"].exists { closeDetailSheet(app) }
        sleep(3)
        assertChaosHealthy(app, "after 20 fast taps on the map")
        let card = mapCard(app)
        guard card.waitForExistence(timeout: 10) else { return }  // the last tap may have deselected: allowed
        let title = app.buttons["mapCardTitle"].label
        let names = [367000001: "HARBOR LARK", 367000002: "ANNABEL K", 367000003: "WREN", 367000004: "Unnamed boat"]
        let selected = try XCTUnwrap(names.first { title.hasPrefix($0.value) }?.key, "card for an unknown boat: \(title)")
        assertCardClear(card, of: vesselMarker(app, selected), in: app)
    }

    /// The card stays on a selected boat that the filter now hides (a selected target is always shown), and units
    /// change under an open sheet's list.
    @MainActor
    func testChaosUnitsAndFiltersChangeWithASheetOpen() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets()))
        // Zoomed in: on the Duo cover's whole-area map the markers overlap and the tap can select a neighbour.
        let app = launchChaos(script, environment: ["BOATAR_MAP_REGION": "40.7065,-73.9910,1500"])
        defer { restoreAfterChaos() }
        openMap(app)
        let marker = vesselMarker(app, 367000004)  // no speed, no type: hidden by Moving only and by Other
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        marker.tap()
        XCTAssertTrue(mapCard(app).waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["mapCardTitle"].label.hasPrefix("Unnamed boat"),
                      "the tap selected another boat: \(app.buttons["mapCardTitle"].label)")
        let button = app.descendants(matching: .any).matching(identifier: "mapFilterButton").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        button.tap()
        menuItem(app, "listMovingOnly", "Moving only").tap()
        sleep(1)
        let afterMoving = (card: mapCard(app).exists, marker: marker.exists)
        menuItem(app, "listType-vessel.other", "Other").tap()
        sleep(1)
        let afterType = (card: mapCard(app).exists, marker: marker.exists)
        // Closed with the filter button itself (a tap on the map could be taken as deselecting).
        if button.isHittable { button.tap() } else { closeListFilter(app) }
        waitUntil(filterMenuMarker(app), "exists == false", "the filter menu didn't close")
        sleep(1)
        XCTAssertTrue(mapCard(app).exists && marker.exists,
                      "the selected boat was dropped by the filter: after Moving only card \(afterMoving.card) marker "
                      + "\(afterMoving.marker); after Other card \(afterType.card) marker \(afterType.marker); after closing "
                      + "card \(mapCard(app).exists) marker \(marker.exists); selection log: "
                      + (probeValue(app, "selectionLog") ?? "unreadable"))
        print("CHAOS selection log: \(probeValue(app, "selectionLog") ?? "unreadable")")
        // Deselect: now the filter applies.
        app.buttons["closeDetails"].firstMatch.tap()
        waitUntil(marker, "exists == false", "a boat the filter hides stays on the map after deselecting")
        // Units under the list while it is open in another tab.
        app.buttons["Nearby"].firstMatch.tap()
        chooseUnit(app, picker: "unitsSpeedPicker", "Kilometers per hour")
        let annabel = app.buttons["vesselRow-367000002"]
        XCTAssertTrue(annabel.waitForExistence(timeout: 20))
        waitUntil(annabel, "label CONTAINS 'kilometers per hour'", "units didn't apply: \(annabel.label)")
        assertChaosHealthy(app, "after units and filters changed with a card up")
    }

    /// S3: a server that turns the app away (a rejected token) gets its own banner, not "can't reach", on the list
    /// and a notice in the camera; the last boats stay listed.
    @MainActor
    func testChaosRejectedTokenShowsItsOwnBanner() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets()))
        script.disconnect(after: 2)
        script.reject(after: 0.5)
        let app = launchChaos(script)
        defer { restoreAfterChaos() }
        let banner = app.otherElements["offlineBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 30))
        waitUntil(banner.staticTexts["offlineTitle"], "label == \"The server didn't accept this app\"",
                  "the rejected banner: \(banner.staticTexts["offlineTitle"].label)")
        XCTAssertTrue(app.buttons["vesselRow-367000002"].exists, "the last boats stay listed")
        openCamera(app)
        let notice = app.descendants(matching: .any).matching(identifier: "cameraOffline").firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "the camera says it too")
        assertChaosHealthy(app, "after a rejected token")
    }

    /// Side by side (forced regular width) while boats move every half second and a crowd arrives.
    @MainActor
    func testChaosSideBySideWhileTheFeedChurns() throws {
        try requireChaos()
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets() + fixtureTrainTargets()))
        for i in 0..<60 {
            script.message(updateJSON(chaosVessel(367000002, name: "ANNABEL K", lat: 40.7068 + Double(i % 10) * 0.0003,
                                                  lon: -73.9890, sog: 6.8, cog: 0, type: 52)), after: 0.5, age: 0)
            if i == 20 { script.crowd(vessels: 120, trains: 60, seed: 9) }
        }
        let app = launchChaos(script, regular: true)
        defer { restoreAfterChaos() }
        try rotateForSideBySide(app)
        let row = app.buttons["vesselRow-367000002"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let map = app.descendants(matching: .any).matching(identifier: "vesselMap").firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 20))
        for i in 0..<6 {
            if i % 2 == 0 { map.swipeLeft() } else { map.swipeRight() }
            map.pinch(withScale: i % 2 == 0 ? 0.7 : 1.4, velocity: i % 2 == 0 ? -1 : 1)
        }
        sleep(5)
        assertChaosHealthy(app, "side by side while the feed churned")
        XCTAssertTrue(app.buttons["Camera"].firstMatch.exists, "tabs gone after churn")
    }

    /// The fake trailing column (like the Duo's status column) on, then off: the map buttons move and the card keeps
    /// clear of them either way.
    @MainActor
    func testChaosFakeTrailingColumnOnAndOff() throws {
        try requireChaos()
        for column in ["90", nil] as [String?] {
            var script = ChaosScript()
            script.connect()
            script.message(snapshotJSON(fixtureTargets()))
            var env: [String: String] = [:]
            if let column { env["BOATAR_FAKE_TRAILING_COLUMN"] = column }
            let app = launchChaos(script, regular: true, environment: env)
            try rotateForSideBySide(app)
            let marker = vesselMarker(app, 367000002)
            XCTAssertTrue(marker.waitForExistence(timeout: 20))
            marker.tap()
            let card = mapCard(app)
            assertCardClear(card, of: marker, in: app)
            let stack = app.descendants(matching: .any).matching(identifier: "mapButtons").firstMatch
            let window = app.windows.firstMatch.frame
            if stack.exists {
                XCTAssertFalse(card.frame.intersects(stack.frame), "card \(card.frame) over the buttons \(stack.frame)")
                if column != nil {
                    XCTAssertLessThan(stack.frame.midX, window.midX, "buttons beside the column, not away from it")
                }
            }
            assertChaosHealthy(app, "trailing column \(column ?? "off")")
            app.terminate()
        }
        restoreAfterChaos()
    }
}
