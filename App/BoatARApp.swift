import BoatAIS
import BoatCore
import SwiftUI
#if DEBUG
import UIKit
#endif

@main
struct BoatARApp: App {
    @State private var hinge = HingeMonitor()
    @State private var vessels = VesselStore()
    @State private var sensors = DeviceSensors(fake: BoatARApp.testHooks["BOATAR_FAKE_SENSORS"])
    /// The app's one camera: kept across folds (docs/CRASH-HUNT.md, F3); `ContentView` runs it on the Camera tab.
    @State private var camera = CameraSession()
    /// Relay entered in Settings; empty uses the build's RELAY_URL.
    @AppStorage("relayURL") private var userRelayURL = ""
    /// The feed starts after the first-launch screen, so iOS's local-network prompt for the relay doesn't pile onto
    /// the location prompt there.
    @AppStorage("onboardingDone") private var onboardingDone = false

    /// Launch environment for the UI-test hooks (replay feed, fake sensors, onboarding reset). Debug builds only: a
    /// shipped build ignores its environment.
    private static var testHooks: [String: String] {
        #if DEBUG
        return ProcessInfo.processInfo.environment
        #else
        return [:]
        #endif
    }

    #if DEBUG
    init() {
        launchMark("App.init (stored properties made)")
        if Self.testHooks["BOATAR_HANG_WATCHDOG"] == "1" { LaunchTimeline.shared.observeMainRunLoop() }
        // UI tests: start from a first launch (the permissions screen) without reinstalling.
        if Self.testHooks["BOATAR_RESET_ONBOARDING"] == "1" {
            UserDefaults.standard.removeObject(forKey: "onboardingDone")
        }
        // UI tests: back to GPS height, whatever a test before this one set in Settings.
        if Self.testHooks["BOATAR_RESET_EYE_HEIGHT"] == "1" {
            UserDefaults.standard.removeObject(forKey: EyeHeightSetting.key)
        }
        // UI tests: trains back on, underground ones too, whatever a test before this one set in Settings.
        if Self.testHooks["BOATAR_RESET_TRAIN_SETTINGS"] == "1" {
            UserDefaults.standard.removeObject(forKey: TrainSettings.showTrainsKey)
            UserDefaults.standard.removeObject(forKey: TrainSettings.showUndergroundKey)
        }
        // UI tests: the camera's filter back to its defaults (3 mi, everything shown).
        if Self.testHooks["BOATAR_RESET_CAMERA_FILTER"] == "1" {
            UserDefaults.standard.removeObject(forKey: CameraFilter.storageKey)
        }
        // UI tests: units back to each vehicle's standard and the region's.
        if Self.testHooks["BOATAR_RESET_UNITS"] == "1" {
            for key in [UnitPreferences.speedKey, UnitPreferences.distanceKey, UnitPreferences.heightKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        // UI tests: the list and map's filter back to its defaults, every list section in its default state.
        if Self.testHooks["BOATAR_RESET_BROWSE"] == "1" {
            UserDefaults.standard.removeObject(forKey: BrowseFilter.storageKey)
            for section in ListSection.allCases {
                UserDefaults.standard.removeObject(forKey: section.storageKey)
            }
        }
        // Chaos tests: night mode back to Automatic and the relay back to the built-in one, whatever the monkey chose.
        if Self.testHooks["BOATAR_RESET_NIGHT_MODE"] == "1" {
            UserDefaults.standard.removeObject(forKey: "nightMode")
        }
        if Self.testHooks["BOATAR_RESET_RELAY_URL"] == "1" {
            UserDefaults.standard.removeObject(forKey: "relayURL")
        }
        // Chaos tests: count main-thread hangs over 2 s (ChaosProbe.swift).
        if Self.testHooks["BOATAR_HANG_WATCHDOG"] == "1" {
            HangWatchdog.shared.start()
        }
        // UI tests: no animations, so assertions don't wait on transitions and a loaded machine times out less.
        if Self.testHooks["BOATAR_DISABLE_ANIMATIONS"] == "1" {
            UIView.setAnimationsEnabled(false)
        }
    }
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                #if DEBUG
                // UI tests: BOATAR_FAKE_TRAILING_COLUMN=<points> adds a trailing safe-area column like the Duo's status
                // column, so the forced side-by-side layout on a phone can show where the map buttons go beside it.
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    if let width = Self.testHooks["BOATAR_FAKE_TRAILING_COLUMN"].flatMap(Double.init) {
                        Color.clear.frame(width: width)
                    }
                }
                #endif
                .environment(hinge)
                .environment(vessels)
                .environment(sensors)
                .environment(camera)
                // Restarts the feed whenever the relay address in Settings changes or onboarding finishes.
                .task(id: "\(onboardingDone)|\(userRelayURL)") {
                    guard onboardingDone else { return }
                    launchMark("feed start")
                    vessels.start(feed: FeedConfiguration.feed(
                        environment: Self.testHooks,
                        relayURL: Bundle.main.object(forInfoDictionaryKey: FeedConfiguration.relayURLInfoKey) as? String,
                        userRelayURL: userRelayURL))
                }
                #if DEBUG
                .overlay(alignment: .topLeading) {
                    if Self.testHooks["BOATAR_ACCESSIBILITY_PROBE"] == "1" { AccessibilityProbe() }
                }
                .overlay(alignment: .topTrailing) {
                    if Self.testHooks["BOATAR_HANG_WATCHDOG"] == "1" {
                        HangWatchdogProbe()
                        LaunchTimelineProbe()
                    }
                }
                #endif
                .background {
                    // UIHingeInteraction is iOS 27.1+; on 27.0 the monitor stays .unavailable.
                    if #available(iOS 27.1, *) {
                        HingeObserver(monitor: hinge)
                    }
                }
        }
    }
}
