import BoatCore
import SwiftUI

/// A boat on the map: its type disc (34 pt, 44 pt selected with an accent ring), a small wedge on the rim pointing the
/// way it's going (`VesselMap.courseArrowDegrees`), and its finer type name under it once the map is zoomed in
/// (`VesselMap.showsTypeLabel`). The touch target is 44 pt whatever the disc's size; the wedge and the label draw
/// outside the marker's frame, so they don't move its anchor or widen its touch target.
struct VesselMarker: View {
    let row: VesselRow
    let selected: Bool
    /// The wedge's rotation on screen, degrees; nil hides it (stopped, or no course).
    var courseDegrees: Double?
    var showsTypeLabel = false

    /// The disc, ring included.
    static let size: CGFloat = 34
    static let selectedSize: CGFloat = 44
    /// Room the type label takes under a marker, for the map card's placement.
    static let labelAllowance: CGFloat = 20

    private var diameter: CGFloat { selected ? Self.selectedSize : Self.size }
    private var ring: CGFloat { selected ? 3 : 1.5 }

    var body: some View {
        TypeBadge(category: row.category, size: diameter - ring * 2)
            .padding(ring)
            .background(selected ? .token(.accent) : .token(.bgBase), in: .circle)
            .overlay {
                if let courseDegrees {
                    CourseWedge(diameter: diameter)
                        .rotationEffect(.degrees(courseDegrees))
                }
            }
            .frame(minWidth: Metrics.minTouch, minHeight: Metrics.minTouch)
            .overlay(alignment: .bottom) {
                if showsTypeLabel {
                    MarkerLabel(text: row.typeName)
                        .alignmentGuide(.bottom) { $0[.top] }
                }
            }
            .contentShape(.circle)
            .staleFade(row.freshness != .live)
            .animation(.snappy, value: selected)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel())
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("vesselMarker-\(row.id)")
    }
}

/// A small triangle on the marker's rim, pointing up before rotation. At night it's drawn in `mapMark`, which the
/// map's red multiply turns into the brightest night red.
private struct CourseWedge: View {
    @Environment(\.nightMode) private var nightMode
    let diameter: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            WedgeShape()
                .fill(nightMode ? AnyShapeStyle(NightPalette.mapMark) : AnyShapeStyle(.token(.textPrimary)))
                .overlay(WedgeShape().stroke(nightMode ? AnyShapeStyle(NightPalette.mapInk) : AnyShapeStyle(.token(.bgBase)),
                                             lineWidth: 1))
                .frame(width: 11, height: 8)
                // Just outside the disc.
                .offset(y: -8)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

private struct WedgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// The finer type ("Pilot") under a marker: a small solid capsule (content, not glass). At night it is drawn in the
/// map's own `mapMark`/`mapInk`, which the red multiply keeps legible.
private struct MarkerLabel: View {
    @Environment(\.nightMode) private var nightMode
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(nightMode ? AnyShapeStyle(NightPalette.mapMark) : AnyShapeStyle(.token(.textPrimary)))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(nightMode ? AnyShapeStyle(NightPalette.mapInk) : AnyShapeStyle(.token(.bgBase)), in: .capsule)
            .padding(.top, 2)
            // Fixed room under the marker (`VesselMarker.labelAllowance`).
            .dynamicTypeSize(...DynamicTypeSize.large)
            .accessibilityHidden(true)
    }
}
