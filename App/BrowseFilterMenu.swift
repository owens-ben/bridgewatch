import BoatCore
import MapKit
import Observation
import SwiftUI

/// The list and map's filter as the app stores it: its own setting (`BrowseFilter.storageKey`) plus the Settings >
/// Trains switches, which it shares with Settings and the camera's menu.
enum BrowseFilterSetting {
    static func filter(stored: BrowseFilter, showTrains: Bool, showUnderground: Bool) -> BrowseFilter {
        stored.merging(shared: [.trains: showTrains, .undergroundTrains: showUnderground])
    }
}

/// The part of the map on screen, side by side with the list: the map reports where it settled, the list follows.
/// The region changes only once the map has stopped moving (`onMapCameraChange(.onEnd)`) and a short pause after
/// that, so a run of quick pans updates the list once, never per frame.
@MainActor
@Observable
final class MapViewport {
    private(set) var region: MapRegion?
    @ObservationIgnored private var pending: Task<Void, Never>?
    static let settleDelay = Duration.milliseconds(250)

    /// The visible part of the map where it settled (`MapRegion.bounding` of its corners).
    func mapSettled(_ new: MapRegion) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self, self.region != new else { return }
            self.region = new
        }
    }
}

extension MapRegion {
    /// MapKit's region as BoatCore's.
    init(_ region: MKCoordinateRegion) {
        self.init(centerLatitude: region.center.latitude, centerLongitude: region.center.longitude,
                  latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta)
    }
}

extension EnvironmentValues {
    /// True where the system draws a column down the screen's trailing side (the iPhone Duo's status column with the
    /// ring that opens Control Center): the map's buttons then go top leading (`MapControlsLayout`). Set at the root
    /// from the window's safe area.
    @Entry var mapButtonsLeading = false
    /// The window's safe area's trailing edge, in window coordinates (infinity until measured). A map draws its
    /// frame past it in a split view: floating controls keep inside it.
    @Entry var safeTrailingEdge = CGFloat.infinity
}

/// When the list and map filter last changed from its menu. The map ignores MapKit's deselect for a moment after
/// (`VesselMapScreen.mapSelection`, CHAOS-FINDINGS D3).
@MainActor
enum FilterMenuActivity {
    static var lastChange: Date?
    /// How long after a change a deselect from MapKit is taken as the menu closing.
    static let window: TimeInterval = 4
}

/// The list's filter button: a menu to hide boat types or trains, show only moving ones, follow the map (side by side
/// only), and reset (docs/DESIGN.md, Filters). Filled while any filter is on. Logic and text come from BoatCore's
/// `BrowseFilter`; the boat types and train switches are the camera menu's own options and symbols.
struct BrowseFilterMenu: View {
    @AppStorage(BrowseFilter.storageKey) private var stored = BrowseFilter.default
    @AppStorage(TrainSettings.showTrainsKey) private var showTrains = true
    @AppStorage(TrainSettings.showUndergroundKey) private var showUnderground = true
    /// Side by side with the map: offers "Only what's on the map".
    let sideBySide: Bool
    /// In the map's button stack (compact width): a 44pt button in the stack's style, its own identifier.
    var inMapStack = false

    private var filter: BrowseFilter {
        BrowseFilterSetting.filter(stored: stored, showTrains: showTrains, showUnderground: showUnderground)
    }

    private func update(_ change: (inout BrowseFilter) -> Void) {
        FilterMenuActivity.lastChange = Date()
        var new = filter
        change(&new)
        stored = new
        if showTrains != new.isShown(.trains) { showTrains = new.isShown(.trains) }
        if showUnderground != new.isShown(.undergroundTrains) { showUnderground = new.isShown(.undergroundTrains) }
    }

    private func shown(_ option: CameraFilterOption) -> Binding<Bool> {
        Binding(get: { filter.isShown(option) }, set: { shown in update { $0.setShown(option, shown) } })
    }

    var body: some View {
        let filter = filter
        Menu {
            if sideBySide {
                Section {
                    Toggle(isOn: Binding(get: { filter.onlyOnMap }, set: { on in update { $0.onlyOnMap = on } })) {
                        Label("Only what's on the map", systemImage: "map")
                    }
                    .accessibilityIdentifier("listOnlyOnMap")
                }
            }
            ForEach(CameraFilter.menuSections) { section in
                Section(section.title) {
                    ForEach(section.options, id: \.self) { option in
                        Toggle(isOn: shown(option)) {
                            Label(option.title, systemImage: option.symbolName)
                        }
                        .disabled(!filter.isAvailable(option))
                        .accessibilityIdentifier("listType-\(option.key)")
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { filter.movingOnly }, set: { on in update { $0.movingOnly = on } })) {
                    Label("Moving only", systemImage: "gauge.with.needle")
                }
                .accessibilityIdentifier("listMovingOnly")
                Button {
                    update { $0.reset() }
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .disabled(!filter.canReset(sideBySide: sideBySide))
                .accessibilityIdentifier("listFilterReset")
            }
        } label: {
            Image(systemName: filter.isFiltering ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .frame(width: inMapStack ? Metrics.minTouch : nil, height: inMapStack ? Metrics.minTouch : nil)
        }
        // Several switches in a row: the menu stays open while they're flipped.
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel("Filters")
        .accessibilityValue(filter.spokenSummary(sideBySide: sideBySide))
        .accessibilityHint("Opens the list and map filter menu")
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier(inMapStack ? "mapFilterButton" : "listFilterButton")
    }
}

/// One header for every list group: its title and count, a chevron, tap to open or close it (animated), the state
/// kept per group across launches (`ListSection.storageKey`). `alwaysOpen` shows it open with no chevron (out of sight
/// when nothing is in sight).
struct CollapsibleSection<Content: View>: View {
    @AppStorage private var expanded: Bool
    @Environment(\.units) private var units
    let section: ListSection
    let count: Int
    let hasDistances: Bool
    let alwaysOpen: Bool
    let content: Content

    init(_ section: ListSection, count: Int, hasDistances: Bool = true, alwaysOpen: Bool = false,
         @ViewBuilder content: () -> Content) {
        _expanded = AppStorage(wrappedValue: section.expandedByDefault, section.storageKey)
        self.section = section
        self.count = count
        self.hasDistances = hasDistances
        self.alwaysOpen = alwaysOpen
        self.content = content()
    }

    private var open: Bool { alwaysOpen || expanded }

    private var headerContent: some View {
        HStack(spacing: 6) {
            Text(section.title(count: count, hasDistances: hasDistances))
                .monospacedDigit()
            Spacer(minLength: 8)
            if !alwaysOpen {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.token(.textSecondary))
        .frame(maxWidth: .infinity, minHeight: Metrics.minTouch, alignment: .leading)
        .contentShape(.rect)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if alwaysOpen {
                // Nothing to open or close: a plain heading, not a dimmed button.
                headerContent
                    .padding(.horizontal, Metrics.screenMargin)
                    .padding(.top, 8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(section.spokenTitle(count: count, hasDistances: hasDistances))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHint(section.hint(units: units))
                    .accessibilityIdentifier(section.headerIdentifier)
            } else {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    headerContent
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Metrics.screenMargin)
                .padding(.top, 8)
                .accessibilityLabel(section.spokenTitle(count: count, hasDistances: hasDistances))
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(open ? "Expanded" : "Collapsed")
                .accessibilityHint(section.hint(units: units))
                .accessibilityIdentifier(section.headerIdentifier)
            }
            if open {
                content
            }
        }
    }
}
