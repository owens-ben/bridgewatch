import XCTest

/// The chaos monkey (docs/CHAOS-FINDINGS.md): N random actions (BOATAR_CHAOS_ACTIONS, default 400) drawn from a seeded
/// generator (BOATAR_CHAOS_SEED replays a run; without it a seed is picked and printed). Every `checkEvery` actions it
/// checks the app is up in the foreground, a way out (the tabs, or a sheet's close button) is reachable, the primary
/// controls are on screen, and the main thread hasn't hung. A failure message carries the seed and the last 30 actions.
/// It never leaves the app on purpose: links, "Open Settings" and anything that would hand off to another app are
/// never tapped, and a system alert is answered explicitly ("Don't Allow", else "OK") and logged.
extension BoatARUITests {
    /// SplitMix64: tiny, seedable, the same sequence on every machine.
    struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
        mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
    }

    enum MonkeyAction: String, CaseIterable {
        case tapElement, tapPoint, swipe, drag, pinchMap, rotateMap, switchTab, closeSheet, typeText, longPress,
             rotateDevice, backgroundForeground, toggleAppearance, relaunchWithTextSize, wait
    }

    static let monkeyWeights: [(MonkeyAction, Int)] = [
        (.tapElement, 34), (.tapPoint, 8), (.swipe, 12), (.drag, 4), (.pinchMap, 4), (.rotateMap, 2),
        (.switchTab, 10), (.closeSheet, 6), (.typeText, 4), (.longPress, 3), (.rotateDevice, 4),
        (.backgroundForeground, 2), (.toggleAppearance, 2), (.relaunchWithTextSize, 1), (.wait, 4),
    ]

    static let textSizes = [
        "UICTContentSizeCategoryM", "UICTContentSizeCategoryL", "UICTContentSizeCategoryXS",
        "UICTContentSizeCategoryXXXL", "UICTContentSizeCategoryAccessibilityXL", "UICTContentSizeCategoryAccessibilityXXXL",
    ]

    /// Never tapped: they hand off to another app (Safari, Settings) or the share sheet.
    static func monkeyMayTap(identifier: String, label: String, type: XCUIElement.ElementType) -> Bool {
        if type == .link { return false }
        if identifier == "lookUpVessel" { return false }
        // SF Symbol names XCUITest reports for the link's icon and other hand-off icons.
        if label.contains("Up-Right Arrow") || label.contains("Square And Arrow Up") { return false }
        let lowered = label.lowercased()
        for word in ["marinetraffic", "open settings", "look up", "share"] where lowered.contains(word) { return false }
        return true
    }

    static let monkeyTexts = [
        "ws://relay-box:8095/v2/targets", "🚢⚓️", "مركب", "\u{202E}evil", String(repeating: "x", count: 300), "12",
        "-1", "%@%n", "<b>bold</b>", "   ", "*WALL ST*",
    ]

    /// The feed the monkey plays against: the fixture boats and trains, a boat that keeps moving, a drop and a return,
    /// and a crowd.
    func monkeyScript() -> ChaosScript {
        var script = ChaosScript()
        script.connect()
        script.message(snapshotJSON(fixtureTargets() + fixtureTrainTargets()))
        for i in 0..<300 {
            script.message(updateJSON(chaosVessel(367000002, name: "ANNABEL K", lat: 40.7062 + Double(i % 20) * 0.0002,
                                                  lon: -73.9890, sog: 6.8, cog: 0, type: 52)), after: 3, age: 0)
            if i == 30 { script.disconnect(after: 0) }
            if i == 33 {
                script.connect()
                script.message(snapshotJSON(fixtureTargets() + fixtureTrainTargets()), age: 0)
            }
            if i == 60 { script.crowd(vessels: 80, trains: 40, nameLength: 60, seed: 5) }
        }
        return script
    }

    @MainActor
    func testChaosMonkey() throws {
        try requireChaos()
        let env = ProcessInfo.processInfo.environment
        let seed = env["BOATAR_CHAOS_SEED"].flatMap(UInt64.init) ?? UInt64.random(in: 1...999_999)
        let actions = env["BOATAR_CHAOS_ACTIONS"].flatMap(Int.init) ?? 400
        let checkEvery = 10
        print("CHAOS MONKEY seed=\(seed) actions=\(actions) (replay: BOATAR_CHAOS_SEED=\(seed))")
        var rng = SplitMix64(seed: seed)
        // The launch's own choices come from the seed too.
        let regular = !Self.isDuo && rng.below(4) == 0
        var textSize = rng.pick(Self.textSizes)
        func start() -> XCUIApplication {
            launchChaos(monkeyScript(), regular: regular,
                        arguments: ["-UIPreferredContentSizeCategoryName", textSize])
        }
        var app = start()
        addTeardownBlock { self.restoreAfterChaos() }
        var log: [String] = ["launch seed=\(seed) regular=\(regular) textSize=\(textSize)"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        func fail(_ problem: String) {
            let tail = log.suffix(30).joined(separator: "\n  ")
            XCTFail("CHAOS MONKEY: \(problem)\nseed=\(seed) (replay: BOATAR_CHAOS_SEED=\(seed) "
                + "scripts/ui-test.sh only BoatARUITests/testChaosMonkey --chaos --seed \(seed))\nlast actions:\n  \(tail)")
        }
        let total = Self.monkeyWeights.map(\.1).reduce(0, +)

        for step in 0..<actions {
            // A system alert (none is expected with the fake sensors): answered explicitly, never blindly.
            let alert = springboard.alerts.firstMatch
            if alert.exists {
                let label = alert.label
                let deny = alert.buttons["Don’t Allow"].exists ? alert.buttons["Don’t Allow"] : alert.buttons["Don't Allow"]
                if deny.exists { deny.tap() } else if alert.buttons["OK"].exists { alert.buttons["OK"].tap() }
                log.append("\(step): system alert answered: \(label)")
            }
            var roll = rng.below(total)
            var action = MonkeyAction.wait
            for (candidate, weight) in Self.monkeyWeights {
                if roll < weight { action = candidate; break }
                roll -= weight
            }
            let note = perform(action, app: app, rng: &rng, step: step) { newSize in
                textSize = newSize
                app.terminate()
                app = start()
            }
            log.append("\(step): \(action.rawValue) \(note)")

            if app.state != .runningForeground {
                if action == .backgroundForeground, app.state == .runningBackground || app.state == .runningBackgroundSuspended {
                    app.activate()
                } else {
                    fail("the app is \(app.state.rawValue) after step \(step) (crashed or left the app)")
                    return
                }
            }
            if step % checkEvery == checkEvery - 1 || step == actions - 1 {
                if let problem = monkeyCheck(app) {
                    fail(problem)
                    return
                }
            }
        }
        print("CHAOS MONKEY done: seed=\(seed), \(actions) actions, hangs: \(hangSummary(app) ?? "unread")")
    }

    /// One action; returns what it did, for the log.
    @MainActor
    func perform(_ action: MonkeyAction, app: XCUIApplication, rng: inout SplitMix64, step: Int,
                 relaunch: (String) -> Void) -> String {
        let window = app.windows.firstMatch
        let size = window.frame.size
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        }
        switch action {
        case .tapElement:
            let candidates = monkeyTargets(app)
            guard !candidates.isEmpty else { return "(nothing to tap)" }
            let target = candidates[rng.below(candidates.count)]
            point(target.frame.midX, target.frame.midY).tap()
            return "\(target.description)"
        case .tapPoint:
            // Inside the safe-ish middle: the status bar and the home indicator belong to the system.
            let x = size.width * (0.05 + 0.9 * rng.unit()), y = size.height * (0.08 + 0.84 * rng.unit())
            point(x, y).tap()
            return "at (\(Int(x)), \(Int(y)))"
        case .swipe:
            let direction = rng.below(4)
            switch direction {
            case 0: app.swipeUp()
            case 1: app.swipeDown()
            case 2: app.swipeLeft()
            default: app.swipeRight()
            }
            return ["up", "down", "left", "right"][direction]
        case .drag:
            let from = (size.width * (0.1 + 0.8 * rng.unit()), size.height * (0.2 + 0.6 * rng.unit()))
            let to = (size.width * (0.1 + 0.8 * rng.unit()), size.height * (0.2 + 0.6 * rng.unit()))
            point(from.0, from.1).press(forDuration: 0.1, thenDragTo: point(to.0, to.1))
            return "from (\(Int(from.0)), \(Int(from.1))) to (\(Int(to.0)), \(Int(to.1)))"
        case .pinchMap, .rotateMap:
            let map = app.descendants(matching: .any).matching(identifier: "vesselMap").firstMatch
            guard map.exists, map.isHittable else { return "(no map)" }
            if action == .pinchMap {
                let scale = rng.unit() < 0.5 ? 0.4 + 0.5 * rng.unit() : 1.2 + rng.unit()
                map.pinch(withScale: scale, velocity: scale < 1 ? -1 : 1)
                return "scale \(String(format: "%.2f", scale))"
            }
            let angle = (rng.unit() - 0.5) * 2
            map.rotate(angle, withVelocity: angle < 0 ? -1 : 1)
            return "angle \(String(format: "%.2f", angle))"
        case .switchTab:
            let tab = rng.pick(["Nearby", "Map", "Camera"])
            let button = app.buttons[tab].firstMatch
            guard button.exists, button.isHittable else { return "\(tab) (not reachable)" }
            button.tap()
            return tab
        case .closeSheet:
            for id in ["closeDetails", "settingsDone", "closeMapKey"] {
                let button = app.buttons[id].firstMatch
                if button.exists, button.isHittable { button.tap(); return id }
            }
            app.swipeDown(velocity: .fast)
            return "swipe down"
        case .typeText:
            guard app.keyboards.count > 0 else { return "(no keyboard)" }
            let text = rng.pick(Self.monkeyTexts)
            app.typeText(text)
            return "\(text.prefix(20).debugDescription)"
        case .longPress:
            let candidates = monkeyTargets(app)
            guard !candidates.isEmpty else { return "(nothing)" }
            let target = candidates[rng.below(candidates.count)]
            point(target.frame.midX, target.frame.midY).press(forDuration: 1.2)
            return target.description
        case .rotateDevice:
            let orientation = rng.pick([UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight])
            XCUIDevice.shared.orientation = orientation
            return "\(orientation.rawValue)"
        case .backgroundForeground:
            XCUIDevice.shared.press(.home)
            sleep(1)
            app.activate()
            return "home, then back"
        case .toggleAppearance:
            let dark = rng.unit() < 0.5
            XCUIDevice.shared.appearance = dark ? .dark : .light
            return dark ? "dark" : "light"
        case .relaunchWithTextSize:
            let size = rng.pick(Self.textSizes)
            relaunch(size)
            return size
        case .wait:
            let seconds = 1 + rng.below(3)
            sleep(UInt32(seconds))
            return "\(seconds) s"
        }
    }

    struct MonkeyTarget: CustomStringConvertible {
        let frame: CGRect
        let type: XCUIElement.ElementType
        let identifier: String
        let label: String
        var description: String { "\(type.rawValue) \(identifier.isEmpty ? "-" : identifier) \"\(label.prefix(40))\"" }
    }

    /// Tappable elements on screen now, from one snapshot of the tree (one query, in a stable order).
    @MainActor
    func monkeyTargets(_ app: XCUIApplication) -> [MonkeyTarget] {
        guard let root = try? app.snapshot() else { return [] }
        let window = app.windows.firstMatch.frame
        let types: Set<XCUIElement.ElementType> = [.button, .cell, .switch, .textField, .slider, .stepper,
                                                     .segmentedControl, .menuItem, .tab, .link, .image]
        var found: [MonkeyTarget] = []
        func visit(_ node: XCUIElementSnapshot, depth: Int) {
            guard depth < 60 else { return }
            // Nothing inside a link (its icon is an image that opens Safari just the same: seed 2, step 84).
            guard Self.monkeyMayTap(identifier: node.identifier, label: node.label, type: node.elementType) else { return }
            if types.contains(node.elementType), node.isEnabled, node.frame.width >= 4, node.frame.height >= 4,
               window.contains(CGPoint(x: node.frame.midX, y: node.frame.midY)),
               Self.monkeyMayTap(identifier: node.identifier, label: node.label, type: node.elementType) {
                found.append(MonkeyTarget(frame: node.frame, type: node.elementType, identifier: node.identifier,
                                          label: node.label))
            }
            node.children.forEach { visit($0, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return found
    }

    /// Nil when the app is fine; else what's wrong.
    @MainActor
    func monkeyCheck(_ app: XCUIApplication) -> String? {
        guard app.state == .runningForeground else { return "the app isn't in the foreground (\(app.state.rawValue))" }
        if let summary = hangSummary(app), let problem = Self.midSessionHang(summary) {
            return "BOATAR_HANG main thread blocked over 2 s mid-session: \(problem)"
        }
        var window = app.windows.firstMatch.frame
        // Right after a rotation the window reports a frame mid-turn (seed 4: origin (-1, 473)): let it settle.
        for _ in 0..<4 where window.origin != .zero {
            sleep(1)
            window = app.windows.firstMatch.frame
        }
        guard window.width > 0, window.height > 0 else { return "the window has no size: \(window)" }
        if window.origin != .zero { return "the window never settled after turning: \(window)" }
        func wayOut() -> Bool {
            if app.keyboards.count > 0 { return true }
            for tab in ["Nearby", "Map", "Camera"] {
                let button = app.buttons[tab].firstMatch
                if button.exists, button.isHittable { return true }
            }
            for id in ["closeDetails", "settingsDone", "closeMapKey"] where app.buttons[id].firstMatch.exists {
                return true
            }
            // A menu or a sheet without a button: a swipe down or a tap outside dismisses it.
            return app.collectionViews.firstMatch.exists || app.sheets.firstMatch.exists
        }
        if !wayOut() {
            // One honest attempt to get out, as a user would: swipe the sheet down, tap outside a menu.
            app.swipeDown(velocity: .fast)
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
            if !wayOut() { return "stuck: no tab, close button, menu or keyboard reachable" }
        }
        // Primary controls that are on screen must have a real frame inside the window.
        for id in ["Nearby", "Map", "Camera"] {
            let button = app.buttons[id].firstMatch
            guard button.exists, button.isHittable else { continue }
            let frame = button.frame
            if frame.width < 1 || frame.height < 1 || !window.intersects(frame) {
                return "tab \(id) has a zero or off-screen frame \(frame) in \(window)"
            }
        }
        // Floating controls (not list content, which may be scrolled partly off screen): a real frame that reaches into
        // the window.
        for id in ["settingsButton", "mapButtons", "compassStrip", "mapCard", "offlineBanner"] {
            let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
            guard element.exists, element.isHittable else { continue }
            let frame = element.frame
            if frame.width < 1 || frame.height < 1 || !window.intersects(frame) {
                return "\(id) has a zero or off-screen frame \(frame) in \(window)"
            }
        }
        return nil
    }
}
