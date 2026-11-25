import BoatCore
import SwiftUI

/// The camera's filter as the app stores it: its own setting (`CameraFilter.storageKey`) plus the Settings > Trains
/// switches, which the camera menu shares rather than copies, so the two always agree.
enum CameraFilterSetting {
    static func filter(stored: CameraFilter, showTrains: Bool, showUnderground: Bool) -> CameraFilter {
        stored.merging(shared: [.trains: showTrains, .undergroundTrains: showUnderground])
    }
}

/// The camera's filter button: a floating glass circle that opens a menu to change the radius, hide boat types or
/// trains, show only moving ones, and reset (docs/DESIGN.md, Camera). Filled with an accent dot while anything
/// differs from the defaults. Logic, text and counts come from BoatCore's `CameraFilter`.
struct CameraFilterMenu: View {
    @AppStorage(CameraFilter.storageKey) private var stored = CameraFilter.default
    @AppStorage(TrainSettings.showTrainsKey) private var showTrains = true
    @AppStorage(TrainSettings.showUndergroundKey) private var showUnderground = true
    @Environment(\.units) private var units
    /// The circle's width and height (`CameraControlsRow`'s `buttonSize`).
    let size: CGFloat

    private var filter: CameraFilter {
        CameraFilterSetting.filter(stored: stored, showTrains: showTrains, showUnderground: showUnderground)
    }

    /// Applies a change to the filter and writes each part back to where it's kept: the camera's own parts to its
    /// setting, the train switches to Settings' (Reset leaves those as they are).
    private func update(_ change: (inout CameraFilter) -> Void) {
        var new = filter
        change(&new)
        stored = new
        if showTrains != new.isShown(.trains) { showTrains = new.isShown(.trains) }
        if showUnderground != new.isShown(.undergroundTrains) { showUnderground = new.isShown(.undergroundTrains) }
    }

    private var radius: Binding<CameraRadius> {
        Binding(get: { filter.radius }, set: { radius in update { $0.radius = radius } })
    }

    private func shown(_ option: CameraFilterOption) -> Binding<Bool> {
        Binding(get: { filter.isShown(option) }, set: { shown in update { $0.setShown(option, shown) } })
    }

    private var movingOnly: Binding<Bool> {
        Binding(get: { filter.movingOnly }, set: { on in update { $0.movingOnly = on } })
    }

    var body: some View {
        let filter = filter
        Menu {
            Section {
                // One row that opens the six distances: inline, they pushed the train switches and Moving only out of
                // sight above the boat types (the menu opens upward and was taller than the screen; dogfood 4). Now
                // the menu holds what the map's does, plus this row.
                Picker(selection: radius) {
                    ForEach(CameraRadius.allCases) { radius in
                        Text(radius.text(units: units))
                            .accessibilityLabel(radius.spokenText(units: units))
                            .accessibilityIdentifier("cameraRadius-\(radius.rawValue)")
                            .tag(radius)
                    }
                } label: {
                    Label("Radius", systemImage: "scope")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("cameraRadiusMenu")
            }
            ForEach(CameraFilter.menuSections) { section in
                Section(section.title) {
                    ForEach(section.options, id: \.self) { option in
                        Toggle(isOn: shown(option)) {
                            Label(option.title, systemImage: option.symbolName)
                        }
                        // Underground trains can't show with trains off.
                        .disabled(!filter.isAvailable(option))
                        .accessibilityIdentifier("cameraType-\(option.key)")
                    }
                }
            }
            Section {
                Toggle(isOn: movingOnly) {
                    Label("Moving only", systemImage: "gauge.with.needle")
                }
                .accessibilityIdentifier("cameraMovingOnly")
                Button {
                    update { $0.reset() }
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .disabled(filter.isDefault)
                .accessibilityIdentifier("cameraFilterReset")
            }
        } label: {
            CameraFilterButtonLabel(isDefault: filter.isDefault, size: size)
        }
        // Several switches in a row: the menu stays open while they're flipped.
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel("Filters")
        .accessibilityValue(filter.spokenSummary(units: units))
        .accessibilityHint("Opens the radius and filter menu")
        .accessibilityShowsLargeContentViewer {
            Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("cameraFilterButton")
    }
}

/// The camera's bottom row: the zoom buttons centered, the filter button at the trailing end. An empty slot as wide as
/// the filter button balances it on the leading side, so the zoom buttons stay centered and the two never overlap,
/// however narrow the space between the safe area's sides (the Duo cover's right-hand columns are already outside
/// it). The button's size is read here, once, for both the button and the slot, inside the camera's capped text
/// size, so the two always match.
struct CameraControlsRow<Zoom: View>: View {
    /// Grows with the text size, up to the cap the camera's other controls share (set above this row).
    @ScaledMetric(relativeTo: .title3) private var buttonSize = Metrics.minTouch
    private let zoom: Zoom

    init(@ViewBuilder zoom: () -> Zoom) {
        self.zoom = zoom()
    }

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: buttonSize, height: 1)
            Spacer(minLength: 0)
            zoom
            Spacer(minLength: 0)
            CameraFilterMenu(size: buttonSize)
        }
    }
}

/// The glass circle: outlined at the defaults, filled with an accent dot when anything is filtered.
private struct CameraFilterButtonLabel: View {
    let isDefault: Bool
    let size: CGFloat

    var body: some View {
        Image(systemName: isDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.token(.textPrimary))
            .frame(width: size, height: size)
            .floatingGlass(in: .circle)
            .overlay(alignment: .topTrailing) {
                if !isDefault {
                    Circle()
                        .fill(.token(.accent))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.token(.bgRaised), lineWidth: 1.5))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.circle)
    }
}

extension CameraFilterOption {
    /// SF Symbol beside the option's name: a boat type's own symbol, a tram for trains.
    var symbolName: String {
        switch self {
        case .vessel(let category): category.symbolName
        case .trains: "tram.fill"
        case .undergroundTrains: "tram.tunnel.fill"
        }
    }
}

#if DEBUG
#Preview("Camera filter") {
    ZStack(alignment: .bottomTrailing) {
        Color.gray.ignoresSafeArea()
        CameraFilterMenu(size: Metrics.minTouch).padding()
    }
}
#endif
