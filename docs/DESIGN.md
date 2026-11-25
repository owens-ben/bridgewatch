# Bridgewatch — Design Spec

The app was called Boat AR, then briefly TransitAR, and became Bridgewatch on 2026-11-10. Code names (the BoatAR target and scheme, BoatCore, BoatAIS) and the bundle ID `com.bsowens.BoatAR` keep the old names; everything the user sees says Bridgewatch.

Source of truth for UI. This file is what to build from. Native SwiftUI only: no custom fonts, no third-party UI, no custom map tiles.

## Look in one line

Deep navy content layer, Liquid Glass control layer, brand indigo accent, red-only night mode.

## Brand

The brand is the "bullet" direction: Bridgewatch watches boats, trains and aircraft cross the city's bridges. Brand indigo `#2B3F8C`, paper `#FBF8F1`, periwinkle `#A3B1FF`. The app keeps its dark navy and glass look (decided 2026-11-10); the brand shows in the accent (indigo by day, periwinkle in dark mode) and the icon. Night mode stays red only.

App icon "B2" (owner-chosen 2026-11-22, replacing the round stamp): an indigo field with three stacked layers, an aircraft seen from above in the sky, a suspension bridge (two braced towers with pointed caps, a gently curved main cable, side spans sweeping down to the anchorages, periwinkle suspenders, a deck; an homage to the East River bridges, not a copy of one) with a round subway "bullet" on the deck, and a boat on the water over two wave lines. Flat shapes in paper with periwinkle as the second tone; no text. The original sketch files were not readable (dataless iCloud files), so it was designed from the owner's description. Drawn by `scripts/make-app-icon.swift` (Core Graphics, no dependencies): default is paper and periwinkle on indigo with no alpha channel, dark is paper and a brighter periwinkle on deep indigo `#10162E`, tinted is white and grey on black for iOS to tint. Change the icon by editing the script and running it (`--preview DIR` renders 1024/180/120/60 px previews with the home-screen mask and a contact sheet); never edit the PNGs by hand.

## Two layers (Apple's rule, keep it)

- **Content** (lists, cards, rows) sits on solid navy surfaces. Never put `.glassEffect()` on content.
- **Controls** that float over content are glass: tab bar, sheets, map buttons, the camera's compass strip and pills, banners.
- System tab bars and medium-detent sheets are already glass on iOS 26+. Do not add `.glassEffect()` to them. Use `.glassEffect()` only on custom floating controls (camera compass strip and pills, offline banner, map button stack, unfolded detail card).
- AR labels are solid `bgRaised` capsules, not glass. They're content (one per boat), and glass re-samples the live camera behind each one on every frame: too costly for a dozen labels moving with the compass.

## Color tokens

Create each as a Color Set in `Assets.xcassets` with Any/Dark appearances. Night mode is a separate in-app palette (see below), not an asset appearance.

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| `bgBase` | #050D1A | #F2F6FB | Screen background |
| `bgSurface` | #0E1D33 | #FFFFFF | Grouped list, cards |
| `bgRaised` | #16294A | #E3ECF7 | Selected row, tiles |
| `separator` | #1F3456 | #C9D6E6 | Row dividers |
| `textPrimary` | #FFFFFF | #0B2545 | Primary text |
| `textSecondary` | #9AA8BF | #4A5A72 | Secondary text (passes 4.5:1 on both surfaces) |
| `accent` | #A3B1FF | #2B3F8C | App tint, links, primary buttons (black text on dark, white text on light), selection rings. Brand indigo by day, a periwinkle by night. `ColorContrastTests` in BoatCore holds it to 4.5:1 as text on every surface and on glass, 3:1 as icons on map glass, 4.5:1 under on-fill text |

Vessel types (fill behind a black glyph in dark, white glyph in light). Always pair with the symbol; never color alone. Names are one or two words with no slashes (`VesselCategory.name`); the map key adds what each covers (`coverage`). A row's detail says "Vessel" for Other ("Vessel · 4 kn"); the marker label and the card give the finer AIS type ("Law enforcement").

| Group | Covers | AIS ship type | SF Symbol | Night letter | Dark | Light |
| --- | --- | --- | --- | --- | --- | --- |
| Passenger | Ferries and passenger ships | 60–69 | `ferry.fill` | P | #64D2FF | #0071A4 |
| Cargo | Cargo ships and tankers | 70–89 | `shippingbox.fill` | C | #FFD60A | #8A6100 |
| Service | Tugs, towing, dredging, diving, pilots and port tenders | 31–34, 50, 52–54, 56, 57, 59 | `wrench.fill` | T | #30D158 | #1E7B34 |
| First responder | Coast Guard, police, fire, rescue and military | 35, 51, 55, 58 | `light.beacon.max.fill` | R | red #D0283E, blue #3A5BEF | red #C41E2A, blue #1F45C7 |
| Pleasure | Sailboats and pleasure craft | 36–37 | `sailboat.fill` | S | #BF5AF2 | #8E2DB8 |
| Other | Fishing boats, high-speed craft and boats that don't send a type | everything else | `circle.fill` | ? | #8E8E93 | #6B7280 |

First responder is a two-tone swatch, left half red and right half blue like emergency lights (`VesselFill`, tokens `responderRed`/`responderBlue`, assets `typeResponderRed`/`typeResponderBlue`), with a white glyph in light and dark (both halves at least 3:1 against white; the blue is deeper and bluer than Passenger's). Every place a group's color shows uses it: badges (list rows, map markers, the map card, the key, camera labels), the closest card's fill, the camera's dot. At night it's the letter R like every other group, so the marker never shows blue. `TypeColorContrastTests` (BoatCore) reads the color sets and checks every type color against its glyph.

Mapping from AIS ship type number to group lives in BoatCore with a unit test per range. The group's raw value is stored in the camera filter: Service keeps "tug". The stored filter has a `version`; one from before First responder existed that hides Service also hides First responder, so nothing a user saw before disappears and nothing they hid comes back.

Subway route bullets (`RouteBullet`): the route's letter or number in a filled circle, a diamond for the express variants (6X, 7X, FX), in MTA's line colors, the same in light and dark (`ColorToken.route(SubwayLine)`, asset colors `route*`). The letter is white (`ColorToken.routeText`), black on the yellow. Which route is on which line is `SubwayLine` in BoatCore.

| Line | Routes | Color |
| --- | --- | --- |
| Broadway-7 Av | 1 2 3 | #EE352E red |
| Lexington Av | 4 5 6 | #00933C green |
| Flushing | 7 | #B933AD purple |
| 8 Av | A C E | #0039A6 blue |
| 6 Av | B D F M | #FF6319 orange |
| Crosstown | G | #6CBE45 light green |
| Nassau St | J Z | #996633 brown |
| Canarsie | L | #A7A9AC gray |
| Broadway | N Q R W | #FCCC0A yellow (black letter) |
| Shuttles (and unknown routes) | S | #808183 dark gray |

Late data: when the app says Live but the newest position it has received is old, the status line says so instead (`DataFreshness` in BoatCore, from `VesselStore`, which keeps the newest timestamp per kind apart from the targets because trains expire at 60 s): "Trains last updated 2 min ago" past 60 s (MTA's terms ask for a notice over a minute; its feeds refresh about every 30 s), "Boats last updated 7 min ago" past 5 minutes (AIS boats report every few minutes at anchor; the list already greys a boat at 1 min and drops it at 10); both are joined with a full stop. A timestamp ahead of the clock counts as now. Read on the list's 5 second clock, so no extra redraws; VoiceOver reads the minutes in full. First screen: "Positions come from public feeds and can be late or wrong."

Data states for boats: live (<1 min since last report) full opacity; stale (1–10 min) 70% opacity; offline, the frozen list is 70% too, with last-report ages; older than 10 min removed (already the BoatCore rule). Trains are different: a train moves about 15 m/s, so its last position is worth little after a minute. Live is under 20 s since the position the relay estimated (`Train.liveSeconds`), stale up to 60 s (70%, like boats), then the train is gone, offline too: it leaves the list, the map and the camera, and an open train sheet closes (`TrainList` drops it by age for the clock's now, so a frozen store doesn't keep it). Offline with no trains left, the Trains section says "Trains need a live connection." (`TrainText.emptyNote(offline:)`, id `trainsOfflineNote`). 70% in every palette, day and night: at 50% the text on the frozen offline closest card fell to about 1.6:1 contrast by day and the night red to about 2:1.

### Night mode

Red only, to protect dark-adapted eyes. On automatically between sunset and sunrise at the user's location; manual override in a settings menu.

| Token | Value |
| --- | --- |
| `nightText` | #FF6A5C |
| `nightSecondary` | #F23A2E |
| `nightGlassTint` | #3C0804 at 45–55% |
| `nightLine` | #FF5A4A at 30% |

In night mode vessel-type colors are dropped; the type shows as a letter in an outlined circle (P, C, T, R, S, ?). Route bullets do the same: the route's letter in red in an outlined circle (or diamond), no line color. Camera preview is dimmed 40%. Map markers (the `onMap` environment flag) can't use the glass or the outlined look, because the map's red multiply would turn a dark fill black: at night a vessel's or train's marker is a white fill with a black letter, which the multiply turns bright red; an underground train's is a white outline on black. Sunrise/sunset math goes in BoatCore (pure function, tested), not in a view.

Titles: SwiftUI has no way to color a large navigation title (it follows the system label color, white in dark), so at night the list shows an inline title drawn in `nightText` red instead. The navigation bar keeps its name ("Vessels"), so VoiceOver and tests are unaffected.

System chrome that can't be recolored from SwiftUI (status bar, the tab bar's unselected icons, the glass behind toolbar buttons) stays in system colors; see Known gaps.

## Type

Dynamic Type text styles only; nothing fixed-size. Numbers always `.monospacedDigit()` so they don't jitter.

| Style | Where |
| --- | --- |
| `.largeTitle.bold()` | Screen titles ("Vessels"; inline and red at night, see Night mode) |
| `.title2.bold()` | Vessel name in sheet and closest card |
| `.headline` | Row titles |
| `.subheadline` | Row details ("Passenger · 14.2 kn", "Manhattan Bridge · 21 mph") |
| `.footnote` | Hints, timestamps |
| `.title3.bold()` + `.fontDesign(.rounded)` | Distances and stat values |
| `.largeTitle.weight(.heavy)` + `.fontDesign(.rounded)` | The two big numbers on the closest card |

## Components

| Component | SwiftUI |
| --- | --- |
| Tabs: Nearby · Map · Camera | `TabView` with `Tab`, SF Symbols `list.bullet`, `map`, `camera.viewfinder`. The list is "Nearby" (it holds boats and trains) |
| Unfolded (regular width) | `NavigationSplitView`: list sidebar + map detail; Camera stays a tab. The system tab bar is hidden there: centered on the window it straddled the list and the map and covered the map's Legal link. A glass switcher "Nearby · Camera" (`RegularTabSwitcher`) sits at the foot of the list column and of the camera instead |
| Vessel row | `HStack`: 36pt type circle, name + detail, trailing distance + bearing arrow (`location.north.fill` rotated by relative bearing). Min height 68pt |
| Train row | Same as the vessel row: 36pt route bullet, "Q to 96 St" (route, "to", destination; "Q train" without one) + "Manhattan Bridge · 21 mph" (under the Underground header just the speed: the header already says it) (see Units), trailing distance over height: above ground against you ("120 ft up"; "about 120 ft up" on the Franklin Av shuttle, whose heights are estimated), underground below the street ("about 40 ft below street") and the bearing arrow |
| Route bullet | Fixed size like the type circle (36pt in rows, 44pt in the detail, 26pt on AR labels and map markers); where it stands alone (map, camera) the element shows Large Content Viewer |
| Closest card | Top of list, filled with the vessel's type color, tap selects it on the map. Text and glyphs in the fill's ink, white or black, whichever contrasts better with the whole fill (`TypePalette.ink`, 4.5:1 or more in light and dark, both halves of First responder's; tested against the asset catalog), all at full strength and not faded when stale (the age line says so). The name wraps; the subtitle is the group alone, the speed shows once in large type |
| Vessel detail | `.sheet` with `.presentationDetents([.medium, .large])` (large only from a map card's "More info"); header: name, finer type ("Pilot", `AISShipType`), MMSI (long press to copy); 2×2 stat tiles (Distance, Speed, Course, Last report) + "Find in Camera"; then the AIS details the boat sends, each row only when known (`VesselRow.detailItems`): Status (navigational status in words), Destination, Arrival ("Nov 17, 14:30 UTC", "(past)" added once it has gone by: AIS ETAs are UTC and carry no year, the nearest year is assumed), Length and width and Draught (in feet like every distance; clamped at 1000 m and 100 m, draught under 10 ft with one decimal, under 0.1 m left out), Heading (only when reported), Position, IMO, Call sign (each copyable: long press, or VoiceOver's Copy action; the header has "Copy MMSI"); then "Look up on MarineTraffic", a plain link built from the MMSI that opens in Safari. Floating unfolded, the card has "More info" for these rows |
| Train detail | The same sheet (or floating card unfolded): 44pt bullet, destination, route ("Q train", "6 express"), level ("Manhattan Bridge · 120 ft up", "Underground · about 40 ft below street", just "Underground" where there's no ground data under the train); tiles Distance, Speed, Course, Last report (the same words as a boat's); a note that positions are estimated from MTA's predictions; "Find in Camera" |
| Map | `Map` with one `ForEach` of custom `Annotation`s keyed by target (the selected one ordered last, `MapMarkerOrder.selectedLast`, so it draws on top without its marker being rebuilt): per vessel (`VesselMarker`: a 34pt disc in the type's color with its icon, 44pt selected with an accent ring, a small wedge on the rim pointing along the course over ground above 0.5 kn (`VesselMap.courseArrowDegrees`, turned against the map's heading, hidden when stopped), and the finer type name in a small solid capsule under it while the visible span is 2.5 km or less, always for the selected boat (`VesselMap.showsTypeLabel`); the selected marker is drawn last, on top) and per train (`TrainMarker`), each tagged with its `TargetID` for selection; `.mapStyle(.standard(emphasis: .muted))`; user location `UserAnnotation()`. A bullet marker per train (26pt with a ring); underground ones smaller (18pt), outlined and dimmed, drawn under everything else. Every marker's touch target is 44pt (an underground marker's is its size plus 6pt). Where an underground marker's touch target would overlap a train above ground or a boat (`TrainMap.undergroundBlockedFromTaps`, from the markers' coordinates, the visible span and the map's size in points), it isn't drawn: MapKit decides which of two overlapping markers a tap selects, unreliably (neither `allowsHitTesting(false)`, nor an untagged annotation, nor declaration order kept the underground one from taking the tap), so the one above ground always wins. The underground train is still in the list, and its marker returns once the map is zoomed in far enough that the two part. Underground markers appear only while the visible span is 3 km or less (`TrainMap.showsUnderground`); trains above ground always show. Zoomed out, a glass note "4 trains underground · zoom in to see them" (`undergroundMapNote`) says how many are hidden. It sits in the bottom-left, 36pt above the map's edge so Apple's Maps logo and Legal link stay fully visible, clear of the buttons (top right), the offline banner (top) and the tab bar; its text size is capped at xxLarge |
| Map buttons | Vertical stack, `.glassEffect()`: re-center (`location.fill`), map style (`square.3.layers.3d`), Key (`info.circle`). Top trailing, except where the system draws a column down the screen's trailing side: the iPhone Duo's status column (time, Wi-Fi and the battery ring that opens Control Center, about 230pt tall and 80-100pt wide at the top right, folded and unfolded). There the stack goes top leading, well away from it (`MapControlsLayout`: the window's trailing safe-area inset at least 20pt wider than its leading one; a phone in landscape has equal insets and keeps top trailing). The safe area already keeps the stack out of the column; the move keeps it away from the Control Center ring too, which sat about 25pt from the buttons. The offline banner keeps clear of the stack on whichever side it is, and the map card treats it as an obstacle as before (a compact card reserves no width for a stack on the leading side: it slides past it vertically, `MapCardLayout.reservedTrailing`) |
| List filter | Toolbar button beside Settings (`line.3.horizontal.decrease.circle`, filled while a filter is on); in compact width also the last button of the map's stack (`mapFilterButton`), since the map follows the same filter on its own tab. A menu that stays open while switches flip: Only what's on the map (side by side only), Boat types (the six groups), Trains and Underground trains (the shared Settings switches, as in the camera's menu), Moving only, Reset. See Filters |
| Collapsible group | Every list group has the same header: its title and count ("In sight · 4", "Out of sight · 12"; VoiceOver "In sight, 4", "Underground · 60"), a chevron that turns when open, tap to open or close (animated). VoiceOver: a header, value "Expanded"/"Collapsed", hint saying what the group holds. Open or closed is kept per group across launches (`ListSection`) |
| Map key | Sheet (medium/large) from the Key button: each boat group's badge with its name (Passenger, Cargo, Service, First responder, Pleasure, Other) and what it covers (by day color and icon, at night the letter in an outlined circle), the course wedge ("Direction"), and the train bullets: "Above ground" (on bridges, viaducts and open track; solid bullet) and "Underground" (in tunnels; outlined, shown when zoomed in). No slashes anywhere on the sheet |
| Map card | See Map card below |
| AR label (selected) | Capsule, solid `bgRaised`: type circle + name + "14.2 kn · 0.2 mi", accent 2pt stroke; stem line down to a dot at the vessel's horizon point |
| AR label (others) | Same capsule, no accent stroke, 60% opacity beyond 0.5 mi. Overlapping labels stack in lanes, nearest lowest, between the horizon and the compass strip; when those lanes are full, farther boats show only their dot. Only the 60 nearest boats and 60 nearest trains within the radius (plus the focused one) get sightlines and labels (`CameraFilter.nearestCandidates`): with 1,000 targets the once-a-second sightline work stalled the tab for 2 s (CHAOS-FINDINGS H2) |
| AR label (train in sight) | The same capsule with the route bullet, the destination and "0.4 mi · 120 ft up"; its dot sits at the rail's true elevation (above the horizon on a bridge) and stacks with the boats |
| AR x-ray label (train underground) | See-through `bgRaised` capsule (55%) with a dashed outline, outlined bullet, a compact depth "about 40 ft deep" ("under 10 ft deep" when shallower than 3 m; "Underground" with no depth; `TrainRow.xrayDepthText`, the list, sheet and VoiceOver keep "below street") over the distance. Dot hollow, stem dashed. They stack in lanes downward from their dots below the horizon and are drawn behind the other labels. Only the 8 nearest within 1.5 km (plus a train found from its detail). They don't count toward the edge hints or as "in sight" |
| Compass strip | Glass capsule at top: heading as "NW 318°", then the ticks with the accent needle, then the "N", "NE" letters under the ticks (`CompassStripLayout`): the needle stays in the tick row and never runs through a letter |
| Off-screen hint | Pill at the screen edge: "2 more ›". Like the accuracy pill it has a solid layer under the glass, so label stems and x-ray leaders passing under it don't show through |
| Accuracy pill | Glass pill (solid layer underneath) above tab bar when heading accuracy is worse than ±10°: "Compass ±12° · wave in a figure 8 to improve" |
| Primary button | Capsule, accent fill, 50pt tall |

## Screens and states

| Screen | Notes |
| --- | --- |
| Permissions (first launch) | Explains location (when in use) and camera. "Continue" shows the location prompt and goes straight to the list without waiting for the answer; the camera is asked for the first time the Camera tab opens ("Turn On Camera"). "Not now — just the list" skips. The relay connects only after this screen, so iOS's local-network prompt doesn't stack on the location prompt. The app works list-only without either permission |
| List | Large title, live status line (count of every boat in the area, then every train shown: "Live · 12 vessels · 80 trains"; the train count goes under the rest when it doesn't fit; scoped, "Live · 3 of 12 vessels · 9 of 80 trains on the map", see Filters), "In sight · N" (open) holding the closest card (nearest boat in sight) and the rest in sight sorted by distance, then "Out of sight · N", collapsed, for boats behind land or too far. With boats around but none in sight, a "No boats in sight from here" card replaces the in-sight group and the out-of-sight list is open (no chevron). Without location there are no sightlines: everything is listed by name under "All boats · N". Under the boats (and under "The river's quiet" when there are none), "Trains": "In sight · N" nearest first, then "Out of sight · N" (open: there are only a few above ground), then "Underground · N", collapsed until tapped. Without location the trains above ground are one group by route ("Above ground · N"), and the underground group is still there. Every group collapses the same way (Collapsible group) |
| Map | Full-bleed map, glass buttons top right. Selecting a marker (boat or train) shows the map card (below), not a sheet; "More info" on it opens the full detail sheet. Selecting from the list still opens the sheet; the list's "Show on map" (the closest card) goes to the map and shows the card |
| Camera | Live preview, compass strip, labels at computed bearings for boats and trains in sight (plus the "Find in Camera" boat or train wherever it is), x-ray labels for the nearest underground trains, off-screen hints counting what's in sight, accuracy pill, "Nothing in sight from here" when nothing is ("No boats in sight from here" with trains off). Filter menu: a 44pt glass circle (`line.3.horizontal.decrease.circle`, filled with an accent dot when the camera's own filter differs from its defaults) at the trailing end of the zoom buttons' row, inside the safe area, opening a menu that stays open while switches flip: Radius (one row opening its own submenu: ½, 1, 2, 3, 5, 10 mi; default 3 mi, the old 5 km; inline, the six rows made the menu taller than the screen and hid the train switches), Boat types (Passenger, Cargo, Service, First responder, Pleasure, Other), Trains and Underground trains (the very same switches as Settings > Trains, so they also hide trains from the list and map), Moving only (boats and trains at 0.5 kn or more, the dead-reckoning floor; a train at a station reports 0), Reset (off at the defaults). The train switches are Settings' state, not camera filters: they don't light the dot, count as "filters on" or enable Reset, and Reset leaves them as they are (it resets the radius, boat types and Moving only). Defaults show everything within 5 km, exactly as before. The radius is the sightline range for boats and trains and caps the x-ray labels (the smaller of 1.5 km and the radius). The focused boat or train is labelled whatever the camera's own filter or radius says; trains switched off in Settings stay off even when focused, as before the menu. Hints and the empty message count only what's shown. The message is "Nothing …" while trains are shown and "No boats …" with them off in Settings, and says why only when the camera's own settings narrow things: "No boats in sight from here" / "Nothing in sight from here" at the defaults (as before), "Nothing in sight within 1 mi" for a changed radius, "No boats match your filters within 1 mi" with a type or Moving only filter (VoiceOver reads "1 mile", "half a mile"). VoiceOver: "Filters, Radius 3 miles, no filters on", hint "Opens the radius and filter menu". Kept across launches (`CameraFilter` in BoatCore, `@AppStorage`); the radius, types and moving only are camera only. Zoom like the Camera app: buttons for each lens plus 2× (0.5, 1, 2, 5 on a phone with an ultra wide and a 5× telephoto; the lit one shows the exact zoom), pinch to zoom, and the Camera Control button's system zoom dial (the buttons step aside while its overlay is up). The camera starts at 1×; labels use the field of view at the current zoom |
| Settings | Display (night mode), Your height, Trains ("Trains" on/off; "Underground trains" on/off, shown while trains are on: off hides them from the list, the map and the camera), Units (see Units), Server (the address, placeholder `wss://example.com/v2/targets`; errors describe the format, never a private address), About (Version "1.0, build 17 (355e543)", Hinge, and the row "Data and credits", which opens one screen with every credit and notice: boats via aisstream.io, trains from the MTA's real-time predictions with the not-endorsed and as-is sentences, Apple Maps, NYC Open Data, Census TIGER/Line, USGS, OpenStreetMap contributors, and "Positions can be late or wrong. Don't use this app for navigation or safety."; each source with a link opens in the browser. The words are `DataCredits` in BoatCore, the layout `DataCreditsView`). All stored like the other settings |
| Empty | "The river's quiet". ("Widen the area" waits until the relay can change its area; a button that can't work reads as broken) |
| Offline | Glass banner "Can't reach the server" · "Showing the last positions. Trying again…" (or "Check the address in Settings" while an address typed there is in use) · Retry; a server that turns the app away (401/403) says "The server didn't accept this app" · "Update the app from TestFlight." (`FeedText`). The camera shows the same as a one-line notice with Retry above its other pills. List frozen at 70% opacity with last-report ages |
| Duo cover (466×678) | Same list, compact: inline-size title, horizontal closest card |
| Duo unfolded (951×669) | Split view: list left (340pt), map right, floating glass detail card in the corner that leaves the selected marker clear (bottom right first; see Map card). The list shows only what's on the visible map (Filters). The map buttons are top leading, away from the status column |

## Map card

Selecting a boat or train on the map shows a card over it. Compact width (a phone, the Duo cover): a glass summary docked at the top or bottom edge: type badge or route bullet, name or destination, finer type and speed, a status line (navigational status and destination when the boat sends them; the train's place and speed), distance and bearing, "More info" and a close button. The header row is a button to "More info" too. Regular width (unfolded): the detail view floats in one of the four corners (at most 380pt wide), with "More info" for the AIS details.

The rule (`MapCardLayout.place` in BoatCore, pure and tested): the card never covers the selected marker (its 44pt disc and type label, plus a 12pt margin), the map buttons, the offline banner, the underground note, Apple's Maps logo and Legal link (a 120×36pt obstacle in the bottom-left corner of the safe area, `MapCardScene.attribution`), or the safe areas (status bar, tab bar). Compact cards are as wide as the map's safe area less 16pt margins and the buttons' column on the right (the buttons' width plus 8pt), so they never reach it; a card that would overlap the banner, the note or the attribution slides away from its edge past it. Candidates in order: compact bottom, then top (the bottom is nearest the thumb); regular bottom trailing, bottom leading, top leading, top trailing. The current placement is kept while it leaves the marker clear (so the card doesn't flap), otherwise the first clear candidate; when none is clear the card stays where it is and the map pans the marker into the middle of the area the card leaves (`uncoveredCenter`, at a point where the whole marker box fits). Selecting a target moves the map only when its marker is off screen or under the card (`selectionPan`), keeping the zoom; at most two pans per selection, none under 2pt, and a pan never runs while the user is dragging or pinching the map; if the map can't yet say where the marker is, the card takes its default place (bottom, or bottom trailing) without a pan; only when the marker is off screen and the map shows more than 20 km does it zoom to 5 km first (the dev area itself is about 9 km, so in practice selection never zooms). Placement is re-checked when the map settles after a pan or zoom (`onMapCameraChange(.onEnd)`, with `MapProxy` turning the coordinate into a point), when the target moves on the map's 5 s tick, and when the card's measured size or the controls change; moves are animated. The card's height is capped (40% of the map compact, 60% regular, and never taller than the tallest gap between the controls) and scrolls inside at the largest text sizes, with the header row kept in view; at accessibility text sizes "More info" is an icon button pinned in the header beside Close, so it is never scrolled out of reach.

## Filters

The list and the map share one filter (`BrowseFilter` in BoatCore, stored as `browseFilter`), apart from the camera's (`CameraFilter`, which has a radius and labels only). From the list's filter button: Boat types (Passenger, Cargo, Service, First responder, Pleasure, Other), Trains and Underground trains (Settings > Trains' own switches, shared with Settings and the camera's menu: not stored in the filter, not counted as a filter, left alone by Reset), Moving only (0.5 kn and up, the dead-reckoning floor; a train at a station reports 0; `gauge.with.needle`, in the camera's menu too), and side by side only "Only what's on the map". Reset puts the types, Moving only and Only what's on the map back (on); in compact width, where that switch isn't offered, Reset is off unless a type or Moving only is on. The button is filled while a type or Moving only is on, and VoiceOver reads "Filters, 1 filter on, only what's on the map". The map's markers follow the same filter (never a region). A selected boat or train is always shown, in the list and on the map, whatever the filter or the region says, until it's deselected. The Closest card honours the filter: it is the nearest boat in sight among those listed (a hidden boat being "closest" would contradict the list under it).

Side by side (regular width), the list holds only what's on the visible map, on by default. The visible map is the bounding box of the map frame's four corners (`MapRegion.bounding`; MapKit's own region covers the map under the list's column too), taken when the map settles (`onMapCameraChange(.onEnd)`) and 250 ms after that (`MapViewport`), so a run of pans updates the list once and dragging costs nothing per frame. A coordinate is on the map with a 3% margin of the span on each side, so a marker whose center is just past the edge counts (`MapRegion.contains`, antimeridian-safe). Boats and trains are placed where the markers are (dead-reckoned). Underground trains count where they are, whether or not the map draws them at this zoom: they stay in their collapsed "Underground" group. Compact width (the list on its own tab, the Duo cover) has no map beside it and no region.

Counts: while anything is left out, the status goes on its own line and the scope leads the counts, so "3 of 12" can't be read as all there is: "On the map: 3 of 12 vessels · 9 of 80 trains" ("With filters on:", "On the map, with filters on:"; `BrowseResult`; identifiers `vesselCount`, `trainCount`, `listScope`). VoiceOver reads the whole status line as one element: "Live. On the map: 3 of 12 vessels, 9 of 80 trains" (`BrowseText.spokenStatusLine`). A scope that leaves everything in reads like none ("12 vessels"). When nothing at all is listed although boats or trains are about: "Nothing on this part of the map" with "Show the whole list" ("Show all that match your filters" while boat types or Moving only are on), which turns Only what's on the map off and nothing else (it doesn't move the map: the user put it there, and the switch is in the menu to turn back on), or "Nothing matches your filters" with "Reset filters". When only one kind is scoped away, its section says so ("No boats on this part of the map", "No trains match your filters").

## Units

Every unit the app shows goes through one formatter, `Units` in BoatCore (`format(value, quantity, kind:)`, from the user's choices and the device's region), and views only pass it in (`\.units`, set at the root). The relay sends knots for every kind (relay/PROTOCOL.md); nothing on the wire changed.

| | Standard (default) | Settings > Units choices |
|---|---|---|
| Speed | Boats knots, one decimal ("14.2 kn"). Trains mph, whole ("21 mph"), km/h in a metric region. Aircraft (later) knots | Standard for each vehicle, Knots, mph, km/h: a choice applies to every kind. Boats keep one decimal, trains whole numbers |
| Distance | Miles ("0.2 mi", feet under a tenth), kilometers in a metric region ("1.4 km", meters under 0.1 km) | Automatic, Miles, Kilometers, Nautical miles ("0.3 nmi"; under 0.1 nmi in the height unit). Never nautical miles unless chosen: the user is on shore |
| Height and depth | Feet to the nearest 10 ("120 ft up", "about 40 ft below street"), meters (whole) in a metric region | Automatic, Feet, Meters. Also the AIS size and draught |

"Stopped" stays for a train at a station. Values are clamped before they become whole numbers (speeds at 1,000 kn, distances at 20,000 km, heights at 100 km; NaN and negatives as 0), and a train over 200 kn or a boat outside AIS's 0-102.2 kn decodes with no speed. The out-of-sight note ("more than 3 miles away"), its VoiceOver hint and the key's course wedge ("over 0.5 kn") follow the units too. At accessibility text sizes each Units choice is its own row under a "Speed", "Distance" or "Height and depth" heading (a menu's "Standard for each vehicle" wrapped and was cut off); VoiceOver reads "Miles per hour", "Kilometers per hour". VoiceOver says "knots", "miles per hour", "kilometers per hour", "nautical miles", "meters". The camera radius stays stored in meters; only its label follows the distance unit ("5 km", "2.7 nmi"). Settings > Your height stays in feet (an input, not a reading). The footer under Units says what Standard means here: "Standard speed: knots for boats, mph for trains."

## Untrusted text

A boat's name, destination and call sign are typed in by its crew. The relay strips control and invisible characters (relay/PROTOCOL.md, Vessels); the app cleans them again (`VesselDetailText.plain`: one line, no controls, bidirectional overrides or zero-width characters, whitespace collapsed, `@` padding trimmed) and shows them with `Text(verbatim:)`: never as markdown, a link or a localization key.

## Layout rules

- Size from container and size class; no fixed widths, no orientation lock (see CLAUDE.md, Devices).
- 16pt screen margins, 22pt corner radius on grouped surfaces, 28pt on the closest card.
- Touch targets ≥ 44pt. Icon-only buttons get `accessibilityLabel`.
- Every row and card reads as one accessibility element: "NYC Ferry 112, passenger, 0.2 miles northwest, 14 knots".
- Respect Reduce Transparency: glass falls back to `bgSurface` automatically for system components; for custom glass, check `accessibilityReduceTransparency` and use a solid `bgRaised`.

## Sightlines

A boat is in sight when it's within range (the camera's radius, 5 km or about 3 miles unless the filter menu changes it; the list always uses 5 km) and nothing, ground or roof, rises more than a meter above the straight line from the user's eye to the boat's upper deck (8 m above the water). The first 75 m from the user (their own building and street; GPS is tens of meters off) and the last 50 m before the boat (its pier) don't count. Heights come from a ~50 m grid (`HarborSurface` in BoatCore): the highest roof or ground in each cell, from NYC Open Data building footprints (roof height plus ground elevation), 0 on the water, with the water/land line from Census TIGER/Line outlines; New Jersey land has no building data and counts as 20 m. The grid is rough on purpose: trees, bridges and the Earth's curve are ignored.

The eye is GPS altitude when GPS vouches for it to within 15 m, otherwise standing on the ground (1.6 m above the grid's ground), and never below 4 m above sea level (the waterfront's bulkheads and piers; GPS often puts someone at the river's edge in the river). Indoors GPS rarely has an altitude, so Settings > Your height can set it by hand, in feet above the street (about 10 ft a floor). From a high window or the Brooklyn Bridge deck the line clears low roofs; Lower Manhattan's towers still hide the Hudson.

The camera labels the boats and trains in sight, and x-ray labels the nearest underground trains (never in sight); the list puts the rest under "Out of sight"; the map still shows every boat in the area. The check takes any target height, so it isn't tied to boats.

Trains (BoatCore's `TrainList`) use the same check to the car roofs, 3 m above the rail height the relay sends. A train underground is never in sight and the check doesn't run: trains split into in sight, out of sight (above ground but hidden or too far) and underground, each nearest first.

Elevated targets: a target whose top is at least 10 m above the ground under it (`Sightlines.elevatedTargetMeters`: a train on a bridge or viaduct; a boat's 8 m deck over the water never is) ignores its own grid cell and the eight around it (about one cell diagonal, ~70 m). Each cell holds the tallest roof anywhere in it, so the cells beside a bridge hold the buildings along it, and the bridge itself isn't in the grid: without this a train on the approach read as hidden behind its own neighbors. Anything farther along the line still counts, and boats keep the exact rule (a test compares every boat sightline over the harbor grid with the old algorithm). From the DUMBO waterfront the B on the Manhattan Bridge's Brooklyn approach stays hidden: the line runs low past tall buildings (an 84 m cell 120 m out) well short of the bridge; from the river off DUMBO it is now in sight.

One eye for both: the camera places boats and trains from the same eye, the one the sightlines use (`VesselList.eyeAltitude`, `TrainList.eyeAltitude`: `Sightlines.eyeAltitude(at:height:)`), by each point's true elevation (`ARProjection.elevationDegrees`). A train on a bridge above the eye sits above the horizon line, one in a tunnel below it, and a boat's waterline just below it. Boats used to be placed from a fixed 1.6 m eye; now from the waterfront (eye 4 m) their dots sit a little lower, and from a high window (Settings > Your height) much lower, where the water really is.

## Positions between reports

AIS reports reach the relay every few seconds at best, and around DUMBO often only every minute or two, long enough for a ferry to cover hundreds of meters. So a boat's position is its last report carried forward along its course over ground at its speed over ground (`DeadReckoning` in BoatCore), for at most 2 minutes, after which it may well have turned, slowed or docked. Slower than 0.5 kn, or without a speed or course, it stays where it was reported. The list's distances, the map's markers, sightlines and the camera all use the estimate. Camera labels move on ten times a second between the once-a-second updates, so they glide with the boat. Once a report is a minute old, the label adds its age ("6.1 kn · 0.4 mi · 2 min ago").

Trains are estimated by the relay and re-sent every 10 s, so the same `DeadReckoning` carries them for at most 15 s: enough for one missed update, and no more (the track curves, trains stop at stations and change level; at 30 s a stale train was carried about 450 m past a bridge portal while still drawn as elevated); a train standing at a station (speed 0) stays put. A train's position is live under 20 s old and stale up to 60 s, when it's dropped.

## Build order

1. Color sets + vessel-type mapping in BoatCore (tested).
2. List screen with fixture data, including empty and offline states (UI tests assert `vesselCount`, empty title, offline banner).
3. Map + detail sheet.
4. Split view for regular width; verify on the Duo simulator folded, unfolded, and across the transition.
5. Night mode palette + sun-position function (tested).
6. Camera screen (Milestone 3).

## Status (2026-11-16)

Steps 1-6 are built: color tokens, vessel types, list with empty/offline states, map + detail, split view, night mode (with sun position in BoatCore), camera screen. Design review fixes from the screenshot tour: rows, offline banner and detail stats stack at accessibility text sizes; camera overlay and map buttons cap their text size and show Large Content Viewer; the detail sheet has a close button; location and camera hints are buttons (ask, or open Settings when denied); build info moved to Settings > About; at night the list title is inline and red (see Night mode).

Performance (2026-11-10, after build 7 ran hot on a phone): a `TimelineView` wrapped around the whole app (night mode's minute clock) around the screens' own `TimelineView`s made SwiftUI re-run layout every frame, a full CPU core on every screen, idle or not. Night mode now moves its clock with a task. The camera also stopped recomputing every vessel and redrawing every label on each compass reading: vessels, distances and sightlines are worked out once a second, only the label layer follows the compass, the heading is smoothed and published only when it moves 0.2° or more, and labels are solid instead of glass. Opt-in performance tests (README, Performance), 80 vessels, app CPU over 8 s, before → after:

| Screen | CPU before | CPU after |
|---|---|---|
| Camera, compass panning 30×/s | 7.82 s (98% of a core) | 0.64 s (8%) |
| List sitting | 7.45 s | 0.02 s |
| List scrolling (6 swipes) | 56.9 s | 1.9 s |
| Map sitting | 7.48 s | 0.17 s |

Trains (2026-11-11): subway trains from the relay's /v2/targets are in the list (under the boats: in sight, out of sight, a collapsed underground group), on the map (bullet markers, underground ones dimmed), in the camera (labels for trains in sight, x-ray labels for the 8 nearest underground ones within 1.5 km) and in their own detail sheet, with Settings toggles for trains and for underground trains. The store publishes trains at most once a second (the relay re-sends ~80 in a burst every 10 s). The performance fixture now carries 80 trains (60 underground) beside the 80 vessels.

Performance with trains (2026-11-16): the same four opt-in tests run on one quiet Mac and one simulator (iPhone 18 Pro, iOS 27.0), each in its own `xcodebuild`, `main` before trains against the trains branch, app CPU over 8 s, mean of 5 iterations. The 2026-11-10 numbers above were measured on another day and machine state, so they aren't comparable to these; the same-day pair is the comparison.

| Screen | Before trains (80 boats) | With trains (80 boats + 80 trains) | Peak memory |
|---|---|---|---|
| Camera, compass panning 30×/s | 1.19 s (15% of a core) | 1.66 s (21%) | 50 → 53 MB |
| List sitting | 0.015 s | 0.020 s | 48 → 49 MB |
| List scrolling (6 swipes) | 1.69 s | 2.97 s | 49 → 58 MB |
| Map sitting | 0.115 s | 0.127 s | 122 → 128 MB |

Twice the objects cost the camera and the list scroll 39% and 76% more CPU and the map about 10%; nothing is near the 98%-of-a-core regression of build 7. The simulator measures app CPU only: the phone's GPU work and heat are still unmeasured (Known gaps).

List follows the map, filters, collapsible groups, units (2026-11-18, `m3/list-follows-map`): the same four opt-in tests, one hour, one simulator, branch / base (`m3/map-key-simplify`, 3f26181) / branch again, app CPU over 8 s, mean of 5 (RSD; first iteration in brackets where it stands out):

| Screen | Branch, run 1 | Base (3f26181) | Branch, run 2 | Peak memory (base → branch) |
|---|---|---|---|---|
| Camera, compass panning 30×/s | 1.68 s (11%) | 2.08 s (26%; first 3.16) | 1.71 s (9%) | about 54 → 55 MB |
| List sitting | 0.161 s (173%; first 0.72, others 0.007-0.034) | 0.069 s (151%; first 0.28, others 0.007-0.033) | 0.212 s (178%; first 0.97, others 0.012-0.034) | about 50 MB |
| List scrolling (6 swipes) | 3.32 s (8%) | 3.02 s (9%) | 3.20 s (13%) | about 58 → 60 MB |
| Map sitting | 0.331 s (85%; first 0.88) | 0.188 s (34%) | 0.454 s (110%; first 1.45) | about 140 MB |

The camera is no slower (an earlier 1.43 s vs 2.04 s was a different hour). Steady state the list and map cost what they did; the list scroll is 6-10% slower (more rows: group headers). Both list and map have a first measured iteration far above the rest, the base's list too (0.28 s), larger on the branch. An A/B with the list's filter button taken out of the toolbar kept the spike (1.17 s and 0.28 s without it, 0.52 s and 1.16 s with it), so the menu isn't the cause; it stays unexplained. These tests run compact width, so the region filter isn't in them; it only works when the map settles (`onEnd`, then 250 ms), never per frame.

Beta fixes (2026-11-19, `m8/beta-fixes`, 0787f0f): one perf run, one simulator, app CPU over 8 s, five iterations each
(no same-hour base run, so compare with care; fseventsd was at 127% at the start):

| Screen | Mean (RSD) | Iterations | Peak memory |
|---|---|---|---|
| Camera, compass panning 30×/s | 1.92 s (38%) | 2.62, 2.66, 0.90, 1.67, 1.77 | 58 MB |
| List sitting | 0.213 s (197%) | 0.96, 0.037, 0.012, 0.037, 0.015 | 53 MB |
| List scrolling (6 swipes) | 3.13 s (11%) | 2.57, 3.00, 3.33, 3.46, 3.29 | 62 MB |
| Map sitting | 0.137 s (40%) | 0.139, 0.198, 0.085, 0.183, 0.078 | 145 MB |

The map's first-iteration spike (0.88-1.45 s before) is gone: the map no longer works out sightlines it never used
(CHAOS-FINDINGS H2), and its mean is down from 0.33-0.45 s. The list's first iteration still stands out (0.96 s). The
launch timeline (CHAOS-FINDINGS H1) puts MapKit's first creation at 0.3-1.1 s of main thread on the simulator, a
likely part of the old map spike; the list's has no such single cause in the timeline. The camera is within its
earlier spread (1.68-2.08 s) in a noisy run; the 60-per-kind candidate cap keeps the nearest 60 of the test's 80 boats
and 80 trains, so it can only lower the sightline work.

Robustness (2026-11-18, `m8/crash-fixes`, docs/CRASH-HUNT.md):

- Feed liveness: the app pings the relay every 15 s; no pong within 10 s, or nothing it can decode within 20 s of
  connecting, closes the connection, so a wedged relay, a stalled tunnel or a half-open path after a network handover
  shows the offline banner with Retry and reconnects with backoff instead of sitting "live" while the list empties.
  There is no idle timeout: nothing in the protocol promises a cadence. The app accepts messages up to 8 MiB; the
  relay logs a warning for a snapshot over 512 KiB.
- Camera session ownership: one `CameraSession` for the app (`BoatARApp`, passed down the environment), configured on
  its own queue, started and stopped only by `CameraLifecycle` in `ContentView` (Camera tab selected and the app not
  in the background), which also runs the compass and motion tracking and best location accuracy. Folding or
  unfolding on the Camera tab keeps the same session running and tracking on. A runtime error or the end of an
  interruption restarts the session if it's still wanted.
- Location: ten-meter accuracy on the list and map (their distances are tenths of a mile), best only while the camera
  shows.
- Publishing cadence: boats are published at most 4 times a second (the first change after a quiet spell, such as
  the snapshot, at once), trains at most once a second as before, and pruning on a message at most once a second.
  Course and heading are kept in [0, 360), a boat with an impossible position is dropped, a target timestamped more than 15 min in
  the future counts as 15 min after it arrived, and one boat shows per MMSI.

Bridgewatch brand (2026-11-16): display name, permission strings and screens say Bridgewatch; accent is brand indigo (see Color tokens, Brand); app icon B2 (aircraft, curved bridge with a bullet, boat) with default, dark and tinted variants. Checked in the screenshot tour on the iPhone 18 Pro simulator: light, dark, AX5 and night (still red only).

Known gaps:

- The toggle-on track uses the accent with the system's white knob (about 2:1 against the dark-mode periwinkle, which is the system's usual pairing; the track itself is about 7:1 against the sheet).

- System chrome that can't be recolored in night mode: the status bar, the tab bar's unselected icons and the glass behind toolbar buttons.
- `.preferredColorScheme(nil)`: night mode forces dark, and turning it off hands the choice back to the system. Check it on a device: with the system on Light, switch Night mode On, then Off. The app must return to light.
- The camera heading and label placement are verified in tests and math only, not yet on a phone at the river.
- Sightlines are rough (see Sightlines): ~50 m cells holding each cell's tallest roof, no New Jersey buildings, no trees, ground interpolated from building data (parks next to bluffs read a few meters high). GPS altitude indoors is usually missing: Settings > Your height covers apartment windows. Check from the waterfront, an apartment and the Brooklyn Bridge.
- Right after the app (re)connects, the relay's snapshot stamps each boat with the time of its newest message of any kind, not of its last position, so a boat whose newest message was static data is carried forward from a little too late until its next position report.
- Performance numbers are from the simulator (app CPU only). The phone's GPU work (glass, the camera preview) and heat are unmeasured: watch the phone's temperature with the camera open for a few minutes.
- Underground depth is the relay's depth model (relay/PROTOCOL.md, Levels), no longer a flat -10 m: published depths at four stations and two river tubes, a 6 m cut-and-cover rule everywhere else, so `altitudeEstimated` is true for every underground train and the text always says "about". Depth below the street (`TrainText.belowStreet`) is the sightline grid's ground under the train (`SurfaceGrid.ground`, ~50 m cells, rough near bluffs) less the rail: it never says up, level or "below you". Under the river the grid's ground is the water (0 m), so a train in a tube reads "about 90 ft below street" though there is no street over it. Shallower than 3 m (the model's cover rule) reads "just below street"; no ground cell, or a relay older than the depth model (no `altitudeEstimated`, flat -10 m), reads "Underground" with no figure. Above ground the height stays against the user's eye.
- The Franklin Av shuttle (`franklin-av`, about 4 km from DUMBO) is an above-ground stretch with estimated heights ("about … ft up"). Its sightline is treated like any other above-ground train's, unchanged: from the waterfront it usually reads out of sight (too far or behind Brooklyn's buildings).
- The map's tap-blocking rule (an underground marker that overlaps a marker above ground isn't drawn) assumes an unrotated, unpitched map: it turns the narrower side of the visible span into meters per point, which a pitched or rotated map doesn't keep, and it works with the view's size as last measured (400 pt until then), failing open (nothing blocked) at a zero size. A misjudged overlap leaves a marker drawn that MapKit may let take a tap over the one above it, or hides one that isn't covered.
- An elevated target's own cell and the eight around it are skipped by the sightline check, so a tall roof in the ring cell right between the observer and a bridge train can't hide it, though it is on the line (`ElevatedSightlineTests`): accepted, to stop a bridge's own approach buildings hiding it.
- Train positions are estimates from MTA's predictions (relay/PROTOCOL.md, Estimate): a few hundred meters off on the bridge runs, and a train that leaves a station shows there until the next poll.
- The white letter on the L's gray and the G's light green bullets is MTA's standard but low contrast (about 2.4:1 and 2.3:1); the bullets are bold and every row and label also says the route to VoiceOver.
- The camera's radius reaches 10 mi, but the relay only sends what's inside its bounding box (`devBoundingBox`, about 7.6 by 6.7 km), so radii past about 3.5 mi show little more until that area grows.
- The camera filter's radius, boat types and "Moving only" apply to the camera only; the list and the map have their own filter (Filters). (Its train switches are Settings > Trains', which apply everywhere.)
- Without camera access the filter button isn't shown (the bottom row is only there with the camera allowed); a stored filter still applies once access is given, which is harmless since nothing is labelled until then.
- A focused train ("Find in Camera") is still hidden when trains, or underground trains, are off in Settings, as before the filter menu: those switches hide trains everywhere. The camera's own filter (types, Moving only, radius) never hides the focused boat or train.
- The filter menu is a system menu: at night its items draw in system colors, not the red-only palette, like the other system chrome above.
- The map card's placement is checked by the pure tests and by UI tests that compare accessibility frames; the marker's on-screen point comes from `MapProxy`, and a pitched or rotated map hasn't been tried. The type label under a marker is allowed a fixed 20pt (its text size is capped at Large).
- The Duo fold/unfold transition is untested: the simulator can't fold, so tests cover the cover-screen layout and the regular-width layout forced with `BOATAR_FORCE_REGULAR`, not the live change between them. On the Camera tab the fold now keeps one capture session (Robustness above); that the preview stays live through the swap of preview views, and that tracking keeps running, needs a real Duo.
- The unfolded Duo's status column has only been seen in the owner's screenshot: the simulator can't unfold, and the forced regular-width tests run on an iPhone 18 Pro in landscape, which has no such column. The map buttons' move is tested on the Duo cover screen, where the same column is a trailing safe-area inset. That the unfolded Duo reports the column the same way (as its map's trailing inset of about 84pt in the screenshot suggests) is unverified on a device.
- "Only what's on the map" uses the bounding box of the visible map's corners: on a rotated map that box is a little bigger than what shows, so a boat just outside a corner can be listed.

