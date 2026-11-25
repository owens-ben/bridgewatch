import BoatCore
import SwiftUI

/// A diamond filling its frame: the bullet of an express variant (the diamond 6, 7 and F).
struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
    }
}

/// A route's bullet: its letter or number in a circle (a diamond for an express) filled with MTA's line color. Its
/// size is fixed like the vessel badges, so where it stands alone (map, camera) the element shows Large Content
/// Viewer. Night mode drops the color like the vessel badges do: the letter in red in an outlined shape, or on the
/// night map (`onMap`) a black letter on a red fill, since the map darkens its markers. `outlined` draws it outlined
/// by day too, in the line color, for trains underground.
struct RouteBullet: View {
    @Environment(\.nightMode) private var nightMode
    @Environment(\.onMap) private var onMap
    let train: Train
    var size: CGFloat = Metrics.rowBadge
    var outlined = false

    private enum Look { case lineFill, lineOutline, nightOutline, nightMapFill, nightMapOutline }

    private var look: Look {
        switch (nightMode, onMap, outlined) {
        case (false, _, false): .lineFill
        case (false, _, true): .lineOutline
        case (true, true, false): .nightMapFill
        case (true, true, true): .nightMapOutline
        case (true, false, _): .nightOutline
        }
    }

    private var letterStyle: AnyShapeStyle {
        switch look {
        case .lineFill: AnyShapeStyle(.token(.routeText(train.line)))
        case .lineOutline, .nightOutline: AnyShapeStyle(.token(.textPrimary))
        case .nightMapFill: AnyShapeStyle(NightPalette.mapInk)
        case .nightMapOutline: AnyShapeStyle(NightPalette.mapMark)
        }
    }

    var body: some View {
        let text = train.bullet
        Text(text)
            .font(.system(size: size * (train.isDiamond ? 0.42 : text.count > 1 ? 0.42 : 0.56), weight: .bold))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .foregroundStyle(letterStyle)
            .padding(size * (train.isDiamond ? 0.2 : 0.08))
            .frame(width: size, height: size)
            .background {
                if train.isDiamond {
                    shape(Diamond())
                } else {
                    shape(Circle())
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func shape<S: Shape>(_ shape: S) -> some View {
        switch look {
        case .lineFill:
            shape.fill(.token(.route(train.line)))
        case .nightMapFill:
            shape.fill(NightPalette.mapMark)
        case .lineOutline:
            shape.fill(.token(.bgBase)).overlay(shape.stroke(.token(.route(train.line)), lineWidth: 2))
        case .nightOutline:
            shape.fill(.token(.bgBase)).overlay(shape.stroke(.token(.textPrimary), lineWidth: 2))
        case .nightMapOutline:
            shape.fill(NightPalette.mapInk).overlay(shape.stroke(NightPalette.mapMark, lineWidth: 2))
        }
    }
}

/// A train in the list: bullet, destination, "Manhattan Bridge · 21 mph", then distance and height against the user.
/// Stacks at accessibility text sizes like the vessel rows.
struct TrainRowView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let row: TrainRow
    let showsAge: Bool

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    RouteBullet(train: row.train)
                    nameBlock
                    distanceBlock(alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    RouteBullet(train: row.train)
                    nameBlock
                    Spacer(minLength: 8)
                    distanceBlock(alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, Metrics.screenMargin)
        .padding(.vertical, 10)
        .frame(minHeight: Metrics.rowMinHeight)
        .contentShape(.rect)
        .staleFade(!showsAge && row.freshness != .live)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel(includeAge: showsAge))
        .accessibilityAddTraits(.isButton)
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            // "Q to 96 St": the destination comes from the feed, so plain text.
            Text(verbatim: row.title)
                .font(.headline)
                .foregroundStyle(.token(.textPrimary))
            // Under the Underground header, an underground row doesn't repeat it.
            if let detail = row.groupedDetail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.token(.textSecondary))
                    .monospacedDigit()
            }
            if showsAge || row.freshness != .live {
                Text(row.ageText)
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func distanceBlock(alignment: HorizontalAlignment) -> some View {
        if let distance = row.distanceText, let bearing = row.bearingDegrees {
            VStack(alignment: alignment, spacing: 2) {
                Text(distance)
                    .font(.title3.bold())
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(.token(.textPrimary))
                HStack(spacing: 4) {
                    if let height = row.relativeHeightText {
                        Text(height)
                            .monospacedDigit()
                    }
                    BearingArrow(degrees: bearing)
                }
                .font(.footnote)
                .foregroundStyle(.token(.textSecondary))
            }
        }
    }
}

/// A train on the map: its bullet with a ring like the vessel markers, touch target padded out to 44pt. Underground
/// it's smaller, outlined and dimmed, and secondary: its touch target is its drawn size plus a small margin, so it
/// doesn't take taps meant for a train above ground or a boat nearby.
struct TrainMarker: View {
    let row: TrainRow
    let selected: Bool

    private var size: CGFloat { selected ? 36 : row.isUnderground ? 18 : 26 }
    private var touch: CGFloat { row.isUnderground && !selected ? Metrics.undergroundTouch : Metrics.minTouch }

    var body: some View {
        RouteBullet(train: row.train, size: size, outlined: row.isUnderground)
            .padding(row.isUnderground && !selected ? 0 : selected ? 3 : 1.5)
            .background(selected ? .token(.accent) : .token(.bgBase),
                        in: row.train.isDiamond ? AnyShape(Diamond()) : AnyShape(Circle()))
            .opacity(row.isUnderground && !selected ? 0.8 : 1)
            .frame(minWidth: touch, minHeight: touch)
            .contentShape(.circle)
            .staleFade(row.freshness != .live)
            .animation(.snappy, value: selected)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel())
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityShowsLargeContentViewer {
                Text(row.spokenRoute)
            }
            .accessibilityIdentifier("trainMarker-\(row.id)")
    }
}
