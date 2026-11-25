import BoatCore
import SwiftUI

/// The AIS details a vessel sends (`VesselRow.detailItems`): status, destination, arrival, size, draught, heading,
/// position, IMO, call sign, only those known. Values typed in by a crew are shown verbatim: never as markdown, a
/// link or a localization key.
struct VesselDetailsSection: View {
    let items: [VesselDetailItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                DetailItemRow(item: item)
                if item.id != items.last?.id {
                    Rectangle()
                        .fill(.token(.separator))
                        .frame(height: 0.5)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 12)
        .background(.token(.bgRaised), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vesselAISDetails")
    }
}

/// "Status   Moored". At accessibility text sizes the value goes under its title instead of squeezing beside it.
private struct DetailItemRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: VesselDetailItem

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    title
                    value.multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    title
                    Spacer(minLength: 8)
                    value.multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: Metrics.minTouch)
        .accessibilityElement(children: .combine)
        // Position, IMO and call sign: long press to copy, or VoiceOver's Copy action.
        .copyable(item.copyable ? item.value : nil)
        .accessibilityIdentifier("detailRow-\(item.id)")
    }

    private var title: some View {
        Text(item.title)
            .font(.subheadline)
            .foregroundStyle(.token(.textSecondary))
    }

    private var value: some View {
        Text(verbatim: item.value)
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.token(.textPrimary))
            .lineLimit(2)
    }
}

/// "Look up on MarineTraffic": a plain link to the vessel's page there, built only from its MMSI
/// (`VesselDetailText.marineTrafficURL`). Opens in the browser; the app sends nothing and reads nothing back.
struct VesselLookupLink: View {
    let mmsi: Int

    var body: some View {
        if let url = VesselDetailText.marineTrafficURL(mmsi: mmsi).flatMap(URL.init(string:)) {
            Link(destination: url) {
                Label("Look up on MarineTraffic", systemImage: "arrow.up.right.square")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: Metrics.minTouch)
            }
            .foregroundStyle(.token(.accent))
            .accessibilityHint("Opens in Safari")
            .accessibilityIdentifier("lookUpVessel")
        }
    }
}

/// "More info": the floating card's way to the full details sheet.
struct MoreInfoButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("More info")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: Metrics.minTouch)
                .contentShape(.capsule)
        }
        .foregroundStyle(.token(.accent))
        .background(.token(.bgRaised), in: .capsule)
        .accessibilityHint("Shows all of its details")
        .accessibilityIdentifier("moreInfo")
    }
}
