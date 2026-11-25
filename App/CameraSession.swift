@preconcurrency import AVFoundation
import BoatCore
import Observation
import Synchronization
import SwiftUI
import UIKit

/// The back camera, all its lenses as one (ultra wide, wide, telephoto): capture session, zoom, field of view, the
/// Camera Control button, and the preview view. The only file that touches AVFoundation capture and UIKit for the
/// camera; views use `CameraPreview` and the published values.
///
/// One for the app, made at the root and passed down the environment (docs/CRASH-HUNT.md, F3-F5): folding or
/// unfolding the Duo swaps the compact and regular view trees, and a session per `CameraScreen` was rebuilt and
/// configured on the main thread mid-transition, and raced the old one's stop. Whether it runs is decided in one
/// place, `ContentView` (the Camera tab showing, the app not in the background), through `start()` and `stop()`.
/// Everything that touches the capture session runs on `queue`, in order: configuring, starting, stopping and
/// recovering after a runtime error or an interruption. The results reach the main actor afterwards.
@MainActor
@Observable
final class CameraSession {
    /// Typical wide-camera values, used when there is no camera (simulator) so the overlay can still be laid out.
    static let fallbackLongSideFOV = 70.0
    static let fallbackAspect = 4.0 / 3.0

    enum Availability: Equatable {
        /// Not configured yet, or being configured: draw nothing in its place yet.
        case unknown
        case available
        /// No camera (simulator) or no access when last configured; tried again on the next `start()`.
        case unavailable
    }

    private(set) var availability = Availability.unknown
    var isAvailable: Bool { availability == .available }
    /// Field of view along the sensor's long side at the current zoom, degrees.
    var longSideFOV: Double {
        CameraZoom.fieldOfView(baseDegrees: baseLongSideFOV, zoomFactor: zoomFactor)
    }
    /// The same at zoom factor 1, the widest lens (AVCaptureDevice.Format.videoFieldOfView, distortion-corrected).
    private(set) var baseLongSideFOV = fallbackLongSideFOV
    /// Long side / short side of the active format.
    private(set) var aspect = fallbackAspect
    /// `AVCaptureDevice.videoZoomFactor`: 1 is the widest lens. Follows the buttons, pinching and the Camera
    /// Control alike.
    private(set) var zoomFactor = 1.0
    /// Displayed zoom per zoom factor: 0.5 with an ultra wide, whose factor 2 is the Camera app's 1×.
    private(set) var displayMultiplier = 1.0
    private(set) var minZoomFactor = 1.0
    private(set) var maxZoomFactor = 1.0
    /// Zoom buttons, in displayed zoom (0.5, 1, 2, 5); empty without a camera.
    private(set) var zoomPresets: [Double] = []
    /// True while the Camera Control's overlay is on screen: the app's own zoom buttons step aside for it.
    private(set) var cameraControlFullscreen = false

    /// The zoom as the Camera app shows it (0.5×, 1×, 5×).
    var displayZoom: Double { zoomFactor * displayMultiplier }
    /// Rotation, in degrees, that keeps the preview level with the horizon (0, 90, 180 or 270). Reported by the
    /// preview view; nil while there is no preview.
    fileprivate(set) var previewRotationAngle: Double?

    /// Whether the sensor's long side runs up the screen. The view's shape can't say: the Duo unfolded is a wide
    /// view over a sensor that is still upright. Nil until the preview reports its angle.
    var longSideIsVertical: Bool? {
        previewRotationAngle.map { $0 == 90 || $0 == 270 }
    }

    /// Made on the first `start()`, not with the app: a launch that never opens the Camera tab never touches
    /// AVFoundation capture (as before one session was shared).
    @ObservationIgnored private var createdSession: AVCaptureSession?
    var session: AVCaptureSession {
        if let createdSession { return createdSession }
        let session = AVCaptureSession()
        createdSession = session
        observeRecovery(of: session)
        return session
    }
    @ObservationIgnored private(set) var device: AVCaptureDevice?
    @ObservationIgnored private let queue = DispatchQueue(label: "boatar.camera")
    /// Whether the app wants the session running: set on the main actor, read on `queue` when recovering.
    @ObservationIgnored private let wanted = RunFlag()
    @ObservationIgnored private var configuring = false
    @ObservationIgnored private var retryAfterConfigure = false
    @ObservationIgnored private var zoomObservation: NSKeyValueObservation?
    @ObservationIgnored private var controlsDelegate: CameraControlsDelegate?
    @ObservationIgnored private var notificationTokens: [any NSObjectProtocol] = []

    #if DEBUG
    /// UI tests: BOATAR_FAKE_ZOOM=1 gives the simulator, which has no camera, an ultra wide/wide/5× telephoto
    /// camera's zoom buttons and fields of view, so zooming can be tested.
    @ObservationIgnored private var fakeZoom = ProcessInfo.processInfo.environment["BOATAR_FAKE_ZOOM"] == "1"
    #endif

    isolated deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    /// Runs the session, configuring it first if it isn't yet (retried on each start: access may have been granted
    /// since the last time). Cheap to call again while running.
    func start() {
        #if DEBUG
        if fakeZoom, !isAvailable, zoomPresets.isEmpty {
            // A 4:3 sensor's ~109° ultra wide is the main camera's 70° (`fallbackLongSideFOV`) at 1×.
            baseLongSideFOV = 2 * atan(tan(Self.fallbackLongSideFOV * .pi / 360) * 2) * 180 / .pi
            displayMultiplier = 0.5
            maxZoomFactor = 20
            zoomPresets = CameraZoom.presets(switchOverFactors: [2, 10], displayMultiplier: 0.5, maxFactor: 20)
            zoomFactor = 2
        }
        #endif
        wanted.set(true)
        if configuring {
            // Access may have been granted after the configuration in flight checked it: try again once it's done.
            retryAfterConfigure = true
        } else if availability != .available {
            // Allowed now: draw nothing while configuring rather than "No camera on this device" left from a
            // configuration without access. (Without access it stays unavailable, so the simulator doesn't flicker.)
            if availability == .unavailable, AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                availability = .unknown
            }
            configure()
        }
        let session = session
        // After the configuration queued above, if any: the queue is serial.
        queue.async { if !session.inputs.isEmpty, !session.isRunning { session.startRunning() } }
    }

    func stop() {
        wanted.set(false)
        guard let session = createdSession else { return }
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    /// Zooms to a displayed zoom (0.5, 1, 5...): smoothly from the buttons, at once while pinching.
    func setZoom(display: Double, animated: Bool) {
        guard display.isFinite, displayMultiplier > 0 else { return }
        let factor = min(max(display / displayMultiplier, minZoomFactor), maxZoomFactor)
        guard let device else {
            #if DEBUG
            if fakeZoom { zoomFactor = factor }
            #endif
            return
        }
        queue.async { Self.zoom(device, to: factor, animated: animated) }
    }

    nonisolated private static func zoom(_ device: AVCaptureDevice, to factor: Double, animated: Bool) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        if animated {
            device.ramp(toVideoZoomFactor: CGFloat(factor), withRate: 8)
        } else {
            device.videoZoomFactor = CGFloat(factor)
        }
        device.unlockForConfiguration()
    }

    /// The richest back camera there is: ultra wide + wide + telephoto, then ultra wide + wide, then wide alone.
    nonisolated private static func backCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
                                                   .builtInWideAngleCamera]
        return types.lazy.compactMap { AVCaptureDevice.default($0, for: .video, position: .back) }.first
    }

    /// What configuring found, handed from `queue` to the main actor.
    private struct Configuration {
        let device: AVCaptureDevice
        let baseLongSideFOV: Double
        let aspect: Double?
        let displayMultiplier: Double
        let minZoomFactor: Double
        let maxZoomFactor: Double
        let zoomPresets: [Double]
        let zoomObservation: NSKeyValueObservation
        let controlsDelegate: CameraControlsDelegate?
    }

    /// Configures the session on `queue` (opening the camera blocks for tens to hundreds of ms) and publishes the
    /// result on the main actor.
    private func configure() {
        configuring = true
        let session = session, queue = queue
        // Built here, on the main actor, so they aren't taken to be the queue's code; they hop back on their own.
        let zoomUpdates = LatestValue<Double>()
        let onZoom: @Sendable (Double) -> Void = { [weak self] factor in
            guard zoomUpdates.post(factor) else { return }
            Task { @MainActor in
                if let latest = zoomUpdates.take() { self?.zoomFactor = latest }
            }
        }
        let onFullscreen: @Sendable (Bool) -> Void = { [weak self] fullscreen in
            Task { @MainActor in self?.cameraControlFullscreen = fullscreen }
        }
        queue.async { [weak self] in
            let configuration = Self.configure(session, queue: queue, onZoom: onZoom, onFullscreen: onFullscreen)
            Task { @MainActor in self?.apply(configuration) }
        }
    }

    private func apply(_ configuration: Configuration?) {
        configuring = false
        let retry = retryAfterConfigure
        retryAfterConfigure = false
        guard let configuration else {
            availability = .unavailable
            if retry, wanted.isSet { start() }
            return
        }
        device = configuration.device
        baseLongSideFOV = configuration.baseLongSideFOV
        if let aspect = configuration.aspect { self.aspect = aspect }
        displayMultiplier = configuration.displayMultiplier
        minZoomFactor = configuration.minZoomFactor
        maxZoomFactor = configuration.maxZoomFactor
        zoomPresets = configuration.zoomPresets
        zoomObservation = configuration.zoomObservation
        controlsDelegate = configuration.controlsDelegate
        availability = .available
    }

    /// Runs on `queue`. Nil when the camera isn't allowed or there is none; nothing is added to the session then.
    nonisolated private static func configure(
        _ session: AVCaptureSession, queue: DispatchQueue, onZoom: @escaping @Sendable (Double) -> Void,
        onFullscreen: @escaping @Sendable (Bool) -> Void
    ) -> Configuration? {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = backCamera(),
              let input = try? AVCaptureDeviceInput(device: device),
              // An empty session would count as available and stay black, never configured again.
              session.canAddInput(input)
        else { return nil }
        session.beginConfiguration()
        session.sessionPreset = .high
        session.addInput(input)
        let delegate = addCameraControl(to: session, for: device, queue: queue, onFullscreen: onFullscreen)
        session.commitConfiguration()

        let format = device.activeFormat
        let base = Double(device.isGeometricDistortionCorrectionEnabled
                          ? format.geometricDistortionCorrectedVideoFieldOfView : format.videoFieldOfView)
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let aspect = dims.width > 0 && dims.height > 0
            ? Double(max(dims.width, dims.height)) / Double(min(dims.width, dims.height)) : nil
        let multiplier = Double(device.displayVideoZoomFactorMultiplier)
        let minFactor = Double(device.minAvailableVideoZoomFactor)
        let maxFactor = multiplier > 0
            ? min(Double(device.maxAvailableVideoZoomFactor), CameraZoom.maxDisplayZoom / multiplier)
            : Double(device.maxAvailableVideoZoomFactor)
        let presets = CameraZoom.presets(
            switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue),
            displayMultiplier: multiplier, maxFactor: maxFactor)
        let observation = device.observe(\.videoZoomFactor, options: [.initial, .new]) { device, _ in
            onZoom(Double(device.videoZoomFactor))
        }
        // Start where the Camera app does: 1×, the main camera.
        if multiplier > 0 { zoom(device, to: min(max(1 / multiplier, minFactor), maxFactor), animated: false) }
        return Configuration(device: device, baseLongSideFOV: base, aspect: aspect, displayMultiplier: multiplier,
                             minZoomFactor: minFactor, maxZoomFactor: maxFactor, zoomPresets: presets,
                             zoomObservation: observation, controlsDelegate: delegate)
    }

    /// The Camera Control button (iPhone 16 and later): a light press and slide zooms, with the system's own dial.
    /// The slider changes the device's zoom itself; the zoom observation picks the change up. Runs on `queue`,
    /// inside the session's configuration.
    nonisolated private static func addCameraControl(
        to session: AVCaptureSession, for device: AVCaptureDevice, queue: DispatchQueue,
        onFullscreen: @escaping @Sendable (Bool) -> Void
    ) -> CameraControlsDelegate? {
        guard session.supportsControls else { return nil }
        let delegate = CameraControlsDelegate(fullscreen: onFullscreen)
        session.setControlsDelegate(delegate, queue: queue)
        let zoom = AVCaptureSystemZoomSlider(device: device)
        if session.canAddControl(zoom) { session.addControl(zoom) }
        return delegate
    }

    /// A runtime error (media services reset, among others) stops the session, and an interruption (a phone call,
    /// another app taking the camera, Split View) can leave it stopped: restart it on `queue` if it's still wanted.
    /// A second later, so an error that repeats at once doesn't spin.
    private func observeRecovery(of session: AVCaptureSession) {
        let queue = queue, wanted = wanted
        let recover: @Sendable (Notification) -> Void = { _ in
            queue.asyncAfter(deadline: .now() + 1) {
                if wanted.isSet, !session.inputs.isEmpty, !session.isRunning { session.startRunning() }
            }
        }
        notificationTokens = [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.interruptionEndedNotification]
            .map { NotificationCenter.default.addObserver(forName: $0, object: session, queue: nil, using: recover) }
    }
}

/// Whether the camera should be running: written on the main actor, read on the camera queue.
private final class RunFlag: Sendable {
    private let value = Atomic(false)

    var isSet: Bool { value.load(ordering: .sequentiallyConsistent) }

    func set(_ new: Bool) {
        value.store(new, ordering: .sequentiallyConsistent)
    }
}

/// Tells the session when the Camera Control's overlay takes over the screen and when it leaves.
private final class CameraControlsDelegate: NSObject, AVCaptureSessionControlsDelegate {
    let fullscreen: @Sendable (Bool) -> Void

    init(fullscreen: @escaping @Sendable (Bool) -> Void) {
        self.fullscreen = fullscreen
    }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) { fullscreen(true) }
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) { fullscreen(false) }
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}

/// Aspect-fill camera preview, kept level with the horizon as the device rotates.
struct CameraPreview: UIViewRepresentable {
    let camera: CameraSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let device = camera.device {
            view.follow(device: device, reportingTo: camera)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    /// The session outlives this view (a fold replaces the view, not the session): let go of it.
    static func dismantleUIView(_ uiView: PreviewView, coordinator: ()) {
        uiView.previewLayer.session = nil
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private var coordinator: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?

        /// Levels the preview now and on every change, and tells `camera` the angle: it can't derive which way the
        /// sensor is turned from the view's shape.
        func follow(device: AVCaptureDevice, reportingTo camera: CameraSession) {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            self.coordinator = coordinator
            let initial = coordinator.videoRotationAngleForHorizonLevelPreview
            previewLayer.connection?.videoRotationAngle = initial
            // This runs inside a SwiftUI update, which must not change observed state: report on the next turn.
            DispatchQueue.main.async { camera.previewRotationAngle = Double(initial) }
            observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) {
                [weak self, weak camera] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async {
                    self?.previewLayer.connection?.videoRotationAngle = angle
                    camera?.previewRotationAngle = Double(angle)
                }
            }
        }
    }
}
