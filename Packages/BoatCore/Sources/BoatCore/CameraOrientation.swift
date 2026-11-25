import Foundation

/// A 3D vector in the device's own frame: x toward the right edge, y toward the top, z out of the screen.
public struct DeviceVector: Sendable, Equatable {
    public var x, y, z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    func dot(_ o: DeviceVector) -> Double { x * o.x + y * o.y + z * o.z }

    func cross(_ o: DeviceVector) -> DeviceVector {
        DeviceVector(x: y * o.z - z * o.y, y: z * o.x - x * o.z, z: x * o.y - y * o.x)
    }

    var length: Double { sqrt(dot(self)) }

    func normalized() -> DeviceVector? {
        let l = length
        guard l > 1e-9 else { return nil }
        return DeviceVector(x: x / l, y: y / l, z: z / l)
    }

    static prefix func - (v: DeviceVector) -> DeviceVector { DeviceVector(x: -v.x, y: -v.y, z: -v.z) }
}

/// Which way the back camera looks, from gravity and the magnetic field (a tilt-compensated compass).
/// Everything is in the device frame, so it holds in any orientation, portrait or landscape.
public enum CameraOrientation {
    /// The back camera looks along -z.
    static let cameraAxis = DeviceVector(x: 0, y: 0, z: -1)

    /// - Parameters:
    ///   - gravity: pointing toward the ground (CMDeviceMotion.gravity), any length.
    ///   - magneticField: the calibrated field (CMDeviceMotion.magneticField.field), any length.
    ///   - declinationDegrees: true north minus magnetic north (east positive), from CLHeading.
    /// - Returns: the camera axis's true heading in [0, 360) and its elevation above the horizon (degrees),
    ///   or nil when the vectors are degenerate (camera pointing straight up or down, or no field).
    public static func cameraHeadingAndPitch(
        gravity: DeviceVector, magneticField: DeviceVector, declinationDegrees: Double = 0
    ) -> (heading: Double, pitch: Double)? {
        guard let up = (-gravity).normalized(),
              let east = magneticField.cross(up).normalized()
        else { return nil }
        let north = up.cross(east)
        let axis = cameraAxis
        let pitch = asin(max(-1, min(1, axis.dot(up)))) * 180 / .pi
        // Straight up or down there is no meaningful heading.
        guard abs(pitch) < 89 else { return nil }
        var heading = atan2(axis.dot(east), axis.dot(north)) * 180 / .pi + declinationDegrees
        heading = (heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return (heading, pitch)
    }

    /// Declination from a heading reading: true minus magnetic, in (-180, 180].
    public static func declination(trueHeading: Double, magneticHeading: Double) -> Double {
        ARProjection.relativeBearing(trueHeading, heading: magneticHeading)
    }
}
