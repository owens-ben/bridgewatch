import BoatCore
import SwiftUI

/// Compact width: List, Map and Camera tabs. Selecting from the list or the camera opens the details in a sheet; on
/// the map a summary card shows instead, with "More info" for the full sheet. Regular width (Duo unfolded): a list
/// sidebar + map tab with details in a floating card ("More info" opens the sheet), and the Camera tab.
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Set once the permissions screen is answered either way.
    @AppStorage("onboardingDone") private var onboardingDone = false
    /// The selected boat or train: highlighted on the map (with its card) and in the camera.
    @State private var selection: TargetID?
    /// The detail sheet, when one is open. Kept apart from `selection` so selecting on the map shows only the card.
    @State private var sheet: DetailSheetRequest?
    /// Whether the open (or last) sheet came from a map card's "More info": closing it then keeps the selection, so
    /// the card stays; closing one opened from the list or the camera clears it, as before.
    @State private var sheetFromCard = false
    /// Highlighted in the camera by "Find in Camera".
    @State private var cameraFocus: TargetID?
    @State private var tab: AppTab = .list
    /// Full screen height including safe areas: 678pt on the Duo cover, 874pt on the iPhone 18 Pro.
    @State private var screenHeight: CGFloat = 0
    /// Unfolded, the list and map always sit side by side (docs/DESIGN.md).
    @State private var columns: NavigationSplitViewVisibility = .all
    /// Side by side, where the map has settled: the list follows it.
    @State private var viewport = MapViewport()
    /// The system's column down the trailing side (the Duo), from the window's safe area: the map's buttons move
    /// away from it (`MapControlsLayout`).
    @State private var mapButtonsLeading = false
    @State private var safeTrailingEdge = CGFloat.infinity

    private var isShort: Bool { screenHeight > 0 && screenHeight < 750 }

    // UI tests set BOATAR_FORCE_REGULAR=1 to exercise the regular-width layout on any simulator. Debug builds only.
    #if DEBUG
    private let forceRegular = ProcessInfo.processInfo.environment["BOATAR_FORCE_REGULAR"] == "1"
    #else
    private let forceRegular = false
    #endif

    enum AppTab: Hashable {
        case list, map, camera
    }

    var body: some View {
        launchMark("ContentView.body")
        return root.modifier(NightModeRoot()).modifier(UnitsRoot())
            .modifier(CameraLifecycle(cameraTabSelected: onboardingDone && tab == .camera))
    }

    private var root: some View {
        Group {
            if !onboardingDone {
                PermissionsView { onboardingDone = true }
            } else if forceRegular || horizontalSizeClass == .regular {
                regularTabs
                    .environment(\.horizontalSizeClass, .regular)
            } else {
                tabView
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        } action: { screenHeight = $0; launchMark("root laid out") }
        .onAppear { launchMark("root onAppear") }
        .onGeometryChange(for: Bool.self) { proxy in
            MapControlsLayout.buttonsOnLeadingSide(windowLeadingInset: proxy.safeAreaInsets.leading,
                                                   windowTrailingInset: proxy.safeAreaInsets.trailing)
        } action: { mapButtonsLeading = $0 }
        .environment(\.mapButtonsLeading, mapButtonsLeading)
        // The root keeps to the safe area: its trailing edge is the safe area's.
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { safeTrailingEdge = $0 }
        .environment(\.safeTrailingEdge, safeTrailingEdge)
        #if DEBUG
        .onChange(of: tab) { _, new in launchMark("tab \(new) at \(String(format: "%.1f", LaunchTimeline.sinceStart))") }
        .onChange(of: selection) { old, new in
            SelectionLog.shared.record("selection \(old.map { "\($0)" } ?? "nil") -> \(new.map { "\($0)" } ?? "nil")")
        }
        #endif
        // Its own view, so the store's changes re-evaluate only it, not the tabs.
        .background {
            SelectionWatcher(watched: [selection, cameraFocus, sheet?.target].compactMap { $0 }, gone: targetGone)
        }
    }

    /// A selected (or found, or open) boat or train is gone: aged out, or hidden in Settings. Nothing stays
    /// highlighted for it: no card, no camera ring, no sheet.
    private func targetGone(_ target: TargetID) {
        if selection == target { selection = nil }
        if cameraFocus == target { cameraFocus = nil }
        if sheet?.target == target {
            sheetFromCard = false
            sheet = nil
        }
    }

    private var tabView: some View {
        TabView(selection: $tab) {
            Tab("Nearby", systemImage: "list.bullet", value: AppTab.list) {
                NavigationStack {
                    VesselListScreen(select: select, showOnMap: showOnMap, isShort: isShort, selection: selection)
                }
            }
            Tab("Map", systemImage: "map", value: AppTab.map) {
                VesselMapScreen(selection: $selection, showsFloatingDetail: false, findInCamera: findInCamera,
                                moreInfo: showMoreInfo)
            }
            Tab("Camera", systemImage: "camera.viewfinder", value: AppTab.camera) {
                cameraScreen
            }
        }
        .sheet(item: $sheet, onDismiss: sheetDismissed) { request in
            detailSheet(request)
        }
    }

    /// Unfolded: list and map side by side in one tab; the camera stays its own tab. The system's floating tab bar
    /// is hidden here: centered on the window it sat across the list and the map, over the map's Apple Maps legal
    /// link (dogfood 15). The same two tabs are a switcher at the foot of the list column instead, and at the foot
    /// of the camera (`RegularTabSwitcher`).
    private var regularTabs: some View {
        TabView(selection: $tab) {
            Tab("Nearby", systemImage: "list.bullet", value: AppTab.list) {
                splitView
                    .toolbarVisibility(.hidden, for: .tabBar)
            }
            Tab("Camera", systemImage: "camera.viewfinder", value: AppTab.camera) {
                cameraScreen
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        RegularTabSwitcher(tab: $tab)
                            .padding(.bottom, 8)
                    }
                    .toolbarVisibility(.hidden, for: .tabBar)
            }
        }
        // Next to the map, details float over it; over the camera, and for "More info", they come up as a sheet.
        .sheet(item: $sheet, onDismiss: sheetDismissed) { request in
            detailSheet(request)
        }
    }

    private var cameraScreen: some View {
        CameraScreen(focus: cameraFocus ?? selection, select: select)
    }

    /// From the list (compact) or the camera: select it and open its sheet.
    private func select(_ target: TargetID) {
        selection = target
        sheetFromCard = false
        sheet = DetailSheetRequest(target: target, full: false)
    }

    /// "More info" on a map card: the full sheet, over the card.
    private func showMoreInfo(_ target: TargetID) {
        sheetFromCard = true
        sheet = DetailSheetRequest(target: target, full: true)
    }

    private func sheetDismissed() {
        if !sheetFromCard { selection = nil }
    }

    private func detailSheet(_ request: DetailSheetRequest) -> some View {
        let selected = request.target
        return Group {
            switch selected {
            case .vessel(let mmsi):
                VesselDetailSheet(mmsi: mmsi, close: { sheet = nil }, findInCamera: { findInCamera(selected) })
            case .train(let id):
                TrainDetailSheet(id: id, close: { sheet = nil }, findInCamera: { findInCamera(selected) })
            }
        }
            // "More info" is the full details: large. Otherwise Find in Camera is off screen at the medium detent
            // once text is this large.
            .presentationDetents(request.full || typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
            .nightSheetBackground()
    }

    private func findInCamera(_ target: TargetID) {
        sheetFromCard = false
        sheet = nil
        selection = nil
        cameraFocus = target
        tab = .camera
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columns) {
            // Unfolded the map is beside the list: selecting shows the floating card, not a sheet.
            VesselListScreen(select: { selection = $0 }, showOnMap: { selection = $0 }, isShort: false,
                             mapViewport: viewport, selection: selection)
                // The tabs, inside the list's column: clear of the map and its legal link.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    RegularTabSwitcher(tab: $tab)
                        .padding(.bottom, 8)
                }
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 400)
        } detail: {
            VesselMapScreen(selection: $selection, showsFloatingDetail: true, findInCamera: findInCamera,
                            moreInfo: showMoreInfo, viewport: viewport)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// "Show on map" from the list: the map tab with the target's card, no sheet.
    private func showOnMap(_ target: TargetID) {
        selection = target
        tab = .map
    }
}

/// Side by side, the app's two tabs as a floating glass switcher: "Nearby" (the list and map) and "Camera". Two
/// buttons named like the tabs (UI tests and VoiceOver find them by those names), the selected one marked selected.
private struct RegularTabSwitcher: View {
    @Binding var tab: ContentView.AppTab

    var body: some View {
        HStack(spacing: 4) {
            item("Nearby", systemImage: "list.bullet", value: .list)
            item("Camera", systemImage: "camera.viewfinder", value: .camera)
        }
        .padding(4)
        .floatingGlass(in: .capsule)
        // Over the camera and under the list, like the system's tab bar: capped so it stays one row.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("regularTabs")
    }

    private func item(_ title: String, systemImage: String, value: ContentView.AppTab) -> some View {
        let selected = tab == value || (value == .list && tab == .map)
        return Button {
            tab = value
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: Metrics.minTouch)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.token(selected ? .accent : .textPrimary))
        .background {
            if selected { Capsule().fill(.token(.bgRaised)) }
        }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityShowsLargeContentViewer()
    }
}

/// An open detail sheet: which target, and whether it's the full details ("More info", large only).
private struct DetailSheetRequest: Identifiable, Hashable {
    let target: TargetID
    let full: Bool

    var id: Self { self }
}

/// Detail sheet contents, kept current while open; closes itself if the vessel ages out.
private struct VesselDetailSheet: View {
    @Environment(VesselStore.self) private var store
    @Environment(DeviceSensors.self) private var sensors
    @Environment(\.units) private var units
    let mmsi: Int
    let close: () -> Void
    let findInCamera: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let list = VesselList(vessels: store.vessels, observer: sensors.location, now: context.date, units: units)
            ScrollView {
                if let row = list.row(mmsi: mmsi) {
                    VesselDetailView(row: row, showsAge: store.status == .offline,
                                     findInCamera: findInCamera, close: close,
                                     detailItems: row.detailItems(now: context.date), showsLookup: true)
                        .padding(20)
                } else {
                    Color.clear.onAppear(perform: close)
                }
            }
        }
    }
}

/// Train detail sheet contents, kept current while open; closes itself if the train is gone (or hidden in Settings).
private struct TrainDetailSheet: View {
    @Environment(VesselStore.self) private var store
    @Environment(DeviceSensors.self) private var sensors
    @Environment(\.units) private var units
    @AppStorage(EyeHeightSetting.key) private var eyeHeightFeet = EyeHeightSetting.automatic
    @AppStorage(TrainSettings.showTrainsKey) private var showTrains = true
    @AppStorage(TrainSettings.showUndergroundKey) private var showUnderground = true
    let id: String
    let close: () -> Void
    let findInCamera: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let list = TrainList(
                trains: TrainSettings.visible(store.trains, showTrains: showTrains, showUnderground: showUnderground),
                observer: sensors.location,
                eye: EyeHeightSetting.eyeHeight(setting: eyeHeightFeet, gpsAltitude: sensors.altitude),
                now: context.date, units: units)
            ScrollView {
                if let row = list.row(id: id) {
                    TrainDetailView(row: row, showsAge: store.status == .offline,
                                    findInCamera: findInCamera, close: close)
                        .padding(20)
                } else {
                    Color.clear.onAppear(perform: close)
                }
            }
        }
    }
}

/// Watches the store for the targets in `watched` and reports each one that's no longer shown (`SelectionCheck`):
/// when the store changes, when the train settings do, and every 5 s for one that ages out while the feed is quiet.
private struct SelectionWatcher: View {
    @Environment(VesselStore.self) private var store
    @AppStorage(TrainSettings.showTrainsKey) private var showTrains = true
    @AppStorage(TrainSettings.showUndergroundKey) private var showUnderground = true
    let watched: [TargetID]
    let gone: (TargetID) -> Void

    var body: some View {
        Color.clear
            .onChange(of: store.vessels) { check() }
            .onChange(of: store.trains) { check() }
            .onChange(of: showTrains) { check() }
            .onChange(of: showUnderground) { check() }
            // Restarted (with the new targets) whenever they change.
            .task(id: watched) {
                check()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    check()
                }
            }
            .accessibilityHidden(true)
    }

    private func check() {
        let now = Date()
        for target in Set(watched) where !isShown(target, now: now) {
            gone(target)
        }
    }

    private func isShown(_ target: TargetID, now: Date) -> Bool {
        switch target {
        case .vessel(let mmsi):
            SelectionCheck.vesselIsShown(mmsi: mmsi, in: store.vessels, now: now)
        case .train(let id):
            SelectionCheck.trainIsShown(
                id: id, in: TrainSettings.visible(store.trains, showTrains: showTrains, showUnderground: showUnderground),
                now: now)
        }
    }
}

/// The one place that runs the camera and the camera-only sensors (docs/CRASH-HUNT.md, F3-F5, F13): while the
/// Camera tab is selected and the app isn't in the background. The tab selection outlives a fold (the compact and
/// regular trees are swapped, `tab` isn't), so folding on the Camera tab neither stops nor rebuilds anything, and no
/// screen's appear/disappear order can switch tracking off under the screen that's showing. Its own modifier, so the
/// scene phase and camera access re-evaluate only it.
private struct CameraLifecycle: ViewModifier {
    let cameraTabSelected: Bool
    @Environment(CameraSession.self) private var camera
    @Environment(DeviceSensors.self) private var sensors
    @Environment(\.scenePhase) private var scenePhase

    private var showing: Bool { cameraTabSelected && scenePhase != .background }

    func body(content: Content) -> some View {
        content
            .onChange(of: showing, initial: true) { _, showing in
                if showing {
                    camera.start()
                    sensors.startCameraTracking()
                } else {
                    camera.stop()
                    sensors.stopCameraTracking()
                }
            }
            // Allowed from the Camera tab's own button or in Settings while away: configure and run it now.
            .onChange(of: sensors.cameraAccess) { _, access in
                if access == .authorized, showing { camera.start() }
            }
    }
}

/// Decides night mode and applies it to everything below. It reads the GPS fix itself, so a new fix re-evaluates only
/// this modifier and not the tab tree it wraps.
private struct NightModeRoot: ViewModifier {
    @AppStorage("nightMode") private var setting: NightModeSetting = .automatic
    @Environment(DeviceSensors.self) private var sensors
    /// Moved on every minute so automatic night mode turns on at sunset without a relaunch. Not a TimelineView: one
    /// wrapped around the screens' own TimelineViews redrew the app nonstop, a full CPU core on every screen.
    @State private var now = NightClock.now()

    func body(content: Content) -> some View {
        let night = setting.isActive(at: now, location: sensors.location)
        content
            .tint(night ? NightPalette.text : Color(.accent))
            .environment(\.nightMode, night)
            .preferredColorScheme(night ? .dark : nil)
            #if DEBUG
            .overlay(alignment: .topLeading) {
                if ProcessInfo.processInfo.environment["BOATAR_CHAOS_PROBE"] == "1" {
                    NightModeProbe(night: night)
                    SelectionLogProbe()
                }
            }
            #endif
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: NightClock.tick)
                    now = NightClock.now()
                }
            }
    }
}

// Previews use DEBUG-only fixtures; Release (TestFlight) builds must not compile them.
#if DEBUG
#Preview("List, fixture data") {
    ContentView()
        .environment(HingeMonitor())
        .environment(PreviewFixtures.store())
        .environment(DeviceSensors(fake: PreviewFixtures.sensors))
        .environment(CameraSession())
}

#Preview("Offline") {
    ContentView()
        .environment(HingeMonitor())
        .environment(PreviewFixtures.store(offline: true))
        .environment(DeviceSensors(fake: PreviewFixtures.sensors))
        .environment(CameraSession())
}
#endif
