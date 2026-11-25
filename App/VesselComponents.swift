import BoatCore
import SwiftUI

/// Type circle: category color behind its SF Symbol (First responder's red and blue halves, `VesselFill`). Color is
/// never the only signal. Night mode drops the colors: the type shows as a letter in an outlined circle (P, C, T, R,
/// S, ?).
struct TypeBadge: View {
    @Environment(\.nightMode) private var nightMode
    @Environment(\.onMap) private var onMap
    let category: VesselCategory
    var size: CGFloat = Metrics.rowBadge

    var body: some View {
        Group {
            if nightMode, onMap {
                // The night map darkens everything on it: a filled disc (the night red once multiplied) with a black
                // letter stands out from it.
                Text(category.nightLetter)
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(NightPalette.mapInk)
                    .frame(width: size, height: size)
                    .background(NightPalette.mapMark, in: .circle)
            } else if nightMode {
                Text(category.nightLetter)
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.token(.textPrimary))
                    .frame(width: size, height: size)
                    .overlay(Circle().stroke(.token(.textPrimary), lineWidth: 1.5))
            } else {
                Image(systemName: category.symbolName)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.onFill(category))
                    .frame(width: size, height: size)
                    .background(VesselFill(category: category, shape: .circle))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Points from the observer toward the vessel (north-up until the compass lands in Milestone 3).
struct BearingArrow: View {
    let degrees: Double

    var body: some View {
        Image(systemName: "location.north.fill")
            .rotationEffect(.degrees(degrees))
            .accessibilityHidden(true)
    }
}

struct VesselRowView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let row: VesselRow
    let showsAge: Bool

    var body: some View {
        Group {
            // At accessibility text sizes the distance moves under the name so names don't break mid-word.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    TypeBadge(category: row.category)
                    nameBlock
                    distanceBlock(alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    TypeBadge(category: row.category)
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
        // Offline, the whole list fades instead (VesselListScreen).
        .staleFade(!showsAge && row.freshness != .live)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel(includeAge: showsAge))
        .accessibilityAddTraits(.isButton)
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: row.title)
                .font(.headline)
                .foregroundStyle(.token(.textPrimary))
            Text(row.detail)
                .font(.subheadline)
                .foregroundStyle(.token(.textSecondary))
                .monospacedDigit()
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
                BearingArrow(degrees: bearing)
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
            }
        }
    }
}

/// The nearest vessel, filled with its type color (outlined in red at night). Horizontal on short screens (the Duo
/// cover), except at accessibility text sizes, which don't fit side by side on any screen. All its text is drawn at
/// full strength in the fill's ink (`TypePalette.ink`, 4.5:1 or more): dimmed captions fell under that on the grey of
/// Other. It doesn't fade when stale either (the age line says so): faded, its text fell to about 2:1. The name wraps
/// rather than being cut off, and the speed shows once, in large type.
struct ClosestCard: View {
    @Environment(\.nightMode) private var nightMode
    @Environment(\.dynamicTypeSize) private var typeSize
    let row: VesselRow
    let horizontal: Bool
    let showsAge: Bool

    private var isHorizontal: Bool { horizontal && !typeSize.isAccessibilitySize }

    var body: some View {
        Group {
            if isHorizontal {
                HStack(alignment: .center, spacing: 12) {
                    TypeBadge(category: row.category, size: 44)
                        .background(.onFill.opacity(0.15), in: .circle)
                    nameBlock
                    Spacer(minLength: 8)
                    // Stacked: side by side, the two numbers don't fit the Duo cover next to the name.
                    VStack(alignment: .trailing, spacing: 4) {
                        numbers(alignment: .trailing)
                    }
                    .layoutPriority(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        TypeBadge(category: row.category, size: 44)
                            .background(.onFill.opacity(0.15), in: .circle)
                        nameBlock
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 32) {
                        numbers(alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(nightMode ? AnyShapeStyle(.token(.textPrimary)) : AnyShapeStyle(.onFill(row.category)))
        .padding(20)
        .background {
            if nightMode {
                RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(.token(.bgRaised))
            } else {
                VesselFill(category: row.category, shape: .rect(cornerRadius: Metrics.cardRadius))
            }
        }
        .overlay {
            if nightMode {
                RoundedRectangle(cornerRadius: Metrics.cardRadius).stroke(.token(.separator), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Closest: " + row.accessibilityLabel(includeAge: showsAge))
        .accessibilityHint("Shows it on the map")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("closestCard")
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Closest")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
            Text(verbatim: row.title)
                .font(.title2.bold())
                // Wraps however long (a long name, or at the largest text on the Duo cover) instead of "MMSI 3670…".
                .fixedSize(horizontal: false, vertical: true)
            Text(showsAge || row.freshness != .live ? "\(subtitle) · \(row.ageText)" : subtitle)
                .font(.subheadline)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The group without the speed, which the card shows in large type.
    private var subtitle: String { row.category.detailName }

    @ViewBuilder
    private func numbers(alignment: HorizontalAlignment) -> some View {
        // The closest card only exists when distances are known.
        bigNumber(row.distanceText ?? "—", caption: row.bearingText ?? "", alignment: alignment)
        if let speed = row.speedText {
            bigNumber(speed, caption: "Speed", alignment: alignment)
        }
    }

    private func bigNumber(_ value: String, caption: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(value)
                .font(isHorizontal ? .title.weight(.heavy) : .largeTitle.weight(.heavy))
                .fontDesign(.rounded)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.footnote)
                .monospacedDigit()
        }
    }
}

/// "Live · 4 vessels · 80 trains"; scoped, the status on its own line and the scope leading the counts so "3 of 4" can't
/// be read as all there is: "On the map: 3 of 4 vessels · 9 of 80 trains". VoiceOver reads it as one element ("Live.
/// On the map: 3 of 4 vessels, 9 of 80 trains"); each part keeps its identifier for UI tests. Texts from `BrowseResult`.
struct StatusLine: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let status: VesselStore.Status
    let countText: String
    /// Nil when trains are turned off in Settings.
    var trainCountText: String?
    /// "On the map:", "With filters on:", ahead of the counts; nil when everything is listed.
    var scopeNote: String?
    /// Instead of plain "Live" when the data is late (`DataFreshness.notice`), and what VoiceOver reads for it.
    var lateNotice: String?
    var spokenLateNotice: String?

    var body: some View {
        Group {
            if scopeNote != nil {
                scoped
            } else {
                unscoped
            }
        }
        .font(.subheadline)
        .foregroundStyle(.token(.textSecondary))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(BrowseText.spokenStatusLine(status: spokenStatusText, vessels: countText,
                                                        trains: trainCountText, scope: scopeNote))
    }

    private var scoped: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                dot
                statusLabel
            }
            if typeSize.isAccessibilitySize {
                scopeLabel
                countLabel
                trainCountLabel
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        scopeLabel
                        countLabel
                        if trainCountText != nil {
                            separator
                            trainCountLabel
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            scopeLabel
                            countLabel
                        }
                        trainCountLabel
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        scopeLabel
                        countLabel
                        trainCountLabel
                    }
                }
            }
        }
    }

    @ViewBuilder private var unscoped: some View {
        // At accessibility text sizes the count goes under the status instead of breaking into a narrow column.
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    dot
                    statusLabel
                }
                countLabel
                trainCountLabel
            }
        } else {
            // Wraps under the status on a narrow screen rather than squeezing the counts.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    dot
                    statusLabel
                    separator
                    countLabel
                    if trainCountText != nil {
                        separator
                        trainCountLabel
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        dot
                        statusLabel
                        separator
                        countLabel
                    }
                    trainCountLabel
                }
            }
        }
    }

    private var dot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var statusLabel: some View {
        Text(statusText)
            .accessibilityIdentifier("feedStatus")
    }

    private var countLabel: some View {
        Text(countText)
            .monospacedDigit()
            .accessibilityIdentifier("vesselCount")
    }

    @ViewBuilder private var scopeLabel: some View {
        if let scopeNote {
            Text(scopeNote)
                .accessibilityIdentifier("listScope")
        }
    }

    private var separator: some View {
        Text("·")
            .accessibilityHidden(true)
    }

    @ViewBuilder private var trainCountLabel: some View {
        if let trainCountText {
            Text(trainCountText)
                .monospacedDigit()
                .accessibilityIdentifier("trainCount")
        }
    }

    private var statusText: String {
        switch status {
        case .idle: "No relay set"
        case .connecting: "Connecting"
        case .live: lateNotice ?? "Live"
        case .offline: "Offline"
        }
    }

    private var spokenStatusText: String {
        status == .live ? spokenLateNotice ?? statusText : statusText
    }

    private var dotColor: TokenStyle {
        switch status {
        case .idle: .token(.idle)
        case .connecting: .token(.accent)
        case .live: lateNotice == nil ? .token(.live) : .token(.textSecondary)
        case .offline: .token(.textSecondary)
        }
    }
}

/// "Can't reach the server · Showing the last positions. Trying again… · Retry", as a floating glass control. Plain
/// words (`FeedText`): a tester doesn't know what a relay is. With an address typed into Settings in use, the second
/// line points there.
struct OfflineBanner: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(VesselStore.self) private var store
    @AppStorage("relayURL") private var relayURL = ""
    let retry: () -> Void

    var body: some View {
        Group {
            // At accessibility text sizes Retry gets its own line instead of squeezing the message.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    message
                    retryButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    message
                    Spacer(minLength: 8)
                    retryButton
                }
            }
        }
        .padding(.horizontal, Metrics.screenMargin)
        .padding(.vertical, 8)
        .floatingGlass(in: .rect(cornerRadius: Metrics.surfaceRadius))
        .padding(.horizontal, Metrics.screenMargin)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offlineBanner")
    }

    private var message: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title3)
                .foregroundStyle(.token(.accent))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(FeedText.title(store.problem))
                    .font(.headline)
                    .foregroundStyle(.token(.textPrimary))
                    .accessibilityIdentifier("offlineTitle")
                Text(FeedText.message(store.problem, customAddress: !relayURL.isEmpty))
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
                    .accessibilityIdentifier("offlineMessage")
            }
        }
    }

    private var retryButton: some View {
        Button("Retry", action: retry)
            .font(.headline)
            .foregroundStyle(.token(.accent))
            .frame(minWidth: Metrics.minTouch, minHeight: Metrics.minTouch)
            .accessibilityIdentifier("retryButton")
    }
}

/// No vessels in the last 10 minutes.
struct EmptyRiverView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "water.waves")
                .font(.largeTitle)
                .foregroundStyle(.token(.textSecondary))
                .accessibilityHidden(true)
            Text("The river's quiet")
                .font(.title2.bold())
                .foregroundStyle(.token(.textPrimary))
                .accessibilityIdentifier("emptyTitle")
            Text("No vessels have reported in the area in the last 10 minutes.")
                .font(.footnote)
                .foregroundStyle(.token(.textSecondary))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Metrics.screenMargin * 2)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }
}

/// Boats and trains are about, but the filter or the map's region leaves nothing to list: says why, with the way
/// back ("Show the whole list" turns "Only what's on the map" off and nothing else; "Reset filters").
struct BrowseEmptyView: View {
    let reason: BrowseEmptyReason
    /// Boat types or Moving only are on: the off-map action says they stay.
    let filtering: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: reason == .offMap ? "map" : "line.3.horizontal.decrease.circle")
                .font(.largeTitle)
                .foregroundStyle(.token(.textSecondary))
                .accessibilityHidden(true)
            Text(BrowseText.emptyTitle(reason))
                .font(.title3.bold())
                .foregroundStyle(.token(.textPrimary))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("browseEmptyTitle")
            Button(BrowseText.emptyAction(reason, filtering: filtering), action: action)
                .font(.headline)
                .foregroundStyle(.token(.accent))
                .frame(minWidth: Metrics.minTouch, minHeight: Metrics.minTouch)
                .accessibilityIdentifier("browseEmptyAction")
        }
        .padding(.horizontal, Metrics.screenMargin * 2)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }
}
