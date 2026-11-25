import Foundation
import Testing
@testable import BoatCore

/// The closest card fills with the boat group's color (docs/DESIGN.md, Color tokens); its text and glyphs take
/// `TypePalette.ink`, which must give at least 4.5:1 in light and dark, on both halves of First responder's fill.
struct ContrastTests {
    @Test func knownRatios() {
        #expect(abs(Contrast.ratio(.white, .black) - 21) < 0.001)
        #expect(abs(Contrast.ratio(.white, .white) - 1) < 0.001)
        // WCAG's reference: #777777 on white is 4.48:1.
        #expect(abs(Contrast.ratio(RGB(hex: 0x777777), .white) - 4.48) < 0.01)
        #expect(Contrast.ratio(RGB(hex: 0x0071A4), .white) == Contrast.ratio(.white, RGB(hex: 0x0071A4)))
    }

    @Test func inkPicksTheBetterSideOfTheWholeFill() {
        #expect(Contrast.ink(on: [RGB(hex: 0xFFD60A)]) == .black)
        #expect(Contrast.ink(on: [RGB(hex: 0x1F45C7)]) == .white)
        // Two-tone: the worst half decides.
        #expect(Contrast.ink(on: [RGB(hex: 0xFFFFFF), RGB(hex: 0x000000)]) == .white)
        #expect(Contrast.worstRatio(of: .white, on: [RGB(hex: 0xFFFFFF), RGB(hex: 0x1F45C7)]) == 1)
    }

    @Test(arguments: VesselCategory.allCases, [false, true])
    func everyGroupFillHasReadableInk(_ category: VesselCategory, dark: Bool) {
        let fills = TypePalette.fills(category, dark: dark)
        let ink = TypePalette.ink(category, dark: dark)
        let ratio = Contrast.worstRatio(of: ink, on: fills)
        #expect(ratio >= Contrast.minimumTextRatio, "\(category) \(dark ? "dark" : "light"): \(ink) on \(fills) is \(ratio):1")
    }

    /// The night card: the night red text on the night raised surface (App/Theme.swift, NightPalette), primary and
    /// secondary.
    @Test func nightCardText() {
        let raised = RGB(hex: 0x220806)
        #expect(Contrast.ratio(RGB(hex: 0xFF6A5C), raised) >= Contrast.minimumTextRatio)
        #expect(Contrast.ratio(RGB(hex: 0xF23A2E), raised) >= Contrast.minimumTextRatio)
    }

    /// The card's text is drawn at full strength: the old 80% captions fell to about 3.7:1 on Other's grey.
    @Test func dimmedInkWouldFail() {
        let grey = TypePalette.fills(.other, dark: false)[0]
        let dimmed = Contrast.composite(.white, opacity: 0.8, over: grey)
        #expect(Contrast.ratio(dimmed, grey) < Contrast.minimumTextRatio)
    }

    /// `TypePalette` is the asset catalog's colors: read App/Assets.xcassets and compare, so a color changed in one
    /// place can't drift from the contrast check.
    @Test(arguments: VesselCategory.allCases)
    func paletteMatchesTheAssetCatalog(_ category: VesselCategory) throws {
        let catalog = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../App/Assets.xcassets").standardized
        for (index, name) in TypePalette.assetNames(category).enumerated() {
            let data = try Data(contentsOf: catalog.appending(path: "\(name).colorset/Contents.json"))
            let colors = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])["colors"] as? [[String: Any]]
            for entry in try #require(colors) {
                let dark = (entry["appearances"] as? [[String: String]])?.contains { $0["value"] == "dark" } ?? false
                let components = try #require((entry["color"] as? [String: Any])?["components"] as? [String: String])
                func channel(_ key: String) throws -> Double {
                    let text = try #require(components[key])
                    let value = text.hasPrefix("0x") ? Double(UInt32(text.dropFirst(2), radix: 16) ?? 0) / 255 : Double(text) ?? -1
                    return value
                }
                let asset = RGB(red: try channel("red"), green: try channel("green"), blue: try channel("blue"))
                #expect(asset == TypePalette.fills(category, dark: dark)[index], "\(name) \(dark ? "dark" : "light")")
            }
        }
    }
}
