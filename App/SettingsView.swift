import BoatAIS
import BoatCore
import SwiftUI

/// Night mode (automatic, on, off), your height for sightlines, which trains to show, units, the relay address, plus
/// version info.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.nightMode) private var isNight
    @Environment(DeviceSensors.self) private var sensors
    @Environment(VesselStore.self) private var store
    @Environment(HingeMonitor.self) private var hinge
    @AppStorage("nightMode") private var nightMode: NightModeSetting = .automatic
    /// Empty: use the address built into this version (RELAY_URL).
    @AppStorage("relayURL") private var relayURL = ""
    @AppStorage(EyeHeightSetting.key) private var eyeHeightFeet = EyeHeightSetting.automatic
    @AppStorage(TrainSettings.showTrainsKey) private var showTrains = true
    @AppStorage(TrainSettings.showUndergroundKey) private var showUnderground = true

    @State private var relayDraft = ""
    @State private var relayError: String?

    private let info = Bundle.main.infoDictionary ?? [:]

    /// Night mode is red-only, so the form takes the night tokens; by day these are the form's own text styles.
    private var primaryText: AnyShapeStyle { isNight ? AnyShapeStyle(.token(.textPrimary)) : AnyShapeStyle(.primary) }
    private var secondaryText: AnyShapeStyle { isNight ? AnyShapeStyle(.token(.textSecondary)) : AnyShapeStyle(.secondary) }
    /// By day nil keeps the system's rows.
    private var rowBackground: Color? { isNight ? NightPalette.surface : nil }
    private var rowSeparator: Color? { isNight ? NightPalette.line : nil }

    /// The system draws placeholders in neutral grey, which breaks the red-only rule at night; by day it keeps the
    /// system look.
    private var relayPrompt: Text {
        let prompt = Text(verbatim: FeedConfiguration.exampleAddress)
        return isNight ? prompt.foregroundStyle(.token(.textSecondary)) : prompt
    }

    private var canSaveRelay: Bool { relayDraft.trimmingCharacters(in: .whitespaces) != relayURL }

    @ViewBuilder private var saveRelayButton: some View {
        let button = Button("Use This Address", action: saveRelay)
            .disabled(!canSaveRelay)
            .accessibilityIdentifier("relaySave")
        if isNight, !canSaveRelay {
            // The system draws a disabled button in neutral grey. An explicit red keeps it red, and the system still
            // dims it to half strength, so it reads as disabled (any more dimming on top and it all but vanishes).
            button
                .foregroundStyle(.token(.textSecondary))
        } else {
            button
        }
    }

    /// On: a height set by hand replaces GPS altitude.
    private var heightByHand: Binding<Bool> {
        Binding {
            eyeHeightFeet >= 0
        } set: { on in
            eyeHeightFeet = on ? EyeHeightSetting.manualDefault : EyeHeightSetting.automatic
        }
    }

    private var heightFooter: String {
        if eyeHeightFeet >= 0 {
            return "Boats hidden by land or buildings are left out of the camera. About 10 ft a floor."
        }
        guard let altitude = sensors.altitude else {
            return "No height from GPS yet, so you count as standing on the street. Indoors GPS rarely has one: at a "
                + "window, set your height by hand."
        }
        let feet = Int(saturating: (altitude / 0.3048).rounded())
        return "From GPS: \(feet)\u{00A0}ft above sea level. Indoors GPS height is unreliable: at a window, set it by hand."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Night mode", selection: $nightMode) {
                        ForEach(NightModeSetting.allCases, id: \.self) { setting in
                            Text(setting.title).tag(setting)
                        }
                    }
                    .foregroundStyle(primaryText)
                    .accessibilityIdentifier("nightModePicker")
                } header: {
                    Text("Display")
                        .foregroundStyle(secondaryText)
                } footer: {
                    TimelineView(.everyMinute) { context in
                        Text(nightModeFooter(now: context.date))
                            .foregroundStyle(secondaryText)
                            .accessibilityIdentifier("nightModeStatus")
                    }
                }
                .listRowBackground(rowBackground)
                .listRowSeparatorTint(rowSeparator)

                Section {
                    Toggle("Set my height by hand", isOn: heightByHand)
                        .foregroundStyle(primaryText)
                        .accessibilityIdentifier("heightToggle")
                    if eyeHeightFeet >= 0 {
                        Stepper(value: $eyeHeightFeet, in: 0...1_000, step: 10) {
                            Text("\(eyeHeightFeet)\u{00A0}ft above the street")
                                .monospacedDigit()
                        }
                        .foregroundStyle(primaryText)
                        .accessibilityIdentifier("heightStepper")
                    }
                } header: {
                    Text("Your height")
                        .foregroundStyle(secondaryText)
                } footer: {
                    Text(heightFooter)
                        .foregroundStyle(secondaryText)
                        .accessibilityIdentifier("heightStatus")
                }
                .listRowBackground(rowBackground)
                .listRowSeparatorTint(rowSeparator)

                Section {
                    Toggle("Trains", isOn: $showTrains)
                        .foregroundStyle(primaryText)
                        .accessibilityIdentifier("trainsToggle")
                    if showTrains {
                        Toggle("Underground trains", isOn: $showUnderground)
                            .foregroundStyle(primaryText)
                            .accessibilityIdentifier("undergroundTrainsToggle")
                    }
                } header: {
                    Text("Trains")
                        .foregroundStyle(secondaryText)
                } footer: {
                    Text(showTrains
                         ? "Subway trains in the area, estimated from MTA's arrival predictions. Underground ones show in "
                            + "the list, dimmed on the map, and as outlined labels in the camera."
                         : "Only boats are shown.")
                        .foregroundStyle(secondaryText)
                }
                .listRowBackground(rowBackground)
                .listRowSeparatorTint(rowSeparator)

                UnitsSettingsSection(primaryText: primaryText, secondaryText: secondaryText)
                    .listRowBackground(rowBackground)
                    .listRowSeparatorTint(rowSeparator)

                Section {
                    TextField("Server address", text: $relayDraft, prompt: relayPrompt)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(saveRelay)
                        .foregroundStyle(primaryText)
                        .accessibilityLabel("Server address")
                        .accessibilityIdentifier("relayField")
                    if let relayError {
                        Text(relayError)
                            .font(.footnote)
                            .foregroundStyle(.token(.textSecondary))
                            .accessibilityIdentifier("relayError")
                    }
                    saveRelayButton
                    if !relayURL.isEmpty {
                        Button("Use the Built-In Address", role: .destructive) {
                            relayURL = ""
                            relayDraft = ""
                            relayError = nil
                        }
                    }
                } header: {
                    Text("Server")
                        .foregroundStyle(secondaryText)
                } footer: {
                    Text(relayURL.isEmpty
                         ? "The server the app gets boats and trains from. Empty uses the one built into this version."
                         : "Using the address above instead of the built-in one.")
                        .foregroundStyle(secondaryText)
                }
                .listRowBackground(rowBackground)
                .listRowSeparatorTint(rowSeparator)

                Section {
                    // "1.0, build 17 (355e543)": the code it was built from in brackets, for bug reports.
                    aboutRow("Version",
                             "\(info["CFBundleShortVersionString"] as? String ?? "unknown"), build "
                             + "\(info["CFBundleVersion"] as? String ?? "unknown") (\(info["GitSHA"] as? String ?? "unknown"))")
                        .monospacedDigit()
                        .accessibilityIdentifier("buildLabel")
                    aboutRow("Hinge", hingeDisplayText(for: hinge.state))
                        .accessibilityIdentifier("hingeLabel")
                    NavigationLink {
                        DataCreditsView()
                    } label: {
                        Text(DataCredits.screenTitle)
                            .foregroundStyle(primaryText)
                    }
                    .accessibilityIdentifier("dataCreditsRow")
                } header: {
                    Text("About")
                        .foregroundStyle(secondaryText)
                }
                .listRowBackground(rowBackground)
                .listRowSeparatorTint(rowSeparator)
            }
            .scrollContentBackground(isNight ? .hidden : .automatic)
            .background(isNight ? NightPalette.base : Color.clear)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isNight {
                    NightTitle("Settings")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settingsDone")
                }
            }
            .onAppear { relayDraft = relayURL }
        }
        .nightSheetBackground()
    }

    private func aboutRow(_ title: String, _ value: String) -> some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(secondaryText)
        } label: {
            Text(title)
                .foregroundStyle(primaryText)
        }
    }

    private func saveRelay() {
        let trimmed = relayDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            relayURL = ""
            relayError = nil
        } else if let url = FeedConfiguration.relayWebSocketURL(trimmed) {
            // A plain ws:// address iOS would block is refused here rather than failing later as "can't reach relay".
            relayError = FeedConfiguration.transportSecurityProblem(for: url)
            if relayError == nil {
                relayURL = trimmed
                relayDraft = trimmed
            }
        } else {
            relayError = FeedConfiguration.addressFormatHint
        }
    }

    private func nightModeFooter(now: Date) -> String {
        let intro = "Red-only display protects your night vision."
        switch nightMode {
        case .on: return "\(intro) On now."
        case .off: return intro
        case .automatic:
            guard let location = sensors.location else {
                return "\(intro) Automatic needs your location; choose On to use it now."
            }
            let night = nightMode.isActive(at: now, location: location)
            guard let next = SunPosition.nextTransition(after: now, coordinate: location) else {
                return "\(intro) \(night ? "On" : "Off") now."
            }
            let time = next.date.formatted(date: .omitted, time: .shortened)
            return night ? "\(intro) On now, off at sunrise (\(time))." : "\(intro) Off now, on at sunset (\(time))."
        }
    }
}
