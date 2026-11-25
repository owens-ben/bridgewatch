# Chaos findings (m8/chaos-tests)

What a chaos suite found before outside beta testers could: hostile relay frames, a relay that drops, stalls or lies,
sensors gone wrong, a churning feed, and a seeded monkey on both reserved simulators. Nothing in the app is fixed on this
branch (see "Guards added"); each finding has a test that reproduces it.

Status (m8/beta-fixes, 2026-11-19): `m8/crash-fixes` (F1-F15) and this suite are merged, and every finding is fixed or
explained in the Status column. The tests that pinned a bug (`trap_…` exit tests, `chaosFinding_…`, the S1
`withKnownIssue`, the relay's `test.failing`) are now plain assertions of the fixed behaviour; none is left.

## How to run it

| What | Command | Time |
|---|---|---|
| BoatCore (decoder fuzz, registry model, formatters, layout) | `cd Packages/BoatCore && swift test` | ~6 s |
| BoatAIS (hostile frames and servers, backoff, convergence, scripted feed) | `cd Packages/BoatAIS && swift test` | <1 s |
| Relay (hostile upstream frames, slow, garbage and 500 clients) | `cd relay && npm test` (`RELAY_CHAOS_SEED=<n>`) | ~7 s of it |
| UI chaos tier: the monkey and every scenario, both simulators | `scripts/ui-test.sh chaos [--seed N] --wait 45` | ~35 min |
| Replay one monkey run | `scripts/ui-test.sh only BoatARUITests/testChaosMonkey --chaos --seed N [--both]` | ~5-15 min |

- Seeds: package tests read `BOATAR_CHAOS_SEED` (default fixed, printed in every failure); `BOATAR_CHAOS_TRACE=1` (BoatCore)
  prints each fuzz input first so a trap names its input. The monkey picks a random seed unless `--seed` /
  `BOATAR_CHAOS_SEED` is given, prints it, and puts it with the last 30 actions in its failure message.
  `BOATAR_CHAOS_ACTIONS` (default 400) sets its length.
- The UI chaos tests skip unless `BOATAR_CHAOS=1` (the tier and `--chaos` set it), like the performance tests.
- Every tier now collects the app's crash reports (`.ips` for `com.bsowens.BoatAR` created during the run, from
  `~/Library/Logs/DiagnosticReports` and the reserved simulators' folders) into the run's `crashes/`, lists them in
  `summary.md` with the first frame in the app's own code, and fails the run.
- Hangs: debug builds launched with `BOATAR_HANG_WATCHDOG=1` ping the main thread 5 times a second; a ping that waits over
  2 s is a hang, logged as `BOATAR_HANG` and read by the tests from the `hangWatchdog` element ("hangs=1 max=2.3
  at=28.7"). A stall in the first 6 s after launch is printed (`CHAOS launch stall`), not failed (see H1).

DEBUG-only hooks added for this (all in the existing test-hook paths, empty in Release: the Release build was checked):
`BOATAR_SCRIPTED_FEED` (a timeline: connect, drop, messages restamped by age, raw frames decoded like the socket's,
generated crowds; `ScriptedVesselFeed` in BoatAIS), `BOATAR_HANG_WATCHDOG`, `BOATAR_CHAOS_PROBE` (night mode on or off
as the `nightModeProbe` element), `BOATAR_NIGHT_CLOCK_START` (night mode's clock starts at a given time), `"none"` as
the heading in `BOATAR_FAKE_SENSORS`, `BOATAR_FAKE_HEADING_SPIN`, `BOATAR_FAKE_LOCATION_JUMP`,
`BOATAR_FAKE_REDUCED_ACCURACY`, `BOATAR_RESET_NIGHT_MODE`, `BOATAR_RESET_RELAY_URL`.

## Findings, ranked

Severity: crash > data wrong > stuck UI > hang > layout > cosmetic. "Covered" means fixed on `m8/crash-fixes`
(CRASH-HUNT.md finding).

| # | Severity | Where | How to reproduce | What the user sees | Suspected cause | Proposed fix | Status |
|---|---|---|---|---|---|---|---|
| C1 | crash | Boat detail sheet (Course tile), boat AIS details (Heading), train sheet (Heading) | UI: `testChaosHugeCourseInTheDetailSheet` (both simulators, run 2: 2 crash reports, first app frame `VesselText.bearing(degrees:)`). Package: `trap_courseText_vesselCourseFromRelayFrame`, `trap_headingText_vesselHeadingFromRelayFrame`, `trap_courseText_trainCourseFromRelayFrame`. Input: a relay frame with `"course"` or `"heading"` ≥ about 9.2e18 (any finite JSON number decodes) | Tapping the boat closes the app (SIGTRAP) | `Int(degrees.rounded())` at Packages/BoatCore/Sources/BoatCore/VesselText.swift:52, reached from VesselList.swift:66 (`courseText`), VesselDetailText.swift:184 (checks only `isFinite`), TrainList.swift:92; Vessel.swift:53-54 copies `course`/`heading` unchecked, Train.swift:117 checks only finiteness | Validate or normalize course and heading on decode; make `bearing` total (normalize first, "" when not finite) | fixed by F2 (m8/crash-fixes); tests flipped to plain assertions (871c351); UI test passes on both simulators |
| C2 | crash (latent) | Camera compass strip and heading text | `trap_compassStripTicks_nanHeading`, `trap_compassStripTicks_hugeHeading`, `trap_vesselText_bearing_nan`, `…_infinity`, `…_beyondIntMax` | Camera closes the app on a NaN or infinite compass heading | `Int(floor(...))` at ARProjection.swift:190; `VesselText.bearing` (CameraScreen.swift:816) | Guard `isFinite`, normalize before converting | fixed by F2; a finite heading of 1e300 still trapped `CompassStrip.ticks`, now normalized first (871c351) |
| C3 | crash (latent) | Report ages, spoken bearing, spoken speed, small distances | `trap_vesselText_age_nan`, `…_age_beyondIntMax`, `…_age_negativeInfinity`, `…_spokenAge_*`, `…_spokenBearing_nan/infinity`, `…_spokenSpeed_*`, `…_distance_hugeNegative` | Any row or VoiceOver label with a NaN/infinite value closes the app; not reachable from a JSON frame today (JSON has no NaN) but from a NaN observer or clock | `Int(...)` before clamping at VesselText.swift:39, 47, 68, 74, 82 | Clamp first / `Int(saturating:)`; delete the unused `VesselText` speed and distance formatters (`Units` replaced them) | fixed by F2; the unused `VesselText` speed and distance formatters deleted (d841251) |
| C4 | crash (latent) | Feed reconnect delay | `trap_backoffNaNRandom` (BoatAIS) | None today: the default random source never returns NaN; a custom one would close the app on the first reconnect | `min(max(NaN, 0), 1)` stays NaN, then `Duration * NaN` traps: Packages/BoatAIS/Sources/BoatAIS/Backoff.swift:17-18 | `let jitter = unitRandom.isNaN ? 1 : min(max(unitRandom, 0), 1)` | fixed (f8bec02): NaN jitter gives the full delay |
| D1 | data wrong | List and map, two relay ids with one MMSI | `testChaosDuplicateMMSIUnderTwoIDs` (both simulators, both runs): two rows, both reading "TWIN A, passenger, …" (TWIN B is drawn with TWIN A's row); `chaosFinding_duplicateMMSIGivesDuplicateVesselIDs` | A second boat drawn as the first one; tapping either opens the first | `TargetRegistry` keys by target id (TargetRegistry.swift:11, 26) but rows, markers and `TargetID.vessel` key by MMSI (Vessel.swift:34), so SwiftUI sees duplicate ids; `VesselList.row(mmsi:)` finds only the first | One vessel per MMSI in `registry.vessels` (newest wins) | fixed by F14; UI test passes on both simulators |
| D2 | data wrong | List counts, distances, map | `testChaosOutOfRangeCoordinates` (both simulators): lat 91, lon 181, lat/lon swapped and 1e300 are all listed, "8 vessels" for 4 real ones; `chaosFinding_vesselsAcceptPositionsThatCantBeReal`. The map didn't crash with them drawn but unselected; selecting one (a `MKCoordinateRegion` around it) was not tried | Boats thousands of km away in the count and "Out of sight" group | `Vessel.init` checks speed but not position (Vessel.swift:48-50); `Train.init` does check | Reject lat outside ±90 / lon outside ±180 / non-finite in `Vessel.init` (and on the relay, D7) | fixed by F2 (`Vessel.init` rejects impossible positions); the UI test now expects SWAPPED, a real coordinate, to be listed (the relay drops it, D7) |
| D3 | data wrong / lost selection | Map card + the map's filter menu | `testChaosUnitsAndFiltersChangeWithASheetOpen`, failing in all 4 runs on both simulators: select MMSI 367000004 (no speed, type Other) on the map, open the map's filter button, turn on Moving only and turn off Other, close the menu (with the filter button itself). In 3 runs the card and marker stayed while the menu was open and both went the moment it closed; in 1 run the marker went at the first switch | The card closes and the boat disappears from the map when the filter menu closes, though DESIGN says "A selected boat or train is always shown … until it's deselected" | The scope keeps the selection (`BrowseScope.vessels(keep:)`, Packages/BoatCore/Sources/BoatCore/Browse.swift:212), so the selection itself is being cleared: most likely the touch that dismisses the menu reaches MapKit, whose `Map(selection:)` binding (App/VesselMapScreen.swift:112) deselects on a tap on the map, after which the filter rightly hides the boat. Not confirmed | Log `selection`'s changes while closing the menu; if MapKit clears it, ignore a nil from MapKit that arrives while/just after the menu is dismissed, or close the menu without a tap on the map | fixed (be5767e, 833db0f, ac6b9f2). Cause confirmed with the DEBUG selection log: MapKit writes nil to `Map(selection:)` the moment the filter menu closes; the tap that closes it (on the button, or beside the menu) also reaches the map. A nil from MapKit now applies only with a tap on the open map (not on the buttons, banner, note or card) and no filter change in the 4 s before. Passes on the Duo; on the iPhone 18 Pro the last run failed earlier, in the test tool ("Failed to determine hittability of Moving only"), see the final chaos run. `testTappingTheOpenMapDeselects` checks a real deselect still works |
| D4 | data wrong | Every list, map, camera | `chaosFinding_futureTimestampNeverPrunedAndReadsLiveForever` | A target stamped in the future reads "0 s ago", live, and is never pruned | TargetRegistry.swift:55 (age negative) | Clamp to the time received | fixed by F12 (15 min lead); test flipped (`futureTimestampIsPrunedEventually`) |
| D5 | data wrong (low) | Registry | `chaosFinding_olderUpdateReplacesNewerState` | An out-of-order (older) update moves a boat back to where it was and makes it look staler | `store` replaces unconditionally, TargetRegistry.swift:58-63 (the relay's own registry does keep the newest, relay/src/registry.ts:44) | Keep the newer timestamp per id, in updates and within a snapshot | fixed (26b8582): the newest timestamp per id wins, in updates and within a snapshot |
| D6 | data wrong (low) | Registry | `anIdSwitchingKind` (BoatCore), the WREN case in `testChaosHostileFramesKeepTheAppUp` | An update for a held id that can't be used (unknown kind, missing `vessel`/`train` object, impossible train position) is ignored, so the old state stays until it ages out | TargetRegistry.swift:58-60 | Remove the id when its replacement is unusable | fixed (26b8582): an unusable update removes the held id |
| D7 | data wrong | Relay | relay `chaos.test.ts`, `test.failing('nothing outside the bounding box is published …')` | Positions outside the dev area (swapped, 0/0, Europe) are published to every client | relay/src/normalizer.ts:25 checks only ±90/±180 | Also require `BOUNDING_BOXES` (shared `inBoundingBoxes()` in config.ts) | fixed (2c1a0f9) for boats, shared `inBoundingBoxes()`; not applied to trains: the subway source places trains only on its track, which is clipped to the box except the named stretches kept whole on purpose (Franklin Av ~25 m, Culver viaduct ~634 m, Williamsburg Bridge ~13 m outside) |
| D8 | data wrong (low odds) | Relay | `test.failing('a bogus far-future time_utc must not freeze a vessel …')` | One aisstream frame with a 2099 `time_utc` freezes that boat: later real positions are older, so ignored, and it never expires | relay/src/normalizer.ts:125 accepts years to 9999; relay/src/registry.ts:44 keeps the newest | Reject or clamp a timestamp more than ~1 min past `receivedAt` | fixed (58f90c7): a `time_utc` more than 60 s past receipt falls back to the receive time |
| S1 | stuck UI | Feed | `answersThenGoesSilentStaysConnectedForever` (BoatAIS, `withKnownIssue`) | A relay that goes silent (half-open TCP after a Wi-Fi/cellular change) leaves the app "Live" with emptying screens, no banner, no Retry | No idle deadline or ping in `RelayVesselFeed.pump`, RelayVesselFeed.swift:52-64 | Ping and deadline | fixed by F1; test flipped (797fdd6) |
| S2 | stuck UI | Feed | `FeedHostileFrameTests` (a connection of only undecodable frames never emits `.connected`) | A wrong address that answers with something else shows "connecting" forever | RelayVesselFeed.swift:62-71 | Fail the connection when nothing decodes in time | fixed by F11 |
| S3 | cosmetic (UX) | Feed | `tokenRejectedKeepsRetryingWithinBackoffBounds` | A rejected relay token looks like any outage ("Can't reach your relay · Check Tailscale is on") and retries every 30-60 s forever | `try?` swallows the connect error, RelayVesselFeed.swift:28 | A typed auth error and its own banner text | fixed (3eef646, aea9319): `FeedEvent.rejected` on a 401/403, retried at the backoff cap; banner "The server didn't accept this app" and the camera notice; chaos UI test `testChaosRejectedTokenShowsItsOwnBanner` |
| H1 | hang (to check on a phone) | App launch | Every chaos launch on both simulators: one main-thread stall of 2.0-4.6 s at the first watchdog ping (`CHAOS launch stall … at=0.0` in each run's log); twice a second one shortly after (at 7.9 s with the largest text size, `testChaosLongNamesAtTheLargestTextSize`; at 8.2 s on the Duo right after the monkey first opened the Camera then the Map tab, seed 2) | A frozen first frame for a few seconds; a stall on the first camera or map visit | Debug build on a shared Mac's simulator; not attributed. Not the harbor grid (decodes in 4 ms in a debug build). The first Camera visit configures the capture session on the main thread (F3) | Time the launch on the phone (Instruments, App Launch; iOS kills an app that blocks launch for ~20 s); the first camera visit after F3 | investigated, not the app's own work (see "H1: the launch stall" below): ~1.6 s of the 2.0-3.2 s stall is before the app's first view code runs, the app's own launch work is 0.15-0.4 s |
| H2 | hang | Camera with a crowd | `testChaosThousandTargetsArriveThenVanish` on the Duo, run 2: 2.3 s main-thread hang 28.7 s after launch, right after opening the Camera with 500 boats and 500 trains (passed on the iPhone 18 Pro both runs and on the Duo in run 1) | The camera tab freezes for a couple of seconds when the area is very busy | Every boat and train's sightline and label worked out on the main thread when the camera opens (CameraScreen's once-a-second recompute); coalescing in F6 helps the store side, not this | Cap the camera's candidates by distance before sightlines; measure with the perf tests at 1,000 targets | partly fixed. The camera keeps the 60 nearest boats and trains within its radius before sightlines (1b9c0a5, aea9319). The launch timeline showed the 1-2 s turns that tripped the test happen on the Map tab, before the camera opens: the map's 5 s tick with 1,000 markers (MapKit annotations); dropping the map's unused sightlines (833db0f) didn't remove them. Still a 2.1 s turn on the Duo (Debug, simulator); passes on the iPhone 18 Pro. Needs the phone (device checklist) |
| L1 | layout (low) | Map card height | `chaosFinding_maxCardHeightIgnoresAnObstacleJustOutsideTheCardBounds` | Contrived scene only: a card of exactly the promised height fits nowhere, so no card | `tallestGap` (MapCardLayout.swift:165) ignores an obstacle within `spacing` of the bounds that `frame(for:)` (:191) counts | Use the same spacing rule in both | fixed (ec916ce) |
| L2 | layout (trivial) | Map card obstacles | `chaosFinding_attributionRectEscapesAMapShorterThanItsReservedHeight` | Only on a map shorter than 36 pt | MapCardLayout.swift:80 | Clamp the height | fixed (ec916ce) |
| L3 | accessibility (low) | Map card "More info" at the largest text size | `testChaosLongNamesAtTheLargestTextSize` (prints `CHAOS: moreInfo not reachable…`): with a 200-character name at AX XXXL the compact card's "More info" isn't in the accessibility tree at all (run 1 also logged "Automation type mismatch: computed Button … vs PopUpButton"); the header row still opens the details | A VoiceOver or Switch Control user may not find "More info" without scrolling the card first | The card scrolls inside at the largest sizes (MapCard.swift) and the button is below its fold | Check with VoiceOver on a phone; consider keeping "More info" in the pinned header row | fixed (d3770c5): "More info" pinned in the header beside Close at accessibility sizes; the chaos test now asserts it |
| X1 | cosmetic | Unused/edge formatters | `chaosFinding_unclampedVesselTextShowsNaNAndNegatives`, `chaosFinding_coordinateTextForImpossiblePositions`, `trainTextWithNaNAndInfinity` | "nan mi", "-0.0 kn", a 300-digit coordinate, "0 ft down" for a NaN height | VesselText.swift (no clamps), VesselDetailText `coordinate`, TrainText `relativeHeight` | Clamp, or "" for non-finite | fixed (d841251): clamps, "" for impossible coordinates and heights, dead formatters deleted |
| X2 | cosmetic | Relay log | `test.failing('an upstream {"error"} frame cannot forge or flood the log')` | A 100k-character error with newlines logged raw | relay/src/upstream.ts:183 | `safeText(...)` (guard.ts) | fixed (c4cfbe7) |
| X3 | cosmetic | Relay | `test.failing('a draught that rounds to 0 is omitted, not sent as 0')` | "Draught 0 ft" | relay/src/normalizer.ts:88 | Round first, then require > 0 | fixed (822fcd6) |
| F? | unconfirmed | Map card after its boat is removed | `testChaosSelectedBoatVanishesWithItsMapCardOpen` failed once (Duo, run 2: the card was still there 40 s after the remove); passed in the other 3 runs | A card for a boat that's gone | Unknown; Duo failure screenshots are black (see Harness notes), so there is no picture | Re-run on the Duo a few times | not an app bug: reproduced once on the Duo; the failure screenshot shows HARBOR LARK's card, not ANNABEL K's: on the cover's whole-area map the markers overlap and the tap selected the other boat, whose card rightly stayed. The test now zooms in and checks which boat it selected; passes on both simulators |

## H1: the launch stall

Measured with the DEBUG launch timeline (`LaunchTimeline` in App/ChaosProbe.swift: named marks from the process start,
from the kernel's start time, and every main run loop turn over 100 ms with the marks inside it), Debug build, both
simulators, 16 launches of the chaos tests:

| Moment (s after the process started) | Range |
|---|---|
| `App.init` runs (dyld, Debug dylibs, the runtime) | 0.50-0.86 |
| First app object made by SwiftUI (`DeviceSensors.init`, `CameraSession.init`) | 2.09-2.93 |
| `ContentView.body` | 2.14-3.05 |
| List rows built (sightlines for the fixture boats included) | 2.23-3.42 |
| Watchdog's first ping answered (the stall it reports at 0.0) | waited 1.83-3.00 s |
| Feed connected, first boats published | 2.53-3.99 |

The first main run loop turn lasts 2.06-3.32 s and holds everything up to the first boats. Of it, 1.6-2.2 s pass between
`App.init` and SwiftUI making the app's first `@State` object, before any of the app's views: UIKit's scene setup,
SwiftUI's graph and the first frame, which the app doesn't run. The app's own part (body, list rows, feed start) is
0.15-0.4 s. Not attributable to the harbor grid (4 ms), the store or the feed. So H1 is launch overhead of a Debug build
on a shared Mac's simulator, plus SwiftUI and UIKit's own start, not the app's work; the phone's Release launch is on the
device checklist. The first Map visit is the next slowest turn, 0.3-1.1 s (MapKit's first creation), and the first Camera
visit 0.1-1.0 s: this is very likely the first-iteration spike in the map performance test (docs/DESIGN.md, Status).

## Tested and found sound

- Decoding: 12k mutated relay frames (BoatCore), 3,000 more through the feed (BoatAIS), every truncation of a real frame,
  100k-deep nesting, 1 MB and 5,000-target (844 KiB, decoded and applied in 0.04 s) frames, non-UTF-8 bytes, BOMs, v1 and
  v2 shapes mixed: never a trap; bad frames skipped, good ones delivered in order; `.connected` only after the first
  decodable frame.
- Feed: one connection at a time; 200 start/stop cycles leave nothing open; no connect attempts after the stream is
  dropped; backoff delays within [base/2, cap], growing to the cap, reset after a delivered message; a relay flapping
  every 200 ms for a minute; 600 snapshots 50 ms apart with updates and removes converge on the last good data.
- Registry: 150 random message sequences against a model; prune removes exactly the over-age targets.
- `Units`: 10k random values per preference × region × kind, NaN and infinities: never empty, never "nan"/"inf".
- Browse: counts add up, the selected item is kept by `BrowseResult` whatever the filter or region, no duplicates.
- `MapRegion`, `MapCardLayout.place` (20k random scenes: inside the safe area, clear of obstacles and the marker, no
  flapping), `ARProjection.place`, `LabelLayout.lanes`.
- Relay: 4,000 hostile AIS frames and 300 mutated subway feeds publish only finite, cleaned, in-range values; a client that
  stops reading is dropped (bounded buffer); 500 clients all get a snapshot and leave `clientCount` at 0; garbage from
  clients is ignored; unknown paths don't upgrade.
- UI, both simulators (unless noted), with no crash and no mid-session hang: garbage frames between good ones (count, "Live"
  kept, a 10,000-character name with controls, bidi overrides and newlines shown on one line inside the screen); the relay
  dropping for 5 s (banner, "Offline", frozen list, then back) and for a minute (the sheet on a boat that didn't come back
  closes, the new boats replace the old); boats stale while trains stay live and the reverse (trains gone after a minute,
  boats still live); the selected boat vanishing under its sheet, its map card (3 of 4 runs) and its camera focus; the
  selected train vanishing under its sheet; the closest boat changing every second (the card follows, its tap shows a
  real boat); 500 boats + 500 trains then nothing (list, map and camera cope; "The river's quiet" after); location denied
  (no distances, no camera labels), a 5 km location jump, approximate location (precise-location pill), no compass heading
  (guidance, no labels), the heading spinning at 720°/s; UTC+14 (ages unchanged); night mode turning on at sunset with a
  sheet open (the sheet stays); 20 marker taps in ~3 s (card on the last selected boat, clear of its marker); side by side
  with the feed churning and the fake trailing column on and off (iPhone 18 Pro only: the Duo cover can't turn).
- The monkey: see below.

## The monkey

Seeded, 400 actions per run (taps on elements and points, swipes, drags, pinch and rotate on the map, tab switches,
closing sheets and menus, typing, long presses, turning the device, home and back, light/dark, relaunching at another
text size, waits), against a feed that keeps one boat moving every 3 s, drops and comes back at ~90 s and adds a crowd of
80 boats and 40 trains with 60-character names. Every 10 actions: app in the foreground, a way out reachable (tabs, a
close button, a menu or the keyboard), floating controls on screen, no mid-session hang.

| Seed | iPhone 18 Pro | iPhone Duo (cover) |
|---|---|---|
| 1 | stopped at the first check: launch stall counted as a hang (before launch stalls were told apart) | same |
| 2 | first run: left the app at step 84, tapping the "Look up on MarineTraffic" link's icon (Safari opened: the monkey's denylist covered the link but not the image inside it; fixed). Rerun: **400 actions, pass** | 400 actions, pass; rerun: 4.6 s hang at 8.2 s after the first Camera and Map visits (H1) |
| 3 | first run: false alarm (the Closest card scrolled partly off screen counted as "off screen"; fixed). Rerun: **400 actions, pass** | **400 actions, pass** |
| 4 | first run: false alarm (the window's frame read mid-rotation; fixed). Rerun: **400 actions, pass** | **400 actions, pass** |

No crash, no stuck screen, no mid-session hang after launch in 6 complete runs (2,400 actions). The monkey can't reach the
hostile-data crashes (C1) because its feed is well-formed; the scenarios cover those.

## Guards added

On m8/beta-fixes every finding has its fix (Status column); the tests assert the fixed behaviour.

## Harness notes

- Duo (iOS 27.1) failure screenshots come out black; the iPhone 18 Pro's are fine. A Duo-only failure has only its
  message.
- `scripts/ui-test.sh selftest` has one environment-dependent check (`watchdog: reason names the disk`) that fails while
  another session has a reserved simulator booted; it isn't about this branch.
- The scripted feed's times are from the app's start of the feed, about 1-3 s after launch; scenario tests that race a
  timed remove assert they got there first.

## What the simulator can't cover: device checklist for the owner

- [ ] Real hinge: fold and unfold with each tab open, a sheet up, the map card shown and the camera running; the camera
      preview comes back and labels move (F3-F5 on m8/crash-fixes change this path).
- [ ] Real GPS: walk the waterfront; a fix that jumps (tunnel exit, a bridge) settles; approximate location gives the pill.
- [ ] Real compass: figure-8 calibration, a phone near a car or railing (bad heading), the accuracy pill, labels steady when
      held still; no crash when the compass gives no heading.
- [ ] Thermal: camera open 10 minutes in sun; watch the phone's temperature (Known gaps in DESIGN.md).
- [ ] Cellular handover: Wi-Fi to 5G with the app open; the feed recovers within a minute and the banner says so (S1, F1).
- [ ] Background kills: leave the app for an hour, come back; it relaunches or resumes on live data, no stale "Live".
- [ ] Launch time (H1): cold launch on the phone, Instruments App Launch; under 1 s to the first frame.
- [ ] Busy harbor (H2): with the relay's box widened or a replay of 1,000 targets, open the camera; no freeze.
- [ ] VoiceOver on the map card at the largest text size (L3).
- [ ] Night mode at real sunset (automatic) with the camera open.
- [ ] D3 on the phone: select a boat on the map, open the map's filter, hide its type, close the menu by tapping the
      button and by tapping beside the menu: the card and marker stay; a tap on open map afterwards deselects.
- [ ] Unfolded Duo: the "Nearby · Camera" switcher at the foot of the list column (system tab bar hidden), the map's
      Legal link visible and tappable; fold and unfold on each tab.
- [ ] A rejected token (S3): with the public relay's APP_TOKEN set and the app built without it, the banner says "The
      server didn't accept this app".
- [ ] Busy map (H2): 1,000 targets on the map tab of a Release build on the phone; note any freeze on its 5 s refresh.
