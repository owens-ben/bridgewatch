import CoreGraphics
import CoreLocation
import Foundation
import Testing
@testable import BoatCore

/// The layout math under random and hostile inputs: the map region, the map card's placement, the camera's
/// projection, label lanes and compass strip, and the underground-tap blocking. Never a trap, never a negative or NaN
/// frame, and the rules each one documents hold.
@Suite(.timeLimit(.minutes(1))) struct LayoutChaosTests {
    func finite(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { Double($0).isFinite }
    }

    // MARK: MapRegion

    @Test func boundingRegionHoldsItsCornersAndItsCenter() {
        var rng = Chaos.rng("boundingRegionHoldsItsCornersAndItsCenter")
        var made = 0, refused = 0
        for iteration in 0..<10_000 {
            let corners = (0..<rng.int(0...6)).map { _ -> CLLocationCoordinate2D in
                // Around the antimeridian, the poles, the origin, or anywhere (out-of-range longitudes too).
                let (lat, lon): (Double, Double) = switch rng.int(0...3) {
                case 0: (rng.double(-90...90), rng.pick([179.9, -179.9, 180, -180]) + rng.double(-0.5...0.5))
                case 1: (rng.pick([90, -90, 89.9]), rng.double(-540...540))
                case 2: (rng.double(-1...1), rng.double(-1...1))
                default: (rng.double(-90...90), rng.double(-180...180))
                }
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            var all = corners
            if rng.chance(0.05) { all.append(CLLocationCoordinate2D(latitude: rng.pick([.nan, .infinity, 0]), longitude: rng.pick([.nan, -.infinity, .infinity]))) }
            let context = Chaos.context("bounding", iteration: iteration, all.map { "(\($0.latitude), \($0.longitude))" }.joined(separator: " "))
            guard let region = MapRegion.bounding(all) else {
                refused += 1
                // Refused: no corners, a coordinate that isn't a number, or no area.
                let hostile = all.contains { !$0.latitude.isFinite || !$0.longitude.isFinite }
                let lats = all.map(\.latitude), lons = all.map(\.longitude)
                let flat = all.isEmpty || ((lats.max() ?? 0) - (lats.min() ?? 0) <= 0) || (Set(lons.map { ($0 - lons[0]).truncatingRemainder(dividingBy: 360) }).count == 1)
                #expect(hostile || flat || all.count < 3, context)
                continue
            }
            made += 1
            let allFinite = [region.centerLatitude, region.centerLongitude, region.latitudeDelta, region.longitudeDelta].allSatisfy { $0.isFinite }
            #expect(allFinite, context)
            #expect(region.latitudeDelta > 0 && region.longitudeDelta > 0 && region.longitudeDelta < 360 && region.latitudeDelta <= 180, context)
            #expect(region.centerLongitude >= -180 && region.centerLongitude < 180, context)
            #expect(region.contains(latitude: region.centerLatitude, longitude: region.centerLongitude), context)
            for corner in all { #expect(region.contains(corner, margin: 1e-6), context) }
        }
        #expect(made > 3_000 && refused > 500, "seed=\(Chaos.seed) made=\(made) refused=\(refused)")
    }

    @Test func aRegionContainsItsCenterAndTheMarginExactly() {
        var rng = Chaos.rng("aRegionContainsItsCenterAndTheMarginExactly")
        for iteration in 0..<10_000 {
            let latDelta = pow(10, rng.double(-6...2.2)), lonDelta = pow(10, rng.double(-6...2.5))
            let region = MapRegion(centerLatitude: rng.double(-89...89), centerLongitude: rng.double(-540...540), latitudeDelta: latDelta, longitudeDelta: lonDelta)
            let context = Chaos.context("contains", iteration: iteration, "\(region)")
            #expect(region.contains(latitude: region.centerLatitude, longitude: region.centerLongitude), context)
            #expect(region.contains(latitude: region.centerLatitude, longitude: region.centerLongitude, margin: -5), context)
            // Just inside the 3% margin on each side, just outside it (latitude; longitude where it doesn't wrap).
            let reach = latDelta * (0.5 + MapRegion.edgeMargin)
            #expect(region.contains(latitude: region.centerLatitude + reach * 0.999, longitude: region.centerLongitude), context)
            #expect(!region.contains(latitude: region.centerLatitude + reach * 1.001, longitude: region.centerLongitude), context)
            let lonReach = lonDelta * (0.5 + MapRegion.edgeMargin)
            if lonDelta < 300, lonReach < 175 {
                #expect(region.contains(latitude: region.centerLatitude, longitude: region.centerLongitude + lonReach * 0.999), context)
                #expect(!region.contains(latitude: region.centerLatitude, longitude: region.centerLongitude + lonReach * 1.001), context)
                #expect(!region.contains(latitude: region.centerLatitude, longitude: region.centerLongitude - lonReach * 1.001), context)
            }
            // Shifting the longitude by a full turn changes nothing.
            #expect(region.contains(latitude: region.centerLatitude, longitude: region.centerLongitude + 360) == true, context)
        }
        // A region that holds nothing.
        for bad in [MapRegion(centerLatitude: 0, centerLongitude: 0, latitudeDelta: 0, longitudeDelta: 1),
                    MapRegion(centerLatitude: 0, centerLongitude: 0, latitudeDelta: 1, longitudeDelta: -1),
                    MapRegion(centerLatitude: .nan, centerLongitude: 0, latitudeDelta: 1, longitudeDelta: 1),
                    MapRegion(centerLatitude: 0, centerLongitude: 0, latitudeDelta: .infinity, longitudeDelta: 1),
                    MapRegion(centerLatitude: 0, centerLongitude: .nan, latitudeDelta: 1, longitudeDelta: 1)] {
            #expect(!bad.contains(latitude: 0, longitude: 0))
        }
    }

    // MARK: MapCardLayout

    static let sizes: [Double] = [0, 1, 10, 44, 100, 300, 402, 466, 678, 874, 951, 1_500, 1e4, 1e6, 1e15, .greatestFiniteMagnitude, -5, -.infinity, .infinity, .nan]
    static let insets: [Double] = [0, 0, 0, 1, 20, 44, 62, 83, 400, 1e4, -10, .infinity, .nan]

    static func randomScene(_ rng: inout SplitMix64) -> MapCardScene {
        // Mostly real screens, sometimes anything.
        let realistic = rng.chance(0.75)
        let width = realistic ? rng.double(200...1_200) : rng.pick(sizes), height = realistic ? rng.double(200...1_200) : rng.pick(sizes)
        let insets = realistic
            ? MapInsets(top: rng.double(0...80), leading: rng.pick([0, 0, 62]), bottom: rng.double(0...90), trailing: rng.pick([0, 0, 62, 20]))
            : MapInsets(top: rng.pick(Self.insets), leading: rng.pick(Self.insets), bottom: rng.pick(Self.insets), trailing: rng.pick(Self.insets))
        let obstacles = (0..<rng.int(0...6)).map { _ -> CGRect in
            if realistic || rng.chance(0.7) {
                let w = width.isFinite && width > 0 && width < 1e6 ? width : 100, h = height.isFinite && height > 0 && height < 1e6 ? height : 100
                return CGRect(x: rng.double(-20...w), y: rng.double(-20...h), width: rng.double(0...300), height: rng.double(0...200))
            }
            return CGRect(x: rng.pick(sizes), y: rng.pick(sizes), width: rng.pick(sizes), height: rng.pick(sizes))
        }
        return MapCardScene(container: CGSize(width: width, height: height), safeInsets: insets, obstacles: obstacles,
                            edgePadding: realistic ? rng.pick([16, 0, 8]) : rng.pick(sizes), spacing: realistic ? rng.pick([8, 0, 4]) : rng.pick(sizes))
    }

    @Test func theSceneIsAlwaysWellFormed() {
        var rng = Chaos.rng("theSceneIsAlwaysWellFormed")
        for iteration in 0..<20_000 {
            let scene = Self.randomScene(&rng)
            let context = Chaos.context("scene", iteration: iteration, "\(scene)")
            for rect in [scene.safeBounds, scene.cardBounds, scene.attribution()] {
                #expect(finite(rect) && rect.width >= 0 && rect.height >= 0, Chaos.context("scene rect", iteration: iteration, "\(rect) in \(scene)"))
            }
            #expect(scene.container.width >= 0 && scene.container.height >= 0 && scene.container.width.isFinite, context)
            #expect(scene.edgePadding >= 0 && scene.spacing >= 0 && scene.edgePadding.isFinite && scene.spacing.isFinite, context)
            let safe = scene.safeBounds
            if !safe.isEmpty {
                #expect(CGRect(origin: .zero, size: scene.container).insetBy(dx: -0.5, dy: -0.5).contains(safe), context)
                #expect(safe.insetBy(dx: -0.5, dy: -0.5).contains(scene.cardBounds) || scene.cardBounds.isEmpty, context)
                if safe.height >= MapCardLayout.attributionHeight {
                    #expect(safe.insetBy(dx: -0.5, dy: -0.5).contains(scene.attribution()) || scene.attribution().isEmpty, context)
                }
            }
            #expect(scene.obstacles.allSatisfy { finite($0) && !$0.isEmpty }, context)
        }
    }

    @Test func placingTheCardKeepsItsRules() {
        var rng = Chaos.rng("placingTheCardKeepsItsRules")
        var decided = 0, none = 0, panned = 0
        for iteration in 0..<20_000 {
            let scene = Self.randomScene(&rng)
            let compact = rng.chance(0.5)
            let candidates = compact ? MapCardPlacement.compactPreference : MapCardPlacement.regularPreference
            let cardSize = rng.chance(0.8)
                ? CGSize(width: rng.double(50...420), height: rng.double(40...600)) : CGSize(width: rng.pick(Self.sizes), height: rng.pick(Self.sizes))
            let center = rng.chance(0.7) ? CGPoint(x: rng.double(-100...1_300), y: rng.double(-100...1_300)) : CGPoint(x: rng.pick(Self.sizes), y: rng.pick(Self.sizes))
            let radius = rng.pick([22, 0, 1, 100, -3]) as Double
            let marker = MapCardLayout.markerRect(center: center, radius: radius, labelHeight: rng.pick([0, 18, 200, -5]))
            let margin = rng.pick([12, 0, 12, 50, -4]) as Double
            let current = rng.chance(0.6) ? rng.pick(candidates) : nil
            let context = Chaos.context("place", iteration: iteration, "scene=\(scene) card=\(cardSize) marker=\(marker) margin=\(margin) current=\(String(describing: current)) compact=\(compact)")

            let decision = MapCardLayout.place(marker: marker, cardSize: cardSize, scene: scene, margin: margin, candidates: candidates, current: current)
            let again = MapCardLayout.place(marker: marker, cardSize: cardSize, scene: scene, margin: margin, candidates: candidates, current: current)
            #expect(decision == again, context)
            _ = MapCardLayout.defaultPlacement(cardSize: cardSize, scene: scene, candidates: candidates, current: current)
            _ = MapCardLayout.markerRect(center: center, radius: radius)
            guard let decision else { none += 1; continue }
            decided += 1
            let frame = decision.frame
            #expect(candidates.contains(decision.placement), context)
            #expect(finite(frame) && frame.width > 0 && frame.height > 0, context)
            #expect(Double(frame.width) <= Double(cardSize.width) + 1e-6 && Double(frame.height) <= Double(cardSize.height) + 1e-6, context)
            // Inside the map's safe area (and its card bounds), and clear of every obstacle by the spacing.
            #expect(scene.safeBounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), context)
            #expect(scene.cardBounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), context)
            let reach = max(0, scene.spacing - 0.001)
            for obstacle in scene.obstacles {
                #expect(!obstacle.intersects(frame.insetBy(dx: -reach, dy: -reach)), context)
                #expect(!obstacle.intersects(frame), context)
            }
            let keepClear = marker.insetBy(dx: -margin, dy: -margin)
            if finite(marker) && finite(keepClear) {
                if let pan = decision.panMarkerTo {
                    panned += 1
                    // No candidate that fits leaves the marker clear: that's why the map pans it.
                    #expect(pan.x.isFinite && pan.y.isFinite, context)
                    #expect(scene.safeBounds.insetBy(dx: -0.5, dy: -0.5).contains(pan) || scene.safeBounds.isEmpty, context)
                    for placement in candidates {
                        if let other = MapCardLayout.frame(for: placement, cardSize: cardSize, scene: scene) {
                            #expect(other.intersects(keepClear), context)
                        }
                    }
                } else {
                    // The result says it's clear: the card never overlaps the marker's box (with its margin).
                    #expect(!frame.intersects(keepClear), context)
                    if margin >= 0 { #expect(!frame.intersects(marker), context) }
                }
                // No flapping: the current placement is kept while it fits and is clear.
                if let current, let kept = MapCardLayout.frame(for: current, cardSize: cardSize, scene: scene), !kept.intersects(keepClear) {
                    #expect(decision.placement == current && decision.frame == kept && decision.panMarkerTo == nil, context)
                }
            }
            // Selecting: where to pan, and what the map does.
            if let pan = MapCardLayout.selectionPan(marker: marker, decision: decision, scene: scene, margin: margin) {
                #expect(pan.x.isFinite && pan.y.isFinite, context)
            }
            let plan = MapCardLayout.move(isSelectionPan: rng.chance(0.5), mapSettled: rng.chance(0.8), pansLeft: rng.int(-1...3), userMoving: rng.chance(0.3),
                                          point: center, marker: marker, decision: decision, scene: scene, visibleSpanMeters: rng.pick([0, 500, 25_000, .nan, .infinity, -1]))
            if case .pan(let target) = plan.move { #expect(target.x.isFinite && target.y.isFinite, context) }
            if case .zoom(let span) = plan.move { #expect(span > 0 && span.isFinite, context) }
        }
        #expect(decided > 3_000 && none > 500 && panned > 100, "seed=\(Chaos.seed) decided=\(decided) none=\(none) panned=\(panned)")
    }

    @Test func cardSizesAndColumnsStayNonNegative() {
        var rng = Chaos.rng("cardSizesAndColumnsStayNonNegative")
        for iteration in 0..<10_000 {
            let scene = Self.randomScene(&rng)
            let column = rng.chance(0.2) ? CGRect.null : CGRect(x: rng.double(-50...1_300), y: rng.double(-50...1_300), width: rng.double(0...100), height: rng.double(0...400))
            let context = Chaos.context("sizes", iteration: iteration, "\(scene) column=\(column)")
            let reserved = MapCardLayout.reservedTrailing(scene: scene, column: column)
            #expect(reserved.isFinite && reserved >= 0, context)
            for width in [MapCardLayout.cardWidth(scene: scene), MapCardLayout.cardWidth(scene: scene, reservedTrailing: rng.pick([0, 70, -5, 1e9]), maxWidth: rng.pick([380, 0, -1])),
                          MapCardLayout.regularCardWidth(scene: scene, column: column)] {
                #expect(width.isFinite && width >= 0 && width <= Double(scene.cardBounds.width) + 1e-6, context)
            }
            let width = MapCardLayout.regularCardWidth(scene: scene, column: column)
            for fraction in [MapCardLayout.compactMaxHeightFraction, MapCardLayout.regularMaxHeightFraction] {
                let height = MapCardLayout.maxCardHeight(scene: scene, cardWidth: width, fraction: fraction, candidates: MapCardPlacement.regularPreference)
                #expect(height.isFinite && height >= 0 && height <= Double(scene.cardBounds.height) + 1e-6, context)
                // A card of that height fits somewhere (its content scrolls inside): the promise of `maxCardHeight`, to
                // within the spacing (an exact fit is the finding below).
                let smaller = height - 2 * scene.spacing - 0.01
                if smaller >= 1, width >= 1 {
                    let fits = MapCardPlacement.regularPreference.contains { MapCardLayout.frame(for: $0, cardSize: CGSize(width: width, height: smaller), scene: scene) != nil }
                    #expect(fits, context)
                }
            }
            let uncovered = MapCardLayout.uncoveredCenter(scene: scene, card: CGRect(x: rng.double(0...800), y: rng.double(0...800), width: rng.double(0...400), height: rng.double(0...400)),
                                                          marker: MapCardLayout.markerRect(center: .zero, radius: 22, labelHeight: 18), margin: 12)
            #expect(uncovered.x.isFinite && uncovered.y.isFinite, context)
            _ = MapCardLayout.selectionSpan(visibleSpanMeters: rng.pick([0, 5_000, 20_001, .nan, .infinity]), markerVisible: rng.chance(0.5))
            _ = MapCardLayout.isWorthPanning(from: CGPoint(x: 1e308, y: 0), to: CGPoint(x: -1e308, y: .nan))
            _ = MapCardLayout.panCenter(cameraCenter: .zero, marker: CGPoint(x: Double.nan, y: 1), target: CGPoint(x: 1, y: 1))
        }
    }

    /// L1: `maxCardHeight` promises "a card of this height always fits somewhere". `tallestGap` used to count only
    /// obstacles touching the card bounds while `frame(for:)` also counts one within `spacing` outside them, so with a
    /// control hugging the edge the promised card fit nowhere. Both use the same rule now.
    @Test func maxCardHeightCountsAnObstacleJustOutsideTheCardBounds() {
        let scene = MapCardScene(container: CGSize(width: 400, height: 800), obstacles: [
            CGRect(x: 0, y: 16, width: 400, height: 484),   // across the top, to y 500
            CGRect(x: 0, y: 788, width: 400, height: 12),   // across the bottom edge, 4 pt below the card bounds (y 784)
        ])
        let width = MapCardLayout.cardWidth(scene: scene)
        let height = MapCardLayout.maxCardHeight(scene: scene, cardWidth: width, fraction: MapCardLayout.regularMaxHeightFraction,
                                                 candidates: MapCardPlacement.regularPreference)
        #expect(height > 200 && height < 276, "the gap less the spacing to the bottom control: \(height)")
        let size = CGSize(width: width, height: height)
        #expect(MapCardLayout.place(marker: .zero, cardSize: size, scene: scene, candidates: MapCardPlacement.regularPreference, current: nil) != nil)
        #expect(MapCardLayout.frame(for: .bottomTrailing, cardSize: size, scene: scene) != nil)
    }

    /// L2: on a map shorter than the attribution's reserved height, the attribution rect fills the map instead of
    /// starting above it.
    @Test func attributionRectStaysInsideAMapShorterThanItsReservedHeight() {
        let scene = MapCardScene(container: CGSize(width: 300, height: 20))
        let attribution = scene.attribution()
        #expect(attribution == scene.safeBounds.intersection(attribution))
        #expect(attribution.minY == scene.safeBounds.minY && attribution.height == 20)
    }

    @Test func mapControlsAndUndergroundTapBlocking() {
        var rng = Chaos.rng("mapControlsAndUndergroundTapBlocking")
        for iteration in 0..<5_000 {
            let leading = chaosDouble(&rng), trailing = chaosDouble(&rng)
            let onLeading = MapControlsLayout.buttonsOnLeadingSide(windowLeadingInset: leading, windowTrailingInset: trailing)
            #expect(onLeading == MapControlsLayout.hasTrailingSystemColumn(leadingInset: leading, trailingInset: trailing))
            let span = TrainMap.visibleSpanMeters(latitudeDelta: rng.pick([0.01, -0.01, 1e300, .nan, 0]), longitudeDelta: rng.pick([0.02, 360, -1, 1e-300]), latitude: rng.double(-90...90))
            #expect(span.isNaN || span >= 0, Chaos.context("span", iteration: iteration, "\(span)"))
            _ = TrainMap.showsUnderground(visibleSpanMeters: span)
            _ = TrainMap.undergroundNote(count: rng.int(-3...500))
            let center = CLLocationCoordinate2D(latitude: 40.7, longitude: -73.99)
            let under = (0..<rng.int(0...8)).map { (id: $0, coordinate: moved(center, east: rng.double(-3_000...3_000), north: rng.double(-3_000...3_000))) }
            let above = (0..<rng.int(0...8)).map { _ in moved(center, east: rng.double(-3_000...3_000), north: rng.double(-3_000...3_000)) }
            let blocked = TrainMap.undergroundBlockedFromTaps(underground: under, aboveGround: above, visibleSpanMeters: rng.pick([0, 500, 3_000, 30_000, .nan]),
                                                              viewSidePoints: rng.pick([0, 400, 800, -1]), overlapRadiusPoints: rng.pick([0, 44, 22, .nan]))
            #expect(blocked.isSubset(of: Set(under.map(\.id))), Chaos.context("tap blocking", iteration: iteration, "\(blocked)"))
            if above.isEmpty { #expect(blocked.isEmpty) }
        }
    }

    // MARK: Camera: projection, lanes, compass strip

    static let fovs: [Double] = [0, 1, 10, 45, 60, 90, 120, 179, 179.9, 180, 181, 360, -60, .nan, .infinity]
    static let views: [Double] = [0, 1, 100, 402, 466, 669, 874, 951, 2_000, 1e6, -5, .nan, .infinity]

    @Test func projectionNeverTrapsAndKeepsItsPromisesForSanePoses() {
        var rng = Chaos.rng("projectionNeverTrapsAndKeepsItsPromisesForSanePoses")
        for iteration in 0..<30_000 {
            let sane = rng.chance(0.6)
            let pose = sane
                ? CameraPose(headingDegrees: rng.double(-720...720), pitchDegrees: rng.double(-90...90), horizontalFOVDegrees: rng.double(10...120),
                             viewWidth: rng.double(100...2_000), viewHeight: rng.double(100...2_000))
                : CameraPose(headingDegrees: chaosDouble(&rng), pitchDegrees: chaosDouble(&rng), horizontalFOVDegrees: rng.pick(Self.fovs), viewWidth: rng.pick(Self.views), viewHeight: rng.pick(Self.views))
            let bearing = sane ? rng.double(-720...720) : chaosDouble(&rng), distance = sane ? pow(10, rng.double(-1...4.5)) : chaosDouble(&rng)
            let context = Chaos.context("projection", iteration: iteration, "\(pose) bearing=\(bearing) distance=\(distance)")
            let placement = ARProjection.place(bearingDegrees: bearing, distanceMeters: distance, pose: pose,
                                               targetAltitude: sane ? rng.double(-60...120) : chaosDouble(&rng), eyeAltitude: sane ? rng.double(1.6...100) : chaosDouble(&rng))
            _ = ARProjection.horizonY(pose: pose)
            _ = pose.verticalFOVDegrees
            _ = ARProjection.visibleFieldOfView(sensorLongSideFOVDegrees: rng.pick(Self.fovs), sensorAspect: rng.pick([0, 4.0 / 3, -1, .nan, 1e300]), viewWidth: rng.pick(Self.views),
                                                viewHeight: rng.pick(Self.views), longSideIsVertical: rng.chance(0.5))
            _ = ARProjection.labelOpacity(distanceMeters: distance, selected: rng.chance(0.5))
            let relative = ARProjection.relativeBearing(bearing, heading: pose.headingDegrees)
            if abs(bearing) < 1e100 && abs(pose.headingDegrees) < 1e100 { #expect(relative > -180 - 1e-9 && relative <= 180 + 1e-9, context) }
            guard sane else { continue }
            // Sane pose: on screen exactly when within half the field of view, and then across the view.
            switch placement {
            case .onScreen(let x, let y):
                #expect(abs(relative) <= pose.horizontalFOVDegrees / 2 + 1e-9, context)
                #expect(x.isFinite && y.isFinite, context)
                #expect(x >= -1e-6 && x <= pose.viewWidth + 1e-6, context)
            case .offScreen(let side):
                #expect(abs(relative) > pose.horizontalFOVDegrees / 2 - 1e-9, context)
                #expect(side == (relative < 0 ? .left : .right), context)
            }
            let horizon = ARProjection.horizonY(pose: pose)
            #expect(horizon.isFinite || abs(pose.pitchDegrees) >= 89.9, context)
        }
    }

    @Test func labelLanesNeverOverlapWithinALane() {
        var rng = Chaos.rng("labelLanesNeverOverlapWithinALane")
        for iteration in 0..<4_000 {
            let count = rng.pick([0, 1, 2, 5, 20, 80, 200])
            let width = rng.pick([40, 120, 400]) as Double
            let slots = (0..<count).map { LabelSlot(id: $0, x: rng.double(-200...1_200), width: rng.double(0...width), distanceMeters: rng.chance(0.2) ? 100 : rng.double(0...20_000)) }
            let spacing = rng.pick([8, 0, 4, 40]) as Double
            let maxLanes = rng.pick([Int.max, 0, 1, 2, 4, 10])
            let context = Chaos.context("lanes", iteration: iteration, "spacing=\(spacing) maxLanes=\(maxLanes) slots=\(slots)")
            let lanes = LabelLayout.lanes(for: slots, spacing: spacing, maxLanes: maxLanes)
            #expect(lanes == LabelLayout.lanes(for: slots.reversed(), spacing: spacing, maxLanes: maxLanes), context)
            func overlap(_ a: LabelSlot, _ b: LabelSlot) -> Bool { abs(a.x - b.x) < (a.width + b.width) / 2 + spacing }
            var byLane: [Int: [LabelSlot]] = [:]
            for slot in slots { if let lane = lanes[slot.id] { byLane[lane, default: []].append(slot) } }
            for (lane, members) in byLane {
                #expect(lane >= 0 && lane < maxLanes, context)
                for (i, a) in members.enumerated() { for b in members[(i + 1)...] { #expect(!overlap(a, b), context) } }
            }
            // A label left out met an overlapping one in every lane it could have used.
            for slot in slots where lanes[slot.id] == nil {
                for lane in 0..<min(maxLanes, (byLane.keys.max() ?? -1) + 1) { #expect(byLane[lane]?.contains { overlap($0, slot) } == true, context) }
                if maxLanes != Int.max { #expect(byLane.count == maxLanes || maxLanes == 0, context) }
            }
            if maxLanes == Int.max { #expect(lanes.count == slots.count, context) }
            // The nearest keeps the lowest lane.
            if let nearest = slots.min(by: { ($0.distanceMeters, $0.id) < ($1.distanceMeters, $1.id) }), maxLanes > 0 { #expect(lanes[nearest.id] == 0, context) }
        }
        // Not numbers: placed or left out, never a trap.
        let odd = [LabelSlot(id: 1, x: .nan, width: .nan, distanceMeters: .nan), LabelSlot(id: 2, x: .infinity, width: -5, distanceMeters: 1), LabelSlot(id: 3, x: 0, width: .infinity, distanceMeters: -1)]
        _ = LabelLayout.lanes(for: odd, spacing: .nan, maxLanes: -3)
    }

    @Test func compassStripTicksStayOnTheStrip() {
        var rng = Chaos.rng("compassStripTicksStayOnTheStrip")
        for iteration in 0..<10_000 {
            // Headings are finite and within where whole numbers still fit (the huge ones are the `trap_` tests).
            let heading = rng.chance(0.7) ? rng.double(-720...720) : rng.pick([0, -0.0, 359.99, 360, 1e6, -1e6, 1e12, -1e12, 1e15])
            let fov = rng.chance(0.8) ? rng.double(5...150) : rng.pick(Self.fovs)
            let pose = CameraPose(headingDegrees: heading, pitchDegrees: rng.double(-90...90), horizontalFOVDegrees: fov,
                                  viewWidth: rng.pick([0, 1, 402, 951, 1e6, -3]), viewHeight: rng.pick([0, 800, 402, .nan]))
            let step = rng.pick([15, 1, 5, 45, 7, 360, 0, -15, 1_000])
            let context = Chaos.context("ticks", iteration: iteration, "\(pose) step=\(step)")
            let ticks = CompassStrip.ticks(pose: pose, step: step)
            guard fov > 0, fov < 180, step > 0, pose.viewWidth > 0 else { continue }
            #expect(ticks.count <= Int(fov / Double(step)) + 3, context)
            #expect(ticks.allSatisfy { (0..<360).contains($0.degrees) && (360 % step != 0 || $0.degrees % step == 0) }, context)
            #expect(ticks.allSatisfy { $0.x.isFinite && $0.x >= -1e-6 && $0.x <= pose.viewWidth + 1e-6 }, context)
            #expect(ticks.allSatisfy { ($0.label != nil) == ($0.degrees % 45 == 0) }, context)
            // Steps that are a turn or more apart (an API misuse the camera never makes) repeat a bearing.
            if step < 360 {
                #expect(ticks.map(\.degrees).count == Set(ticks.map(\.degrees)).count || fov > 150, context)
                // Ordered along the strip, left to right.
                #expect(ticks.map(\.x) == ticks.map(\.x).sorted() || fov > 150, context)
            }
        }
        // The pose with nothing to draw.
        #expect(CompassStrip.ticks(pose: CameraPose(headingDegrees: 10, pitchDegrees: 0, horizontalFOVDegrees: 180, viewWidth: 400, viewHeight: 800)).isEmpty)
        #expect(CompassStrip.ticks(pose: CameraPose(headingDegrees: 10, pitchDegrees: 0, horizontalFOVDegrees: .nan, viewWidth: 400, viewHeight: 800)).isEmpty)
    }
}
