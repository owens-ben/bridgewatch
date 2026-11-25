import Foundation

/// An sRGB color with components in 0...1, for WCAG contrast checks on the design tokens (docs/DESIGN.md, Color
/// tokens). Pure math: the app's colors live in the asset catalog, and tests read them from there.
public struct SRGBColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// "#2B3F8C" or "2B3F8C".
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    public static let black = SRGBColor(red: 0, green: 0, blue: 0)
    public static let white = SRGBColor(red: 1, green: 1, blue: 1)

    /// WCAG 2.x relative luminance (alpha ignored).
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// This color drawn over an opaque `background` (source-over, in sRGB as UIKit composites).
    public func composited(over background: SRGBColor) -> SRGBColor {
        func mix(_ top: Double, _ bottom: Double) -> Double { top * alpha + bottom * (1 - alpha) }
        return SRGBColor(red: mix(red, background.red), green: mix(green, background.green),
                         blue: mix(blue, background.blue))
    }

    /// WCAG contrast ratio, 1...21. Order doesn't matter.
    public static func contrastRatio(_ a: SRGBColor, _ b: SRGBColor) -> Double {
        let (la, lb) = (a.relativeLuminance, b.relativeLuminance)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

/// WCAG thresholds the color tokens are held to.
public enum ContrastMinimum {
    /// Text and links (WCAG 1.4.3, normal-size text).
    public static let text = 4.5
    /// Icons, controls, focus rings, selection rings (WCAG 1.4.11).
    public static let graphics = 3.0
}

/// One Xcode color set (`<name>.colorset/Contents.json`): its Any (light) and Dark appearance colors.
public struct ColorSet: Sendable {
    public let light: SRGBColor
    public let dark: SRGBColor

    public enum ParseError: Error, Equatable {
        case notAColorSet
        case missingAppearance(String)
        case badComponent(String)
        case unsupportedColorSpace(String)
    }

    /// Reads the JSON Xcode writes. Components can be hex ("0x2B"), 0-255 integers ("43") or 0-1 decimals ("0.169").
    public init(contentsJSON data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let colors = root["colors"] as? [[String: Any]] else { throw ParseError.notAColorSet }
        var light: SRGBColor?
        var dark: SRGBColor?
        for entry in colors {
            guard let color = entry["color"] as? [String: Any],
                  let components = color["components"] as? [String: String] else { continue }
            let space = color["color-space"] as? String ?? "srgb"
            guard space == "srgb" else { throw ParseError.unsupportedColorSpace(space) }
            let parsed = try SRGBColor(red: Self.component(components["red"]),
                                       green: Self.component(components["green"]),
                                       blue: Self.component(components["blue"]),
                                       alpha: components["alpha"].map { try Self.component($0) } ?? 1)
            let appearances = entry["appearances"] as? [[String: String]] ?? []
            if appearances.isEmpty {
                light = parsed
            } else if appearances.contains(where: { $0["appearance"] == "luminosity" && $0["value"] == "dark" }) {
                dark = parsed
            }
        }
        guard let light else { throw ParseError.missingAppearance("any") }
        guard let dark else { throw ParseError.missingAppearance("dark") }
        self.light = light
        self.dark = dark
    }

    static func component(_ text: String?) throws -> Double {
        guard let text else { throw ParseError.badComponent("missing") }
        if text.lowercased().hasPrefix("0x"), let value = UInt8(text.dropFirst(2), radix: 16) {
            return Double(value) / 255
        }
        if text.contains("."), let value = Double(text), (0...1).contains(value) { return value }
        if let value = Int(text), (0...255).contains(value) { return Double(value) / 255 }
        throw ParseError.badComponent(text)
    }
}
