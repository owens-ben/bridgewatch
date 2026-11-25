import BoatCore
import SwiftUI

/// Live preview with each vessel and train in sight labelled at its computed bearing, underground trains nearby as
/// x-ray labels, a compass strip, off-screen hints and a compass accuracy pill (docs/DESIGN.md, Camera). Projection
/// math lives in BoatCore (`ARProjection`, `VesselARTarget`, `TrainARTarget`).
struct CameraScreen: View {
    @Environment(VesselStore.self) private var store
    @Environment(DeviceSensors.self) private var sensors
    @Environment(\.openURL) private var openURL
    @Environment(\.nightMode) private var nightMode
    @Environment(\.units) private var units
    /// The vessel or train to highlight ("Find in Camera" or the current selection).
    let focus: TargetID?
    let select: (TargetID) -> Void

    /// Underground trains get x-ray labels only this close, and only this many, nearest first: dozens run under the
    /// area, and labels for all of them would bury what's in sight.
    static let undergroundRadiusMeters = 1_500.0
    static let undergroundLimit = 8

    /// The app's one camera (`BoatARApp`); `ContentView` starts and stops it with the tab, so a fold that swaps
    /// this screen for another keeps it running.
    @Environment(CameraSession.self) private var camera
    @AppStorage(EyeHeightSetting.key) private var eyeHeightFeet = EyeHeightSetting.automatic
    private var eye: EyeHeight { EyeHeightSetting.eyeHeight(setting: eyeHeightFeet, gpsAltitude: sensors.altitude) }
    @AppStorage(TrainSettings.showTrainsKey) private var showTrains = true
    @AppStorage(TrainSettings.showUndergroundKey) private var showUnderground = true
    /// The filter menu's radius, boat types and "Moving only"; the train switches above are its train options.
    @AppStorage(CameraFilter.storageKey) private var storedFilter = CameraFilter.default
    private var filter: CameraFilter {
        CameraFilterSetting.filter(stored: storedFilter, showTrains: showTrains, showUnderground: showUnderground)
    }
    /// Window-space frames of the full-bleed container and of a clear layer next to it that stays inside the safe
    /// area (see `body`); `safeInsets` is the difference.
    @State private var containerFrame = CGRect.zero
    @State private var safeFrame = CGRect.zero
    /// The zoom a pinch started from.
    @State private var pinchStart: Double?

    /// False for the first layout pass, until both frames are in.
    private var isMeasured: Bool { !containerFrame.isEmpty && !safeFrame.isEmpty }

    /// The safe area as insets from the full-bleed container: the status bar on top, and on the Duo cover the status
    /// and tab columns on the right.
    private var safeInsets: EdgeInsets {
        guard isMeasured else { return EdgeInsets() }
        return EdgeInsets(top: max(0, safeFrame.minY - containerFrame.minY),
                          leading: max(0, safeFrame.minX - containerFrame.minX),
                          bottom: max(0, containerFrame.maxY - safeFrame.maxY),
                          trailing: max(0, containerFrame.maxX - safeFrame.maxX))
    }

    var body: some View {
        let _ = launchMark("camera body")
        ZStack {
            // The preview and the label positions use the whole view; controls stay inside the safe area (on the Duo
            // cover the status bar and the tabs are columns on the right). A view that ignores the safe area reads
            // zero insets from its own proxy, so they come from the gap between this clear layer, which respects it,
            // and the container below, which doesn't.
            Color.clear
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { safeFrame = $0 }
            GeometryReader { proxy in
                let size = proxy.size
                let insets = safeInsets
                ZStack {
                    background
                    switch sensors.cameraAccess {
                    case .denied: cameraDenied
                    case .notDetermined: cameraNotAsked
                    case .authorized: overlay(size: size, insets: insets)
                    }
                }
                .overlay(alignment: .bottom) {
                    bottomPills
                        .padding(.leading, insets.leading + Metrics.screenMargin)
                        .padding(.trailing, insets.trailing + Metrics.screenMargin)
                        // The screen already stops above the floating tab bar (bottom safe area kept).
                        .padding(.bottom, insets.bottom + 12)
                }
            }
            // Until the insets are known the controls would sit under the status bar for a frame.
            .opacity(isMeasured ? 1 : 0)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { containerFrame = $0 }
            .ignoresSafeArea(edges: [.top, .horizontal])
        }
        // Pinching zooms, like the Camera app; labels are tapped with one finger, so they don't compete.
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    guard camera.zoomPresets.count > 1 else { return }
                    let start = pinchStart ?? camera.displayZoom
                    pinchStart = start
                    camera.setZoom(display: start * value.magnification, animated: false)
                }
                .onEnded { _ in pinchStart = nil }
        )
        .onAppear {
            sensors.requestPreciseLocationIfNeeded()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cameraScreen")
    }

    @ViewBuilder
    private var background: some View {
        if sensors.cameraAccess != .authorized || camera.availability == .unknown {
            // No camera access, or before the session is configured.
            Rectangle().fill(.token(.bgBase))
        } else if camera.isAvailable {
            CameraPreview(camera: camera)
                // Night mode dims the preview 40% to protect dark-adapted eyes.
                .overlay(Color.black.opacity(nightMode ? 0.4 : 0))
        } else {
            Rectangle().fill(.token(.bgBase))
                // Kept clear of the horizon, where labels and their waterline dots sit.
                .overlay(alignment: .bottom) {
                    Text("No camera on this device")
                        .font(.footnote)
                        .foregroundStyle(.token(.textSecondary))
                        .padding(.bottom, 120)
                        .accessibilityIdentifier("cameraUnavailable")
                }
        }
    }

    /// Skipped at first launch: ask here, where the reason is obvious.
    private var cameraNotAsked: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.largeTitle)
                .foregroundStyle(.token(.textSecondary))
                .accessibilityHidden(true)
            Text("Point your camera at the river")
                .font(.title3.bold())
                .foregroundStyle(.token(.textPrimary))
                .multilineTextAlignment(.center)
            Text("Bridgewatch labels the boats and trains it sees. Nothing is recorded or uploaded.")
                .font(.subheadline)
                .foregroundStyle(.token(.textSecondary))
                .multilineTextAlignment(.center)
            Button("Turn On Camera") {
                Task { if await sensors.requestCamera() { camera.start() } }
            }
            .buttonStyle(.primary)
            .frame(maxWidth: 320)
            .accessibilityIdentifier("enableCamera")
        }
        .padding(32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cameraNotAsked")
    }

    private var cameraDenied: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
                .foregroundStyle(.token(.textSecondary))
                .accessibilityHidden(true)
            Text("Camera access is off")
                .font(.title3.bold())
                .foregroundStyle(.token(.textPrimary))
            Text("Turn it on in Settings to label the boats and trains you point at.")
                .font(.subheadline)
                .foregroundStyle(.token(.textSecondary))
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.glass)
        }
        .padding(32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cameraDenied")
    }

    /// Vessels, trains, distances and sightlines are worked out once a second (and when the feed or the location
    /// changes); only `ARLayer` follows the compass, which reports up to 30 times a second.
    @ViewBuilder
    private func overlay(size: CGSize, insets: EdgeInsets) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if sensors.location != nil, sensors.hasCameraHeading, size.width > 0, size.height > 0 {
                // Only what the filter shows (and the focused one), with sightlines reaching to its radius: the nearest
                // `CameraFilter.candidateLimit` of each kind within it, so a crowd of 1,000 doesn't stall the tab (H2).
                let filter = filter
                let list = VesselList(vessels: filter.nearestCandidates(store.vessels, observer: sensors.location,
                                                                        now: context.date, focus: focus?.vessel),
                                      observer: sensors.location, eye: eye, now: context.date,
                                      rangeMeters: filter.radius.meters, units: units)
                let trains = TrainList(trains: filter.nearestCandidates(store.trains, observer: sensors.location,
                                                                        now: context.date, focus: focus?.train),
                                       observer: sensors.location, eye: eye, now: context.date,
                                       rangeMeters: filter.radius.meters, units: units)
                let fov = ARProjection.visibleFieldOfView(
                    sensorLongSideFOVDegrees: camera.longSideFOV,
                    sensorAspect: camera.aspect,
                    viewWidth: size.width, viewHeight: size.height,
                    // The view's shape can't say which way the sensor is turned (the Duo unfolded is a wide view
                    // over an upright sensor), so the preview reports it; the shape only guesses with no camera.
                    longSideIsVertical: camera.longSideIsVertical ?? (size.height > size.width))
                ARLayer(items: items(vessels: list, trains: trains, filter: filter), horizontalFOV: fov.horizontal,
                        size: size, safeInsets: insets, focus: focus, emptyText: filter.emptyMessage(units: units),
                        spokenEmptyText: filter.spokenEmptyMessage(units: units), select: select)
                    // Labels share the sky with each other; past this size they'd overlap. Large Content Viewer
                    // shows any label at full size on a long press.
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            } else {
                guidance(insets: insets)
            }
        }
    }

    /// The boats in sight, the trains in sight, the nearest underground trains, and the focused one wherever it is.
    /// Both kinds are placed from the lists' one eye (`VesselList.eyeAltitude`, `TrainList.eyeAltitude`). The x-ray
    /// labels reach no farther than the filter's radius.
    private func items(vessels: VesselList, trains: TrainList, filter: CameraFilter) -> [ARItem] {
        let trainTargets = TrainARTarget.targets(in: trains, focus: focus?.train,
                                                 undergroundRadiusMeters: filter.undergroundRadiusMeters(
                                                     cap: Self.undergroundRadiusMeters),
                                                 undergroundLimit: Self.undergroundLimit)
        return VesselARTarget.targets(in: vessels, focus: focus?.vessel).map { ARItem(target: .vessel($0)) }
            + trainTargets.all.map { ARItem(target: .train($0)) }
    }

    private func guidance(insets: EdgeInsets) -> some View {
        Group {
            if sensors.location != nil {
                guidancePill(Text("Hold the phone up toward the river"))
            } else if sensors.needsLocationPermission {
                // Not a dead end: asks for location, or opens Settings if it was turned down.
                Button {
                    if !sensors.requestLocation(), let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    guidancePill(Text("Turn on location to place labels"))
                }
                .buttonStyle(.plain)
            } else {
                // Allowed already, just no fix yet: nothing for the user to tap.
                guidancePill(Text("Finding your location…"))
            }
        }
        .padding(.leading, insets.leading + Metrics.screenMargin)
        .padding(.trailing, insets.trailing + Metrics.screenMargin)
    }

    private func guidancePill(_ text: Text) -> some View {
        text
            .font(.headline)
            .foregroundStyle(.token(.textPrimary))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .floatingGlass(in: .capsule)
            .accessibilityIdentifier("cameraGuidance")
    }

    /// Warnings over the camera, one above the other, then the zoom buttons, nearest the thumb. Only with the camera
    /// allowed: they're about the labels and the camera.
    private var bottomPills: some View {
        VStack(spacing: 8) {
            // Like the list's and the map's banner: the labels are where things were when the data stopped.
            if store.status == .offline {
                offlinePill
            }
            if sensors.cameraAccess == .authorized, !sensors.hasPreciseLocation {
                preciseLocationPill
            }
            if sensors.cameraAccess == .authorized, sensors.hasCameraHeading,
               ARProjection.needsCompassCalibration(headingAccuracyDegrees: sensors.headingAccuracy) {
                accuracyPill
            }
            if sensors.cameraAccess == .authorized {
                zoomAndFilterRow
            }
        }
        // They sit over the camera: past this size they'd wrap over a good part of it.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// The zoom buttons centered and the filter button at the trailing end (`CameraControlsRow`).
    private var zoomAndFilterRow: some View {
        CameraControlsRow {
            // The Camera Control's own dial takes over while it's up.
            if camera.zoomPresets.count > 1, !camera.cameraControlFullscreen {
                ZoomControl(presets: camera.zoomPresets, displayZoom: camera.displayZoom) {
                    camera.setZoom(display: $0, animated: true)
                }
            }
        }
    }

    private var accuracyPill: some View {
        let accuracy = max(0, Int(saturating: sensors.headingAccuracy.rounded()))
        return Text(sensors.headingAccuracy < 0
                    ? "Compass uncalibrated · wave in a figure 8 to improve"
                    : "Compass ±\(accuracy)° · wave in a figure 8 to improve")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.token(.textPrimary))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .floatingGlass(in: .capsule)
            .accessibilityIdentifier("accuracyPill")
    }

    /// The camera's offline notice (`FeedText.cameraNotice`) with Retry, above the other warnings: clear of the
    /// compass strip at the top, the filter button in the row below it and, inside the safe area, the Duo's columns.
    private var offlinePill: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.token(.accent))
                .accessibilityHidden(true)
            Text(FeedText.cameraNotice(store.problem))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.token(.textPrimary))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cameraOfflineText")
            Button("Retry", action: store.retry)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.token(.accent))
                .frame(minWidth: Metrics.minTouch, minHeight: Metrics.minTouch)
                .accessibilityIdentifier("retryButton")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .floatingGlass(in: .rect(cornerRadius: Metrics.surfaceRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cameraOffline")
    }

    /// Approximate location can put every label hundreds of meters off.
    private var preciseLocationPill: some View {
        Text("Precise location is off · labels may be misplaced")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.token(.textPrimary))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .floatingGlass(in: .capsule)
            .accessibilityIdentifier("preciseLocationPill")
    }
}

/// One camera label, a boat or a train, worked out once a second (`VesselARTarget`, `TrainARTarget`, which hold the
/// projection math). A moving boat or train keeps moving between those updates: its estimated position goes on along
/// its course, so the label glides with it.
struct ARItem: Identifiable, Equatable {
    enum Target: Equatable {
        case vessel(VesselARTarget)
        case train(TrainARTarget)
    }

    let target: Target

    var id: TargetID {
        switch target {
        case .vessel(let vessel): .vessel(vessel.id)
        case .train(let train): .train(train.id)
        }
    }

    /// An underground train: an outlined "x-ray" label below the horizon, behind the others.
    var isXray: Bool {
        if case .train(let train) = target { return train.isUnderground }
        return false
    }

    var isMoving: Bool {
        switch target {
        case .vessel(let vessel): vessel.isMoving
        case .train(let train): train.isMoving
        }
    }

    var accessibilityLabel: String {
        switch target {
        case .vessel(let vessel): vessel.accessibilityLabel
        case .train(let train): train.row.accessibilityLabel()
        }
    }

    /// Bearing and distance from the observer at `date`.
    func placement(at date: Date) -> (bearing: Double, distance: Double) {
        switch target {
        case .vessel(let vessel): vessel.placement(at: date)
        case .train(let train): train.placement(at: date)
        }
    }

    /// Where its point (a boat's waterline, a train's rail) lands on screen, seen from the user's eye.
    func place(at date: Date, pose: CameraPose) -> ScreenPlacement {
        switch target {
        case .vessel(let vessel): vessel.place(at: date, pose: pose)
        case .train(let train): train.place(at: date, pose: pose)
        }
    }
}

/// The part of the overlay that follows the compass. It alone reads the heading, so a compass reading redraws the
/// labels and the strip, not the screen.
private struct ARLayer: View {
    @Environment(DeviceSensors.self) private var sensors
    let items: [ARItem]
    let horizontalFOV: Double
    let size: CGSize
    let safeInsets: EdgeInsets
    let focus: TargetID?
    /// "Nothing in sight from here", or why the filter leaves nothing (`CameraFilter.emptyMessage`).
    let emptyText: String
    let spokenEmptyText: String
    let select: (TargetID) -> Void
    /// Moved on ten times a second while anything is moving, so its label glides between the once-a-second
    /// updates. A task, not a TimelineView: this sits inside the overlay's TimelineView, and nested ones redraw the
    /// screen nonstop.
    @State private var now = Date()

    private var anyMoving: Bool { items.contains(where: \.isMoving) }

    var body: some View {
        let pose = CameraPose(headingDegrees: sensors.cameraHeading ?? 0, pitchDegrees: sensors.cameraPitch,
                              horizontalFOVDegrees: horizontalFOV, viewWidth: size.width, viewHeight: size.height)
        ARLabelsLayer(items: items, now: now, pose: pose, focus: focus, safeInsets: safeInsets, select: select)
            .overlay(alignment: .top) {
                CompassStripView(pose: pose, safeInsets: safeInsets)
            }
            .overlay {
                // Underground trains are never in sight: x-ray labels alone don't count.
                if !items.contains(where: { !$0.isXray }) {
                    Text(emptyText)
                        .font(.headline)
                        .foregroundStyle(.token(.textPrimary))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .floatingGlass(in: .capsule)
                        .padding(.horizontal, Metrics.screenMargin)
                        .accessibilityLabel(spokenEmptyText)
                        .accessibilityIdentifier("noBoatsInSight")
                }
            }
            .task(id: anyMoving) {
                guard anyMoving else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    now = Date()
                }
            }
    }
}

/// Labels for what's on screen and "n more" pills for the rest. Boats and trains in sight stack in lanes up from the
/// horizon, nearest lowest; when the lanes between the horizon and the compass strip are full, farther ones show only
/// their dot. Underground trains' x-ray labels stack down from their dots below the horizon, drawn behind the rest.
private struct ARLabelsLayer: View {
    let items: [ARItem]
    /// Where moving boats and trains have got to (`ARItem.placement(at:)`).
    let now: Date
    let pose: CameraPose
    let focus: TargetID?
    /// Labels use the whole view; the "n more" pills stay inside the screen's safe area.
    let safeInsets: EdgeInsets
    let select: (TargetID) -> Void

    @Environment(\.nightMode) private var nightMode
    /// Estimated label sizes for lane layout (labels size to their content); they scale with the text size.
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth = 200.0
    @ScaledMetric(relativeTo: .subheadline) private var labelHeight = 52.0
    // The capsule's width for stacking: bullet, "about 100 ft deep" and the padding (it was 120 for the shorter "50 ft down").
    @ScaledMetric(relativeTo: .caption) private var xrayWidth = 156.0
    @ScaledMetric(relativeTo: .caption) private var xrayHeight = 52.0

    /// Something on screen: its dot (a boat's waterline, a train's rail) and, if it got a lane, where its label sits.
    private struct Anchor: Identifiable {
        let item: ARItem
        let x: Double
        let dotY: Double
        let labelY: Double?
        let distance: Double
        var id: TargetID { item.id }
    }

    /// The horizon, kept where a dot at it stays on screen.
    private var horizon: Double { min(max(ARProjection.horizonY(pose: pose), 120), pose.viewHeight - 120) }

    /// How many lanes fit between a label at the horizon and the compass strip; at least one.
    private var maxLanes: Int {
        let top = safeInsets.top + CompassStripView.topPadding + CompassStripView.height + 8
        let room = horizon - 40 - labelHeight / 2 - top
        return LabelLayout.laneCount(room: room, laneHeight: labelHeight)
    }

    /// How many x-ray lanes fit between the horizon and the zoom buttons; at least one.
    private var maxLanesDown: Int {
        let bottom = pose.viewHeight - 80 - xrayHeight / 2
        let room = bottom - (horizon + 40)
        return LabelLayout.laneCount(room: room, laneHeight: xrayHeight)
    }

    /// Stems and dot rings are white over the live preview; at night they take the red text color (red only).
    private var markColor: Color {
        nightMode ? ColorToken.textPrimary.night : .white
    }

    private func anchors(_ placed: [(item: ARItem, x: Double, y: Double, distance: Double)], width: Double,
                         lanes maxLanes: Int, below: Bool) -> [Anchor] {
        // The focused one goes first, so it always gets a label.
        let lanes = LabelLayout.lanes(for: placed.enumerated().map { index, item in
            LabelSlot(id: index, x: item.x, width: width, distanceMeters: item.item.id == focus ? -1 : item.distance)
        }, maxLanes: maxLanes)
        return placed.enumerated().map { index, item in
            // Keep the dot on screen even when the phone is tilted far up or down.
            let dotY = min(max(item.y, 120), pose.viewHeight - 120)
            let labelY = lanes[index].map { lane in
                below ? dotY + 40 + Double(lane) * (xrayHeight + 8) : dotY - 40 - Double(lane) * (labelHeight + 8)
            }
            return Anchor(item: item.item, x: item.x, dotY: dotY, labelY: labelY, distance: item.distance)
        }
    }

    var body: some View {
        let placed = items.compactMap { item -> (item: ARItem, x: Double, y: Double, distance: Double)? in
            guard case .onScreen(let x, let y) = item.place(at: now, pose: pose) else { return nil }
            return (item, x, y, item.placement(at: now).distance)
        }
        let inSight = anchors(placed.filter { !$0.item.isXray }, width: labelWidth, lanes: maxLanes, below: false)
        let xray = anchors(placed.filter(\.item.isXray), width: xrayWidth, lanes: maxLanesDown, below: true)
        // The hints count what's in sight (and the one asked for), not the x-ray labels.
        let offscreen = items.reduce(into: (left: 0, right: 0)) { count, item in
            guard !item.isXray || item.id == focus,
                  case .offScreen(let side) = item.place(at: now, pose: pose) else { return }
            if side == .left { count.left += 1 } else { count.right += 1 }
        }
        let stemHalf = labelHeight / 2
        let xrayHalf = xrayHeight / 2
        let mark = markColor
        let night = nightMode

        ZStack(alignment: .topLeading) {
            // Every stem and dot in one drawing, under all the labels: a stem passes behind the labels it crosses.
            Canvas { context, _ in
                var faint = context
                faint.opacity = 0.8
                for anchor in xray {
                    let dot = Path(ellipseIn: CGRect(x: anchor.x - 4, y: anchor.dotY - 4, width: 8, height: 8))
                    if let labelY = anchor.labelY {
                        var stem = Path()
                        stem.move(to: CGPoint(x: anchor.x, y: anchor.dotY + 4))
                        stem.addLine(to: CGPoint(x: anchor.x, y: labelY - xrayHalf))
                        faint.stroke(stem, with: .color(mark), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    }
                    faint.stroke(dot, with: .color(mark), lineWidth: 1.5)
                }
                for anchor in inSight {
                    if let labelY = anchor.labelY {
                        var stem = Path()
                        stem.move(to: CGPoint(x: anchor.x, y: labelY + stemHalf))
                        stem.addLine(to: CGPoint(x: anchor.x, y: anchor.dotY))
                        faint.stroke(stem, with: .color(mark), lineWidth: 1.5)
                    }
                    let rect = CGRect(x: anchor.x - 5, y: anchor.dotY - 5, width: 10, height: 10)
                    let dot = Path(ellipseIn: rect)
                    switch anchor.item.target {
                    case .vessel(let vessel) where vessel.category == .firstResponder:
                        // `VesselFill`'s two halves: red on the left, blue on the right.
                        let halves = rect.divided(atDistance: rect.width / 2, from: .minXEdge)
                        for (token, half) in [(ColorToken.responderRed, halves.slice), (.responderBlue, halves.remainder)] {
                            var clipped = context
                            clipped.clip(to: Path(half))
                            clipped.fill(dot, with: .color(night ? token.night : token.day))
                        }
                    case .vessel(let vessel):
                        let fill = ColorToken.vessel(vessel.category)
                        context.fill(dot, with: .color(night ? fill.night : fill.day))
                    case .train(let train):
                        let fill = ColorToken.route(train.row.train.line)
                        context.fill(dot, with: .color(night ? fill.night : fill.day))
                    }
                    context.stroke(dot, with: .color(mark), lineWidth: 2)
                }
            }
            .accessibilityHidden(true)
            // X-ray labels first: drawn behind the labels of what's in sight.
            ForEach(xray) { anchor in
                if let labelY = anchor.labelY, case .train(let train) = anchor.item.target {
                    XrayLabel(target: train, selected: focus == anchor.id, select: select)
                        .position(x: min(max(anchor.x, xrayWidth / 2), pose.viewWidth - xrayWidth / 2), y: labelY)
                }
            }
            ForEach(inSight) { anchor in
                if let labelY = anchor.labelY {
                    ARLabel(item: anchor.item, distance: anchor.distance, selected: focus == anchor.id, select: select)
                        .position(x: min(max(anchor.x, labelWidth / 2), pose.viewWidth - labelWidth / 2), y: labelY)
                }
            }
        }
        .frame(width: pose.viewWidth, height: pose.viewHeight)
        .overlay(alignment: .leading) {
            if offscreen.left > 0 {
                OffscreenPill(text: "‹ \(offscreen.left) more", identifier: "offscreenLeft")
                    .padding(.leading, safeInsets.leading)
            }
        }
        .overlay(alignment: .trailing) {
            if offscreen.right > 0 {
                OffscreenPill(text: "\(offscreen.right) more ›", identifier: "offscreenRight")
                    .padding(.trailing, safeInsets.trailing)
            }
        }
    }
}

/// A label over the camera: type circle or route bullet, name, "14.2 kn · 0.2 mi". The focused one gets a 2pt accent
/// ring.
private struct ARLabel: View {
    let item: ARItem
    /// Meters from the observer now, for the far-label fade.
    let distance: Double
    let selected: Bool
    let select: (TargetID) -> Void

    private var identifier: String {
        switch item.target {
        case .vessel(let vessel): "arLabel-\(vessel.id)"
        case .train(let train): "arLabel-\(train.id)"
        }
    }

    var body: some View {
        Button { select(item.id) } label: {
            switch item.target {
            case .vessel(let vessel):
                ARLabelContent(mark: .vessel(vessel.category), title: vessel.title, detail: vessel.detail,
                               selected: selected)
            case .train(let train):
                ARLabelContent(mark: .train(train.row.train), title: train.row.title, detail: train.row.cameraDetail,
                               selected: selected)
            }
        }
        .buttonStyle(.plain)
        .opacity(ARProjection.labelOpacity(distanceMeters: distance, selected: selected))
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier(identifier)
    }
}

/// The label itself. Plain data, no closures, so SwiftUI skips redrawing it while the label only moves.
private struct ARLabelContent: View {
    enum Mark: Equatable {
        case vessel(VesselCategory)
        case train(Train)
    }

    let mark: Mark
    let title: String
    let detail: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            switch mark {
            case .vessel(let category): TypeBadge(category: category, size: 26)
            case .train(let train): RouteBullet(train: train, size: 26)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(.token(.textPrimary))
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .frame(minHeight: Metrics.minTouch)
        // Solid rather than glass: glass re-samples the live camera behind each label on every frame, and labels
        // are content, not controls.
        .background(.token(.bgRaised), in: .capsule)
        .overlay {
            if selected { Capsule().stroke(.token(.accent), lineWidth: 2) }
        }
    }
}

/// An underground train, seen "through" the ground: its outlined bullet and how far below the street it is ("about 40 ft
/// deep", `TrainRow.xrayDepthText`; "Underground" where there's no ground data under it) over its
/// distance, in a see-through capsule with a dashed outline, so it never reads as something in sight.
private struct XrayLabel: View {
    let target: TrainARTarget
    let selected: Bool
    let select: (TargetID) -> Void

    var body: some View {
        Button { select(.train(target.id)) } label: {
            XrayLabelContent(train: target.row.train, depth: target.row.xrayDepthText,
                             distance: target.row.distanceText ?? "", selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target.row.accessibilityLabel())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier("xrayLabel-\(target.id)")
    }
}

private struct XrayLabelContent: View {
    let train: Train
    let depth: String
    let distance: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            RouteBullet(train: train, size: 22, outlined: true)
            VStack(alignment: .leading, spacing: 0) {
                Text(depth)
                    .font(.caption.bold())
                    .lineLimit(1)
                Text(distance)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .monospacedDigit()
            .foregroundStyle(.token(.textPrimary))
        }
        .padding(.leading, 5)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .frame(minHeight: Metrics.minTouch)
        .background(.token(.bgRaised).opacity(0.55), in: .capsule)
        .overlay {
            if selected {
                Capsule().stroke(.token(.accent), lineWidth: 2)
            } else {
                Capsule().strokeBorder(.token(.textPrimary).opacity(0.8),
                                       style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
    }
}

/// The Camera app's zoom buttons: one per lens (0.5, 1, 5) and 2×. The lit one shows the exact zoom ("1.4×").
private struct ZoomControl: View {
    let presets: [Double]
    let displayZoom: Double
    let select: (Double) -> Void

    var body: some View {
        let active = CameraZoom.activePreset(for: displayZoom, in: presets)
        HStack(spacing: 2) {
            ForEach(presets, id: \.self) { preset in
                let isActive = preset == active
                Button { select(preset) } label: {
                    Text(isActive ? CameraZoom.text(displayZoom) + "×" : CameraZoom.text(preset))
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.token(isActive ? .accent : .textPrimary))
                        .frame(minWidth: Metrics.minTouch, minHeight: Metrics.minTouch)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(CameraZoom.text(preset))x zoom")
                .accessibilityAddTraits(isActive ? .isSelected : [])
                .accessibilityIdentifier("zoom-\(CameraZoom.text(preset))")
            }
        }
        .padding(.horizontal, 6)
        .floatingGlass(in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("zoomControl")
    }
}

private struct OffscreenPill: View {
    let text: String
    let identifier: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.token(.textPrimary))
            .padding(.horizontal, 14)
            .frame(minHeight: Metrics.minTouch)
            // Labels' stems and x-ray leaders pass under the pills: a solid layer under the glass keeps them from
            // showing through it.
            .background(.token(.bgRaised).opacity(0.9), in: .capsule)
            .floatingGlass(in: .capsule)
            .padding(.horizontal, 8)
            .accessibilityIdentifier(identifier)
    }
}

/// Glass capsule at the top: heading as "NW 318°" over ticks that line up with the labels below.
private struct CompassStripView: View {
    let pose: CameraPose
    /// The screen's safe area; the strip sits inside it, below the status bar and clear of the side columns.
    let safeInsets: EdgeInsets

    static let layout = CompassStripLayout.standard
    static let height = layout.height
    static let topPadding = 8.0

    var body: some View {
        let ticks = CompassStrip.ticks(pose: pose)
        let layout = Self.layout
        // The ticks are laid out for the full view width, the strip is inset: shift each tick by the strip's
        // leading offset so it still sits above its bearing.
        let inset = safeInsets.leading + Metrics.screenMargin
        let width = max(0, pose.viewWidth - inset - safeInsets.trailing - Metrics.screenMargin)
        // The camera axis, which the safe area can move off the strip's middle.
        let axis = pose.viewWidth / 2 - inset
        // Rows from `CompassStripLayout`: readout, ticks with the needle, letters; the needle stays in its row.
        ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.degrees) { tick in
                let length = tick.label == nil ? layout.minorTickHeight : layout.majorTickHeight
                Rectangle()
                    .fill(.token(.textSecondary))
                    .frame(width: 1.5, height: length)
                    .position(x: tick.x - inset, y: layout.tickTop + length / 2)
                if let label = tick.label {
                    Text(label)
                        .font(.caption2.bold())
                        .foregroundStyle(.token(.textSecondary))
                        .position(x: tick.x - inset, y: layout.labelCenterY)
                }
            }
            // Center mark: where the camera is pointing.
            Rectangle()
                .fill(.token(.accent))
                .frame(width: 2, height: layout.needleBottom - layout.needleTop)
                .position(x: axis, y: (layout.needleTop + layout.needleBottom) / 2)
                .accessibilityHidden(true)
            Text(VesselText.bearing(degrees: pose.headingDegrees))
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(.token(.textPrimary))
                .position(x: axis, y: layout.headingCenterY)
                .accessibilityIdentifier("compassHeading")
        }
        .frame(width: width, height: Self.height)
        .clipped()
        .floatingGlass(in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compassStrip")
        .padding(.leading, inset)
        .padding(.top, safeInsets.top + Self.topPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
