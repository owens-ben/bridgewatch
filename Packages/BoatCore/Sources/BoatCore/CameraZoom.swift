import Foundation

/// Zoom in the Camera app's terms ("displayed" zoom): 1× is the main wide camera, 0.5× the ultra wide, 5× a
/// telephoto. `AVCaptureDevice.videoZoomFactor` counts from the widest camera instead, so on a phone with an ultra
/// wide, 1× is a factor of 2; `displayMultiplier` (`displayVideoZoomFactorMultiplier`, 0.5 there) converts.
public enum CameraZoom {
    /// The widest the zoom buttons and pinching go: past this, labels are no help.
    public static let maxDisplayZoom = 10.0

    /// Field of view at a zoom factor: zooming in crops the image, which narrows the view by its tangent.
    public static func fieldOfView(baseDegrees: Double, zoomFactor: Double) -> Double {
        guard zoomFactor > 0 else { return baseDegrees }
        return 2 * atan(tan(baseDegrees * .pi / 360) / zoomFactor) * 180 / .pi
    }

    /// Zoom buttons, in displayed zoom: the widest camera (0.5 with an ultra wide), the main camera (1), a 2× crop
    /// of it, and each telephoto (e.g. 5), up to `maxFactor`.
    /// - Parameters:
    ///   - switchOverFactors: the device's `virtualDeviceSwitchOverVideoZoomFactors` (empty for a single camera).
    ///   - maxFactor: the highest `videoZoomFactor` allowed.
    public static func presets(switchOverFactors: [Double], displayMultiplier: Double, maxFactor: Double) -> [Double] {
        guard displayMultiplier > 0 else { return [] }
        let widest = displayMultiplier
        let highest = min(maxFactor * displayMultiplier, maxDisplayZoom)
        let telephotos = switchOverFactors.map { $0 * displayMultiplier }.filter { $0 > 1.01 }
        var presets = [widest, 1, 2] + telephotos
        // One decimal, as shown, and once each.
        presets = presets.map { ($0 * 10).rounded() / 10 }.filter { $0 >= widest - 0.01 && $0 <= highest + 0.01 }
        return Array(Set(presets)).sorted()
    }

    /// The button that's lit for a displayed zoom: the highest preset at or below it.
    public static func activePreset(for displayZoom: Double, in presets: [Double]) -> Double? {
        presets.last { $0 <= displayZoom + 0.05 } ?? presets.first
    }

    /// "0.5", "1", "2", "1.4": as the buttons show it; "" for a zoom that isn't finite.
    public static func text(_ displayZoom: Double) -> String {
        guard displayZoom.isFinite, abs(displayZoom) < 1e6 else { return "" }
        let tenths = (displayZoom * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }
}
