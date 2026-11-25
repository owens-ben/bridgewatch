import Foundation
import Testing

/// The boat-type colors in the app's asset catalog (App/Assets.xcassets/type*.colorset, docs/DESIGN.md "Vessel types")
/// against the glyph drawn on them (`OnFillColor`): at least 3:1 (WCAG 1.4.11, non-text contrast) in light and dark.
/// Read from the color files themselves, so a changed color can't slip past.
@Suite struct TypeColorContrastTests {
    struct RGB: CustomStringConvertible {
        let red, green, blue: Double

        var description: String {
            String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
        }

        static let white = RGB(red: 1, green: 1, blue: 1)
        static let black = RGB(red: 0, green: 0, blue: 0)

        /// WCAG relative luminance.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        func contrast(with other: RGB) -> Double {
            let (a, b) = (luminance, other.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        /// Hue in degrees, 0-360.
        var hue: Double {
            let maxC = max(red, green, blue), minC = min(red, green, blue), delta = maxC - minC
            guard delta > 0 else { return 0 }
            let h: Double = if maxC == red {
                ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == green {
                (blue - red) / delta + 2
            } else {
                (red - green) / delta + 4
            }
            return (h * 60 + 360).truncatingRemainder(dividingBy: 360)
        }
    }

    /// The asset catalog, found from this file: Packages/BoatCore/Tests/BoatCoreTests/ -> the repository root.
    static let assets = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Assets.xcassets")

    /// A color set's (light, dark) values.
    static func colorSet(_ name: String) throws -> (light: RGB, dark: RGB) {
        let url = assets.appendingPathComponent("\(name).colorset/Contents.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let colors = try #require(json["colors"] as? [[String: Any]])
        func rgb(_ entry: [String: Any]) throws -> RGB {
            let components = try #require((entry["color"] as? [String: Any])?["components"] as? [String: String])
            func value(_ key: String) throws -> Double {
                let text = try #require(components[key])
                if text.hasPrefix("0x") { return Double(try #require(Int(text.dropFirst(2), radix: 16))) / 255 }
                return try #require(Double(text))
            }
            return RGB(red: try value("red"), green: try value("green"), blue: try value("blue"))
        }
        let isDark: ([String: Any]) -> Bool = { entry in
            (entry["appearances"] as? [[String: String]])?.contains { $0["value"] == "dark" } ?? false
        }
        let light = try #require(colors.first { !isDark($0) })
        let dark = try #require(colors.first(where: isDark))
        return (try rgb(light), try rgb(dark))
    }

    /// Glyph white in light, black in dark (`OnFillColor`).
    @Test(arguments: ["typePassenger", "typeCargo", "typeTug", "typePleasure", "typeOther"])
    func typeColorsHoldAgainstTheirGlyph(name: String) throws {
        let set = try Self.colorSet(name)
        #expect(set.light.contrast(with: .white) >= 3, "\(name) light \(set.light)")
        #expect(set.dark.contrast(with: .black) >= 3, "\(name) dark \(set.dark)")
    }

    /// First responder's halves sit under a white glyph in both appearances.
    @Test(arguments: ["typeResponderRed", "typeResponderBlue"])
    func responderColorsHoldAgainstWhite(name: String) throws {
        let set = try Self.colorSet(name)
        #expect(set.light.contrast(with: .white) >= 3, "\(name) light \(set.light)")
        #expect(set.dark.contrast(with: .white) >= 3, "\(name) dark \(set.dark)")
    }

    /// The responder blue is its own blue, not Passenger's: a clearly different hue in both appearances.
    @Test func responderBlueIsNotPassengerBlue() throws {
        let responder = try Self.colorSet("typeResponderBlue")
        let passenger = try Self.colorSet("typePassenger")
        #expect(abs(responder.light.hue - passenger.light.hue) >= 20, "\(responder.light) vs \(passenger.light)")
        #expect(abs(responder.dark.hue - passenger.dark.hue) >= 20, "\(responder.dark) vs \(passenger.dark)")
        // Red and blue halves read as two colors.
        #expect(abs(responder.light.hue - (try Self.colorSet("typeResponderRed")).light.hue) >= 90)
    }
}
