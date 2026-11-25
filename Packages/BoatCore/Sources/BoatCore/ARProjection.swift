import CoreLocation
import Foundation

/// Where the camera points and what it sees. Sizes are the real view size in points; nothing assumes a phone
/// aspect ratio. Roll is ignored: the camera screen is used held upright.
public struct CameraPose: Sendable, Equatable {
    /// True heading of the camera's optical axis, degrees.
    public var headingDegrees: Double
    /// Elevation of the optical axis above the horizon, degrees (positive when tilted up).
    public var pitchDegrees: Double
    /// Horizontal field of view of the visible preview, degrees (see `visibleFieldOfView`).
    public var horizontalFOVDegrees: Double
    public var viewWidth: Double
    public var viewHeight: Double

    public init(headingDegrees: Double, pitchDegrees: Double, horizontalFOVDegrees: Double,
                viewWidth: Double, viewHeight: Double) {
        self.headingDegrees = headingDegrees
        self.pitchDegrees = pitchDegrees
        self.horizontalFOVDegrees = horizontalFOVDegrees
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
    }

    /// Vertical field of view implied by the horizontal one and the view's aspect ratio (square pixels).
    public var verticalFOVDegrees: Double {
        guard viewWidth > 0 else { return 0 }
        return degrees(2 * atan(tan(radians(horizontalFOVDegrees) / 2) * viewHeight / viewWidth))
    }
}

/// Which screen edge an off-screen vessel is beyond.
public enum ScreenSide: Sendable, Equatable {
    case left, right
}

/// Where a vessel lands on screen.
public enum ScreenPlacement: Sendable, Equatable {
    /// `x` across the view, `y` the target's point (a vessel's waterline, a train's rail; may lie above or below the
    /// view when tilted far).
    case onScreen(x: Double, y: Double)
    case offScreen(ScreenSide)
}

public enum ARProjection {
    /// Eye height above the water used for the waterline point (standing on a pier).
    public static let observerHeightMeters = 1.6
    /// Labels beyond this distance draw at reduced opacity (0.5 mi).
    public static let farDistanceMeters = 804.672

    /// Bearing relative to the camera axis, in (-180, 180]: negative is left of center.
    public static func relativeBearing(_ bearingDegrees: Double, heading headingDegrees: Double) -> Double {
        var r = (bearingDegrees - headingDegrees).truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 }
        if r <= -180 { r += 360 }
        return r
    }

    /// Elevation of a point above the horizon as seen from the eye, degrees (negative below it):
    /// `atan((targetAltitude - eyeAltitude) / distance)`, with the distance at least 1 m. Flat earth: the Earth's
    /// curve drops a point 5 km off by about 2 m, a few hundredths of a degree.
    /// - Parameters:
    ///   - targetAltitude: the point's height, meters above sea level: 0 for a boat's waterline, a train's rail.
    ///   - eyeAltitude: the eye's, meters above sea level (`Sightlines.eyeAltitude(at:height:)`).
    public static func elevationDegrees(distanceMeters: Double, targetAltitude: Double, eyeAltitude: Double) -> Double {
        // Written as the depression of the eye above the target so that a boat (target 0, eye
        // `observerHeightMeters`) computes exactly the expression this function replaced.
        -degrees(atan((eyeAltitude - targetAltitude) / max(distanceMeters, 1)))
    }

    /// Projects a target at `bearingDegrees` and `distanceMeters` from the observer onto the view. `y` is where a
    /// point `targetAltitude` meters above sea level lands, seen from an eye `eyeAltitude` above sea level, by its
    /// true elevation angle (`elevationDegrees`): above the horizon line when it's higher than the eye, below it when
    /// lower. The defaults are a boat's waterline seen standing on a pier (`observerHeightMeters`), what every vessel
    /// label uses.
    public static func place(bearingDegrees: Double, distanceMeters: Double, pose: CameraPose,
                             targetAltitude: Double = 0, eyeAltitude: Double = observerHeightMeters) -> ScreenPlacement {
        let relative = relativeBearing(bearingDegrees, heading: pose.headingDegrees)
        let halfH = pose.horizontalFOVDegrees / 2
        guard abs(relative) <= halfH, halfH > 0, halfH < 90 else {
            return .offScreen(relative < 0 ? .left : .right)
        }
        let w = pose.viewWidth, h = pose.viewHeight
        let x = w / 2 + (w / 2) * tan(radians(relative)) / tan(radians(halfH))

        // A boat's waterline sits just below the horizon: depression atan(eye height / distance).
        let elevation = elevationDegrees(distanceMeters: distanceMeters, targetAltitude: targetAltitude,
                                         eyeAltitude: eyeAltitude)
        let offAxis = elevation - pose.pitchDegrees
        let halfV = pose.verticalFOVDegrees / 2
        // A view with no height has no vertical field of view: put the dot on the middle line rather than at NaN.
        let y = halfV > 0 && halfV < 90 ? h / 2 - (h / 2) * tan(radians(offAxis)) / tan(radians(halfV)) : h / 2
        return .onScreen(x: x, y: y)
    }

    /// Screen y of the horizon for this pose.
    /// The middle of the view when there's no usable vertical field of view (0 or not finite), or the pitch isn't
    /// finite: tan(0) / tan(0) would be NaN.
    public static func horizonY(pose: CameraPose) -> Double {
        let halfV = pose.verticalFOVDegrees / 2
        guard halfV > 0, halfV < 90, pose.pitchDegrees.isFinite else { return pose.viewHeight / 2 }
        return pose.viewHeight / 2 + (pose.viewHeight / 2) * tan(radians(pose.pitchDegrees)) / tan(radians(halfV))
    }

    /// Visible field of view of an aspect-fill preview, from the sensor's field of view along its long side.
    /// - Parameters:
    ///   - sensorLongSideFOVDegrees: e.g. `AVCaptureDevice.Format.videoFieldOfView` (landscape horizontal).
    ///   - sensorAspect: long side / short side of the capture format, e.g. 4/3.
    ///   - longSideIsVertical: true when the preview is in portrait (sensor long side runs up the view).
    /// - Returns: horizontal and vertical field of view of what the view actually shows, degrees.
    public static func visibleFieldOfView(
        sensorLongSideFOVDegrees: Double, sensorAspect: Double, viewWidth: Double, viewHeight: Double,
        longSideIsVertical: Bool
    ) -> (horizontal: Double, vertical: Double) {
        guard viewWidth > 0, viewHeight > 0, sensorAspect > 0 else { return (0, 0) }
        let tanLong = tan(radians(sensorLongSideFOVDegrees) / 2)
        let tanShort = tanLong / sensorAspect
        let tanX = longSideIsVertical ? tanShort : tanLong
        let tanY = longSideIsVertical ? tanLong : tanShort
        // Aspect fill scales the image to cover the view and crops the overflow, so each axis shows the
        // smaller of its own extent and the other axis's extent scaled by the view's aspect ratio.
        let visibleX = min(tanX, tanY * viewWidth / viewHeight)
        let visibleY = min(tanY, tanX * viewHeight / viewWidth)
        return (degrees(2 * atan(visibleX)), degrees(2 * atan(visibleY)))
    }

    /// True when the heading is too uncertain to place labels well (worse than ±10°, or invalid).
    public static func needsCompassCalibration(headingAccuracyDegrees: Double) -> Bool {
        headingAccuracyDegrees < 0 || headingAccuracyDegrees > 10
    }

    /// Opacity for a label: selected and nearby labels full, others beyond 0.5 mi at 60%.
    public static func labelOpacity(distanceMeters: Double, selected: Bool) -> Double {
        selected || distanceMeters <= farDistanceMeters ? 1 : 0.6
    }
}

/// One label to lay out: its anchor x and its width on screen.
public struct LabelSlot: Sendable, Equatable {
    public let id: Int
    public let x: Double
    public let width: Double
    /// Nearer labels take the lowest lanes, closest to the horizon.
    public let distanceMeters: Double

    public init(id: Int, x: Double, width: Double, distanceMeters: Double) {
        self.id = id
        self.x = x
        self.width = width
        self.distanceMeters = distanceMeters
    }
}

public enum LabelLayout {
    /// Stacks overlapping labels into lanes (0 = lowest). Nearest vessels are placed first, so they keep lane 0;
    /// a label moves up until it no longer overlaps any label already in that lane. With every lane up to `maxLanes`
    /// taken, a label gets none: it's left out of the result (the farther vessels show only their waterline dot).
    public static func lanes(for slots: [LabelSlot], spacing: Double = 8, maxLanes: Int = .max) -> [Int: Int] {
        var placed: [[LabelSlot]] = []
        var result: [Int: Int] = [:]
        for slot in slots.sorted(by: { ($0.distanceMeters, $0.id) < ($1.distanceMeters, $1.id) }) {
            var lane = 0
            while lane < placed.count, placed[lane].contains(where: { overlaps($0, slot, spacing: spacing) }) {
                lane += 1
            }
            guard lane < maxLanes else { continue }
            if lane == placed.count { placed.append([]) }
            placed[lane].append(slot)
            result[slot.id] = lane
        }
        return result
    }

    /// How many lanes of `laneHeight` (plus `spacing`) fit in `room` points above the first lane: at least one,
    /// also when `room` isn't finite or is negative.
    public static func laneCount(room: Double, laneHeight: Double, spacing: Double = 8) -> Int {
        let pitch = laneHeight + spacing
        guard room.isFinite, pitch.isFinite, pitch > 0 else { return 1 }
        return max(1, Int(saturating: room / pitch) + 1)
    }

    private static func overlaps(_ a: LabelSlot, _ b: LabelSlot, spacing: Double) -> Bool {
        abs(a.x - b.x) < (a.width + b.width) / 2 + spacing
    }
}

/// A mark on the compass strip.
public struct CompassTick: Sendable, Equatable {
    public let degrees: Int
    public let x: Double
    /// "N", "NE", ... on 45° marks, nil on minor ticks.
    public let label: String?
}

/// The compass strip's rows, top to bottom, in points from the strip's top: the heading readout ("NE 45°"), the
/// ticks with the needle (where the camera points) among them, then the "N", "NE" letters under the ticks. The
/// needle stays in the tick row, so it never runs through a letter or the readout, whatever the heading.
public struct CompassStripLayout: Sendable, Equatable {
    public var height = 52.0
    /// The readout's center and half height (headline, the strip's text capped at xxLarge).
    public var headingCenterY = 12.0
    public var headingHalfHeight = 11.0
    /// Ticks hang from `tickTop`: a 45° mark is `majorTickHeight` long, the rest `minorTickHeight`.
    public var tickTop = 25.0
    public var majorTickHeight = 9.0
    public var minorTickHeight = 5.0
    /// The needle, a little longer than a major tick on either end.
    public var needleTop = 24.0
    public var needleBottom = 36.0
    /// The letters' center and half height (caption2 bold at the capped size).
    public var labelCenterY = 44.0
    public var labelHalfHeight = 7.0

    public init() {}

    public static let standard = CompassStripLayout()

    public var headingBottom: Double { headingCenterY + headingHalfHeight }
    public var labelTop: Double { labelCenterY - labelHalfHeight }
    public var labelBottom: Double { labelCenterY + labelHalfHeight }

    /// The needle sits between the readout and the letters, and the letters inside the strip.
    public var isClear: Bool {
        headingBottom <= needleTop && needleBottom < labelTop && labelBottom <= height
            && tickTop + majorTickHeight <= labelTop
    }
}

public enum CompassStrip {
    /// Ticks every `step` degrees across the camera's field of view, positioned like the labels so a tick lines
    /// up with a vessel at that bearing. `x` is relative to a strip as wide as the view.
    public static func ticks(pose: CameraPose, step: Int = 15) -> [CompassTick] {
        let half = pose.horizontalFOVDegrees / 2
        guard step > 0, half > 0, half < 90, pose.headingDegrees.isFinite else { return [] }
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        // Into [0, 360) first: a finite heading past Int.max (1e300) would trap the conversions below. `place`
        // normalizes the relative bearing, so the ticks are the same.
        let heading = pose.headingDegrees.truncatingRemainder(dividingBy: 360)
        let low = Int(floor((heading - half) / Double(step))) * step
        let high = Int(ceil((heading + half) / Double(step))) * step
        return stride(from: low, through: high, by: step).compactMap { raw in
            let degrees = ((raw % 360) + 360) % 360
            guard case .onScreen(let x, _) = ARProjection.place(
                bearingDegrees: Double(degrees), distanceMeters: 1_000, pose: pose) else { return nil }
            return CompassTick(degrees: degrees, x: x, label: degrees % 45 == 0 ? names[degrees / 45] : nil)
        }
    }
}

private func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
private func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
