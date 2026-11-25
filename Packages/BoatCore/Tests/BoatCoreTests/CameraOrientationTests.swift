import Foundation
import Testing
@testable import BoatCore

@Suite struct CameraOrientationTests {
    /// Magnetic field around New York: pointing north and steeply down (inclination about 67°).
    func field(north: DeviceVector, down: DeviceVector) -> DeviceVector {
        let h = cos(67 * Double.pi / 180), v = sin(67 * Double.pi / 180)
        return DeviceVector(x: north.x * h + down.x * v, y: north.y * h + down.y * v, z: north.z * h + down.z * v)
    }

    func check(_ result: (heading: Double, pitch: Double)?, heading: Double, pitch: Double,
               sourceLocation: SourceLocation = #_sourceLocation) {
        guard let result else {
            Issue.record("no result", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(ARProjection.relativeBearing(result.heading, heading: heading)) < 1e-6, sourceLocation: sourceLocation)
        #expect(abs(result.pitch - pitch) < 1e-6, sourceLocation: sourceLocation)
    }

    @Test func portraitUprightFacingNorth() {
        // Screen toward the user, so the camera (-z) looks north; down is -y.
        let down = DeviceVector(x: 0, y: -1, z: 0)
        let result = CameraOrientation.cameraHeadingAndPitch(
            gravity: down, magneticField: field(north: DeviceVector(x: 0, y: 0, z: -1), down: down))
        check(result, heading: 0, pitch: 0)
    }

    @Test func portraitUprightFacingEast() {
        // Camera looks east; north is then to the user's left (-x).
        let down = DeviceVector(x: 0, y: -1, z: 0)
        let result = CameraOrientation.cameraHeadingAndPitch(
            gravity: down, magneticField: field(north: DeviceVector(x: -1, y: 0, z: 0), down: down))
        check(result, heading: 90, pitch: 0)
    }

    @Test func landscapeFacingSouthWest() {
        // Landscape left: the device's +x points up, so down is -x. Camera looks along -z.
        let down = DeviceVector(x: -1, y: 0, z: 0)
        // In this pose the device's top edge (+y) points left, so the viewer's right is -y and forward is -z.
        // North sits 225° counter-clockwise from forward when the camera faces SW.
        let angle = -225 * Double.pi / 180
        let north = DeviceVector(x: 0, y: -sin(angle), z: -cos(angle))
        let result = CameraOrientation.cameraHeadingAndPitch(gravity: down, magneticField: field(north: north, down: down))
        check(result, heading: 225, pitch: 0)
    }

    @Test func tiltedUpTwentyDegrees() {
        // Rotate the upright north-facing pose about x so the camera looks 20° above the horizon.
        let t = 20 * Double.pi / 180
        let down = DeviceVector(x: 0, y: -cos(t), z: sin(t))
        let north = DeviceVector(x: 0, y: -sin(t), z: -cos(t))
        let result = CameraOrientation.cameraHeadingAndPitch(gravity: down, magneticField: field(north: north, down: down))
        check(result, heading: 0, pitch: 20)
    }

    @Test func declinationTurnsMagneticIntoTrue() {
        let down = DeviceVector(x: 0, y: -1, z: 0)
        let result = CameraOrientation.cameraHeadingAndPitch(
            gravity: down, magneticField: field(north: DeviceVector(x: 0, y: 0, z: -1), down: down),
            declinationDegrees: -13)
        check(result, heading: 347, pitch: 0)
    }

    @Test func vectorLengthsDoNotMatter() {
        let down = DeviceVector(x: 0, y: -9.81, z: 0)
        let f = field(north: DeviceVector(x: -1, y: 0, z: 0), down: DeviceVector(x: 0, y: -1, z: 0))
        let result = CameraOrientation.cameraHeadingAndPitch(gravity: down, magneticField: DeviceVector(x: f.x * 50, y: f.y * 50, z: f.z * 50))
        check(result, heading: 90, pitch: 0)
    }

    @Test func degenerateInputsGiveNil() {
        // Lying flat, screen up: the camera points at the ground.
        let flat = DeviceVector(x: 0, y: 0, z: -1)
        #expect(CameraOrientation.cameraHeadingAndPitch(
            gravity: flat, magneticField: DeviceVector(x: 0, y: 0.4, z: -0.9)) == nil)
        #expect(CameraOrientation.cameraHeadingAndPitch(
            gravity: DeviceVector(x: 0, y: -1, z: 0), magneticField: DeviceVector(x: 0, y: 0, z: 0)) == nil)
        #expect(CameraOrientation.cameraHeadingAndPitch(
            gravity: DeviceVector(x: 0, y: 0, z: 0), magneticField: DeviceVector(x: 0, y: 0, z: -1)) == nil)
    }

    @Test func declinationFromHeadingReading() {
        #expect(CameraOrientation.declination(trueHeading: 347, magneticHeading: 0) == -13)
        #expect(CameraOrientation.declination(trueHeading: 5, magneticHeading: 355) == 10)
    }
}
