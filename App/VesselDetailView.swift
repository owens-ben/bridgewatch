import BoatCore
import SwiftUI

/// Name, type and the four stats, plus "Find in Camera", then the AIS details the vessel sends. Shown in a sheet
/// (compact; "More info" from the map card), or in a floating card over the map (regular) with "More info" for the
/// rest.
struct VesselDetailView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let row: VesselRow
    let showsAge: Bool
    /// Switches to the camera with this vessel highlighted; nil hides the action.
    var findInCamera: (() -> Void)?
    /// Dismisses the details; nil hides the close button.
    var close: (() -> Void)?
    /// Opens the full details (the floating card); nil hides the button.
    var moreInfo: (() -> Void)?
    /// The AIS section (`VesselRow.detailItems`); empty leaves it out.
    var detailItems: [VesselDetailItem] = []
    /// Shows the "Look up on MarineTraffic" link (the full details sheet).
    var showsLookup = false

    /// Stale reports fade. Offline every report is stale, so the ages are shown at full strength instead.
    private var fades: Bool { !showsAge && row.freshness != .live }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            // Natural height: the tiles fill their cells, which must not stretch a floating card to the map's height.
            statGrid
                .fixedSize(horizontal: false, vertical: true)
                .staleFade(fades)

            if let findInCamera {
                Button("Find in Camera", action: findInCamera)
                    .buttonStyle(.primary)
                    // Placing a label needs a bearing, so the device's location.
                    .disabled(row.bearingDegrees == nil)
                    .accessibilityHint(row.bearingDegrees == nil ? "Needs location" : "Shows this vessel in the camera view")
                    .accessibilityIdentifier("findInCamera")
                    .staleFade(fades)
            }

            if let moreInfo {
                MoreInfoButton(action: moreInfo)
            }

            if !detailItems.isEmpty {
                VesselDetailsSection(items: detailItems)
                    .staleFade(fades)
            }

            if showsLookup {
                VesselLookupLink(mmsi: row.vessel.mmsi)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vesselDetail")
    }

    /// Badge, name and type beside the close button. At accessibility sizes the name needs the full width (beside the
    /// badge it breaks mid-word), so the badge and the close button share a row and the name runs below them.
    @ViewBuilder private var header: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    TypeBadge(category: row.category, size: 44)
                        .staleFade(fades)
                    Spacer(minLength: 0)
                    if let close {
                        closeButton(close)
                    }
                }
                nameBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: "Copy MMSI") { Pasteboard.copy(String(row.vessel.mmsi)) }
                    .accessibilityIdentifier("detailHeader")
                    .staleFade(fades)
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                HStack(spacing: 12) {
                    TypeBadge(category: row.category, size: 44)
                    nameBlock
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: "Copy MMSI") { Pasteboard.copy(String(row.vessel.mmsi)) }
                .accessibilityIdentifier("detailHeader")
                .staleFade(fades)
                if let close {
                    closeButton(close)
                }
            }
        }
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Typed in by the crew: plain text, never markdown or a localization key.
            Text(verbatim: row.title)
                .font(.title2.bold())
                .foregroundStyle(.token(.textPrimary))
                .accessibilityIdentifier("detailTitle")
            Text(verbatim: row.typeName)
                .font(.subheadline)
                .foregroundStyle(.token(.textSecondary))
                .accessibilityIdentifier("detailType")
            mmsiLine
                .font(.subheadline)
                .foregroundStyle(.token(.textSecondary))
                .monospacedDigit()
                // Long press to copy; VoiceOver has "Copy MMSI" on the header.
                .textSelection(.enabled)
                .accessibilityIdentifier("detailMMSI")
        }
    }

    /// Its own line: next to the type, large text splits the number across two lines. At accessibility sizes the
    /// label goes over the number, so the digits are never split or cut off.
    @ViewBuilder private var mmsiLine: some View {
        let mmsi = String(row.vessel.mmsi)
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 0) {
                Text("MMSI")
                Text(mmsi)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        } else {
            Text("MMSI \(mmsi)")
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func closeButton(_ action: @escaping () -> Void) -> some View {
        CloseDetailsButton(action: action)
    }

    // Two columns normally; one at accessibility text sizes so labels don't hyphenate.
    @ViewBuilder private var statGrid: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 12) { stats }
        } else {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    distanceTile
                    speedTile
                }
                GridRow {
                    courseTile
                    lastReportTile
                }
            }
        }
    }

    @ViewBuilder private var stats: some View {
        distanceTile
        speedTile
        courseTile
        lastReportTile
    }

    private var distanceTile: some View {
        StatTile(title: "Distance", value: row.distanceText ?? "—", caption: row.bearingText ?? "Location off")
    }

    private var speedTile: some View {
        StatTile(title: "Speed", value: row.speedText ?? "—", caption: nil)
    }

    private var courseTile: some View {
        StatTile(title: "Course", value: row.courseText ?? "—", caption: nil)
    }

    private var lastReportTile: some View {
        StatTile(title: "Last report", value: row.ageText, caption: nil)
    }
}

/// The details' visible way out, beside the header.
struct CloseDetailsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.headline)
                .frame(width: Metrics.minTouch, height: Metrics.minTouch)
                .contentShape(.rect)
        }
        .foregroundStyle(.token(.textSecondary))
        // Icon-only at a fixed 44pt, so like the map buttons it caps its text size and shows Large Content Viewer.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer()
        .accessibilityLabel("Close details")
        .accessibilityIdentifier("closeDetails")
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.token(.textSecondary))
            Text(value)
                .font(.title3.bold())
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(.token(.textPrimary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.token(.textSecondary))
            }
        }
        // Fills its cell, so tiles in a row match heights (Speed has no caption, Distance does).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(.token(.bgRaised), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
