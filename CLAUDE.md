# Bridgewatch (formerly Boat AR, then TransitAR)

iOS app that shows AIS-tracked vessels on the East River (DUMBO stretch) and tags them in an AR camera view.

Shown to users as Bridgewatch. Code names (BoatAR target and scheme, BoatCore, BoatAIS) and the bundle ID com.bsowens.BoatAR keep the old names: don't rename them.

## Stack
- Swift 6.4 (Swift 6 language mode), SwiftUI, iOS 27.0 minimum. Xcode 27.1. No React Native, no third-party UI frameworks.
- Data: aisstream.io WebSocket (free tier), reached only through our relay (relay/, runs on a small home server): aisstream forbids direct client connections and the API key must stay server-side.
- Map: MapKit. AR: compass/GPS bearing overlay first; ARKit ARGeoAnchor is a later spike.
- Tests: Swift Testing for unit, XCUITest for UI. Fixtures are synthetic, never recordings of a provider's data (relay/README.md, "Test data"): the relay generates the subway feeds and the BoatCore fixtures with `npm run fixtures`.
- CI: in the original private repository, GitHub Actions on self-hosted runners (iOS jobs on a Mac, the relay on its host). The workflows are not part of this public copy. Releases went to TestFlight with fastlane, run locally, and are not part of it either.

## Devices
- Primary device: iPhone 18 Pro. Has GPS + magnetometer.
- Also supported: iPhone Duo (foldable, iPhone19,4). Cover screen 466x678pt, inner screen 669x951pt (native landscape), both @3x. Has GPS + magnetometer.
- Every screen must work folded, unfolded, and across the live transition: adaptive layout from size classes / container size, no fixed widths, no orientation lock. Unfolded is the regular-width layout (e.g. list + map side by side).
- Hinge state: UIKit `UIHingeInteraction` / `UIHinge` (iOS 27.1, so gate it with `@available(iOS 27.1, *)`; on 27.0 the hinge reads as unavailable). Wrap it once in App/ and expose it to SwiftUI; views never touch UIKit directly.
- AR/bearing math takes the real view size and camera FOV as inputs; never assume a phone aspect ratio.
- Tests run on both iPhone 18 Pro and iPhone Duo simulators.

## Architecture
- Packages/BoatCore: AIS decoding, vessel model, geo math (bearing, distance). Pure Swift, no UIKit, 100% unit-testable.
- Packages/BoatAIS: `VesselFeed` protocol + `RelayVesselFeed` (WebSocket to the relay, reconnect with backoff). Protocol-based so tests inject a fake.
- relay/: TypeScript (Node 22, `ws`). Each upstream feed is a source plug-in (relay/src/sources/, enabled by the `SOURCES` setting) that publishes `Target`s, one model for every kind (vessel, train, aircraft); the relay serves them on /v2/targets. /v1/vessels (AIS `VesselUpdate`s) stays for app builds from before v2. Contract: relay/PROTOCOL.md (the Swift side must match it). Jest tests use fixtures only.
- The app's relay address is the `RELAY_URL` build setting from Config/Local.xcconfig (git-ignored, see docs/DEVELOPMENT.md).
- App/: SwiftUI views only. No networking or math in views.

## Rules
- Run `swift test` in each package under Packages/, `npm test` in relay/ when it changed, and `scripts/ui-test.sh changed` (or `smoke`) before saying a task is done; `full` before a merge that touches the camera, list or map. Paste the summary lines.
- Simulator tests run only through `scripts/ui-test.sh`, never a bare `xcodebuild test`: it takes the machine-wide lock, checks the machine is quiet and uses its own `BW Test` simulators. Don't boot, erase or run tests on other simulators.
- Exit 75 means the machine was busy (CPU under 40% idle, low disk, another xcodebuild; not the load average, which macOS daemons inflate) or someone else started using it mid-run, not that tests failed. Wait and run again (`--wait <minutes>`); never report it as a failure or as a pass.
- Read the last result with `scripts/ui-test.sh last [tier]`; don't re-run a suite just to see its result.
- New logic gets a test in the same PR. No test, not done.
- Never hit the live aisstream socket in tests; use fixtures.
- Small PRs, one milestone step each. Branch name = `m<N>/<short-topic>`.
- Ask before adding a dependency. Prefer Apple frameworks.
- `.accessibilityIdentifier` on a container overrides its children's identifiers: put `.accessibilityElement(children: .contain)` before it.
- `#Preview` blocks and preview fixtures are `#if DEBUG` only; `scripts/ui-test.sh full` builds the Release configuration to catch anything that isn't.
- Colors come from `ColorToken` (`.token(.textPrimary)`), never asset colors directly, so night mode applies everywhere.
- Never nest a `TimelineView` inside another (e.g. one around the whole app): SwiftUI then re-runs layout every frame, a full CPU core on every screen, and it overheated the phone. Root-level clocks are a `@State` date moved on by a `.task` loop. Anything that changes faster than once a second (compass, motion) is read only by the small view that draws it.
- Changes to the camera, list or map get a run of the opt-in performance tests (`scripts/ui-test.sh perf`, docs/DEVELOPMENT.md, Performance) compared against the last numbers in docs/DESIGN.md, Status.
- Bounding box for dev: lat 40.675-40.735, lon -74.045 to -73.955 (Upper Bay and lower East River, Statue of Liberty to Williamsburg Bridge; the DUMBO stretch alone had too little AIS coverage). It's `devBoundingBox` in BoatCore and `BOUNDING_BOXES` in relay/src/config.ts; keep them equal. Make it a constant, not a literal.

## Build commands
- Build: `xcodebuild -scheme BoatAR -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build`
- UI tests: `scripts/ui-test.sh smoke | changed | full | perf | only <Class/test>` (`--dry-run` shows the plan and whether the machine is fit; `last`, `status`). Details in docs/DEVELOPMENT.md, Build and test.
- Packages: `cd Packages/BoatCore && swift test`, `cd Packages/BoatAIS && swift test`
- Relay: `cd relay && npm test`. Deploying it: deploy/README.md.
