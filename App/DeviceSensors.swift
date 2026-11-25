import AVFoundation
import BoatCore
import CoreLocation
import CoreMotion
import Observation

/// Location, camera heading/pitch and permissions. The only place the app touches Core Location, Core Motion and
/// camera authorization; views read the published values from the environment.
@MainActor
@Observable
final class DeviceSensors: NSObject {
    enum Access: Equatable {
        case notDetermined, denied, authorized
    }

    private(set) var locationAccess: Access = .notDetermined
    private(set) var cameraAccess: Access = .notDetermined
    /// Latest fix, nil until location is authorized and a fix arrives.
    private(set) var location: CLLocationCoordinate2D?
    /// Meters above sea level from GPS, when it vouches for it to within 15 m; nil until then. Kept through fixes
    /// without one (Wi-Fi fixes indoors have none) and published only when it moves 2 m or more.
    private(set) var altitude: Double?
    /// True heading of the back camera, degrees, smoothed; nil while unknown (no motion data yet, or pointing at the
    /// ground). Changes up to 30 times a second: only the label layer should read it.
    private(set) var cameraHeading: Double?
    /// Elevation of the back camera above the horizon, degrees, smoothed. Changes as often as the heading.
    private(set) var cameraPitch: Double = 0
    /// Whether `cameraHeading` is known. Changes only when that flips, so screens can check it without redrawing on
    /// every compass reading.
    private(set) var hasCameraHeading = false
    /// Compass accuracy in degrees; negative when invalid. Published only when the whole-degree value changes.
    private(set) var headingAccuracy: Double = -1
    /// False when location is allowed but only approximately: fixes can be hundreds of meters off, too coarse to
    /// place labels.
    private(set) var hasPreciseLocation = true

    /// True until location is allowed. Hints use it to offer the permission rather than wait for a fix.
    var needsLocationPermission: Bool { locationAccess != .authorized }

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let motionManager = CMMotionManager()
    @ObservationIgnored private var declination: Double = 0
    @ObservationIgnored private var headingFilter = HeadingFilter()
    @ObservationIgnored private let isFake: Bool
    @ObservationIgnored private var askedForPreciseLocation = false

    /// UI tests pin the sensors through the launch environment; release builds never read it.
    private static var launchFake: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["BOATAR_FAKE_SENSORS"]
        #else
        nil
        #endif
    }

    #if DEBUG
    /// UI tests: BOATAR_FAKE_HEADING_SWEEP=1 turns the pinned heading into a slow pan (±25° every 6 s) updated 30
    /// times a second while the camera is open, like a phone sweeping the river, so the camera's cost can be
    /// measured without hardware.
    private static var launchSweep: Bool {
        ProcessInfo.processInfo.environment["BOATAR_FAKE_HEADING_SWEEP"] == "1"
    }
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    @ObservationIgnored private var sweepCenter: (heading: Double, pitch: Double) = (0, 0)
    @ObservationIgnored private var chaosTask: Task<Void, Never>?

    /// Chaos tests, with the fake sensors only (docs/CHAOS-FINDINGS.md):
    /// - BOATAR_FAKE_HEADING_SPIN=<degrees per second>: the pinned heading turns round and round, 30 times a second,
    ///   while the camera is open (a phone spun on the spot, or a compass gone mad).
    /// - BOATAR_FAKE_LOCATION_JUMP=<seconds>,<lat>,<lon>: the fix jumps there that long after launch.
    /// - BOATAR_FAKE_REDUCED_ACCURACY=1: location allowed, but only approximate.
    private static var launchSpin: Double? {
        ProcessInfo.processInfo.environment["BOATAR_FAKE_HEADING_SPIN"].flatMap(Double.init)
    }

    private func startChaosHooks() {
        let env = ProcessInfo.processInfo.environment
        if env["BOATAR_FAKE_REDUCED_ACCURACY"] == "1", locationAccess == .authorized { hasPreciseLocation = false }
        let jump = env["BOATAR_FAKE_LOCATION_JUMP"]?.split(separator: ",").compactMap { Double($0) } ?? []
        guard jump.count == 3 else { return }
        chaosTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(jump[0]))
            self?.location = CLLocationCoordinate2D(latitude: jump[1], longitude: jump[2])
        }
    }
    #endif

    /// - Parameter fake: "lat,lon,heading,pitch,accuracy[,altitude]" (UI tests: BOATAR_FAKE_SENSORS, debug builds
    ///   only). Pins every reading and reports the camera allowed, so camera-screen layout can be tested without
    ///   hardware. "none,none,..." means no location (location turned down); no altitude means GPS gave none.
    init(fake: String? = DeviceSensors.launchFake) {
        launchMark("DeviceSensors.init")
        let parts = fake?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let values = parts.map { Double($0) }
        // Chaos tests (debug builds): "none" as the heading means the compass gives no heading.
        let noHeading = parts.count > 2 && parts[2] == "none"
        isFake = (5...6).contains(parts.count)
            && values.indices.dropFirst(2).allSatisfy { values[$0] != nil || ($0 == 2 && noHeading) }
        super.init()
        if isFake {
            if let lat = values[0], let lon = values[1] {
                location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                altitude = values.count == 6 ? values[5] : nil
                locationAccess = .authorized
            } else {
                locationAccess = .denied
            }
            cameraHeading = values[2]
            cameraPitch = values[3] ?? 0
            hasCameraHeading = values[2] != nil
            headingAccuracy = values[4] ?? -1
            cameraAccess = .authorized
            #if DEBUG
            sweepCenter = (values[2] ?? 0, values[3] ?? 0)
            startChaosHooks()
            #endif
            return
        }
        locationManager.delegate = self
        // Ten meters for the list and map (their distances are tenths of a mile); best only while the camera shows
        // (`startCameraTracking`), where labels are placed from the fix. Saves battery on the other tabs.
        locationManager.desiredAccuracy = Self.browsingAccuracy
        locationManager.distanceFilter = Self.browsingDistanceFilter
        locationManager.headingFilter = 1
        updateLocationAccess(locationManager.authorizationStatus, accuracy: locationManager.accuracyAuthorization)
        updateCameraAccess()
    }

    /// Shows the location prompt (when in use) and returns at once. The camera is asked for on the Camera tab: asking
    /// for both here stacked system prompts on a phone and the camera answer could stall onboarding indefinitely.
    func requestPermissions() {
        guard !isFake else { return }
        if locationAccess == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    /// Asks for location (when in use) if it hasn't been asked yet. Returns false when it was denied: the caller
    /// sends the user to Settings instead.
    func requestLocation() -> Bool {
        guard !isFake else { return true }
        switch locationAccess {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            return true
        case .authorized: return true
        case .denied: return false
        }
    }

    /// Offers a one-time upgrade to precise location when only approximate was granted: labels placed from a fix
    /// hundreds of meters off point at the wrong boats. Asks once until precision is back, so a "no" isn't nagged.
    func requestPreciseLocationIfNeeded() {
        guard !isFake, !hasPreciseLocation, !askedForPreciseLocation else { return }
        askedForPreciseLocation = true
        locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "CameraLabels")
    }

    /// Asks for the camera if it hasn't been asked yet. Returns whether it's allowed now.
    func requestCamera() async -> Bool {
        guard !isFake else { return true }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        updateCameraAccess()
        return cameraAccess == .authorized
    }

    /// Location accuracy for the list and map, and while the camera shows (docs/CRASH-HUNT.md, F13).
    private static let browsingAccuracy = kCLLocationAccuracyNearestTenMeters
    private static let browsingDistanceFilter: CLLocationDistance = 10
    private static let cameraAccuracy = kCLLocationAccuracyBest
    // Best accuracy reports about once a second, and every report redraws the camera and list.
    private static let cameraDistanceFilter: CLLocationDistance = 5

    /// Whether camera tracking is on. Start and stop have one caller (`ContentView`, from the selected tab and the
    /// scene phase), so a fold that swaps the camera screen can't stop the new screen's updates (F5); repeated calls
    /// do nothing.
    @ObservationIgnored private var isTrackingCamera = false

    /// Camera heading and pitch updates, and best location accuracy; run only while the camera screen is visible.
    func startCameraTracking() {
        guard !isTrackingCamera else { return }
        isTrackingCamera = true
        #if DEBUG
        if isFake, let spin = Self.launchSpin, sweepTask == nil {
            let center = sweepCenter
            let start = Date()
            sweepTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(33))
                    let turned = center.heading + spin * Date().timeIntervalSince(start)
                    let heading = (turned.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
                    self?.publishCamera(heading: heading, pitch: center.pitch)
                }
            }
        }
        if isFake, Self.launchSweep, sweepTask == nil {
            let center = sweepCenter
            let start = Date()
            sweepTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(33))
                    let t = Date().timeIntervalSince(start)
                    let heading = (center.heading + 25 * sin(t * 2 * .pi / 6) + 360).truncatingRemainder(dividingBy: 360)
                    // Through the same filter as the real compass, so the measurement covers it.
                    self?.publishCamera(heading: heading, pitch: center.pitch + 3 * sin(t * 2 * .pi / 4))
                }
            }
        }
        #endif
        guard !isFake else { return }
        locationManager.desiredAccuracy = Self.cameraAccuracy
        locationManager.distanceFilter = Self.cameraDistanceFilter
        guard motionManager.isDeviceMotionAvailable else { return }
        locationManager.startUpdatingHeading()
        motionManager.deviceMotionUpdateInterval = 1.0 / 30
        // A magnetometer-backed frame so `magneticField` is calibrated.
        motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let gravity = DeviceVector(x: motion.gravity.x, y: motion.gravity.y, z: motion.gravity.z)
            let field = motion.magneticField.field
            let magnetic = DeviceVector(x: field.x, y: field.y, z: field.z)
            MainActor.assumeIsolated {
                self?.updateCamera(gravity: gravity, magneticField: magnetic)
            }
        }
    }

    func stopCameraTracking() {
        guard isTrackingCamera else { return }
        isTrackingCamera = false
        #if DEBUG
        sweepTask?.cancel()
        sweepTask = nil
        #endif
        guard !isFake else { return }
        motionManager.stopDeviceMotionUpdates()
        locationManager.stopUpdatingHeading()
        locationManager.desiredAccuracy = Self.browsingAccuracy
        locationManager.distanceFilter = Self.browsingDistanceFilter
    }

    private func updateCamera(gravity: DeviceVector, magneticField: DeviceVector) {
        guard let result = CameraOrientation.cameraHeadingAndPitch(
            gravity: gravity, magneticField: magneticField, declinationDegrees: declination)
        else {
            headingFilter.reset()
            if cameraHeading != nil { cameraHeading = nil }
            if hasCameraHeading { hasCameraHeading = false }
            return
        }
        publishCamera(heading: result.heading, pitch: result.pitch)
    }

    /// Smooths a reading and publishes it only when it moved enough to matter: every published change redraws the
    /// labels, and the raw compass jitters even with the phone held still.
    private func publishCamera(heading: Double, pitch: Double) {
        guard let smoothed = headingFilter.update(heading: heading, pitch: pitch) else { return }
        cameraHeading = smoothed.heading
        cameraPitch = smoothed.pitch
        if !hasCameraHeading { hasCameraHeading = true }
    }

    private func updateLocationAccess(_ status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            locationAccess = .authorized
            locationManager.startUpdatingLocation()
        case .denied, .restricted:
            locationAccess = .denied
            location = nil
        default:
            locationAccess = .notDetermined
        }
        // Approximate only matters once location is allowed; before that the permission hints say what to do.
        hasPreciseLocation = locationAccess != .authorized || accuracy == .fullAccuracy
        if hasPreciseLocation { askedForPreciseLocation = false }
    }

    private func updateCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraAccess = .authorized
        case .denied, .restricted: cameraAccess = .denied
        default: cameraAccess = .notDetermined
        }
    }
}

extension DeviceSensors: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization
        MainActor.assumeIsolated { updateLocationAccess(status, accuracy: accuracy) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        let coordinate = fix.coordinate
        let altitude = fix.verticalAccuracy > 0 && fix.verticalAccuracy <= 15 ? fix.altitude : nil
        MainActor.assumeIsolated {
            location = coordinate
            // Every published change recomputes sightlines; a couple of meters of GPS noise isn't worth it.
            if let altitude, abs(altitude - (self.altitude ?? -.infinity)) >= 2 { self.altitude = altitude }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let accuracy = newHeading.headingAccuracy
        // trueHeading is negative until a location fix allows true north.
        let decl = newHeading.trueHeading >= 0
            ? CameraOrientation.declination(trueHeading: newHeading.trueHeading, magneticHeading: newHeading.magneticHeading)
            : nil
        MainActor.assumeIsolated {
            // Each published change redraws the camera's warning pills; the pill only shows whole degrees.
            if accuracy.rounded() != headingAccuracy.rounded() { headingAccuracy = accuracy }
            if let decl { declination = decl }
        }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        // The camera screen shows its own accuracy pill instead of the system overlay.
        false
    }
}
