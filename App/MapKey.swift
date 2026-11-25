import BoatCore
import SwiftUI

/// What the map's markers mean: each boat group's badge (color and icon by day, a letter in an outlined circle at
/// night) and what it covers, the course wedge, and the two train bullet styles. Opened by the map's Key button.
struct MapKeySheet: View {
    @Environment(\.units) private var units
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    Text("Map key")
                        .font(.title2.bold())
                        .foregroundStyle(.token(.textPrimary))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: Metrics.minTouch, height: Metrics.minTouch)
                            .contentShape(.rect)
                    }
                    .foregroundStyle(.token(.textSecondary))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .accessibilityShowsLargeContentViewer()
                    .accessibilityLabel("Close key")
                    .accessibilityIdentifier("closeMapKey")
                }

                Text("Boats")
                    .font(.headline)
                    .foregroundStyle(.token(.textPrimary))
                    .accessibilityAddTraits(.isHeader)
                ForEach(MapKey.categories, id: \.self) { category in
                    KeyRow(title: category.name, detail: category.coverage) {
                        TypeBadge(category: category)
                    }
                    .accessibilityIdentifier("mapKey-\(category.rawValue)")
                }
                KeyRow(title: "Direction", detail: MapKey.courseWedge(units: units)) {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.title3)
                        .foregroundStyle(.token(.textPrimary))
                        .frame(width: Metrics.rowBadge, height: Metrics.rowBadge)
                }
                .accessibilityIdentifier("mapKey-course")

                Text("Trains")
                    .font(.headline)
                    .foregroundStyle(.token(.textPrimary))
                    .accessibilityAddTraits(.isHeader)
                KeyRow(title: "Above ground", detail: MapKey.trainAboveGround) {
                    RouteBullet(train: MapKey.sampleTrain(underground: false))
                }
                .accessibilityIdentifier("mapKey-trainAboveGround")
                KeyRow(title: "Underground", detail: MapKey.trainUnderground) {
                    RouteBullet(train: MapKey.sampleTrain(underground: true), outlined: true)
                }
                .accessibilityIdentifier("mapKey-trainUnderground")
            }
            .padding(20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mapKey")
    }
}

/// A badge beside its name and what it stands for. One accessibility element.
private struct KeyRow<Badge: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let badge: () -> Badge

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.token(.textPrimary))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
