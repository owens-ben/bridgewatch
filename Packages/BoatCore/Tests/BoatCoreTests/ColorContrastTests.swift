import BoatCore
import Foundation
import Testing

@Suite("WCAG contrast math")
struct ContrastMathTests {
    @Test func blackOnWhiteIs21() {
        #expect(abs(SRGBColor.contrastRatio(.black, .white) - 21) < 0.0001)
        #expect(SRGBColor.contrastRatio(.white, .white) == 1)
    }

    @Test func orderDoesNotMatter() throws {
        let indigo = try #require(SRGBColor(hex: "#2B3F8C"))
        #expect(SRGBColor.contrastRatio(indigo, .white) == SRGBColor.contrastRatio(.white, indigo))
    }

    /// Reference values from the WCAG formula worked by hand.
    @Test func knownPairs() throws {
        let gray = try #require(SRGBColor(hex: "777777"))
        #expect(abs(SRGBColor.contrastRatio(gray, .white) - 4.48) < 0.01)
        let indigo = try #require(SRGBColor(hex: "#2B3F8C"))
        #expect(abs(SRGBColor.contrastRatio(indigo, .white) - 9.58) < 0.01)
    }

    @Test func compositing() {
        let halfWhite = SRGBColor(red: 1, green: 1, blue: 1, alpha: 0.5)
        #expect(halfWhite.composited(over: .black) == SRGBColor(red: 0.5, green: 0.5, blue: 0.5))
    }

    @Test func badHexIsRejected() {
        #expect(SRGBColor(hex: "#12345") == nil)
        #expect(SRGBColor(hex: "GGGGGG") == nil)
    }

    @Test func colorSetComponentFormats() throws {
        let json = """
        {"colors":[
          {"color":{"color-space":"srgb","components":{"alpha":"1.000","red":"0x2B","green":"63","blue":"0.549"}},
           "idiom":"universal"},
          {"appearances":[{"appearance":"luminosity","value":"dark"}],
           "color":{"color-space":"srgb","components":{"alpha":"1.000","red":"0xFF","green":"0xFF","blue":"0xFF"}},
           "idiom":"universal"}]}
        """
        let set = try ColorSet(contentsJSON: Data(json.utf8))
        #expect(abs(set.light.red - 0x2B / 255.0) < 0.0001)
        #expect(abs(set.light.green - 63 / 255.0) < 0.0001)
        #expect(abs(set.light.blue - 0.549) < 0.0001)
        #expect(set.dark == .white)
    }

    @Test func colorSetWithoutDarkIsAnError() {
        let json = """
        {"colors":[{"color":{"color-space":"srgb","components":{"red":"0","green":"0","blue":"0"}},"idiom":"universal"}]}
        """
        #expect(throws: ColorSet.ParseError.missingAppearance("dark")) {
            try ColorSet(contentsJSON: Data(json.utf8))
        }
    }
}

/// Guards the accent against the app's real backgrounds, read from App/Assets.xcassets, so a colour edit can't
/// silently make links, buttons or the selection ring illegible (docs/DESIGN.md, Color tokens).
@Suite("Accent contrast")
struct AccentContrastTests {
    /// App/Assets.xcassets, from this file: Packages/BoatCore/Tests/BoatCoreTests/<this file>.
    static let assets = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Assets.xcassets")

    static func colorSet(_ name: String) throws -> ColorSet {
        let url = assets.appendingPathComponent("\(name).colorset/Contents.json")
        return try ColorSet(contentsJSON: Data(contentsOf: url))
    }

    /// Liquid Glass has no colour of its own to read from the catalog, so these are backdrops measured in the
    /// screenshot tour (2026-11-16, iPhone 18 Pro simulator), rounded towards the worse side.
    /// Text on glass: the offline banner's Retry and the compass strip. Measured #F1F5FA light, #232D3E dark.
    static let glassTextLight = SRGBColor(hex: "#D9DCE0")!
    static let glassTextDark = SRGBColor(hex: "#2A3446")!
    /// Icons on glass over the map (re-center, map style), where the glass picks up the map: the dark map's water
    /// makes it lightest, about #42556E. Measured #F2F5F1 light.
    static let glassIconLight = SRGBColor(hex: "#C8CCD0")!
    static let glassIconDark = SRGBColor(hex: "#4A5E7A")!

    /// Accent as text and links on every solid surface (list, Settings, permissions, offline banner on glass).
    @Test(arguments: ["bgBase", "bgSurface", "bgRaised"])
    func accentTextOnSurfaces(_ background: String) throws {
        let accent = try Self.colorSet("accent")
        let bg = try Self.colorSet(background)
        let light = SRGBColor.contrastRatio(accent.light, bg.light)
        let dark = SRGBColor.contrastRatio(accent.dark, bg.dark)
        #expect(light >= ContrastMinimum.text, "light accent on \(background): \(light)")
        #expect(dark >= ContrastMinimum.text, "dark accent on \(background): \(dark)")
    }

    @Test func accentTextOnGlass() throws {
        let accent = try Self.colorSet("accent")
        let light = SRGBColor.contrastRatio(accent.light, Self.glassTextLight)
        let dark = SRGBColor.contrastRatio(accent.dark, Self.glassTextDark)
        #expect(light >= ContrastMinimum.text, "light accent text on glass: \(light)")
        #expect(dark >= ContrastMinimum.text, "dark accent text on glass: \(dark)")
    }

    @Test func accentIconsOnMapGlass() throws {
        let accent = try Self.colorSet("accent")
        let light = SRGBColor.contrastRatio(accent.light, Self.glassIconLight)
        let dark = SRGBColor.contrastRatio(accent.dark, Self.glassIconDark)
        #expect(light >= ContrastMinimum.graphics, "light accent icon on map glass: \(light)")
        #expect(dark >= ContrastMinimum.graphics, "dark accent icon on map glass: \(dark)")
    }

    /// Primary buttons and the selected map marker: text and glyphs on an accent fill are `.onFill`, white in light
    /// mode and black in dark (App/Theme.swift, OnFillColor).
    @Test func onFillOnAccent() throws {
        let accent = try Self.colorSet("accent")
        let light = SRGBColor.contrastRatio(.white, accent.light)
        let dark = SRGBColor.contrastRatio(.black, accent.dark)
        #expect(light >= ContrastMinimum.text, "white on light accent: \(light)")
        #expect(dark >= ContrastMinimum.text, "black on dark accent: \(dark)")
    }

    /// The selection ring on the camera's solid label capsules and the camera centre mark.
    @Test func accentRingOnLabels() throws {
        let accent = try Self.colorSet("accent")
        let raised = try Self.colorSet("bgRaised")
        #expect(SRGBColor.contrastRatio(accent.light, raised.light) >= ContrastMinimum.graphics)
        #expect(SRGBColor.contrastRatio(accent.dark, raised.dark) >= ContrastMinimum.graphics)
    }
}
