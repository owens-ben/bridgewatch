# Development notes

Everything about building, running and testing the app that is too detailed for the README.

Formerly Boat AR, then TransitAR: code names (the BoatAR target and scheme, BoatCore, BoatAIS) and the bundle ID `com.bsowens.BoatAR` keep the old name.

The app shows boats and subway trains around the Upper Bay and the lower East River and tags them in an AR camera view. The data path is aisstream.io and MTA feeds, then the relay, then the app. See `CLAUDE.md` for the stack and the project rules.

- Swift 6 language mode, SwiftUI, iOS 27.0 minimum, Xcode 27.1
- iPhone 18 Pro is the primary device; iPhone Duo (foldable) is also supported. Hinge code (`App/HingeMonitor.swift`) needs iOS 27.1 and is gated with `@available`; on 27.0 the hinge shows as Unavailable.
- `relay/` TypeScript service: the only thing that talks to aisstream.io (the key stays server-side). See `relay/README.md` and `relay/PROTOCOL.md`.
- `Packages/BoatCore` pure Swift logic: geo math, dev bounding box, hinge state, vessel model, relay message decoding (`/v2/targets`) and the targets it holds, with expiry (`TargetRegistry`), camera projection and heading smoothing, and rough 3D sightlines (`Sightlines` over `HarborSurface`, a ~50 m grid of roof and ground heights generated from NYC building footprints and Census land outlines; see docs/DESIGN.md, Sightlines).
- `Packages/BoatAIS` the feed: `VesselFeed` protocol, `RelayVesselFeed` (URLSession WebSocket + backoff), replay feed for tests.
- `App/` SwiftUI views built from `docs/DESIGN.md`: List, Map and Camera tabs (list + map split view when unfolded; on the map the selected boat or train gets a card placed clear of its marker, `MapCardLayout` in BoatCore, and a Key explains the markers), permissions screen, Settings (night mode, relay address, version). `VesselStore` (fed by BoatAIS), `DeviceSensors` (the only Core Location / Core Motion / camera-permission code), `CameraSession` (the only capture code). Colors are tokens in `Theme.swift`: asset color sets by day, the red-only palette at night. `BoatARUITests/` XCUITest
- The Xcode project uses synchronized folders, so adding files under `App/` or `BoatARUITests/` never requires editing the `.pbxproj`.
- The git short SHA is written to `GitSHA` in the built Info.plist by a Run Script phase. That target sets `ENABLE_USER_SCRIPT_SANDBOXING = NO` so the script can read git; it falls back to `unknown` without git.

## Relay URL

The app reads the relay address from the `RELAY_URL` build setting. It is not committed:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # git-ignored; edit the host
```

xcconfig treats `//` as a comment, so write the scheme as `ws:/$()/host:8080/v2/targets` (or `wss:/$()/…`). Empty means no relay: the app runs and shows `Vessels: 0`. Plain `ws://` works for hosts on the local network (`NSAllowsLocalNetworking`; iOS asks for local network access the first time). Without it the build has no built-in address (enter one in Settings > Relay).

UI tests never use the relay. Launch environment switches: `BOATAR_REPLAY_FEED` (JSON array of relay messages to replay), `BOATAR_REPLAY_OFFLINE=1` (replay then drop the connection: offline state), `BOATAR_FORCE_REGULAR=1` (regular-width split view on any simulator; the Duo simulator can't be unfolded from a test). `BOATAR_FAKE_SENSORS=lat,lon,heading,pitch,accuracy` (pins location and camera heading, reports the camera allowed; `none,none,...` for no location), `BOATAR_RESET_ONBOARDING=1` (show the first-launch permissions screen again). `BOATAR_FAKE_SENSORS` takes an optional sixth value, GPS altitude in meters. `BOATAR_FAKE_HEADING_SWEEP=1` pans the fake heading ±25° at 30 Hz while the camera is open, like a phone held up. `BOATAR_RESET_EYE_HEIGHT=1` clears the height set by hand in Settings (every UI test launch sets it). `BOATAR_RESET_TRAIN_SETTINGS=1` turns trains and underground trains back on (every UI test launch sets it too). `BOATAR_RESET_CAMERA_FILTER=1` puts the camera's filter menu back to its defaults: 3 mi, every boat type, not only moving (every UI test launch sets it too; the train switches are reset by `BOATAR_RESET_TRAIN_SETTINGS`). `BOATAR_RESET_UNITS=1` puts Settings > Units back to each vehicle's standard and the region's units, and `BOATAR_RESET_BROWSE=1` puts the list and map's filter (boat types, Moving only, Only what's on the map) and every list group's open or closed state back to their defaults (every UI test launch sets both; a test that checks they're kept across launches passes `"0"`). `BOATAR_MAP_REGION="lat,lon,meters"` (debug builds) opens the map on that center and visible span in meters instead of the whole area, to check what shows zoomed in. `BOATAR_DISABLE_ANIMATIONS=1` (debug builds; `UIView.setAnimationsEnabled(false)`, set in `BoatARApp.init`) turns animations off: the UI tests' `launch` helper sets it for every test except the performance tests and the screenshot tours, so assertions don't wait on transitions and the numbers stay honest. `BOATAR_FAKE_ZOOM=1` gives the simulator, which has no camera, an ultra wide/wide/5× telephoto camera's zoom buttons and fields of view. The chaos tests' hooks (a scripted feed with drops and crowds, a hang watchdog, sensor and clock hooks) are listed in docs/CHAOS-FINDINGS.md.

### Performance

`BoatARUITests/CameraPerformance.swift` measures the app's CPU and memory with a scene of 80 vessels and 80 trains (60 underground): camera (compass panning), list sitting, list scrolling, map sitting. They are opt-in (`BOATAR_PERF=1`) and the script sets that for you:

```sh
scripts/ui-test.sh perf            # about 20 minutes; waits for a quiet machine with --wait <minutes>
```

Each test runs in its own `xcodebuild` invocation on the `BW Test iPhone 18 Pro` simulator, about 30 s apart. One line per test (date, commit, test, average CPU seconds, relative standard deviation %, peak memory MB) is appended to `~/Library/Application Support/bridgewatch-ci/perf-history.tsv` and shown in the run's `summary.md`. Compare with the last numbers in docs/DESIGN.md (Status). Debug build on the Mac's CPU, app process only: GPU work (glass, the camera preview) isn't in them. 

Numbers from a loaded machine are meaningless: the script refuses to start unless the load, disk and other `xcodebuild` checks pass (see Build and test), and aborts the run as invalid if the machine gets busy during it.

The app has no built-in location: without location permission it lists vessels by name with no distances. For local simulator runs, set the simulator's location to the DUMBO waterfront:

```sh
xcrun simctl location "iPhone 18 Pro" set 40.7046,-73.9913
```

The relay address can also be set on the phone: Settings (gear on the list) > Relay. A valid ws/wss address there overrides the built-in `RELAY_URL`, so a TestFlight build can be pointed at your relay without rebuilding. Plain `ws://` is accepted there only for local hosts: short names (`relay-box`), IP addresses and `.local` names. Any other host, such as a dotted VPN name (`relay-box.example.ts.net`), needs `wss://`; Settings refuses a `ws://` address to it with a message and keeps the saved one.

## Design review screenshots

`BoatARUITests/ScreenshotTour.swift` walks every screen and state (permissions, list, detail, map, camera, accuracy pill, offline, empty, no location, Settings) in light, dark, the largest accessibility text size and night mode. Each variant pins night mode with a launch argument (`-nightMode off`, and `on` for the night variant), so the day shots don't come out red when the simulator's clock is after sunset. The tour changes the simulator's appearance and sets it back to light when it finishes. It's skipped unless switched on:

```sh
UITEST_EXPORT_ATTACHMENTS=1 TEST_RUNNER_BOATAR_SCREENSHOT_TOUR=1 scripts/ui-test.sh only BoatARUITests/testScreenshotTour BoatARUITests/testTrainScreenshotTour
```

`testListAndMapScreenshots` (same switch, run it with `--both`) shoots the map's buttons (beside the status column on the Duo cover), the list's filter menu, a collapsed group, a train row and its details in mph, Settings > Units at the largest text size, and on the iPhone 18 Pro side by side in landscape (forced regular width): the list limited to the map, its filter menu, and "Nothing on this part of the map".

`testMapKeyScreenshotTour` (same switch) shoots the map key, top and bottom, and the map zoomed in on a First responder boat (AIS type 55), unselected and selected, in light, dark and night, plus the key at the largest text size.

`UITEST_EXPORT_ATTACHMENTS=1` keeps the tour's screenshots under `attachments/` in the run's results folder (`scripts/ui-test.sh last` prints the path; the result bundle itself is deleted after reading).

## Build and test

```sh
# Swift packages
(cd Packages/BoatCore && swift test) && (cd Packages/BoatAIS && swift test)

# Relay
(cd relay && npm ci && npm test)

# Simulator tests: only through the script (never a bare `xcodebuild test`)
scripts/ui-test.sh smoke                    # about 9 tests, one simulator
scripts/ui-test.sh changed                  # tests mapped from what changed against origin/main, plus smoke
scripts/ui-test.sh only BoatARUITests/testRowOpensDetailSheet --both
scripts/ui-test.sh full                     # every UI test on both simulators + the Release build
scripts/ui-test.sh perf                     # the performance tests (see Performance)
scripts/ui-test.sh smoke --dry-run          # the plan and whether the machine is fit to run it; runs nothing
scripts/ui-test.sh last                     # the newest result summary
scripts/ui-test.sh status                   # who holds the lock, load, free disk
scripts/ui-test.sh selftest                 # the script's own logic, no simulators
scripts/ui-test.sh hold --wait 90 -- <command...>   # the same lock and preflight for the length of <command> (exploratory simulator work), then released

# App build only (no tests)
xcodebuild -scheme BoatAR -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build

```

#### Why a script

The Mac is the dev box and can be shared by several people or agent sessions. Simulator tests that overlap, or start on a machine with no CPU or disk to spare, fail in ways that look like test failures and are not. `scripts/ui-test.sh` is the only way to run them, for everyone:

- **One run at a time, machine-wide.** A lock directory, `~/Library/Caches/sim-test.lock` (holds pid, project, tier, start time; a lock whose process is gone is taken over). The path is not specific to this project on purpose: another project's test runner can take the same lock with `mkdir`, writing a `pid` file in it, and the two will queue instead of colliding.
- **Reserved simulators.** `BW Test iPhone 18 Pro` (iOS 27.0) and `BW Test iPhone Duo` (iOS 27.1), created on first use and addressed by UDID. Nothing else uses them, and the script never erases, deletes or otherwise touches any other simulator. The tests recognise the Duo by its model identifier (`iPhone19,4`), not its name. They are shut down afterwards (`--keep-booted` leaves them up).
- **Preflight.** Refuses to start (exit **75**) when the CPU is under 40% idle (`UITEST_MIN_IDLE_PCT`; measured from the second sample of `top -l 2 -n 0 -s 3`), under 6 GB is free (`UITEST_MIN_FREE_GB`), another `xcodebuild` is running, `~/Library/Developer/CoreSimulator/Devices` is missing or not writable (it may be a symlink to an external volume), or Xcode or `simctl` doesn't answer within 20 s. **The load average is deliberately not used:** on this Mac, background daemons (mediaanalysisd, Apple Intelligence inference, Spotlight) push it to 75 or more while the CPU is 70% idle, and they don't compete with the tests; `status` prints it for information only. During the run a watchdog checks every 30 s and aborts the run as invalid if free disk is under 2 GB (three checks in a row), or an `xcodebuild` that isn't ours appears, or a simulator that wasn't booted at the start (and isn't one of ours) gets booted (two checks in a row). It doesn't check CPU: while the tests run, they are what uses it. Every summary records the CPU idle % at the start and the three busiest processes at the start and the end, so a suspicious result can be judged afterwards.
- **Exit codes.** 0 pass, 1 test failures, 2 build failure, 64 usage, **75 the machine was busy or the run was invalid: not a test failure.** Wait and run again (`--wait <minutes>` waits for you); never report 75 as a failure.
- **Results where any session can read them.** `~/Library/Application Support/bridgewatch-ci/results/<UTC time>-<sha>-<tier>/` holds `summary.json`, `summary.md` (verdict, counts per simulator, each failing test with its assertion message and file:line), `failures/` (a screenshot per failed test) and `xcodebuild.log`; `latest-<tier>` points at the newest, the newest 30 runs are kept, and the `.xcresult` is deleted after it is read. `scripts/ui-test.sh last [tier]` prints the newest. Build products live in `~/Library/Caches/bridgewatch-ci/dd-<tier>` (`smoke`, `changed` and `only` share `dd-smoke`) and are deleted when free disk is under 8 GB.
- **Tiers.** `smoke` is `BoatARUITests/smoke-tests.txt`; `changed` maps changed paths to tests with `BoatARUITests/test-map.txt` (a path with no rule falls back to smoke); add a test to the smoke list only if breaking it would make the app unusable.
  - `scripts/ui-test.sh chaos [--seed N]  # opt-in chaos tests (monkey + scenarios) on both simulators; see docs/CHAOS-FINDINGS.md`. The tests in `BoatARUITests/chaos-tests.txt` skip unless `BOATAR_CHAOS=1`; the tier sets it (`TEST_RUNNER_BOATAR_CHAOS=1`), and forwards `BOATAR_CHAOS_SEED` / `BOATAR_CHAOS_ACTIONS` (or `--seed`) so a monkey run can be replayed. `--chaos` does the same for any tier: `scripts/ui-test.sh only BoatARUITests/testChaosMonkey --chaos --seed 7`. It has its own DerivedData (`dd-chaos`), no Release build and no per-test time limit (the monkey runs about 15 minutes).
- **Crashes.** Every tier that runs tests, once the tests finish, collects the app's `.ips` crash reports made during the run (from `~/Library/Logs/DiagnosticReports`, its `Retired/`, and each reserved simulator's `CrashReporter` and `DiagnosticReports`; matched by content, not name) into `<run folder>/crashes/`, lists them under "Crashes" in `summary.md` (exception, crashing thread's top frame) and counts them in `summary.json`. A crash fails the run even when every test passed. Hang markers (`BOATAR_HANG`) arrive as the chaos tests' failure messages, which the summary keeps whole.

## Demo and README media

- `scripts/demo.sh [simulator]` builds the app and launches it with invented boats and trains (no relay).
- `scripts/ui-test.sh hold --wait 90 -- scripts/record-demo.sh out.mp4` films `testDemoWalkthrough` (opt-in, `TEST_RUNNER_BOATAR_DEMO=1`, set by the script) with `simctl io recordVideo`; the README's GIF is a trimmed `ffmpeg` conversion of it.
- `testReadmeStills` takes the side-by-side still (opt-in with the screenshot tour's switch); the other README images come from the screenshot tours (`UITEST_EXPORT_ATTACHMENTS=1`, see Design review screenshots).
