import BoatCore
import SwiftUI

/// Large title, live status line, closest card, then the rest in sight nearest first, then a collapsed "Out of sight"
/// section (behind land or too far). Under the boats, the trains: in sight, out of sight, then a collapsed
/// "Underground" group. Every group collapses (`CollapsibleSection`). The filter button limits it to some boat types,
/// moving ones, and side by side with the map to what's on it (`BrowseResult`). Empty and offline states included.
struct VesselListScreen: View {
    @Environment(VesselStore.self) private var store
    @Environment(DeviceSensors.self) private var sensors
    @Environment(\.openURL) private var openURL
    @Environment(\.nightMode) private var nightMode
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Tapping a row selects it (detail sheet in compact width, floating card next to the map in regular).
    let select: (TargetID) -> Void
    /// Tapping the closest card shows it on the map.
    let showOnMap: (TargetID) -> Void
    /// Short screens (the Duo cover) get an inline title and a horizontal closest card.
    let isShort: Bool
    /// Side by side with the map: the map's visible region, which the list follows ("Only what's on the map"). Nil
    /// where the list is on its own.
    var mapViewport: MapViewport?
    /// The selected boat or train: listed whatever the filter or the map's region says.
    var selection: TargetID?

    @State private var showSettings = false
    @AppStorage(EyeHeightSetting.key) private var eyeHeightFeet = EyeHeightSetting.automatic
    private var eye: EyeHeight { EyeHeightSetting.eyeHeight(setting: eyeHeightFeet, gpsAltitude: sensors.altitude) }
    @AppStorage(TrainSettings.showTrainsKey) private var showTrains = true
    @AppStorage(TrainSettings.showUndergroundKey) private var showUnderground = true
    @AppStorage(BrowseFilter.storageKey) private var browseFilter = BrowseFilter.default
    @Environment(\.units) private var units

    private var isOffline: Bool { store.status == .offline }
    /// Pinned over the list, the banner takes 40-60% of the screen at accessibility text sizes: there it is the first
    /// item of the scroll content instead.
    private var bannerScrolls: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let _ = launchMark("list body: building rows")
            let scope = BrowseScope(filter: browseFilter, region: BrowseScope.region(
                mapViewport?.region, filter: browseFilter, sideBySide: mapViewport != nil))
            let result = BrowseResult(
                vessels: store.vessels,
                trains: TrainSettings.visible(store.trains, showTrains: showTrains, showUnderground: showUnderground),
                observer: sensors.location, eye: eye, now: context.date, units: units, scope: scope,
                keepVessel: selection?.vessel, keepTrain: selection?.train)
            let list = result.vessels
            let _ = launchMark("list body: rows built")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if isOffline, bannerScrolls {
                        OfflineBanner(retry: store.retry)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        StatusLine(status: store.status, countText: result.vesselCountText,
                                   trainCountText: showTrains ? result.trainCountText : nil,
                                   scopeNote: result.scopeNote,
                                   lateNotice: store.freshness.notice(
                                       now: context.date, isLive: store.status == .live, showTrains: showTrains),
                                   spokenLateNotice: store.freshness.spokenNotice(
                                       now: context.date, isLive: store.status == .live, showTrains: showTrains))
                        locationHint
                    }
                    .padding(.horizontal, Metrics.screenMargin)
                    if let reason = result.emptyReason(includeTrains: showTrains) {
                        BrowseEmptyView(reason: reason, filtering: scope.filter.isFiltering,
                                        action: { emptyAction(reason) })
                    } else {
                        if let note = result.vesselNote {
                            scopeNote(note, identifier: "boatsScopeNote")
                        } else if list.isEmpty {
                            EmptyRiverView()
                        } else {
                            content(list)
                        }
                        if showTrains {
                            trainSection(result.trains, note: result.trainNote)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .background(.token(.bgBase))
            .safeAreaInset(edge: .top) {
                if isOffline, !bannerScrolls {
                    OfflineBanner(retry: store.retry)
                        .padding(.bottom, 8)
                }
            }
        }
        .navigationTitle("Nearby")
        // A large title can't be red, so night mode uses an inline bar with its own title (NightTitle).
        .navigationBarTitleDisplayMode(isShort || nightMode ? .inline : .large)
        .toolbar {
            if nightMode {
                NightTitle("Nearby")
            }
            ToolbarItem(placement: .topBarTrailing) {
                BrowseFilterMenu(sideBySide: mapViewport != nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("settingsButton")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    @ViewBuilder
    private var locationHint: some View {
        if sensors.needsLocationPermission {
            // Not a dead end: asks for location, or opens Settings if it was turned down.
            Button {
                if !sensors.requestLocation(), let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                // The icon keeps it reading as a button at night, when it is no longer the only red text.
                Label("Turn on location to see distances", systemImage: "location")
                    .frame(minHeight: Metrics.minTouch)
                    .contentShape(.rect)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.token(.accent))
            .multilineTextAlignment(.leading)
            .accessibilityIdentifier("locationOffNote")
        } else if sensors.location == nil {
            // Allowed, but the first fix hasn't arrived.
            Text("Finding your location…")
                .font(.footnote)
                .foregroundStyle(.token(.textSecondary))
        }
    }

    /// "Show the whole list" turns "Only what's on the map" off; "Reset filters" resets the filter.
    private func emptyAction(_ reason: BrowseEmptyReason) {
        withAnimation(.snappy) {
            switch reason {
            case .offMap: browseFilter.onlyOnMap = false
            case .filtered: browseFilter.reset()
            }
        }
    }

    /// A kind with nothing in scope though some are about: "No boats on this part of the map".
    private func scopeNote(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.token(.textSecondary))
            .padding(.horizontal, Metrics.screenMargin)
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func content(_ list: VesselList) -> some View {
        Group {
            if !list.hasDistances {
                // No location, no sightlines: every boat by name.
                CollapsibleSection(.boatsInSight, count: list.rows.count, hasDistances: false) {
                    rows(list.rows)
                }
            } else if let closest = list.closest {
                CollapsibleSection(.boatsInSight, count: list.inSight.count) {
                    Button { showOnMap(.vessel(closest.id)) } label: {
                        ClosestCard(row: closest, horizontal: isShort, showsAge: isOffline)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Metrics.screenMargin)
                    if !list.others.isEmpty {
                        rows(Array(list.others))
                    }
                }
            } else {
                nothingInSight
            }
            if !list.outOfSight.isEmpty {
                CollapsibleSection(.boatsOutOfSight, count: list.outOfSight.count, alwaysOpen: list.inSight.isEmpty) {
                    rows(list.outOfSight)
                }
            }
        }
        // Offline the list is frozen and faded, with report ages.
        .staleFade(isOffline)
    }

    private func rows(_ rows: [VesselRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(.token(.separator))
                        .frame(height: 1)
                        .padding(.leading, Metrics.screenMargin + Metrics.rowBadge + 12)
                }
                Button { select(.vessel(row.id)) } label: {
                    VesselRowView(row: row, showsAge: isOffline)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("vesselRow-\(row.id)")
            }
        }
        .background(.token(.bgSurface), in: .rect(cornerRadius: Metrics.surfaceRadius))
        .padding(.horizontal, Metrics.screenMargin)
    }

    /// In place of the closest card when vessels are around but none can be seen from here.
    private var nothingInSight: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No boats in sight from here")
                .font(.headline)
                .foregroundStyle(.token(.textPrimary))
            Text(units.outOfSightNote)
                .font(.footnote)
                .foregroundStyle(.token(.textSecondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.screenMargin)
        .background(.token(.bgSurface), in: .rect(cornerRadius: Metrics.cardRadius))
        .padding(.horizontal, Metrics.screenMargin)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nothingInSight")
    }

    // MARK: Trains

    /// "Trains", then those above ground (in sight, then out of sight; all together without a location), then the
    /// underground ones, collapsed under a count.
    @ViewBuilder
    private func trainSection(_ trains: TrainList, note: String?) -> some View {
        Group {
            Text("Trains")
                .font(.title2.bold())
                .foregroundStyle(.token(.textPrimary))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("trainsHeader")
                .padding(.horizontal, Metrics.screenMargin)
                .padding(.top, 16)
            if let note {
                scopeNote(note, identifier: "trainsScopeNote")
            } else if trains.isEmpty {
                Text(TrainText.emptyNote(offline: isOffline))
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
                    .padding(.horizontal, Metrics.screenMargin)
                    .accessibilityIdentifier(isOffline ? "trainsOfflineNote" : "noTrains")
            }
            if trains.hasDistances {
                if !trains.inSight.isEmpty {
                    CollapsibleSection(.trainsInSight, count: trains.inSight.count) {
                        trainRows(trains.inSight)
                    }
                }
                if !trains.outOfSight.isEmpty {
                    CollapsibleSection(.trainsOutOfSight, count: trains.outOfSight.count) {
                        trainRows(trains.outOfSight)
                    }
                }
            } else if !trains.aboveGround.isEmpty {
                CollapsibleSection(.trainsInSight, count: trains.aboveGround.count, hasDistances: false) {
                    trainRows(trains.aboveGround)
                }
            }
            if !trains.underground.isEmpty {
                // Underground trains can't be seen, and there are dozens: collapsed until asked for.
                CollapsibleSection(.trainsUnderground, count: trains.underground.count) {
                    trainRows(trains.underground)
                }
            }
        }
        .staleFade(isOffline)
    }

    private func trainRows(_ rows: [TrainRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(.token(.separator))
                        .frame(height: 1)
                        .padding(.leading, Metrics.screenMargin + Metrics.rowBadge + 12)
                }
                Button { select(.train(row.id)) } label: {
                    TrainRowView(row: row, showsAge: isOffline)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trainRow-\(row.id)")
            }
        }
        .background(.token(.bgSurface), in: .rect(cornerRadius: Metrics.surfaceRadius))
        .padding(.horizontal, Metrics.screenMargin)
    }
}
