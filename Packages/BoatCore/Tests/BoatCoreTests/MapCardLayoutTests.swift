import CoreGraphics
import Foundation
import Testing
@testable import BoatCore

/// The map card's placement rule: never over the selected marker (with a margin) or the map's controls, stay put
/// while clear, first clear candidate otherwise, and a pan target when nothing is clear.
@Suite struct MapCardLayoutTests {
    /// iPhone 18 Pro portrait (map under the status bar and tab bar), the Duo cover, the Duo unfolded's map column,
    /// a phone in landscape.
    static let screens: [(size: CGSize, insets: MapInsets)] = [
        (CGSize(width: 402, height: 874), MapInsets(top: 62, bottom: 83)),
        (CGSize(width: 466, height: 678), MapInsets(top: 44, bottom: 83)),
        (CGSize(width: 611, height: 669), MapInsets(top: 24, bottom: 70)),
        (CGSize(width: 874, height: 402), MapInsets(top: 0, leading: 62, bottom: 50, trailing: 62)),
    ]

    /// The map button stack, top trailing (16 pt in, 3 buttons).
    static func buttons(_ scene: MapCardScene) -> CGRect {
        let safe = scene.safeBounds
        return CGRect(x: safe.maxX - 16 - 44, y: safe.minY + 16, width: 44, height: 136)
    }

    func scene(_ screen: (size: CGSize, insets: MapInsets), obstacles: Bool = true) -> MapCardScene {
        let bare = MapCardScene(container: screen.size, safeInsets: screen.insets)
        guard obstacles else { return bare }
        let safe = bare.safeBounds
        // Buttons top right, the underground note bottom left, the offline banner across the top.
        let note = CGRect(x: safe.minX + 16, y: safe.maxY - 16 - 36 - 34, width: 260, height: 34)
        let banner = CGRect(x: safe.minX + 16, y: safe.minY + 8, width: safe.width - 32 - 64, height: 60)
        return MapCardScene(container: screen.size, safeInsets: screen.insets,
                            obstacles: [Self.buttons(bare), note, banner, bare.attribution()])
    }

    func marker(_ point: CGPoint) -> CGRect {
        MapCardLayout.markerRect(center: point, radius: 22, labelHeight: 18)
    }

    // MARK: The invariant

    /// A sweep of marker positions (on screen and just off it), screens, text sizes (card heights) and both layouts:
    /// the card never covers an obstacle, always stays inside the safe area, and leaves the marker clear either
    /// where it is or where the decision pans it to.
    @Test(arguments: [false, true])
    func neverCoversTheMarkerOrTheControls(_ regular: Bool) throws {
        var checked = 0
        for screen in Self.screens {
            let scene = scene(screen)
            let reserved = regular ? 0 : 44 + 8.0
            let width = MapCardLayout.cardWidth(scene: scene, reservedTrailing: reserved,
                                                maxWidth: regular ? MapCardLayout.regularMaxWidth : nil)
            let candidates = regular ? MapCardPlacement.regularPreference : MapCardPlacement.compactPreference
            let maxHeight = MapCardLayout.maxCardHeight(
                scene: scene, cardWidth: width,
                fraction: regular ? MapCardLayout.regularMaxHeightFraction : MapCardLayout.compactMaxHeightFraction,
                candidates: candidates)
            #expect(maxHeight > 60, "\(screen.size): \(maxHeight)")
            for height in [90.0, 150, 220, 400] {
                let size = CGSize(width: width, height: min(height, maxHeight))
                var current: MapCardPlacement?
                for fx in stride(from: -0.1, through: 1.1, by: 0.05) {
                    for fy in stride(from: -0.1, through: 1.1, by: 0.025) {
                        let point = CGPoint(x: Double(screen.size.width) * fx, y: Double(screen.size.height) * fy)
                        let decision = try #require(MapCardLayout.place(
                            marker: marker(point), cardSize: size, scene: scene, candidates: candidates,
                            current: current), "no placement on \(screen.size) for \(size)")
                        current = decision.placement
                        let frame = decision.frame
                        #expect(scene.cardBounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                                "\(frame) outside \(scene.cardBounds)")
                        for obstacle in scene.obstacles {
                            #expect(!frame.intersects(obstacle), "\(frame) covers \(obstacle)")
                        }
                        let clearOf = decision.panMarkerTo.map(marker) ?? marker(point)
                        let keepClear = clearOf.insetBy(dx: -MapCardLayout.markerMargin, dy: -MapCardLayout.markerMargin)
                        #expect(!frame.intersects(keepClear),
                                "\(frame) covers the marker at \(decision.panMarkerTo ?? point) on \(screen.size)")
                        if let pan = decision.panMarkerTo {
                            #expect(MapCardLayout.isVisible(pan, scene: scene))
                        }
                        checked += 1
                    }
                }
            }
        }
        #expect(checked > 5_000)
    }

    // MARK: Preference and hysteresis

    let phone = MapCardScene(container: CGSize(width: 402, height: 874), safeInsets: MapInsets(top: 62, bottom: 83))
    let card = CGSize(width: 310, height: 160)

    @Test func firstClearCandidateInOrder() throws {
        // A marker near the top: the bottom (preferred) is clear.
        let top = try #require(MapCardLayout.place(
            marker: marker(CGPoint(x: 200, y: 200)), cardSize: card, scene: phone,
            candidates: MapCardPlacement.compactPreference, current: nil))
        #expect(top.placement == .bottom)
        #expect(top.panMarkerTo == nil)
        #expect(Double(top.frame.maxY) == 874.0 - 83 - 16)
        // A marker near the bottom: the bottom card would cover it, so the top.
        let bottom = try #require(MapCardLayout.place(
            marker: marker(CGPoint(x: 200, y: 700)), cardSize: card, scene: phone,
            candidates: MapCardPlacement.compactPreference, current: nil))
        #expect(bottom.placement == .top)
        #expect(Double(bottom.frame.minY) == 62.0 + 16)
    }

    @Test func keepsTheCurrentPlacementWhileItIsClear() throws {
        // The top card is current; the marker sits low enough for either: no move.
        let kept = try #require(MapCardLayout.place(
            marker: marker(CGPoint(x: 200, y: 450)), cardSize: card, scene: phone,
            candidates: MapCardPlacement.compactPreference, current: .top))
        #expect(kept.placement == .top)
        // The marker drifts up under the top card: now it moves.
        let moved = try #require(MapCardLayout.place(
            marker: marker(CGPoint(x: 200, y: 150)), cardSize: card, scene: phone,
            candidates: MapCardPlacement.compactPreference, current: .top))
        #expect(moved.placement == .bottom)
    }

    /// A marker moving back and forth across the bottom card's edge moves the card once, to the top, and it stays.
    @Test func doesNotFlap() throws {
        var current: MapCardPlacement? = .bottom
        var moves = 0
        for step in 0..<200 {
            let y = 610 + 90 * sin(Double(step) / 5)
            let decision = try #require(MapCardLayout.place(
                marker: marker(CGPoint(x: 200, y: y)), cardSize: card, scene: phone,
                candidates: MapCardPlacement.compactPreference, current: current))
            if decision.placement != current { moves += 1 }
            current = decision.placement
        }
        #expect(moves == 1)
        #expect(current == .top)
    }

    @Test func cornersInRegularWidth() throws {
        let map = MapCardScene(container: CGSize(width: 611, height: 669), safeInsets: MapInsets(top: 24, bottom: 70))
        let floating = CGSize(width: 380, height: 300)
        // Marker bottom right: bottom trailing would cover it; bottom leading is next and clear.
        let decision = try #require(MapCardLayout.place(
            marker: marker(CGPoint(x: 560, y: 520)), cardSize: floating, scene: map,
            candidates: MapCardPlacement.regularPreference, current: nil))
        #expect(decision.placement == .bottomLeading)
        #expect(decision.frame.minX == 16)
    }

    // MARK: Obstacles

    @Test func slidesPastTheControls() throws {
        let banner = CGRect(x: 16, y: 70, width: 300, height: 60)
        let note = CGRect(x: 16, y: 700, width: 250, height: 34)
        let scene = MapCardScene(container: phone.container, safeInsets: phone.safeInsets, obstacles: [banner, note])
        let top = try #require(MapCardLayout.frame(for: .top, cardSize: card, scene: scene))
        #expect(top.minY == banner.maxY + 8)
        let bottom = try #require(MapCardLayout.frame(for: .bottom, cardSize: card, scene: scene))
        #expect(bottom.maxY == note.minY - 8)
    }

    @Test func aCardThatDoesNotFitIsNoCandidate() {
        #expect(MapCardLayout.frame(for: .top, cardSize: CGSize(width: 500, height: 100), scene: phone) == nil)
        #expect(MapCardLayout.frame(for: .top, cardSize: CGSize(width: 300, height: 800), scene: phone) == nil)
        #expect(MapCardLayout.frame(for: .top, cardSize: .zero, scene: phone) == nil)
        // An obstacle filling the map leaves no room.
        let blocked = MapCardScene(container: phone.container, safeInsets: phone.safeInsets,
                                   obstacles: [CGRect(x: 0, y: 0, width: 402, height: 874)])
        #expect(MapCardLayout.place(marker: marker(CGPoint(x: 10, y: 10)), cardSize: card, scene: blocked,
                                    candidates: MapCardPlacement.compactPreference, current: nil) == nil)
    }

    // MARK: Fallback and panning

    @Test func panTargetWhenNothingIsClear() throws {
        // A card too tall for the marker to clear it at either edge.
        let tall = CGSize(width: 310, height: 500)
        let decision = try #require(MapCardLayout.place(
            marker: marker(CGPoint(x: 200, y: 437)), cardSize: tall, scene: phone,
            candidates: MapCardPlacement.compactPreference, current: .top))
        #expect(decision.placement == .top, "keeps the current placement")
        let pan = try #require(decision.panMarkerTo)
        // Into the middle of what the card leaves: below it.
        #expect(pan.y == (decision.frame.maxY + 874 - 83) / 2)
        #expect(pan.x == 201)
        #expect(!decision.frame.intersects(marker(pan)))
    }

    @Test func uncoveredCenterPicksTheLargestPart() {
        let map = MapCardScene(container: CGSize(width: 600, height: 600))
        // A card in the bottom-right corner: the part to its left is the larger.
        let corner = CGRect(x: 380, y: 300, width: 200, height: 280)
        #expect(MapCardLayout.uncoveredCenter(scene: map, card: corner) == CGPoint(x: 190, y: 300))
        let topBand = CGRect(x: 16, y: 16, width: 568, height: 100)
        #expect(MapCardLayout.uncoveredCenter(scene: map, card: topBand) == CGPoint(x: 300, y: 358))
    }

    @Test func panMovesTheCameraByTheMarkersOffset() {
        let center = MapCardLayout.panCenter(cameraCenter: CGPoint(x: 200, y: 400), marker: CGPoint(x: 250, y: 700),
                                             target: CGPoint(x: 200, y: 300))
        #expect(center == CGPoint(x: 250, y: 800))
    }

    @Test func zoomsOnlyWhenHopeless() {
        #expect(MapCardLayout.selectionSpan(visibleSpanMeters: 9_000, markerVisible: false) == nil)
        #expect(MapCardLayout.selectionSpan(visibleSpanMeters: 50_000, markerVisible: true) == nil)
        #expect(MapCardLayout.selectionSpan(visibleSpanMeters: 50_000, markerVisible: false) == 5_000)
    }

    // MARK: Apple's attribution

    /// Compact and regular: no card covers the Maps logo and Legal link, wherever the marker is.
    @Test(arguments: [false, true])
    func neverCoversTheAttribution(_ regular: Bool) throws {
        for screen in Self.screens {
            let bare = MapCardScene(container: screen.size, safeInsets: screen.insets)
            let attribution = bare.attribution()
            #expect(attribution.height == 36 && attribution.maxY == bare.safeBounds.maxY
                    && attribution.minX == bare.safeBounds.minX)
            let scene = MapCardScene(container: screen.size, safeInsets: screen.insets, obstacles: [attribution])
            let candidates = regular ? MapCardPlacement.regularPreference : MapCardPlacement.compactPreference
            let width = MapCardLayout.cardWidth(scene: scene, maxWidth: regular ? MapCardLayout.regularMaxWidth : nil)
            let size = CGSize(width: width, height: 120)
            for placement in candidates {
                if let frame = MapCardLayout.frame(for: placement, cardSize: size, scene: scene) {
                    #expect(!frame.intersects(attribution), "\(placement) \(frame) covers \(attribution)")
                }
            }
            for fy in stride(from: 0.0, through: 1, by: 0.05) {
                let point = CGPoint(x: Double(screen.size.width) / 2, y: Double(screen.size.height) * fy)
                let decision = try #require(MapCardLayout.place(
                    marker: marker(point), cardSize: size, scene: scene, candidates: candidates, current: nil))
                #expect(!decision.frame.intersects(attribution))
            }
        }
        // The bottom card rides above it, 8 pt clear.
        let scene = MapCardScene(container: phone.container, safeInsets: phone.safeInsets,
                                 obstacles: [phone.attribution()])
        let bottom = try #require(MapCardLayout.frame(for: .bottom, cardSize: card, scene: scene))
        #expect(Double(bottom.maxY) == 874.0 - 83 - 36 - 8)
    }

    // MARK: Odd inputs

    @Test func oddMeasurementsDoNotBreakIt() {
        // NaN and negative insets count as zero.
        let odd = MapCardScene(container: CGSize(width: 402, height: 874),
                               safeInsets: MapInsets(top: .nan, leading: -20, bottom: .infinity, trailing: -1))
        #expect(odd.safeBounds == CGRect(x: 0, y: 0, width: 402, height: 874))
        // A NaN container is empty: nothing fits.
        let empty = MapCardScene(container: CGSize(width: Double.nan, height: 874))
        #expect(empty.safeBounds == .zero)
        #expect(MapCardLayout.frame(for: .bottom, cardSize: card, scene: empty) == nil)
        // Insets bigger than the map leave nothing.
        let squeezed = MapCardScene(container: CGSize(width: 402, height: 200), safeInsets: MapInsets(top: 150, bottom: 100))
        #expect(squeezed.safeBounds == .zero)
        #expect(MapCardLayout.place(marker: marker(CGPoint(x: 100, y: 100)), cardSize: card, scene: squeezed,
                                    candidates: MapCardPlacement.compactPreference, current: nil) == nil)
        // A card taller than the map, or with a NaN size, fits nowhere.
        #expect(MapCardLayout.frame(for: .top, cardSize: CGSize(width: 300, height: 2_000), scene: phone) == nil)
        #expect(MapCardLayout.frame(for: .top, cardSize: CGSize(width: Double.nan, height: 100), scene: phone) == nil)
        // No candidates, no placement.
        #expect(MapCardLayout.place(marker: marker(CGPoint(x: 100, y: 100)), cardSize: card, scene: phone,
                                    candidates: [], current: .bottom) == nil)
        #expect(MapCardLayout.defaultPlacement(cardSize: card, scene: phone, candidates: [], current: .top) == nil)
        // NaN obstacles are ignored.
        let withNaN = MapCardScene(container: phone.container, safeInsets: phone.safeInsets,
                                   obstacles: [CGRect(x: Double.nan, y: 0, width: 10, height: 10)])
        #expect(withNaN.obstacles.isEmpty)
    }

    // MARK: Marker unknown, selection pans

    @Test func defaultPlacementWithoutAMarker() throws {
        let first = try #require(MapCardLayout.defaultPlacement(
            cardSize: card, scene: phone, candidates: MapCardPlacement.compactPreference, current: nil))
        #expect(first.placement == .bottom && first.panMarkerTo == nil)
        let kept = try #require(MapCardLayout.defaultPlacement(
            cardSize: card, scene: phone, candidates: MapCardPlacement.compactPreference, current: .top))
        #expect(kept.placement == .top)
        // A current placement that isn't a candidate here isn't kept.
        let other = try #require(MapCardLayout.defaultPlacement(
            cardSize: card, scene: phone, candidates: MapCardPlacement.compactPreference, current: .topTrailing))
        #expect(other.placement == .bottom)
    }

    @Test func selectionPansOnlyWhenNeeded() throws {
        let candidates = MapCardPlacement.compactPreference
        // On screen and clear: leave the map alone.
        let clearMarker = marker(CGPoint(x: 200, y: 300))
        let clear = try #require(MapCardLayout.place(marker: clearMarker, cardSize: card, scene: phone,
                                                     candidates: candidates, current: nil))
        #expect(MapCardLayout.selectionPan(marker: clearMarker, decision: clear, scene: phone) == nil)
        // Off screen: into the uncovered middle.
        let offMarker = marker(CGPoint(x: 200, y: 2_000))
        let off = try #require(MapCardLayout.place(marker: offMarker, cardSize: card, scene: phone,
                                                   candidates: candidates, current: nil))
        let pan = try #require(MapCardLayout.selectionPan(marker: offMarker, decision: off, scene: phone))
        #expect(phone.safeBounds.contains(pan))
        #expect(!off.frame.intersects(marker(pan)))
        // Covered everywhere: the decision's own target.
        let tall = CGSize(width: 310, height: 500)
        let midMarker = marker(CGPoint(x: 200, y: 437))
        let covered = try #require(MapCardLayout.place(marker: midMarker, cardSize: tall, scene: phone,
                                                       candidates: candidates, current: nil))
        #expect(MapCardLayout.selectionPan(marker: midMarker, decision: covered, scene: phone) == covered.panMarkerTo)
    }

    @Test func tinyPansAreSkipped() {
        #expect(!MapCardLayout.isWorthPanning(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 11, y: 11)))
        #expect(MapCardLayout.isWorthPanning(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 12)))
        #expect(!MapCardLayout.isWorthPanning(from: CGPoint(x: Double.nan, y: 0), to: .zero))
    }

    /// Wherever the card is, the point it gives leaves the whole marker box (disc, label, margin) clear of the card
    /// and inside the visible map, whenever some part of the map has room for it.
    @Test func uncoveredCenterFitsTheMarkerBox() {
        let box = marker(.zero)
        let margin = MapCardLayout.markerMargin
        for screen in Self.screens {
            let scene = MapCardScene(container: screen.size, safeInsets: screen.insets)
            let safe = scene.safeBounds
            for w in stride(from: 100.0, through: Double(safe.width), by: 60) {
                // Up to a card that leaves at least a marker box (about 90 pt) above or below it when centered.
                for h in stride(from: 60.0, through: Double(safe.height) - 200, by: 50) {
                    for (fx, fy) in [(0.0, 0.0), (1, 0), (0, 1), (1, 1), (0.5, 0.5)] {
                        let card = CGRect(x: Double(safe.minX) + (Double(safe.width) - w) * fx,
                                          y: Double(safe.minY) + (Double(safe.height) - h) * fy, width: w, height: h)
                        let point = MapCardLayout.uncoveredCenter(scene: scene, card: card, marker: box, margin: margin)
                        let placed = marker(point).insetBy(dx: -margin, dy: -margin)
                        #expect(!placed.intersects(card), "\(placed) under \(card) on \(screen.size)")
                        #expect(safe.insetBy(dx: -0.5, dy: -0.5).contains(placed), "\(placed) outside \(safe)")
                    }
                }
            }
        }
    }

    @Test func reservedColumnAndOffset() {
        // Buttons 44 wide, 16 in from the safe edge: the card stops 8 short of them.
        let buttons = CGRect(x: 402 - 16 - 44, y: 78, width: 44, height: 136)
        #expect(MapCardLayout.reservedTrailing(scene: phone, column: buttons) == 44 + 8)
        #expect(MapCardLayout.reservedTrailing(scene: phone, column: .zero) == 0)
        #expect(MapCardLayout.offset(of: CGRect(x: 16, y: 600, width: 300, height: 100),
                                     layerOrigin: CGPoint(x: 0, y: 62)) == CGSize(width: 16, height: 538))
    }

    @Test func widthLeavesTheButtonColumn() {
        #expect(MapCardLayout.cardWidth(scene: phone, reservedTrailing: 52) == 402 - 32 - 52)
        let wide = MapCardScene(container: CGSize(width: 611, height: 669))
        #expect(MapCardLayout.cardWidth(scene: wide, maxWidth: 380) == 380)
        #expect(MapCardLayout.maxCardHeight(scene: phone, cardWidth: 318, fraction: 0.4,
                                            candidates: MapCardPlacement.compactPreference)
            == (874.0 - 62 - 83 - 32) * 0.4)
    }

    /// Between a banner and a note, the cap is the gap between them, so the card still fits somewhere.
    @Test func capIsTheTallestGapBetweenTheControls() {
        let banner = CGRect(x: 16, y: 70, width: 370, height: 60)
        let note = CGRect(x: 16, y: 600, width: 370, height: 34)
        let scene = MapCardScene(container: phone.container, safeInsets: phone.safeInsets, obstacles: [banner, note])
        let cap = MapCardLayout.maxCardHeight(scene: scene, cardWidth: 318, fraction: 1,
                                              candidates: MapCardPlacement.compactPreference)
        #expect(cap == (600.0 - 8) - (130 + 8))
        #expect(MapCardLayout.frame(for: .top, cardSize: CGSize(width: 318, height: cap), scene: scene) != nil)
        #expect(MapCardLayout.frame(for: .top, cardSize: CGSize(width: 318, height: cap + 1), scene: scene) == nil)
    }

    // MARK: After a placement: pan, zoom or wait

    /// The Pro's compact map: a bottom card, the marker under it.
    func coveredSelection() -> (scene: MapCardScene, point: CGPoint, marker: CGRect, decision: MapCardDecision) {
        let scene = MapCardScene(container: CGSize(width: 402, height: 729))
        let point = CGPoint(x: 201, y: 600)
        let marker = marker(point)
        let decision = MapCardDecision(placement: .bottom, frame: CGRect(x: 16, y: 450, width: 318, height: 220),
                                       panMarkerTo: nil)
        return (scene, point, marker, decision)
    }

    /// Before the map's first settle nothing moves, and the selection's pan stays pending for it: "Show on map" builds
    /// the map with the selection made, and panning from its answers flew the camera to Apple Park.
    @Test func noMoveUntilTheMapHasSettled() {
        let s = coveredSelection()
        let waiting = MapCardLayout.move(isSelectionPan: true, mapSettled: false, pansLeft: 2, userMoving: false,
                                         point: s.point, marker: s.marker, decision: s.decision, scene: s.scene,
                                         visibleSpanMeters: 1_200)
        #expect(waiting == MapCardMovePlan(move: .none, selectionPanPending: true))
        let settled = MapCardLayout.move(isSelectionPan: true, mapSettled: true, pansLeft: 2, userMoving: false,
                                         point: s.point, marker: s.marker, decision: s.decision, scene: s.scene,
                                         visibleSpanMeters: 1_200)
        guard case .pan(let target) = settled.move else {
            Issue.record("expected a pan, got \(settled.move)")
            return
        }
        #expect(!settled.selectionPanPending)
        #expect(target.y < s.decision.frame.minY, "the marker goes above the bottom card")
        // A placement that isn't a selection's never makes one pending.
        let later = MapCardLayout.move(isSelectionPan: false, mapSettled: false, pansLeft: 2, userMoving: false,
                                       point: s.point, marker: s.marker, decision: s.decision, scene: s.scene,
                                       visibleSpanMeters: 1_200)
        #expect(later == MapCardMovePlan(move: .none, selectionPanPending: false))
    }

    /// The selection's pan happens even while the map still glides; a later one never fights the user's drag, and
    /// none happens with no pans left or for a marker already clear.
    @Test func panRules() {
        let s = coveredSelection()
        func plan(selection: Bool, pansLeft: Int = 2, moving: Bool = false, decision: MapCardDecision? = nil)
            -> MapCardMovePlan {
            MapCardLayout.move(isSelectionPan: selection, mapSettled: true, pansLeft: pansLeft, userMoving: moving,
                               point: s.point, marker: s.marker, decision: decision ?? s.decision, scene: s.scene,
                               visibleSpanMeters: 1_200)
        }
        if case .pan = plan(selection: true, moving: true).move {} else { Issue.record("selection pan while moving") }
        #expect(plan(selection: true, pansLeft: 0).move == .none)
        // Later: only the decision's own pan target, and not mid-drag.
        #expect(plan(selection: false).move == .none)
        let stuck = MapCardDecision(placement: .bottom, frame: s.decision.frame, panMarkerTo: CGPoint(x: 201, y: 200))
        #expect(plan(selection: false, decision: stuck).move == .pan(to: CGPoint(x: 201, y: 200)))
        #expect(plan(selection: false, moving: true, decision: stuck).move == .none)
        // A clear, visible marker stays put.
        let top = MapCardDecision(placement: .top, frame: CGRect(x: 16, y: 16, width: 318, height: 220), panMarkerTo: nil)
        #expect(plan(selection: true, decision: top) == MapCardMovePlan(move: .none, selectionPanPending: false))
    }

    /// Off screen on a map too wide to pick it out: zoom first, and the pan stays pending for the settle there.
    @Test func offScreenOnAWideMapZoomsFirst() {
        let s = coveredSelection()
        let far = CGPoint(x: 900, y: -300)
        let plan = MapCardLayout.move(isSelectionPan: true, mapSettled: true, pansLeft: 2, userMoving: false,
                                      point: far, marker: marker(far), decision: s.decision, scene: s.scene,
                                      visibleSpanMeters: 30_000)
        #expect(plan == MapCardMovePlan(move: .zoom(spanMeters: MapCardLayout.selectionZoomSpanMeters),
                                        selectionPanPending: true))
    }

    // MARK: Regular width

    /// A tall map (the Duo unfolded's map column) gets the full-width floating card; a short one (a phone in landscape
    /// beside the list) gets one narrow enough to pass the buttons, so it isn't squeezed between them and the
    /// attribution.
    @Test func regularWidthPassesTheButtonsOnAShortMap() {
        func scene(_ size: CGSize) -> (MapCardScene, CGRect) {
            let bare = MapCardScene(container: size)
            let buttons = CGRect(x: size.width - 16 - 44, y: 16, width: 44, height: 132.7)
            return (MapCardScene(container: size, obstacles: [buttons, bare.attribution()]), buttons)
        }
        let (tall, tallButtons) = scene(CGSize(width: 611, height: 560))
        #expect(MapCardLayout.regularCardWidth(scene: tall, column: tallButtons) == 380)
        let (short, shortButtons) = scene(CGSize(width: 448, height: 260))
        let width = MapCardLayout.regularCardWidth(scene: short, column: shortButtons)
        #expect(width == 448 - 32 - (432 - 388 + 8))
        let wideCap = MapCardLayout.maxCardHeight(scene: short, cardWidth: 380, fraction: 0.6,
                                                  candidates: MapCardPlacement.regularPreference)
        let cap = MapCardLayout.maxCardHeight(scene: short, cardWidth: width, fraction: 0.6,
                                              candidates: MapCardPlacement.regularPreference)
        #expect(cap > wideCap * 2, "narrow \(cap) vs wide \(wideCap)")
        // And a card that tall fits somewhere, clear of the buttons and the attribution.
        #expect(MapCardPlacement.regularPreference.contains {
            MapCardLayout.frame(for: $0, cardSize: CGSize(width: width, height: cap), scene: short) != nil
        })
    }

    /// MapKit's window points, in the map's own coordinates and back.
    @Test func windowAndScenePoints() {
        let origin = CGPoint(x: 364, y: 78)
        let scene = MapCardLayout.scenePoint(window: CGPoint(x: 500, y: 100), mapOrigin: origin)
        #expect(scene == CGPoint(x: 136, y: 22))
        #expect(MapCardLayout.windowPoint(scene: scene, mapOrigin: origin) == CGPoint(x: 500, y: 100))
    }

    /// On a short map beside the list, the only room the floating card leaves is a strip beside it that the map
    /// buttons share: the marker goes there below the buttons, not under them.
    @Test func panTargetKeepsTheMarkerOutFromUnderTheButtons() {
        let size = CGSize(width: 448, height: 260)
        let bare = MapCardScene(container: size)
        let buttons = CGRect(x: 388, y: 16, width: 44, height: 132.7)
        let scene = MapCardScene(container: size, obstacles: [buttons, bare.attribution()])
        let card = CGRect(x: 16, y: 83, width: 364, height: 133)
        let box = marker(.zero)
        let target = MapCardLayout.uncoveredCenter(scene: scene, card: card, marker: box, margin: 12)
        let placed = MapCardLayout.markerRect(center: target, radius: 22, labelHeight: 18)
        #expect(!placed.intersects(buttons), "\(placed) under the buttons")
        #expect(!placed.insetBy(dx: -12, dy: -12).intersects(card))
        #expect(scene.safeBounds.contains(placed))
    }
}
