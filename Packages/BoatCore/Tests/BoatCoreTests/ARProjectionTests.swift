import Foundation
import Testing
@testable import BoatCore

@Suite struct ARProjectionTests {
    /// iPhone-ish portrait preview, but the math must hold for any size.
    let pose = CameraPose(headingDegrees: 0, pitchDegrees: 0, horizontalFOVDegrees: 60, viewWidth: 400, viewHeight: 800)

    func x(_ placement: ScreenPlacement) -> Double? {
        if case .onScreen(let x, _) = placement { return x }
        return nil
    }

    func y(_ placement: ScreenPlacement) -> Double? {
        if case .onScreen(_, let y) = placement { return y }
        return nil
    }

    @Test(arguments: [
        (10.0, 0.0, 10.0), (350, 0, -10), (180, 0, 180), (0, 90, -90), (270, 90, 180), (90, 270, 180), (45, 400, 5),
    ])
    func relativeBearingIsNormalized(bearing: Double, heading: Double, expected: Double) {
        #expect(abs(ARProjection.relativeBearing(bearing, heading: heading) - expected) < 1e-9)
    }

    @Test func straightAheadIsCentered() {
        #expect(abs(x(ARProjection.place(bearingDegrees: 0, distanceMeters: 300, pose: pose))! - 200) < 1e-9)
    }

    @Test func fieldOfViewEdgesHitViewEdges() {
        #expect(abs(x(ARProjection.place(bearingDegrees: 30, distanceMeters: 300, pose: pose))! - 400) < 1e-6)
        #expect(abs(x(ARProjection.place(bearingDegrees: -30, distanceMeters: 300, pose: pose))! - 0) < 1e-6)
    }

    @Test func pinholeNotLinear() {
        // tan(15°)/tan(30°) of the half width right of center.
        let expected = 200 + 200 * tan(15 * Double.pi / 180) / tan(30 * Double.pi / 180)
        #expect(abs(x(ARProjection.place(bearingDegrees: 15, distanceMeters: 300, pose: pose))! - expected) < 1e-6)
    }

    @Test func outsideFieldOfViewIsOffScreenOnTheNearerSide() {
        #expect(ARProjection.place(bearingDegrees: 31, distanceMeters: 300, pose: pose) == .offScreen(.right))
        #expect(ARProjection.place(bearingDegrees: 329, distanceMeters: 300, pose: pose) == .offScreen(.left))
        #expect(ARProjection.place(bearingDegrees: 170, distanceMeters: 300, pose: pose) == .offScreen(.right))
        #expect(ARProjection.place(bearingDegrees: 190, distanceMeters: 300, pose: pose) == .offScreen(.left))
    }

    @Test func headingRotatesTheScene() {
        var turned = pose
        turned.headingDegrees = 318
        #expect(abs(x(ARProjection.place(bearingDegrees: 318, distanceMeters: 300, pose: turned))! - 200) < 1e-9)
        #expect(x(ARProjection.place(bearingDegrees: 330, distanceMeters: 300, pose: turned))! > 200)
    }

    @Test func waterlineIsJustBelowHorizonAndNearerIsLower() {
        let horizon = ARProjection.horizonY(pose: pose)
        #expect(horizon == 400)
        let far = y(ARProjection.place(bearingDegrees: 0, distanceMeters: 1_500, pose: pose))!
        let near = y(ARProjection.place(bearingDegrees: 0, distanceMeters: 50, pose: pose))!
        #expect(far > horizon && far < horizon + 2)
        #expect(near > far)
    }

    @Test func tiltingUpMovesHorizonDown() {
        var up = pose
        up.pitchDegrees = 10
        #expect(ARProjection.horizonY(pose: up) > 400)
        var down = pose
        down.pitchDegrees = -10
        #expect(ARProjection.horizonY(pose: down) < 400)
    }

    @Test func verticalFieldOfViewFollowsViewAspect() {
        #expect(abs(pose.verticalFOVDegrees - 2 * atan(tan(30 * Double.pi / 180) * 2) * 180 / .pi) < 1e-9)
        let square = CameraPose(headingDegrees: 0, pitchDegrees: 0, horizontalFOVDegrees: 60, viewWidth: 500, viewHeight: 500)
        #expect(abs(square.verticalFOVDegrees - 60) < 1e-9)
    }

    @Test func worksForAnyViewSize() {
        // Duo inner screen, landscape, and a tiny view.
        for (w, h) in [(951.0, 669.0), (466, 678), (120, 40)] {
            let p = CameraPose(headingDegrees: 90, pitchDegrees: 0, horizontalFOVDegrees: 64, viewWidth: w, viewHeight: h)
            #expect(abs(x(ARProjection.place(bearingDegrees: 90, distanceMeters: 300, pose: p))! - w / 2) < 1e-9)
            #expect(abs(x(ARProjection.place(bearingDegrees: 122, distanceMeters: 300, pose: p))! - w) < 1e-6)
        }
    }

    @Test func visibleFieldOfViewPortraitCropsTheSides() {
        // 4:3 sensor, 70° along its long side; portrait view taller than 4:3, so the sides are cropped.
        let fov = ARProjection.visibleFieldOfView(
            sensorLongSideFOVDegrees: 70, sensorAspect: 4.0 / 3.0, viewWidth: 400, viewHeight: 870, longSideIsVertical: true)
        #expect(abs(fov.vertical - 70) < 1e-9)
        let expectedH = 2 * atan(tan(35 * Double.pi / 180) * 400 / 870) * 180 / .pi
        #expect(abs(fov.horizontal - expectedH) < 1e-9)
    }

    @Test func visibleFieldOfViewLandscapeCropsTopAndBottom() {
        // Landscape view wider than 4:3 (Duo inner screen): full width visible, top and bottom cropped.
        let fov = ARProjection.visibleFieldOfView(
            sensorLongSideFOVDegrees: 70, sensorAspect: 4.0 / 3.0, viewWidth: 951, viewHeight: 669, longSideIsVertical: false)
        #expect(abs(fov.horizontal - 70) < 1e-9)
        #expect(fov.vertical < 2 * atan(tan(35 * Double.pi / 180) * 3 / 4) * 180 / .pi)
    }

    @Test func visibleFieldOfViewMatchingAspectShowsWholeSensor() {
        let fov = ARProjection.visibleFieldOfView(
            sensorLongSideFOVDegrees: 70, sensorAspect: 4.0 / 3.0, viewWidth: 400, viewHeight: 300, longSideIsVertical: false)
        #expect(abs(fov.horizontal - 70) < 1e-9)
        #expect(abs(fov.vertical - 2 * atan(tan(35 * Double.pi / 180) * 3 / 4) * 180 / .pi) < 1e-9)
    }

    @Test(arguments: [(-1.0, true), (0, false), (5, false), (10, false), (10.5, true), (12, true)])
    func calibrationThreshold(accuracy: Double, needed: Bool) {
        #expect(ARProjection.needsCompassCalibration(headingAccuracyDegrees: accuracy) == needed)
    }

    @Test func farLabelsFadeUnlessSelected() {
        #expect(ARProjection.labelOpacity(distanceMeters: 800, selected: false) == 1)
        #expect(ARProjection.labelOpacity(distanceMeters: 900, selected: false) == 0.6)
        #expect(ARProjection.labelOpacity(distanceMeters: 900, selected: true) == 1)
    }
}

@Suite struct LabelLayoutTests {
    @Test func separatedLabelsShareTheBottomLane() {
        let lanes = LabelLayout.lanes(for: [
            LabelSlot(id: 1, x: 50, width: 80, distanceMeters: 100),
            LabelSlot(id: 2, x: 300, width: 80, distanceMeters: 200),
        ])
        #expect(lanes == [1: 0, 2: 0])
    }

    @Test func overlappingLabelsStackNearestLowest() {
        let lanes = LabelLayout.lanes(for: [
            LabelSlot(id: 1, x: 200, width: 120, distanceMeters: 600),
            LabelSlot(id: 2, x: 220, width: 120, distanceMeters: 100),
            LabelSlot(id: 3, x: 240, width: 120, distanceMeters: 300),
        ])
        #expect(lanes == [2: 0, 3: 1, 1: 2])
    }

    @Test func labelDropsToLowestFreeLane() {
        let lanes = LabelLayout.lanes(for: [
            LabelSlot(id: 1, x: 100, width: 100, distanceMeters: 1),
            LabelSlot(id: 2, x: 150, width: 100, distanceMeters: 2),
            LabelSlot(id: 3, x: 400, width: 100, distanceMeters: 3),
        ])
        #expect(lanes == [1: 0, 2: 1, 3: 0])
    }

    @Test func labelsPastTheLastLaneAreLeftOutFarthestFirst() {
        let slots = (1...4).map { LabelSlot(id: $0, x: 200, width: 120, distanceMeters: Double($0) * 100) }
        #expect(LabelLayout.lanes(for: slots, maxLanes: 2) == [1: 0, 2: 1])
        // A label that fits in a free spot of a lower lane still gets one.
        let spread = slots + [LabelSlot(id: 5, x: 600, width: 120, distanceMeters: 900)]
        #expect(LabelLayout.lanes(for: spread, maxLanes: 2) == [1: 0, 2: 1, 5: 0])
    }

    @Test func spacingCountsAsOverlap() {
        let slots = [LabelSlot(id: 1, x: 0, width: 100, distanceMeters: 1), LabelSlot(id: 2, x: 104, width: 100, distanceMeters: 2)]
        #expect(LabelLayout.lanes(for: slots, spacing: 8)[2] == 1)
        #expect(LabelLayout.lanes(for: slots, spacing: 2)[2] == 0)
    }
}

@Suite struct CompassStripTests {
    @Test func ticksAlignWithBearingsAndNameCardinals() {
        let pose = CameraPose(headingDegrees: 318, pitchDegrees: 0, horizontalFOVDegrees: 60, viewWidth: 400, viewHeight: 800)
        let ticks = CompassStrip.ticks(pose: pose)
        #expect(ticks.map(\.degrees) == [300, 315, 330, 345])
        #expect(ticks.first { $0.degrees == 315 }?.label == "NW")
        #expect(ticks.first { $0.degrees == 330 }?.label == nil)
        // NW is 3° left of center.
        let nw = ticks.first { $0.degrees == 315 }!.x
        #expect(nw < 200 && nw > 180)
    }

    @Test func wrapsThroughNorth() {
        let pose = CameraPose(headingDegrees: 2, pitchDegrees: 0, horizontalFOVDegrees: 60, viewWidth: 400, viewHeight: 800)
        let ticks = CompassStrip.ticks(pose: pose)
        #expect(ticks.map(\.degrees) == [345, 0, 15, 30])
        #expect(ticks.first { $0.degrees == 0 }?.label == "N")
    }
}

/// The dogfood report's issue 14: the needle ran through "NE" when the heading sat on it.
struct CompassStripLayoutTests {
    @Test func needleKeepsToTheTickRow() {
        let layout = CompassStripLayout.standard
        #expect(layout.isClear)
        #expect(layout.needleBottom < layout.labelTop, "the needle reaches into the letters")
        #expect(layout.headingBottom <= layout.needleTop, "the needle reaches into the readout")
        #expect(layout.labelBottom <= layout.height)
    }

    /// Even with the heading exactly on a lettered mark (the letter right under the needle), they don't overlap.
    @Test func headingOnACardinalPoint() {
        let pose = CameraPose(headingDegrees: 45, pitchDegrees: 0, horizontalFOVDegrees: 60, viewWidth: 400, viewHeight: 800)
        let ne = CompassStrip.ticks(pose: pose).first { $0.label == "NE" }
        #expect(ne.map { abs($0.x - 200) < 1 } == true)
        let layout = CompassStripLayout.standard
        #expect(!(layout.needleTop...layout.needleBottom).overlaps(layout.labelTop...layout.labelBottom))
    }
}
