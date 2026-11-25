import BoatCore
import MapKit
import SwiftUI

/// Full-bleed map of the dev area with a marker per vessel and per train. Underground trains (smaller, dimmed, under
/// the rest) show only zoomed in (`TrainMap`); zoomed out a note says how many there are. The selected boat or train
/// gets a card over the map that never covers its marker or the map's controls (`MapCardLayout`): a summary docked at
/// the top or bottom (compact), or the details floating in a corner (regular width).
struct VesselMapScreen: View {
    @Environment(VesselStore.self) private var store
    @Environment(DeviceSensors.self) private var sensors
    @Environment(\.nightMode) private var nightMode
    @Binding var selection: TargetID?
    /// Regular width: the selected vessel's or train's details float over the map instead of a summary card.
    let showsFloatingDetail: Bool
    var findInCamera: (TargetID) -> Void = { _ in }
    /// Opens the full detail sheet for a target ("More info").
    var moreInfo: (TargetID) -> Void = { _ in }
    /// Side by side with the list: told where the map settles, so the list can follow it.
    var viewport: MapViewport?

    @State private var position: MapCameraPosition = .region(Self.startRegion)
    /// The visible map's narrower side, meters, updated when the user stops moving the map.
    @State private var visibleSpan = Self.span(of: Self.startRegion)
    /// The map view's narrower side, points: with `visibleSpan` it gives meters per point.
    @State private var mapSide: Double = 400
    /// The camera as the map last settled at a real size, for panning the selected marker into view at the same
    /// zoom. Nil until then: the map can't convert points yet (`MapCardLayout.move`).
    @State private var camera: MapCamera?
    @State private var imagery = false
    @State private var showsKey = false
    /// The map and its controls, measured in `Self.space`, for the card's placement.
    @State private var geometry = MapGeometry()
    @State private var card = CardPlacement()
    /// When the map last moved (not an observed state: it changes every frame of a drag).
    @State private var cameraMotion = CameraMotion()
    /// When the user last tapped the map itself (`mapSelection`).
    @State private var tapState = MapTapState()
    @AppStorage(EyeHeightSetting.key) private var eyeHeightFeet = EyeHeightSetting.automatic
    private var eye: EyeHeight { EyeHeightSetting.eyeHeight(setting: eyeHeightFeet, gpsAltitude: sensors.altitude) }
    @AppStorage(TrainSettings.showTrainsKey) private var showTrains = true
    @AppStorage(TrainSettings.showUndergroundKey) private var showUnderground = true
    /// The list's filter: the markers show the same boat types and trains (never limited to a region, of course).
    @AppStorage(BrowseFilter.storageKey) private var browseFilter = BrowseFilter.default
    @Environment(\.units) private var units
    /// Beside a system column on the trailing side (the Duo), the buttons go top leading (`MapControlsLayout`).
    @Environment(\.mapButtonsLeading) private var buttonsLeading
    @Environment(\.safeTrailingEdge) private var safeTrailingEdge
    /// How far the map's frame reaches past the safe area's trailing edge (into a system column), points.
    private var trailingOverhang: CGFloat {
        guard safeTrailingEdge.isFinite else { return 0 }
        return max(0, geometry.frame.origin.x + geometry.frame.size.width - safeTrailingEdge)
    }

    /// The coordinate space the card, the controls and the marker's screen point are measured in: the map's own.
    private static let space = "vesselMap"

    static let devRegion = MKCoordinateRegion(
        center: devBoundingBox.center,
        span: MKCoordinateSpan(latitudeDelta: devBoundingBox.latitudeSpan * 1.4,
                               longitudeDelta: devBoundingBox.longitudeSpan * 1.4))

    /// UI tests: BOATAR_MAP_REGION="lat,lon,meters" starts the map on that square instead of the whole area (zoomed in,
    /// where underground trains show). Debug builds only.
    static var startRegion: MKCoordinateRegion {
        #if DEBUG
        if let hook = ProcessInfo.processInfo.environment["BOATAR_MAP_REGION"] {
            let values = hook.split(separator: ",").compactMap { Double($0) }
            if values.count == 3 {
                return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: values[0], longitude: values[1]),
                                          latitudinalMeters: values[2], longitudinalMeters: values[2])
            }
        }
        #endif
        return devRegion
    }

    private static func span(of region: MKCoordinateRegion) -> Double {
        TrainMap.visibleSpanMeters(latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta,
                                   latitude: region.center.latitude)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let _ = launchMark("map body")
            // The list's filter, without a region; the selected one stays whatever it says.
            let scope = BrowseScope(filter: browseFilter)
            // No sightlines (range 0): the map draws every marker whether it's in sight or not, and with 1,000 targets the
            // walks cost the 5 s tick a good part of the 1-2 s stalls the chaos crowd test saw on the map (H2).
            let list = VesselList(vessels: scope.vessels(store.vessels, now: context.date, keep: selection?.vessel),
                                  observer: sensors.location, eye: eye, now: context.date, rangeMeters: 0,
                                  units: units)
            let trains = TrainList(
                trains: scope.trains(
                    TrainSettings.visible(store.trains, showTrains: showTrains, showUnderground: showUnderground),
                    now: context.date, keep: selection?.train),
                observer: sensors.location, eye: eye, now: context.date, rangeMeters: 0, units: units)
            let showsUnderground = TrainMap.showsUnderground(visibleSpanMeters: visibleSpan)
            // MapKit picks which of two overlapping markers a tap selects, and not by declaration order, nor does
            // hit-testing or a missing tag keep a marker from taking the tap: an underground marker whose touch target
            // overlaps a train above ground or a boat isn't drawn, so the one above ground always wins. It is in the
            // list, and shows again once the map is zoomed in far enough that they part.
            let blocked = showsUnderground ? TrainMap.undergroundBlockedFromTaps(
                underground: trains.underground.map { (id: $0.id, coordinate: $0.position) },
                aboveGround: trains.aboveGround.map(\.position) + list.rows.map(\.position),
                visibleSpanMeters: visibleSpan, viewSidePoints: mapSide,
                overlapRadiusPoints: Metrics.minTouch / 2 + Metrics.undergroundTouch / 2) : []
            let drawnTrains = trains.underground.filter { showsUnderground && !blocked.contains($0.id) }
                + trains.aboveGround
            let selected = SelectedTarget(selection, list: list, trains: trains)
            // Drawn in order: underground trains at the bottom, then the trains above ground, then the boats, and the
            // selected one last, on top. One ForEach keyed by target: moving the selected one to the end doesn't
            // rebuild its marker, so its selection animation runs and MapKit keeps the selection.
            let markers = MapMarkerOrder.selectedLast(drawnTrains.map(MapMarker.train) + list.rows.map(MapMarker.vessel)) {
                $0.id == selection
            }
            MapReader { proxy in
                Map(position: $position, selection: mapSelection) {
                    UserAnnotation()
                    ForEach(markers) { marker in
                        // No title: MapKit made the title a second VoiceOver element ("HARBOR LARK, HARBOR LARK")
                        // beside the marker's own button (dogfood 13, checked with AccessibilityProbe).
                        Annotation(String(), coordinate: marker.coordinate, anchor: .center) {
                            markerView(marker)
                                .environment(\.onMap, true)
                        }
                        .annotationTitles(.hidden)
                        .tag(marker.id)
                    }
                }
                .onGeometryChange(for: Double.self) { Double(min($0.size.width, $0.size.height)) } action: { side in
                    let wasEmpty = mapSide < 1
                    mapSide = side
                    // MapKit laid out at no size (a split view's detail column squeezed shut while it rotates) comes
                    // back somewhere else, the longitude flipped to the other side of the globe: put the camera
                    // back where it last settled.
                    if wasEmpty, side >= 1 {
                        position = camera.map { .camera($0) } ?? .region(Self.startRegion)
                    }
                }
                // Seen alongside MapKit's own handling (simultaneous): a tap on the map, not one closing a menu.
                // Only a tap on the map's open area counts: the tap that closes the filter menu lands on the buttons'
                // stack (or the card), and reaches this gesture too.
                .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(Self.space)).onEnded { tap in
                    let controls = [geometry.buttons, geometry.banner, geometry.note, card.frame ?? .zero]
                    #if DEBUG
                    SelectionLog.shared.record("map tap at \(Int(tap.location.x)),\(Int(tap.location.y)) buttons \(geometry.buttons.integral)")
                    #endif
                    guard !controls.contains(where: { $0.insetBy(dx: -8, dy: -8).contains(tap.location) }) else { return }
                    tapState.lastTap = Date()
                })
                .onMapCameraChange(frequency: .continuous) { _ in
                    cameraMotion.lastChange = Date()
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    cameraMotion.lastChange = .distantPast
                    visibleSpan = Self.span(of: context.region)
                    // A camera settled at no size shows nothing: the list keeps the last real region. Where a corner
                    // can't be converted (a pitched map, with sky in a corner), MapKit's own region stands in: a
                    // little wide (it covers the map under the list's column too), never stale.
                    if mapSide >= 1, let viewport {
                        viewport.mapSettled(visibleRegion(proxy) ?? MapRegion(context.region))
                    }
                    // A camera settled at no size isn't one to pan from or go back to.
                    if mapSide >= 1 { camera = context.camera }
                    placeCard(proxy, for: selected)
                }
                .mapStyle(imagery ? .imagery(elevation: .realistic) : .standard(emphasis: .muted))
                // Night mode: the map goes red-only like the rest of the app.
                .saturation(nightMode ? 0 : 1)
                .colorMultiply(nightMode ? NightPalette.text : .white)
                .overlay(alignment: buttonsLeading ? .topLeading : .topTrailing) {
                    mapButtons
                        .measured(in: Self.space) { geometry.buttons = $0 }
                        .padding(Metrics.screenMargin)
                }
                .overlay(alignment: .top) {
                    if store.status == .offline {
                        OfflineBanner(retry: store.retry)
                            .measured(in: Self.space) { geometry.banner = $0 }
                            .onDisappear { geometry.banner = .zero }
                            .padding(.top, 8)
                            // Clear of the buttons' column, on whichever side it is, and inside the safe area on the
                            // other (a split view's map reaches under the Duo's status column).
                            .padding(buttonsLeading ? .leading : .trailing, 64)
                            .padding(.trailing, trailingOverhang)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if !showsUnderground, let note = TrainMap.undergroundNote(count: trains.underground.count) {
                        undergroundNote(note)
                    }
                }
                .overlay { cardLayer(selected) }
                .onGeometryChange(for: MapGeometry.Frame.self) { proxy in
                    MapGeometry.Frame(size: proxy.size, origin: proxy.frame(in: .global).origin)
                } action: { geometry.frame = $0 }
                .coordinateSpace(.named(Self.space))
                // The selected target moved (the 5 s tick), the card's size changed, or the controls did.
                .onChange(of: selected?.positionKey) { placeCard(proxy, for: selected) }
                .onChange(of: card.size) { placeCard(proxy, for: selected) }
                .onChange(of: geometry) { placeCard(proxy, for: selected) }
                .onChange(of: selection, initial: true) {
                    // A new selection: choose the card's place afresh, then move the marker into the middle of the
                    // map the card leaves.
                    card.placement = nil
                    card.frame = nil
                    card.needsSelectionPan = selection != nil
                    card.pansLeft = CardPlacement.pansPerSelection
                    placeCard(proxy, for: selected)
                }
                .sheet(isPresented: $showsKey) {
                    MapKeySheet(close: { showsKey = false })
                        .presentationDetents([.medium, .large])
                        .nightSheetBackground()
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("vesselMap")
            }
        }
    }

    /// The selection as MapKit sets it. A new selection applies at once. A nil (deselect) applies only when the user
    /// really tapped the map: MapKit also clears the selection when the filter menu closes (CHAOS-FINDINGS D3, seen in
    /// the selection log: "MapKit set nil" the moment the menu went, with no tap on the map), after which the filter
    /// hid the boat. So a nil waits a moment for the map's own tap (`tapState`, which records a tap on the map, not
    /// for one that dismisses a menu) and is dropped without one. The card's Close button sets `selection` directly.
    private var mapSelection: Binding<TargetID?> {
        Binding(get: { selection }, set: { new in
            #if DEBUG
            SelectionLog.shared.record("MapKit set \(new.map { "\($0)" } ?? "nil")")
            #endif
            guard new == nil else {
                selection = new
                return
            }
            let asked = Date()
            let cleared = selection
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                // Another marker selected meanwhile (MapKit can send nil, then the new one): keep that.
                guard selection == cleared else { return }
                let tapped = tapState.lastTap.map({ abs($0.timeIntervalSince(asked)) < 0.6 }) == true
                // Right after the filter changed, the deselect is the menu closing (its dismissing touch can reach
                // the map), not the user: keep the selection, which the filter would otherwise hide.
                let afterFilter = FilterMenuActivity.lastChange.map { asked.timeIntervalSince($0) < FilterMenuActivity.window } == true
                if tapped, !afterFilter {
                    selection = nil
                } else {
                    #if DEBUG
                    SelectionLog.shared.record("ignored MapKit's nil (tap \(tapped), after filter \(afterFilter))")
                    #endif
                }
            }
        })
    }

    // MARK: Markers

    @ViewBuilder private func markerView(_ marker: MapMarker) -> some View {
        switch marker {
        case .vessel(let row):
            let isSelected = selection == .vessel(row.id)
            VesselMarker(
                row: row, selected: isSelected,
                courseDegrees: VesselMap.courseArrowDegrees(speedKnots: row.vessel.sog, courseDegrees: row.vessel.cog,
                                                            mapHeading: camera?.heading ?? 0),
                showsTypeLabel: VesselMap.showsTypeLabel(visibleSpanMeters: visibleSpan, selected: isSelected))
        case .train(let row):
            TrainMarker(row: row, selected: selection == .train(row.id))
        }
    }

    // MARK: Card

    /// The selected target's card, drawn where `MapCardLayout` put it. Until the first placement it's laid out
    /// invisibly, so its size can be measured.
    @ViewBuilder private func cardLayer(_ selected: SelectedTarget?) -> some View {
        if let selected, let scene = geometry.scene, card.width(scene: scene, geometry: geometry, regular: showsFloatingDetail) > 0 {
            let width = card.width(scene: scene, geometry: geometry, regular: showsFloatingDetail)
            let maxHeight = MapCardLayout.maxCardHeight(
                scene: scene, cardWidth: width,
                fraction: showsFloatingDetail ? MapCardLayout.regularMaxHeightFraction
                    : MapCardLayout.compactMaxHeightFraction,
                candidates: candidates)
            Color.clear
                .measured(in: Self.space) { geometry.cardLayer = $0 }
                .overlay(alignment: .topLeading) {
                    cardContent(selected)
                        .frame(width: width)
                        .frame(maxHeight: maxHeight)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { card.size = $0 }
                        .offset(card.frame.map {
                            MapCardLayout.offset(of: $0, layerOrigin: geometry.cardLayer.origin)
                        } ?? .zero)
                        .opacity(card.frame == nil ? 0 : 1)
                        .accessibilityHidden(card.frame == nil)
                }
                .allowsHitTesting(card.frame != nil)
        }
    }

    @ViewBuilder private func cardContent(_ selected: SelectedTarget) -> some View {
        switch selected {
        case .vessel(let row):
            if showsFloatingDetail {
                floating {
                    VesselDetailView(row: row, showsAge: store.status == .offline,
                                     findInCamera: { findInCamera(.vessel(row.id)) }, close: { selection = nil },
                                     moreInfo: { moreInfo(.vessel(row.id)) })
                }
            } else {
                MapSummaryCard(text: row.mapCard, fades: store.status != .offline && row.freshness != .live,
                               moreInfo: { moreInfo(.vessel(row.id)) }, close: { selection = nil }) {
                    TypeBadge(category: row.category)
                }
            }
        case .train(let row):
            if showsFloatingDetail {
                floating {
                    TrainDetailView(row: row, showsAge: store.status == .offline,
                                    findInCamera: { findInCamera(.train(row.id)) }, close: { selection = nil })
                }
            } else {
                MapSummaryCard(text: row.mapCard, fades: store.status != .offline && row.freshness != .live,
                               moreInfo: { moreInfo(.train(row.id)) }, close: { selection = nil }) {
                    RouteBullet(train: row.train, outlined: row.isUnderground)
                }
            }
        }
    }

    /// Unfolded, the details float over the map's corner, scrolling inside the card when they don't fit.
    private func floating<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let details = content()
        return ViewThatFits(in: .vertical) {
            details.padding(20)
            ScrollView { details.padding(20) }
                .scrollBounceBehavior(.basedOnSize)
        }
        .floatingGlass(in: .rect(cornerRadius: Metrics.cardRadius))
        // The card as a whole (what's on screen), apart from its details' own identifier, which scroll inside.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mapCard")
    }

    private var candidates: [MapCardPlacement] {
        showsFloatingDetail ? MapCardPlacement.regularPreference : MapCardPlacement.compactPreference
    }

    /// Chooses the card's place for the selected marker where it is now, and pans the map when the marker has to move:
    /// right after a selection only when it's off screen or covered (`MapCardLayout.selectionPan`), later only when
    /// no place leaves it clear. At most `CardPlacement.pansPerSelection` pans per selection, none shorter than
    /// `MapCardLayout.minimumPanPoints`, and never while the user is moving the map.
    private func placeCard(_ proxy: MapProxy, for selected: SelectedTarget?) {
        guard let selected, let scene = geometry.scene, card.size.width > 0, card.size.height > 0 else { return }
        guard let point = scenePoint(proxy, selected.coordinate) else {
            // The map can't say where the marker is yet: the card still shows, in its default place, and the map
            // stays put. The selection pan waits for a placement that knows the marker.
            if let decision = MapCardLayout.defaultPlacement(cardSize: card.size, scene: scene, candidates: candidates,
                                                             current: card.placement) {
                apply(decision)
            }
            return
        }
        let marker = MapCardLayout.markerRect(center: point, radius: Double(VesselMarker.selectedSize) / 2,
                                              labelHeight: Double(VesselMarker.labelAllowance))
        let isSelection = card.needsSelectionPan
        guard let decision = MapCardLayout.place(
            marker: marker, cardSize: card.size, scene: scene, candidates: candidates,
            current: isSelection ? nil : card.placement)
        else { return }
        apply(decision)
        // "Show on map" builds the map with the selection already made: until its first settle (`camera`) the pan
        // waits, as panning from an unsettled map's answers sends the camera to MapKit's default (Apple Park).
        let plan = MapCardLayout.move(
            isSelectionPan: isSelection, mapSettled: camera != nil, pansLeft: card.pansLeft,
            userMoving: cameraMotion.isMoving(at: Date()), point: point, marker: marker, decision: decision,
            scene: scene, visibleSpanMeters: visibleSpan)
        card.needsSelectionPan = plan.selectionPanPending
        switch plan.move {
        case .none:
            break
        case .zoom(let span):
            // Off screen on a map too wide to pick it out: zoom in on it first, then pan once the map settles there.
            card.pansLeft -= 1
            withAnimation(.smooth) {
                position = .region(MKCoordinateRegion(center: selected.coordinate, latitudinalMeters: span,
                                                      longitudinalMeters: span))
            }
        case .pan(let target):
            card.pansLeft -= 1
            pan(proxy, marker: point, to: target)
        }
    }

    /// Where `coordinate` is on the map, in `Self.space`; nil when MapKit can't say. Converted through the window:
    /// MapKit's answer for a named space is off by the map's safe-area insets (the tab bar's, the sidebar's).
    private func scenePoint(_ proxy: MapProxy, _ coordinate: CLLocationCoordinate2D) -> CGPoint? {
        guard let point = proxy.convert(coordinate, to: .global), point.x.isFinite, point.y.isFinite else { return nil }
        return MapCardLayout.scenePoint(window: point, mapOrigin: geometry.frame.origin)
    }

    /// The part of the map the user can see: the map's own frame (it draws on under the sidebar and the bars, where
    /// nothing shows), its four corners as coordinates. Nil until MapKit can convert points.
    private func visibleRegion(_ proxy: MapProxy) -> MapRegion? {
        let size = geometry.frame.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        let corners = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height),
                       CGPoint(x: 0, y: size.height)]
        let coordinates = corners.compactMap { coordinate(proxy, at: $0) }
        guard coordinates.count == 4 else { return nil }
        return MapRegion.bounding(coordinates)
    }

    /// The coordinate at `point` in `Self.space`.
    private func coordinate(_ proxy: MapProxy, at point: CGPoint) -> CLLocationCoordinate2D? {
        proxy.convert(MapCardLayout.windowPoint(scene: point, mapOrigin: geometry.frame.origin), from: .global)
    }

    private func apply(_ decision: MapCardDecision) {
        guard decision.placement != card.placement || decision.frame != card.frame else { return }
        withAnimation(card.frame == nil ? nil : .snappy) {
            card.placement = decision.placement
            card.frame = decision.frame
        }
    }

    /// Moves the map so the marker at `marker` lands on `target`, keeping the zoom, heading and pitch.
    private func pan(_ proxy: MapProxy, marker: CGPoint, to target: CGPoint) {
        let camera = camera ?? position.camera
        let centerCoordinate = camera?.centerCoordinate ?? position.region?.center
        guard let centerCoordinate, let centerPoint = scenePoint(proxy, centerCoordinate),
              let center = coordinate(
                proxy, at: MapCardLayout.panCenter(cameraCenter: centerPoint, marker: marker, target: target))
        else { return }
        withAnimation(.smooth) {
            if let camera {
                position = .camera(MapCamera(centerCoordinate: center, distance: camera.distance,
                                             heading: camera.heading, pitch: camera.pitch))
            } else if let region = position.region {
                position = .region(MKCoordinateRegion(center: center, span: region.span))
            }
        }
    }

    // MARK: Controls

    /// Height reserved at the map's bottom edge for Apple's attribution (logo + Legal), which can't be moved. The
    /// map card keeps clear of it too (`MapCardScene.attribution`).
    private static let attributionClearance = CGFloat(MapCardLayout.attributionHeight)

    /// Zoomed out, underground trains are hidden: this says they're there.
    private func undergroundNote(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.token(.textPrimary))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .floatingGlass(in: .capsule)
            .measured(in: Self.space) { geometry.note = $0 }
            .onDisappear { geometry.note = .zero }
            .padding(.horizontal, Metrics.screenMargin)
            // Apple's Maps logo and Legal link sit in the map's bottom-left corner and must stay fully visible: the
            // note rides above them. The map card keeps clear of it (`MapCardLayout`).
            .padding(.bottom, Metrics.screenMargin + Self.attributionClearance)
            // Over the map, like its buttons: capped so it stays a line or two.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .accessibilityIdentifier("undergroundMapNote")
    }

    private var mapButtons: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation { position = .region(Self.devRegion) }
            } label: {
                Image(systemName: "location.fill")
                    .frame(width: Metrics.minTouch, height: Metrics.minTouch)
            }
            .accessibilityLabel("Re-center map")
            .accessibilityShowsLargeContentViewer()
            Divider().frame(width: 28)
            Button {
                imagery.toggle()
            } label: {
                Image(systemName: "square.3.layers.3d")
                    .frame(width: Metrics.minTouch, height: Metrics.minTouch)
            }
            .accessibilityLabel(imagery ? "Show standard map" : "Show satellite map")
            .accessibilityShowsLargeContentViewer()
            Divider().frame(width: 28)
            Button {
                showsKey = true
            } label: {
                Image(systemName: "info.circle")
                    .frame(width: Metrics.minTouch, height: Metrics.minTouch)
            }
            .accessibilityLabel("Map key")
            .accessibilityShowsLargeContentViewer()
            .accessibilityIdentifier("mapKeyButton")
            if !showsFloatingDetail {
                // Compact width: the map has its own tab, away from the list's button, and follows the same filter;
                // here it can be seen (filled while filtering) and changed. Side by side the list's button is beside it.
                Divider().frame(width: 28)
                BrowseFilterMenu(sideBySide: false, inMapStack: true)
            }
        }
        .font(.title3)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .foregroundStyle(.token(.accent))
        .floatingGlass(in: .rect(cornerRadius: Metrics.surfaceRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mapButtons")
    }
}

/// A marker on the map, keyed by its target.
private enum MapMarker: Identifiable {
    case vessel(VesselRow)
    case train(TrainRow)

    var id: TargetID {
        switch self {
        case .vessel(let row): .vessel(row.id)
        case .train(let row): .train(row.id)
        }
    }

    var title: String {
        switch self {
        case .vessel(let row): row.title
        case .train(let row): row.title
        }
    }

    /// A boat where it probably is now: its last report carried forward along its course.
    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .vessel(let row): row.position
        case .train(let row): row.position
        }
    }
}

/// When the map's camera last moved, so a pan doesn't fight the user's drag. A plain object: setting it on every
/// frame of a drag doesn't redraw anything.
@MainActor
private final class CameraMotion {
    var lastChange = Date.distantPast

    /// Moved within the last moment (the camera reports while a drag or pinch goes on, then `onEnd`).
    func isMoving(at now: Date) -> Bool {
        now.timeIntervalSince(lastChange) < 0.3
    }
}

/// When the map was last tapped. A plain object, like `CameraMotion`: setting it redraws nothing.
@MainActor
private final class MapTapState {
    var lastTap: Date?
}

/// The selected boat or train as the map draws it now.
private enum SelectedTarget {
    case vessel(VesselRow)
    case train(TrainRow)

    init?(_ selection: TargetID?, list: VesselList, trains: TrainList) {
        switch selection {
        case .vessel(let mmsi):
            guard let row = list.row(mmsi: mmsi) else { return nil }
            self = .vessel(row)
        case .train(let id):
            guard let row = trains.row(id: id) else { return nil }
            self = .train(row)
        case nil:
            return nil
        }
    }

    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .vessel(let row): row.position
        case .train(let row): row.position
        }
    }

    /// Changes when the target or its estimated position does.
    var positionKey: String {
        switch self {
        case .vessel(let row): "\(row.id)|\(row.position.latitude)|\(row.position.longitude)"
        case .train(let row): "\(row.id)|\(row.position.latitude)|\(row.position.longitude)"
        }
    }
}

/// The map's frame and its controls' frames, in the map's coordinate space.
private struct MapGeometry: Equatable {
    /// The map's layout frame: its size, and its origin in the window (`Self.space`'s origin there). The map draws
    /// past it, under the bars and a sidebar, but what's past it is covered or unsafe: the card stays inside.
    struct Frame: Equatable {
        var size: CGSize = .zero
        var origin: CGPoint = .zero
    }

    var frame = Frame()
    var buttons: CGRect = .zero
    var banner: CGRect = .zero
    var note: CGRect = .zero
    /// Where the card's layer starts: the card is offset from here.
    var cardLayer: CGRect = .zero

    /// The map as the placement rule sees it; nil until measured. Apple's attribution is always an obstacle.
    /// The frame is already the safe area: SwiftUI reports the map's safe-area insets as how far it draws *outside*
    /// its frame (the sidebar's width, the bars' heights), so they aren't taken off again.
    var scene: MapCardScene? {
        guard frame.size.width > 0, frame.size.height > 0 else { return nil }
        let bare = MapCardScene(container: frame.size)
        return MapCardScene(container: frame.size, obstacles: [buttons, banner, note, bare.attribution()])
    }
}

/// Where the card is and how big it is.
private struct CardPlacement {
    var placement: MapCardPlacement?
    var frame: CGRect?
    var size: CGSize = .zero
    /// Set by a new selection: the next placement pans the marker into the middle of the map the card leaves, if it
    /// is off screen or covered.
    var needsSelectionPan = false
    /// Pans left for this selection: the second is for a first one that didn't land (a zoom first, a moving target).
    var pansLeft = 0
    static let pansPerSelection = 2

    /// Compact: full width but the buttons' column. Regular: up to `MapCardLayout.regularMaxWidth`, narrower when that
    /// lets it pass the buttons on a short map.
    func width(scene: MapCardScene, geometry: MapGeometry, regular: Bool) -> Double {
        regular
            ? MapCardLayout.regularCardWidth(scene: scene, column: geometry.buttons)
            : MapCardLayout.cardWidth(scene: scene,
                                      reservedTrailing: MapCardLayout.reservedTrailing(scene: scene, column: geometry.buttons))
    }
}

private extension View {
    /// Reports this view's frame in the named coordinate space whenever it changes.
    func measured(in space: String, _ action: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { action($0) }
    }
}
