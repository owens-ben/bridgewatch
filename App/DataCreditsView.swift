import BoatCore
import SwiftUI

/// Settings > Data and credits: where the data comes from and what the app does not promise. The words are
/// `DataCredits`'; this only lays them out. Scrolls, wraps at every text size, and takes the day, dark and night tokens.
struct DataCreditsView: View {
    @Environment(\.nightMode) private var isNight

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(DataCredits.sections) { section in
                    sectionView(section)
                }
            }
            .padding(Metrics.screenMargin)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.token(.bgBase))
        .navigationTitle(DataCredits.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNight {
                NightTitle(DataCredits.screenTitle)
            }
        }
    }

    private func sectionView(_ section: DataCredits.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.headline)
                .foregroundStyle(.token(.textPrimary))
                .accessibilityAddTraits(.isHeader)
            ForEach(0..<section.paragraphs.count, id: \.self) { index in
                paragraph(section.paragraphs[index], identifier: "credits-\(section.id)-\(index)")
            }
            ForEach(section.links, id: \.url) { link in
                linkView(link, identifier: "creditsLink-\(section.id)")
            }
        }
    }

    private func paragraph(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.token(.textPrimary))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    private func linkView(_ link: DataCredits.Link, identifier: String) -> some View {
        Link(destination: link.url) {
            Label(link.title, systemImage: "arrow.up.right.square")
                .font(.body)
                .foregroundStyle(.token(.accent))
                .frame(minHeight: Metrics.minTouch, alignment: .leading)
        }
        .accessibilityIdentifier(identifier)
    }
}

#if DEBUG
#Preview {
    NavigationStack { DataCreditsView() }
}
#endif
