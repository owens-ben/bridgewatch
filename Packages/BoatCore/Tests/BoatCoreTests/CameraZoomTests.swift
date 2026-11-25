import Foundation
import Testing
@testable import BoatCore

@Suite struct CameraZoomTests {
    @Test func zoomingNarrowsTheViewByItsTangent() {
        #expect(CameraZoom.fieldOfView(baseDegrees: 70, zoomFactor: 1) == 70)
        let twice = CameraZoom.fieldOfView(baseDegrees: 70, zoomFactor: 2)
        #expect(abs(twice - 2 * atan(tan(35 * Double.pi / 180) / 2) * 180 / .pi) < 1e-9)
        // An ultra wide's ~109° at factor 1 is the main camera's ~70° at factor 2 (1×).
        #expect(abs(CameraZoom.fieldOfView(baseDegrees: 108.9, zoomFactor: 2) - 70) < 0.1)
    }

    @Test func presetsForATripleCamera() {
        // Ultra wide, wide and a 5× telephoto: switch-overs at factors 2 (1×) and 10 (5×).
        #expect(CameraZoom.presets(switchOverFactors: [2, 10], displayMultiplier: 0.5, maxFactor: 30) == [0.5, 1, 2, 5])
        // A 3× telephoto.
        #expect(CameraZoom.presets(switchOverFactors: [2, 6], displayMultiplier: 0.5, maxFactor: 30) == [0.5, 1, 2, 3])
    }

    @Test func presetsWithoutAnUltraWide() {
        // A single wide camera, and a wide with a 2× telephoto: no 0.5, and 2 only once.
        #expect(CameraZoom.presets(switchOverFactors: [], displayMultiplier: 1, maxFactor: 10) == [1, 2])
        #expect(CameraZoom.presets(switchOverFactors: [2], displayMultiplier: 1, maxFactor: 10) == [1, 2])
    }

    @Test func presetsStopAtTheHighestZoom() {
        #expect(CameraZoom.presets(switchOverFactors: [2, 10], displayMultiplier: 0.5, maxFactor: 3) == [0.5, 1])
    }

    @Test func theLitButtonIsTheHighestAtOrBelowTheZoom() {
        let presets = [0.5, 1, 2, 5]
        #expect(CameraZoom.activePreset(for: 0.5, in: presets) == 0.5)
        #expect(CameraZoom.activePreset(for: 1.4, in: presets) == 1)
        #expect(CameraZoom.activePreset(for: 1.98, in: presets) == 2)
        #expect(CameraZoom.activePreset(for: 8, in: presets) == 5)
    }

    @Test func buttonText() {
        #expect(CameraZoom.text(0.5) == "0.5")
        #expect(CameraZoom.text(1) == "1")
        #expect(CameraZoom.text(1.44) == "1.4")
        #expect(CameraZoom.text(4.98) == "5")
    }
}
