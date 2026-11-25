import BoatCore
import SwiftUI

extension EnvironmentValues {
    /// Red-only night palette (docs/DESIGN.md, Night mode). Set once at the root from the user's setting.
    @Entry var nightMode = false
    /// True for marks drawn on the map. At night the map is multiplied by the night red (`VesselMapScreen`), its
    /// markers included, which turns the red palette into dark brown on a dark map: there marks draw in
    /// `NightPalette.mapMark` instead, which comes out as the night red.
    @Entry var onMap = false
}

/// Night palette, red only, to protect dark-adapted eyes.
enum NightPalette {
    static let text = Color(red: 0xFF / 255, green: 0x6A / 255, blue: 0x5C / 255)
    static let secondary = Color(red: 0xF2 / 255, green: 0x3A / 255, blue: 0x2E / 255)
    static let glassTint = Color(red: 0x3C / 255, green: 0x08 / 255, blue: 0x04 / 255).opacity(0.5)
    static let line = Color(red: 0xFF / 255, green: 0x5A / 255, blue: 0x4A / 255).opacity(0.3)
    static let base = Color.black
    static let surface = Color(red: 0x14 / 255, green: 0x05 / 255, blue: 0x04 / 255)
    static let raised = Color(red: 0x22 / 255, green: 0x08 / 255, blue: 0x06 / 255)
    /// On the night map only: white, which the map's red multiply turns into `text`, the brightest night red.
    static let mapMark = Color.white
    /// On the night map only: black, which the map's red multiply leaves black: the letter on a `mapMark` disc, and
    /// the fill inside an underground train's `mapMark` outline.
    static let mapInk = Color.black
}

/// A design token (docs/DESIGN.md, Color tokens) that resolves to the asset color by day and the red palette
/// by night. Use as any ShapeStyle: `.foregroundStyle(.token(.textPrimary))`.
enum ColorToken: Hashable {
    case bgBase, bgSurface, bgRaised, separator, textPrimary, textSecondary, accent
    /// Status dot: feed live / no relay.
    case live, idle
    /// Vessel type fill. Night mode drops type colors (badges show letters instead). First responder's is its blue
    /// half: where a group shows as a swatch, `VesselFill` draws its two halves.
    case vessel(VesselCategory)
    /// First responder's two halves, red on the left, blue on the right (`VesselFill`). Under a white glyph by day in
    /// both appearances; at night two reds, like every other type color.
    case responderRed, responderBlue
    /// A subway route's bullet fill: MTA's color for its trunk line. Night mode drops it like the vessel colors (the
    /// bullet is outlined, its letter red).
    case route(SubwayLine)
    /// The letter on a route's bullet fill: white, dark on the yellow N Q R W.
    case routeText(SubwayLine)

    var day: Color {
        switch self {
        case .bgBase: Color(.bgBase)
        case .bgSurface: Color(.bgSurface)
        case .bgRaised: Color(.bgRaised)
        case .separator: Color(.separator)
        case .textPrimary: Color(.textPrimary)
        case .textSecondary: Color(.textSecondary)
        case .accent: Color(.accent)
        case .live: Color(.typeTug)
        case .idle: Color(.typeOther)
        case .vessel(let category):
            switch category {
            case .passenger: Color(.typePassenger)
            case .cargo: Color(.typeCargo)
            case .service: Color(.typeTug)
            case .firstResponder: Color(.typeResponderBlue)
            case .pleasure: Color(.typePleasure)
            case .other: Color(.typeOther)
            }
        case .route(let line):
            switch line {
            case .broadwaySeventhAvenue: Color(.routeRed)
            case .lexingtonAvenue: Color(.routeGreen)
            case .flushing: Color(.routePurple)
            case .eighthAvenue: Color(.routeBlue)
            case .sixthAvenue: Color(.routeOrange)
            case .crosstown: Color(.routeLightGreen)
            case .nassau: Color(.routeBrown)
            case .canarsie: Color(.routeGray)
            case .broadway: Color(.routeYellow)
            case .shuttle, .unknown: Color(.routeShuttle)
            }
        case .responderRed: Color(.typeResponderRed)
        case .responderBlue: Color(.typeResponderBlue)
        case .routeText(let line):
            // MTA's bullets: black type on the yellow, white on every other color.
            line == .broadway ? .black : .white
        }
    }

    var night: Color {
        switch self {
        case .bgBase: NightPalette.base
        case .bgSurface: NightPalette.surface
        case .bgRaised: NightPalette.raised
        case .separator: NightPalette.line
        case .textPrimary, .accent, .live, .vessel, .route, .routeText, .responderRed: NightPalette.text
        case .textSecondary, .idle, .responderBlue: NightPalette.secondary
        }
    }
}

struct TokenStyle: ShapeStyle {
    let token: ColorToken

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.nightMode ? token.night : token.day
    }
}

extension ShapeStyle where Self == TokenStyle {
    static func token(_ token: ColorToken) -> TokenStyle { TokenStyle(token: token) }
}

extension View {
    /// Fades a stale report (1-10 min old) or the frozen offline list to 70% in every palette. At half strength the
    /// text on the frozen offline card fell to about 1.6:1 contrast by day and the night red to about 2:1.
    func staleFade(_ isStale: Bool) -> some View {
        opacity(isStale ? 0.7 : 1)
    }
}

/// A navigation title in the night red. The system draws titles white, which breaks the red-only rule, so at night a
/// screen switches to an inline bar and shows its title through this principal item. Keep `.navigationTitle` too: it
/// still names the bar for VoiceOver and UI tests.
struct NightTitle: ToolbarContent {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.token(.textPrimary))
                // The bar doesn't grow with text size.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// At night a sheet sits on the night surface; by day it keeps the system glass, which has no style to name, so the
/// override is only added at night. It rides on a background child: swapping the sheet's own view for a modified one
/// would rebuild it, and Settings (where night mode is chosen) would lose its draft.
private struct NightSheetBackground: ViewModifier {
    @Environment(\.nightMode) private var nightMode

    func body(content: Content) -> some View {
        content.background {
            if nightMode { Color.clear.presentationBackground(NightPalette.surface) }
        }
    }
}

extension View {
    func nightSheetBackground() -> some View {
        modifier(NightSheetBackground())
    }
}

/// Glyphs and text drawn on a type or accent fill: black in dark mode (and on the night red), white in light. On a
/// boat group's fill, whichever of white and black reads better on it (`TypePalette.ink`, tested at 4.5:1 or more in
/// both appearances, on both halves of First responder's).
struct OnFillColor: ShapeStyle {
    var category: VesselCategory?

    func resolve(in environment: EnvironmentValues) -> Color {
        if environment.nightMode { return .black }
        let dark = environment.colorScheme == .dark
        if let category {
            return TypePalette.ink(category, dark: dark) == .white ? .white : .black
        }
        return dark ? .black : .white
    }
}

extension ShapeStyle where Self == OnFillColor {
    static var onFill: OnFillColor { OnFillColor() }
    /// The glyph or text color on `category`'s fill (`VesselFill`).
    static func onFill(_ category: VesselCategory) -> OnFillColor {
        OnFillColor(category: category)
    }
}

/// A boat group's fill in `shape`: its type color, or for First responder a two-tone, red on the left and blue on the
/// right, like emergency lights. The one place a group's swatch is drawn: badges, markers, the closest card. Day
/// palette only: at night badges are letters and cards are outlined.
struct VesselFill<S: Shape>: View {
    let category: VesselCategory
    let shape: S

    var body: some View {
        if category == .firstResponder {
            HStack(spacing: 0) {
                Rectangle().fill(.token(.responderRed))
                Rectangle().fill(.token(.responderBlue))
            }
            .clipShape(shape)
        } else {
            shape.fill(.token(.vessel(category)))
        }
    }
}

/// Liquid Glass for custom floating controls, solid `bgRaised` when Reduce Transparency is on. Night mode tints
/// the glass red.
struct FloatingGlass<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.nightMode) private var nightMode
    let shape: S

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(.token(.bgRaised), in: shape)
        } else {
            content.glassEffect(nightMode ? .regular.tint(NightPalette.glassTint) : .regular, in: shape)
        }
    }
}

extension View {
    func floatingGlass<S: Shape>(in shape: S) -> some View {
        modifier(FloatingGlass(shape: shape))
    }
}

/// Capsule, accent fill, 50pt tall.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.onFill)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(.token(.accent), in: .capsule)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

/// Layout tokens from docs/DESIGN.md.
enum Metrics {
    static let screenMargin: CGFloat = 16
    static let surfaceRadius: CGFloat = 22
    static let cardRadius: CGFloat = 28
    static let rowMinHeight: CGFloat = 68
    static let rowBadge: CGFloat = 36
    static let minTouch: CGFloat = 44
    /// An underground train's map marker: its 18 pt size plus 6 pt (see `TrainMarker`).
    static let undergroundTouch: CGFloat = 24
}
