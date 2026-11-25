import BoatCore
import SwiftUI

extension EnvironmentValues {
    /// The units every screen shows (Settings > Units, else each vehicle's standard and the device's region). Views
    /// pass it to BoatCore's lists and texts; none converts anything itself.
    @Entry var units: Units = .standard
}

/// Reads Settings > Units and the device's region once, at the root, and hands everything below one `Units`.
struct UnitsRoot: ViewModifier {
    @AppStorage(UnitPreferences.speedKey) private var speed: SpeedChoice = .standard
    @AppStorage(UnitPreferences.distanceKey) private var distance: DistanceChoice = .automatic
    @AppStorage(UnitPreferences.heightKey) private var height: HeightChoice = .automatic
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        content.environment(\.units, Units(preferences: UnitPreferences(speed: speed, distance: distance, height: height),
                                           region: Units.region(of: locale)))
    }
}

/// Settings > Units: speed, distance, and height and depth, each "Standard"/"Automatic" until chosen. Menus by default;
/// at accessibility text sizes each choice is its own row instead (a menu's value, "Standard for each vehicle",
/// wraps to three lines there and the row cut it off).
struct UnitsSettingsSection: View {
    @Environment(\.units) private var units
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(UnitPreferences.speedKey) private var speed: SpeedChoice = .standard
    @AppStorage(UnitPreferences.distanceKey) private var distance: DistanceChoice = .automatic
    @AppStorage(UnitPreferences.heightKey) private var height: HeightChoice = .automatic
    let primaryText: AnyShapeStyle
    let secondaryText: AnyShapeStyle

    private var footer: String { units.unitsFooter }

    var body: some View {
        if typeSize.isAccessibilitySize {
            section("Speed", identifier: "unitsSpeedPicker", footer: nil) {
                Picker("Speed", selection: $speed) {
                    ForEach(SpeedChoice.allCases) { Text($0.title).accessibilityLabel($0.spokenTitle).tag($0) }
                }
            }
            section("Distance", identifier: "unitsDistancePicker", footer: nil) {
                Picker("Distance", selection: $distance) {
                    ForEach(DistanceChoice.allCases) { Text($0.title).tag($0) }
                }
            }
            section("Height and depth", identifier: "unitsHeightPicker", footer: footer) {
                Picker("Height and depth", selection: $height) {
                    ForEach(HeightChoice.allCases) { Text($0.title).tag($0) }
                }
            }
        } else {
            Section {
                Picker("Speed", selection: $speed) {
                    ForEach(SpeedChoice.allCases) { Text($0.title).accessibilityLabel($0.spokenTitle).tag($0) }
                }
                .accessibilityIdentifier("unitsSpeedPicker")
                Picker("Distance", selection: $distance) {
                    ForEach(DistanceChoice.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("unitsDistancePicker")
                Picker("Height and depth", selection: $height) {
                    ForEach(HeightChoice.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("unitsHeightPicker")
            } header: {
                Text("Units")
                    .foregroundStyle(secondaryText)
            } footer: {
                Text(footer)
                    .foregroundStyle(secondaryText)
                    .accessibilityIdentifier("unitsFooter")
            }
            .foregroundStyle(primaryText)
            .pickerStyle(.menu)
        }
    }

    /// One picker as a section of its own rows, titled by its header.
    private func section<P: View>(_ title: String, identifier: String, footer: String?,
                                  @ViewBuilder picker: () -> P) -> some View {
        Section {
            picker()
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier(identifier)
        } header: {
            Text(title)
                .foregroundStyle(secondaryText)
        } footer: {
            if let footer {
                Text(footer)
                    .foregroundStyle(secondaryText)
                    .accessibilityIdentifier("unitsFooter")
            }
        }
        .foregroundStyle(primaryText)
    }
}
