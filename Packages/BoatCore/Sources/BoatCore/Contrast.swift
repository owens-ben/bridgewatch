import Foundation

/// An sRGB color, each channel 0-1.
public struct RGB: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 0xRRGGBB.
    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    public static let white = RGB(hex: 0xFFFFFF)
    public static let black = RGB(hex: 0x000000)

    public var description: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()),
               Int((blue * 255).rounded()))
    }
}

/// WCAG 2 contrast: relative luminance, the ratio between two colors, and the ink (white or black) to put on a fill.
public enum Contrast {
    /// What text needs against its background: 4.5:1 (WCAG AA, normal text).
    public static let minimumTextRatio = 4.5

    /// The ink drawn on a fill: white or black, nothing in between (a mid grey would pass on neither light nor dark
    /// fills).
    public enum Ink: Sendable, Equatable {
        case white, black

        public var rgb: RGB { self == .white ? .white : .black }
    }

    public static func relativeLuminance(_ color: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.040_45 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// From 1 (the same) to 21 (black on white), whichever is lighter.
    public static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `color` drawn at `opacity` over `background` (sRGB blending, as the screen composites it).
    public static func composite(_ color: RGB, opacity: Double, over background: RGB) -> RGB {
        let a = min(max(opacity, 0), 1)
        return RGB(red: color.red * a + background.red * (1 - a), green: color.green * a + background.green * (1 - a),
                   blue: color.blue * a + background.blue * (1 - a))
    }

    /// The ink with the better worst-case contrast against every part of a fill: one color for a plain fill, both
    /// halves for a two-tone one (First responder's red and blue). Ties go to white.
    public static func ink(on fills: [RGB]) -> Ink {
        guard !fills.isEmpty else { return .black }
        let white = fills.map { ratio(.white, $0) }.min() ?? 0
        let black = fills.map { ratio(.black, $0) }.min() ?? 0
        return white >= black ? .white : .black
    }

    /// The worst contrast of `ink` against the fill's parts.
    public static func worstRatio(of ink: Ink, on fills: [RGB]) -> Double {
        fills.map { ratio(ink.rgb, $0) }.min() ?? 0
    }
}

/// The boat groups' fills as the app's asset catalog defines them (App/Assets.xcassets, `type*` colors; a test reads
/// the catalog and checks they match), and the ink for text and glyphs drawn on them. The closest card, the type
/// badges and the map markers use it.
public enum TypePalette {
    /// A group's fill in light or dark appearance: one color, or First responder's red and blue halves.
    public static func fills(_ category: VesselCategory, dark: Bool) -> [RGB] {
        switch category {
        case .passenger: [RGB(hex: dark ? 0x64D2FF : 0x0071A4)]
        case .cargo: [RGB(hex: dark ? 0xFFD60A : 0x8A6100)]
        case .service: [RGB(hex: dark ? 0x30D158 : 0x1E7B34)]
        case .firstResponder: [RGB(hex: dark ? 0xD0283E : 0xC41E2A), RGB(hex: dark ? 0x3A5BEF : 0x1F45C7)]
        case .pleasure: [RGB(hex: dark ? 0xBF5AF2 : 0x8E2DB8)]
        case .other: [RGB(hex: dark ? 0x8E8E93 : 0x6B7280)]
        }
    }

    /// The asset catalog color set behind each fill (`fills`), in the same order.
    public static func assetNames(_ category: VesselCategory) -> [String] {
        switch category {
        case .passenger: ["typePassenger"]
        case .cargo: ["typeCargo"]
        case .service: ["typeTug"]
        case .firstResponder: ["typeResponderRed", "typeResponderBlue"]
        case .pleasure: ["typePleasure"]
        case .other: ["typeOther"]
        }
    }

    /// White or black, whichever reads better on the whole fill (`Contrast.ink(on:)`).
    public static func ink(_ category: VesselCategory, dark: Bool) -> Contrast.Ink {
        Contrast.ink(on: fills(category, dark: dark))
    }
}
