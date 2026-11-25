import CoreGraphics
import Foundation

/// Where the map's card for the selected boat or train docks. Compact width (a phone, the Duo cover) docks a summary
/// card at the top or bottom edge; regular width (the Duo unfolded) floats the details in a corner.
public enum MapCardPlacement: String, CaseIterable, Sendable {
    case top, bottom, topLeading, topTrailing, bottomLeading, bottomTrailing

    /// Anchored to the top edge: it moves down, not up, to clear what's there.
    public var isTop: Bool { self == .top || self == .topLeading || self == .topTrailing }

    /// Compact width, in order of preference: the bottom is nearest the thumb.
    public static let compactPreference: [MapCardPlacement] = [.bottom, .top]
    /// Regular width: bottom trailing first (where the card always was), then the other corners.
    public static let regularPreference: [MapCardPlacement] = [.bottomTrailing, .bottomLeading, .topLeading, .topTrailing]
}

/// Safe-area insets, points.
public struct MapInsets: Sendable, Equatable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static let zero = MapInsets()
}

/// The map as the card sees it, all in one coordinate space (the map view's, origin top-left, points).
public struct MapCardScene: Sendable, Equatable {
    /// The map view's size.
    public var container: CGSize
    /// The map view's safe-area insets (status bar, tab bar, a notch in landscape).
    public var safeInsets: MapInsets
    /// What the card must never cover: the map buttons, the offline banner, the underground note. A card that
    /// would overlap one slides away from its edge until it doesn't.
    public var obstacles: [CGRect]
    /// The card's distance from the safe area's edges.
    public var edgePadding: Double
    /// The gap kept between the card and an obstacle.
    public var spacing: Double

    public init(container: CGSize, safeInsets: MapInsets = .zero, obstacles: [CGRect] = [],
                edgePadding: Double = 16, spacing: Double = 8) {
        // Measurements can be anything while a view lays out: a size or inset that isn't a finite, non-negative
        // number counts as zero.
        func clean(_ value: Double) -> Double { value.isFinite && value > 0 ? value : 0 }
        self.container = CGSize(width: clean(Double(container.width)), height: clean(Double(container.height)))
        self.safeInsets = MapInsets(top: clean(safeInsets.top), leading: clean(safeInsets.leading),
                                    bottom: clean(safeInsets.bottom), trailing: clean(safeInsets.trailing))
        self.obstacles = obstacles.filter {
            !$0.isNull && !$0.isEmpty && !$0.isInfinite
                && [$0.minX, $0.minY, $0.width, $0.height].allSatisfy { Double($0).isFinite }
        }
        self.edgePadding = clean(edgePadding)
        self.spacing = clean(spacing)
    }

    /// The visible map inside the safe area.
    public var safeBounds: CGRect {
        // Checked before making the rect: CGRect reports a negative size as positive.
        let width = Double(container.width) - safeInsets.leading - safeInsets.trailing
        let height = Double(container.height) - safeInsets.top - safeInsets.bottom
        guard width > 0, height > 0 else { return .zero }
        return CGRect(x: safeInsets.leading, y: safeInsets.top, width: width, height: height)
    }

    /// Apple's Maps logo and Legal link, which sit in the bottom-left corner of the visible map and must stay
    /// visible: an obstacle for the card. `height` and `width` are the room kept for them, points.
    public func attribution(width: Double = MapCardLayout.attributionWidth,
                            height: Double = MapCardLayout.attributionHeight) -> CGRect {
        let safe = safeBounds
        guard safe.width > 0, safe.height > 0 else { return .zero }
        // Clamped to the map before placing it, so on a map shorter than `height` it fills the map, not more.
        let height = min(height, Double(safe.height))
        return CGRect(x: Double(safe.minX), y: Double(safe.maxY) - height, width: min(width, Double(safe.width)),
                      height: height)
    }

    /// Where a card may go: the safe area less the edge padding.
    public var cardBounds: CGRect {
        let rect = safeBounds.insetBy(dx: edgePadding, dy: edgePadding)
        return rect.isNull || rect.width <= 0 || rect.height <= 0 ? .zero : rect
    }
}

/// What the map does for the card after a placement: nothing, zoom in on the target first, or pan its marker to a
/// point (scene coordinates).
public enum MapCardMove: Sendable, Equatable {
    case none
    case zoom(spanMeters: Double)
    case pan(to: CGPoint)
}

/// A move, and whether the selection's pan is still to come (the map hasn't settled yet, or it zooms first and pans
/// once it settles there).
public struct MapCardMovePlan: Sendable, Equatable {
    public let move: MapCardMove
    public let selectionPanPending: Bool
}

/// A placement decision.
public struct MapCardDecision: Sendable, Equatable {
    public let placement: MapCardPlacement
    /// The card's frame there, in the scene's coordinates.
    public let frame: CGRect
    /// Where the marker has to be moved to (by panning the map) for the card to leave it clear; nil when it already
    /// is.
    public let panMarkerTo: CGPoint?
}

/// The map card's placement rule (docs/DESIGN.md, "Map card"): the card never covers the selected marker (with a
/// margin) nor the map's controls. Pure geometry, so the views only measure and apply it.
public enum MapCardLayout {
    /// Kept clear around the selected marker, points.
    public static let markerMargin = 12.0
    /// The compact card's height cap, as a share of the room for it: at the largest text sizes it scrolls inside.
    public static let compactMaxHeightFraction = 0.4
    /// The floating card's (regular width) height cap.
    public static let regularMaxHeightFraction = 0.6
    /// The floating card's widest.
    public static let regularMaxWidth = 380.0
    /// A visible span this wide (meters) is hopeless for finding one marker: selecting a target off screen then
    /// zooms to `selectionZoomSpanMeters`. Narrower, selection keeps the zoom and only pans.
    public static let hopelessSpanMeters = 20_000.0
    public static let selectionZoomSpanMeters = 5_000.0
    /// Room kept for Apple's Maps logo and Legal link in the map's bottom-left corner (`MapCardScene.attribution`).
    public static let attributionHeight = 36.0
    public static let attributionWidth = 120.0
    /// Pans shorter than this many points aren't worth moving the map for.
    public static let minimumPanPoints = 2.0

    /// The card's width: the room between the edges, less `reservedTrailing` (compact: the map buttons' column,
    /// which the card never covers), at most `maxWidth`.
    public static func cardWidth(scene: MapCardScene, reservedTrailing: Double = 0, maxWidth: Double? = nil) -> Double {
        var width = Double(scene.cardBounds.width) - max(0, reservedTrailing)
        if let maxWidth { width = min(width, maxWidth) }
        return max(0, width)
    }

    /// The card's tallest: `fraction` of the room for it, and no taller than the tallest gap between the controls at
    /// any of `candidates`, so a card of this height always fits somewhere (its content scrolls inside).
    public static func maxCardHeight(scene: MapCardScene, cardWidth: Double, fraction: Double,
                                     candidates: [MapCardPlacement]) -> Double {
        let gaps = candidates.map { tallestGap(for: $0, cardWidth: cardWidth, scene: scene) }
        return max(0, min(Double(scene.cardBounds.height) * fraction, gaps.max() ?? 0))
    }

    private static func x(for placement: MapCardPlacement, width: Double, bounds: CGRect) -> Double {
        switch placement {
        case .top, .bottom, .topLeading, .bottomLeading: Double(bounds.minX)
        case .topTrailing, .bottomTrailing: Double(bounds.maxX) - width
        }
    }

    /// Obstacles closer than this to a card count as overlapping it: the spacing, less a hair so a card set exactly
    /// `spacing` away isn't caught by rounding.
    private static func reach(_ scene: MapCardScene) -> Double { max(0, scene.spacing - 0.001) }

    /// The tallest card that fits in `placement`'s column between the controls. Obstacles count by the same rule as
    /// in `frame(for:)`: within `reach` of the column on any side, so one just past the top or bottom of the card
    /// bounds (which `frame(for:)` keeps the card `spacing` away from) shortens the gap too.
    static func tallestGap(for placement: MapCardPlacement, cardWidth: Double, scene: MapCardScene) -> Double {
        let bounds = scene.cardBounds
        guard cardWidth > 0, cardWidth <= Double(bounds.width) + 0.5 else { return 0 }
        let column = CGRect(x: x(for: placement, width: cardWidth, bounds: bounds), y: Double(bounds.minY),
                            width: cardWidth, height: Double(bounds.height))
            .insetBy(dx: -reach(scene), dy: -reach(scene))
        let blocked = scene.obstacles.filter { $0.intersects(column) }
            .map { (top: Double($0.minY) - scene.spacing, bottom: Double($0.maxY) + scene.spacing) }
            .sorted { $0.top < $1.top }
        var tallest = 0.0
        var start = Double(bounds.minY)
        for span in blocked {
            tallest = max(tallest, min(span.top, Double(bounds.maxY)) - start)
            start = max(start, span.bottom)
        }
        return max(tallest, Double(bounds.maxY) - start)
    }

    /// The area a marker takes: its disc around `center` plus a label of `labelHeight` under it.
    public static func markerRect(center: CGPoint, radius: Double, labelHeight: Double = 0) -> CGRect {
        CGRect(x: Double(center.x) - radius, y: Double(center.y) - radius,
               width: radius * 2, height: radius * 2 + max(0, labelHeight))
    }

    /// The card's frame at `placement`: against that edge (or corner) of `cardBounds`, then slid away from the edge
    /// past any obstacle it would overlap. Nil when it doesn't fit, or can't clear the obstacles inside the bounds.
    public static func frame(for placement: MapCardPlacement, cardSize: CGSize, scene: MapCardScene) -> CGRect? {
        let bounds = scene.cardBounds
        let width = Double(cardSize.width), height = Double(cardSize.height)
        guard width > 0, height > 0, width <= Double(bounds.width) + 0.5, height <= Double(bounds.height) + 0.5
        else { return nil }
        var rect = CGRect(x: x(for: placement, width: width, bounds: bounds),
                          y: placement.isTop ? Double(bounds.minY) : Double(bounds.maxY) - height,
                          width: width, height: height)
        let reach = reach(scene)
        // Each pass clears at least one more obstacle, so this many passes are enough.
        for _ in 0...scene.obstacles.count {
            let gap = rect.insetBy(dx: -reach, dy: -reach)
            let hits = scene.obstacles.filter { $0.intersects(gap) }
            guard !hits.isEmpty else { break }
            if placement.isTop {
                rect.origin.y = hits.map(\.maxY).max()! + scene.spacing
            } else {
                rect.origin.y = hits.map(\.minY).min()! - scene.spacing - rect.height
            }
        }
        let gap = rect.insetBy(dx: -reach, dy: -reach)
        guard !scene.obstacles.contains(where: { $0.intersects(gap) }),
              rect.minY >= bounds.minY - 0.5, rect.maxY <= bounds.maxY + 0.5 else { return nil }
        return rect
    }

    /// Picks the card's placement for the selected marker.
    ///
    /// 1. The current placement while it still fits and leaves the marker clear: the card moves only when it would
    ///    cover the marker, so it never flaps.
    /// 2. Otherwise the first candidate, in preference order, that fits and leaves it clear.
    /// 3. When none does, the current placement if it fits, else the first that fits, with `panMarkerTo`: the middle
    ///    of the map left uncovered, where the map should move the marker.
    ///
    /// - Parameters:
    ///   - marker: the area the marker takes (`markerRect`), in the scene's coordinates.
    ///   - margin: kept clear around the marker.
    /// - Returns: nil when the card fits nowhere (a map smaller than the card).
    public static func place(marker: CGRect, cardSize: CGSize, scene: MapCardScene, margin: Double = markerMargin,
                             candidates: [MapCardPlacement], current: MapCardPlacement?) -> MapCardDecision? {
        let keepClear = marker.insetBy(dx: -margin, dy: -margin)
        let fitting = candidates.compactMap { placement in
            frame(for: placement, cardSize: cardSize, scene: scene).map { (placement, $0) }
        }
        if let current, let kept = fitting.first(where: { $0.0 == current }), !kept.1.intersects(keepClear) {
            return MapCardDecision(placement: current, frame: kept.1, panMarkerTo: nil)
        }
        if let clear = fitting.first(where: { !$0.1.intersects(keepClear) }) {
            return MapCardDecision(placement: clear.0, frame: clear.1, panMarkerTo: nil)
        }
        guard let fallback = fitting.first(where: { $0.0 == current }) ?? fitting.first else { return nil }
        return MapCardDecision(placement: fallback.0, frame: fallback.1,
                               panMarkerTo: uncoveredCenter(scene: scene, card: fallback.1, marker: marker,
                                                            margin: margin))
    }

    /// Where the card goes when the marker's place on screen isn't known (the map can't convert its coordinate yet):
    /// the current placement if it fits, else the first candidate that does; no pan.
    public static func defaultPlacement(cardSize: CGSize, scene: MapCardScene, candidates: [MapCardPlacement],
                                        current: MapCardPlacement?) -> MapCardDecision? {
        let order = (current.map { [$0] } ?? []) + candidates
        for placement in order where candidates.contains(placement) {
            if let frame = frame(for: placement, cardSize: cardSize, scene: scene) {
                return MapCardDecision(placement: placement, frame: frame, panMarkerTo: nil)
            }
        }
        return nil
    }

    /// Right after a selection: where to move the marker, or nil to leave the map alone because the marker is already
    /// on screen and clear of the card (and its margin). Otherwise the decision's own pan target, or the middle of
    /// the area the card leaves (an off-screen marker).
    public static func selectionPan(marker: CGRect, decision: MapCardDecision, scene: MapCardScene,
                                    margin: Double = markerMargin) -> CGPoint? {
        if let pan = decision.panMarkerTo { return pan }
        let clear = !decision.frame.intersects(marker.insetBy(dx: -margin, dy: -margin))
        if clear, scene.safeBounds.contains(marker) { return nil }
        return uncoveredCenter(scene: scene, card: decision.frame, marker: marker, margin: margin)
    }

    /// What the map does after a placement (`place`) for the marker at `point` (its box `marker`).
    ///
    /// - A map that hasn't settled yet (`mapSettled` false: no `onMapCameraChange(.onEnd)` since it was built) can't
    ///   convert between points and coordinates; panning from its answers flies the camera to MapKit's default place.
    ///   Nothing moves, and a pending selection pan stays pending for the first settle (which places the card again).
    /// - Right after a selection (`isSelectionPan`): `selectionPan`. Later: the decision's own `panMarkerTo`, only when
    ///   no place leaves the marker clear, and never while the user is moving the map (`userMoving`).
    /// - None when no pans are left, or the move is shorter than `minimumPanPoints`.
    /// - An off-screen marker on a map too wide to pick it out (`selectionSpan`): zoom in first, the pan stays pending.
    public static func move(isSelectionPan: Bool, mapSettled: Bool, pansLeft: Int, userMoving: Bool, point: CGPoint,
                            marker: CGRect, decision: MapCardDecision, scene: MapCardScene,
                            visibleSpanMeters: Double) -> MapCardMovePlan {
        guard mapSettled else { return MapCardMovePlan(move: .none, selectionPanPending: isSelectionPan) }
        let none = MapCardMovePlan(move: .none, selectionPanPending: false)
        let target = isSelectionPan
            ? selectionPan(marker: marker, decision: decision, scene: scene) : decision.panMarkerTo
        guard let target, pansLeft > 0, isWorthPanning(from: point, to: target) else { return none }
        if !isSelectionPan, userMoving { return none }
        if let span = selectionSpan(visibleSpanMeters: visibleSpanMeters, markerVisible: isVisible(point, scene: scene)) {
            return MapCardMovePlan(move: .zoom(spanMeters: span), selectionPanPending: true)
        }
        return MapCardMovePlan(move: .pan(to: target), selectionPanPending: false)
    }

    /// The floating card's width (regular width): as wide as `maxWidth` allows, unless a card narrow enough to pass
    /// beside the map buttons' `column` could be taller (a short map, where a wide card is squeezed between the
    /// buttons and the attribution): then that narrower width.
    public static func regularCardWidth(scene: MapCardScene, column: CGRect, maxWidth: Double = regularMaxWidth,
                                        fraction: Double = regularMaxHeightFraction,
                                        candidates: [MapCardPlacement] = MapCardPlacement.regularPreference) -> Double {
        let wide = cardWidth(scene: scene, maxWidth: maxWidth)
        let narrow = cardWidth(scene: scene, reservedTrailing: reservedTrailing(scene: scene, column: column),
                               maxWidth: maxWidth)
        guard narrow > 0, narrow < wide else { return wide }
        let height = { (width: Double) in
            maxCardHeight(scene: scene, cardWidth: width, fraction: fraction, candidates: candidates)
        }
        return height(narrow) > height(wide) ? narrow : wide
    }

    /// A point MapKit gave in window coordinates (`MapProxy.convert(_:to: .global)`), in the scene's coordinates
    /// (the map view's own, origin at `mapOrigin`, the map's frame in the window). The map is converted through the
    /// window because MapKit's answers for a named coordinate space are off by the map's safe-area insets.
    public static func scenePoint(window point: CGPoint, mapOrigin: CGPoint) -> CGPoint {
        CGPoint(x: point.x - mapOrigin.x, y: point.y - mapOrigin.y)
    }

    /// The other way: a scene point in window coordinates, for `MapProxy.convert(_:from: .global)`.
    public static func windowPoint(scene point: CGPoint, mapOrigin: CGPoint) -> CGPoint {
        CGPoint(x: point.x + mapOrigin.x, y: point.y + mapOrigin.y)
    }

    /// True when moving a marker from `from` to `to` is worth a pan (at least `minimumPanPoints`).
    public static func isWorthPanning(from: CGPoint, to: CGPoint) -> Bool {
        let distance = hypot(Double(to.x - from.x), Double(to.y - from.y))
        return distance.isFinite && distance >= minimumPanPoints
    }

    /// Where to move a selected marker: in the largest part of the visible map (inside the safe area) the card leaves
    /// uncovered (above, below, left or right of it) that has room for the marker's box (`marker`, a `markerRect`)
    /// and `margin`, the point nearest that part's middle where the whole box fits, clear of the scene's obstacles
    /// (the map buttons) when the part has such a point. With no part big enough, the middle of the largest part.
    public static func uncoveredCenter(scene: MapCardScene, card: CGRect, marker: CGRect = .zero,
                                       margin: Double = 0) -> CGPoint {
        let area = scene.safeBounds
        // A side the card leaves no room on has a zero or negative size: left out (CGRect would flip it positive).
        func part(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect? {
            width > 0 && height > 0 ? CGRect(x: x, y: y, width: width, height: height) : nil
        }
        let parts = [
            part(area.minX, area.minY, area.width, card.minY - area.minY),
            part(area.minX, card.maxY, area.width, area.maxY - card.maxY),
            part(area.minX, area.minY, card.minX - area.minX, area.height),
            part(card.maxX, area.minY, area.maxX - card.maxX, area.height),
        ].compactMap { $0 }
        // The marker's box around its center: the disc is the top square of `markerRect`, the label hangs below.
        let half = Double(marker.width) / 2
        let above = half + margin, below = Double(marker.height) - half + margin, side = half + margin
        func fits(_ part: CGRect) -> Bool {
            Double(part.width) >= side * 2 && Double(part.height) >= above + below
        }
        func box(_ point: CGPoint) -> CGRect {
            CGRect(x: Double(point.x) - side, y: Double(point.y) - above, width: side * 2, height: above + below)
        }
        func isClear(_ point: CGPoint) -> Bool { !scene.obstacles.contains { $0.intersects(box(point)) } }
        /// The point nearest the part's middle where the box fits, preferring one clear of the obstacles: the middle,
        /// or just past an obstacle's edge, vertically or sideways.
        func spot(in part: CGRect) -> (point: CGPoint, clear: Bool) {
            let minX = Double(part.minX) + side, maxX = Double(part.maxX) - side
            let minY = Double(part.minY) + above, maxY = Double(part.maxY) - below
            func clamped(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: min(max(x, minX), maxX), y: min(max(y, minY), maxY))
            }
            let middle = clamped(Double(part.midX), Double(part.midY))
            if isClear(middle) { return (middle, true) }
            let s = scene.spacing
            let moves = scene.obstacles.flatMap { o -> [CGPoint] in [
                clamped(Double(middle.x), Double(o.maxY) + s + above), clamped(Double(middle.x), Double(o.minY) - s - below),
                clamped(Double(o.minX) - s - side, Double(middle.y)), clamped(Double(o.maxX) + s + side, Double(middle.y)),
            ] }
            let clear = moves.filter(isClear).min {
                hypot($0.x - middle.x, $0.y - middle.y) < hypot($1.x - middle.x, $1.y - middle.y)
            }
            return clear.map { ($0, true) } ?? (middle, false)
        }
        let area2 = { (part: CGRect) in Double(part.width * part.height) }
        let roomy = parts.filter(fits).sorted { area2($0) > area2($1) }
        guard !roomy.isEmpty else {
            guard let part = parts.max(by: { area2($0) < area2($1) }) else { return CGPoint(x: area.midX, y: area.midY) }
            return CGPoint(x: part.midX, y: part.midY)
        }
        let spots = roomy.map(spot)
        return (spots.first { $0.clear } ?? spots[0]).point
    }

    /// Where the map's camera center has to go, on screen, to move a marker from `marker` to `target` without
    /// changing the zoom: the whole map shifts by the same amount.
    public static func panCenter(cameraCenter: CGPoint, marker: CGPoint, target: CGPoint) -> CGPoint {
        CGPoint(x: cameraCenter.x + marker.x - target.x, y: cameraCenter.y + marker.y - target.y)
    }

    /// The width a compact card leaves free on its trailing side for a column of controls (the map buttons): from the
    /// column's leading edge, plus the spacing. Zero for an empty column, and for one on the leading side (the map
    /// buttons beside a system column, `MapControlsLayout`): a card there slides past it vertically instead.
    public static func reservedTrailing(scene: MapCardScene, column: CGRect) -> Double {
        guard !column.isNull, !column.isEmpty, column.midX > scene.cardBounds.midX else { return 0 }
        return max(0, Double(scene.cardBounds.maxX) - Double(column.minX) + scene.spacing)
    }

    /// How far to move a card drawn at `layerOrigin` (the origin of the layer it's drawn in, in the scene's
    /// coordinates) for it to land on `frame`.
    public static func offset(of frame: CGRect, layerOrigin: CGPoint) -> CGSize {
        CGSize(width: frame.minX - layerOrigin.x, height: frame.minY - layerOrigin.y)
    }

    /// True when `point` is inside the visible map (the safe area).
    public static func isVisible(_ point: CGPoint, scene: MapCardScene) -> Bool {
        scene.safeBounds.contains(point)
    }

    /// The span to zoom to on selecting a target: nil (keep the zoom) unless the marker is off screen and the map
    /// shows more than `hopelessSpanMeters`, where one marker can't be picked out.
    public static func selectionSpan(visibleSpanMeters: Double, markerVisible: Bool) -> Double? {
        guard !markerVisible, visibleSpanMeters > hopelessSpanMeters else { return nil }
        return selectionZoomSpanMeters
    }
}
