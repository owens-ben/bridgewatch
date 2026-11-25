import CoreGraphics
import Foundation
import Testing
@testable import BoatCore

@Suite struct MapControlsLayoutTests {
    @Test func aTrailingSystemColumnMovesTheButtonsLeading() {
        // Duo cover and unfolded: the status column is a trailing inset.
        #expect(MapControlsLayout.buttonsOnLeadingSide(windowLeadingInset: 0, windowTrailingInset: 84))
        // Phones: none in portrait, equal in landscape.
        #expect(!MapControlsLayout.buttonsOnLeadingSide(windowLeadingInset: 0, windowTrailingInset: 0))
        #expect(!MapControlsLayout.buttonsOnLeadingSide(windowLeadingInset: 62, windowTrailingInset: 62))
        #expect(!MapControlsLayout.buttonsOnLeadingSide(windowLeadingInset: .nan, windowTrailingInset: 10))
    }

    /// The map card with the buttons top leading: never over them, the marker or the other controls.
    @Test(arguments: [false, true])
    func theCardAvoidsLeadingButtons(_ regular: Bool) throws {
        let screens: [(CGSize, MapInsets)] = [
            (CGSize(width: 382, height: 678), MapInsets(top: 0, bottom: 0)),
            (CGSize(width: 527, height: 669), MapInsets(top: 0, bottom: 0)),
        ]
        for (size, insets) in screens {
            let bare = MapCardScene(container: size, safeInsets: insets)
            let safe = bare.safeBounds
            let buttons = CGRect(x: safe.minX + 16, y: safe.minY + 16, width: 44, height: 136)
            let note = CGRect(x: safe.minX + 16, y: safe.maxY - 16 - 36 - 34, width: 260, height: 34)
            let scene = MapCardScene(container: size, safeInsets: insets,
                                     obstacles: [buttons, note, bare.attribution()])
            #expect(MapCardLayout.reservedTrailing(scene: scene, column: buttons) == 0)
            let width = regular ? MapCardLayout.regularCardWidth(scene: scene, column: buttons)
                : MapCardLayout.cardWidth(scene: scene,
                                          reservedTrailing: MapCardLayout.reservedTrailing(scene: scene, column: buttons))
            #expect(width > 200)
            let candidates = regular ? MapCardPlacement.regularPreference : MapCardPlacement.compactPreference
            let maxHeight = MapCardLayout.maxCardHeight(
                scene: scene, cardWidth: width,
                fraction: regular ? MapCardLayout.regularMaxHeightFraction : MapCardLayout.compactMaxHeightFraction,
                candidates: candidates)
            for height in [90.0, 200] {
                let card = CGSize(width: width, height: min(height, maxHeight))
                for fx in stride(from: 0.0, through: 1.0, by: 0.1) {
                    for fy in stride(from: 0.0, through: 1.0, by: 0.05) {
                        let point = CGPoint(x: Double(size.width) * fx, y: Double(size.height) * fy)
                        let marker = MapCardLayout.markerRect(center: point, radius: 22, labelHeight: 18)
                        let decision = try #require(MapCardLayout.place(marker: marker, cardSize: card, scene: scene,
                                                                        candidates: candidates, current: nil))
                        for obstacle in scene.obstacles {
                            #expect(!decision.frame.intersects(obstacle), "\(decision.frame) covers \(obstacle)")
                        }
                    }
                }
            }
        }
    }
}
