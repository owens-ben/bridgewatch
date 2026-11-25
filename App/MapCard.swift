import BoatCore
import SwiftUI

/// Compact width: the selected boat's or train's summary over the map, docked at the top or bottom edge, whichever
/// leaves its marker clear (`MapCardLayout`). Type badge or route bullet, name or destination, type, status, distance,
/// and "More info" for the full sheet. The header row is a button too (More info), and stays put at the largest text
/// sizes while the rest scrolls inside the card's height cap. VoiceOver reads the card as its header: one button with
/// the whole label (status included) and the More info hint, then Close. At accessibility text sizes "More info" is
/// an icon button pinned in the header beside Close (the card's lower part scrolls inside its cap there, and the
/// button at its foot was below the fold: CHAOS-FINDINGS L3), read by VoiceOver as "More info".
struct MapSummaryCard<Badge: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let text: MapCardText
    let fades: Bool
    let moreInfo: () -> Void
    let close: () -> Void
    @ViewBuilder let badge: () -> Badge

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ViewThatFits(in: .vertical) {
                details
                ScrollView { details }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(16)
        .floatingGlass(in: .rect(cornerRadius: Metrics.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mapCard")
    }

    /// Badge, name and type beside Close. At accessibility sizes the badge shares a row with "More info" and Close,
    /// and the name and type run full width below (beside them the name was cut to "HA…").
    @ViewBuilder private var header: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    badge()
                        .staleFade(fades)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    moreInfoIcon
                    CloseDetailsButton(action: close)
                }
                Button(action: moreInfo) {
                    titleBlock
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .staleFade(fades)
                .accessibilityLabel(text.accessibilityLabel)
                .accessibilityHint("Shows more info")
                .accessibilityIdentifier("mapCardTitle")
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Button(action: moreInfo) {
                    HStack(alignment: .center, spacing: 12) {
                        badge()
                        titleBlock
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: Metrics.minTouch)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .staleFade(fades)
                .accessibilityLabel(text.accessibilityLabel)
                .accessibilityHint("Shows more info")
                .accessibilityIdentifier("mapCardTitle")
                CloseDetailsButton(action: close)
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            // A boat's name is typed in by its crew: plain text only.
            Text(verbatim: text.title)
                .font(.headline)
                .foregroundStyle(.token(.textPrimary))
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
            Text(verbatim: text.subtitle)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.token(.textSecondary))
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
        }
    }

    /// "More info" pinned in the header at accessibility sizes (L3).
    private var moreInfoIcon: some View {
        Button(action: moreInfo) {
            Image(systemName: "info.circle")
                .font(.headline)
                .frame(width: Metrics.minTouch, height: Metrics.minTouch)
                .contentShape(.rect)
        }
        .foregroundStyle(.token(.accent))
        // Icon-only at a fixed 44pt, like Close: capped text size, Large Content Viewer.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer()
        .accessibilityLabel("More info")
        .accessibilityIdentifier("moreInfo")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let status = text.status {
                Text(verbatim: status)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.token(.textSecondary))
                    .lineLimit(2)
                    .staleFade(fades)
                    // Read once, in the header's label.
                    .accessibilityHidden(true)
            }
            if typeSize.isAccessibilitySize {
                // "More info" is pinned in the header at these sizes.
                distance
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        distance
                        Spacer(minLength: 8)
                        moreInfoButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        distance
                        moreInfoButton
                    }
                }
            }
        }
    }

    @ViewBuilder private var distance: some View {
        if let distance = text.distance {
            Text(verbatim: distance)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.token(.textPrimary))
                .staleFade(fades)
                .accessibilityHidden(true)
        }
    }

    private var moreInfoButton: some View {
        Button(action: moreInfo) {
            Text("More info")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: Metrics.minTouch)
                .contentShape(.capsule)
        }
        .foregroundStyle(.onFill)
        .background(.token(.accent), in: .capsule)
        // VoiceOver: the header is the one button for More info (its hint says so), so this isn't read twice.
        .accessibilityHidden(true)
    }
}
