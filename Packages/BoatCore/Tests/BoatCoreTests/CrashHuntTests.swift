import CoreLocation
import Foundation
import Testing
@testable import BoatCore

/// Tests for findings in docs/CRASH-HUNT.md. They were written failing (wrapped in `withKnownIssue`); each fix removed
/// its wrapper, so they now guard the fixes.
///
/// The trap tests are exit tests: the body runs in a child process, and a Swift runtime trap there shows up as an
/// abnormal exit instead of killing the test run.
@Suite struct CrashHuntTests {
    // MARK: F2: a course or heading too large for Int traps the list, detail and camera text

    /// F2. `Vessel.init` keeps `course` as sent and checks `heading` only for being finite; `VesselText.bearing` then
    /// does `Int(degrees.rounded())`, which traps past ±2^63. The relay's normalizer keeps `cog`/`heading` in [0, 360),
    /// but the app connects to whatever relay is typed into Settings, and `Train.init` already rejects bad values of
    /// its own kind, so the vessel side is the odd one out.
    @Test func vesselCourseFromRelayDoesNotTrapTheListText() async {
        await #expect(processExitsWith: .success) {
            let frame = #"{"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"x","lat":40.705,"lon":-73.99,"course":1e19,"timestamp":"2026-11-10T14:00:00.000Z","vessel":{"mmsi":1}}}"#
            var registry = TargetRegistry()
            registry.apply(try RelayMessage.decode(Data(frame.utf8)))
            guard let vessel = registry.vessels.first else { return }
            let row = VesselRow(vessel: vessel, observer: nil, now: vessel.lastSeen)
            _ = row.courseText
        }
    }

    /// F2, the heading path: `headingText` checks `isFinite`, which 1e19 passes.
    @Test func vesselHeadingFromRelayDoesNotTrapTheDetailText() async {
        await #expect(processExitsWith: .success) {
            let frame = #"{"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"x","lat":40.705,"lon":-73.99,"heading":-1e19,"timestamp":"2026-11-10T14:00:00.000Z","vessel":{"mmsi":1}}}"#
            var registry = TargetRegistry()
            registry.apply(try RelayMessage.decode(Data(frame.utf8)))
            guard let vessel = registry.vessels.first else { return }
            _ = VesselRow(vessel: vessel, observer: nil, now: vessel.lastSeen).headingText
        }
    }

    /// F2, the train path: `Train.init` rejects a non-finite course but not a huge one; `TrainRow.courseText` traps.
    @Test func trainCourseFromRelayDoesNotTrapTheListText() async {
        await #expect(processExitsWith: .success) {
            let frame = #"{"type":"update","target":{"id":"train:nyct:1","kind":"train","source":"x","lat":40.7,"lon":-73.99,"altitude":20,"speed":10,"course":1e300,"timestamp":"2026-11-10T14:00:00.000Z","train":{"route":"Q","direction":"S","stretch":"manhattan-bridge","underground":false}}}"#
            var registry = TargetRegistry()
            registry.apply(try RelayMessage.decode(Data(frame.utf8)))
            guard let train = registry.trains.first else { return }
            _ = TrainRow(train: train, observer: nil, now: train.timestamp).courseText
        }
    }

    /// F2, the map path's root cause: a vessel whose position can't be real is accepted (a train with the same
    /// position is not). Selecting it pans the map to `MKCoordinateRegion(center:)` with that center
    /// (VesselMapScreen.swift:334), which MapKit rejects.
    @Test func vesselWithImpossiblePositionIsNotAccepted() throws {
        let target = vesselTarget(1, lat: 200, lon: -73.99, timestamp: try date("2026-11-10T14:00:00.000Z"))
        #expect(Vessel(target) == nil)
    }

    /// F2 fix: a vessel takes `course` and `heading` into [0, 360) and drops them when they aren't finite; one with an
    /// impossible position isn't held by the registry at all.
    @Test func vesselCourseAndHeadingAreNormalized() throws {
        let time = try date("2026-11-10T14:00:00.000Z")
        let vessel = try #require(Vessel(vesselTarget(1, course: 1e19, heading: -10, timestamp: time)))
        let cog = try #require(vessel.cog)
        #expect(cog >= 0 && cog < 360)
        #expect(vessel.heading == 350)
        #expect(Vessel(vesselTarget(1, course: 370, heading: 360, timestamp: time))?.cog == 10)
        #expect(Vessel(vesselTarget(1, course: 370, heading: 360, timestamp: time))?.heading == 0)
        #expect(Vessel(vesselTarget(1, course: .nan, heading: .infinity, timestamp: time))?.cog == nil)
        #expect(Vessel(vesselTarget(1, course: .nan, heading: .infinity, timestamp: time))?.heading == nil)
        #expect(Vessel(vesselTarget(1, course: 90, timestamp: time))?.cog == 90)
        for (lat, lon) in [(91.0, 0.0), (0, 181), (.nan, 0), (0, .infinity)] {
            #expect(Vessel(vesselTarget(1, lat: lat, lon: lon, timestamp: time)) == nil)
        }
        var registry = TargetRegistry()
        registry.apply(.update(vesselTarget(1, lat: 200, lon: -73.99, timestamp: time)))
        #expect(registry.count == 0)
    }

    /// F2 fix: a train's course is brought into [0, 360) too.
    @Test func trainCourseIsNormalized() throws {
        let time = try date("2026-11-10T14:00:00.000Z")
        let train = try #require(Train(trainTarget("1", course: -90, timestamp: time)))
        #expect(train.course == 270)
        let huge = try #require(Train(trainTarget("1", course: 1e300, timestamp: time)))
        #expect(huge.course.map { $0 >= 0 && $0 < 360 } == true)
    }

    /// F2 fix: the bearing text is total.
    @Test func bearingTextIsTotal() {
        #expect(VesselText.bearing(degrees: 318) == "NW 318°")
        #expect(VesselText.bearing(degrees: -42) == "NW 318°")
        #expect(VesselText.bearing(degrees: 359.7) == "N 0°")
        #expect(VesselText.bearing(degrees: 1e19).hasSuffix("°"))
        #expect(VesselText.bearing(degrees: .nan) == "")
        #expect(VesselText.bearing(degrees: -.infinity) == "")
        #expect(VesselText.spokenBearing(degrees: .nan) == "")
        #expect(VesselText.spokenBearing(degrees: 725) == "north")
        #expect(VesselText.age(seconds: .infinity) == "\(Int(saturating: Double.infinity) / 3600) h ago")
    }

    /// The sweep's helper: never traps.
    @Test func saturatingIntConversion() {
        #expect(Int(saturating: 3.9) == 3)
        #expect(Int(saturating: -3.9) == -3)
        #expect(Int(saturating: .nan) == 0)
        #expect(Int(saturating: .infinity) == 9_007_199_254_740_992)
        #expect(Int(saturating: -1e300) == -9_007_199_254_740_992)
        #expect(normalizedDegrees(-1e-15) == 0)
        #expect(normalizedDegrees(720) == 0)
        #expect(normalizedDegrees(.nan) == nil)
    }

    /// The sweep: the compass strip is empty rather than trapping when the heading isn't finite.
    @Test func compassTicksForNonFiniteHeading() {
        let pose = CameraPose(headingDegrees: .nan, pitchDegrees: 0, horizontalFOVDegrees: 60, viewWidth: 400,
                              viewHeight: 800)
        #expect(CompassStrip.ticks(pose: pose).isEmpty)
    }

    // MARK: F12: a target timestamped in the future

    /// F12 fix: a target from a clock running far ahead is held as if timestamped `maxFutureLead` after it arrived,
    /// so prune drops it at most that plus its max age after it arrived (before, a negative age kept it for the whole
    /// connection). A smaller lead is kept as sent.
    @Test func futureTimestampIsClampedToTheTimeReceived() throws {
        let received = try date("2026-11-10T14:00:00.000Z")
        let lead = TargetRegistry.maxFutureLead
        let farAhead = received.addingTimeInterval(24 * 3_600)
        var registry = TargetRegistry()
        registry.apply(.update(vesselTarget(1, timestamp: farAhead)), receivedAt: received)
        registry.apply(.update(trainTarget("a", timestamp: farAhead)), receivedAt: received)
        registry.apply(.update(vesselTarget(2, timestamp: received.addingTimeInterval(600))), receivedAt: received)
        #expect(registry.vessels.first { $0.mmsi == 1 }?.lastSeen == received.addingTimeInterval(lead))
        #expect(registry.vessels.first { $0.mmsi == 2 }?.lastSeen == received.addingTimeInterval(600))
        #expect(registry.trains.first?.timestamp == received.addingTimeInterval(lead))

        registry.prune(now: received.addingTimeInterval(lead + TargetRegistry.trainMaxAge + 1))
        #expect(registry.trains.isEmpty)
        #expect(registry.vessels.count == 2)
        registry.prune(now: received.addingTimeInterval(lead + TargetRegistry.vesselMaxAge + 1))
        #expect(registry.vessels.isEmpty)
    }

    // MARK: F14: one vessel per MMSI

    /// F14 fix: two targets with different ids and one MMSI publish one vessel, the newer.
    @Test func oneVesselPerMMSI() throws {
        let time = try date("2026-11-10T14:00:00.000Z")
        func target(_ id: String, seconds: TimeInterval, name: String) -> Target {
            Target(id: id, kind: .vessel, source: "x", name: name, lat: 40.705, lon: -73.99,
                   timestamp: time.addingTimeInterval(seconds), vessel: VesselDetails(mmsi: 7))
        }
        var registry = TargetRegistry()
        registry.apply(.update(target("vessel:7", seconds: 10, name: "NEWER")), receivedAt: time.addingTimeInterval(60))
        registry.apply(.update(target("other:7", seconds: 0, name: "OLDER")), receivedAt: time.addingTimeInterval(60))
        registry.apply(.update(vesselTarget(8, timestamp: time)), receivedAt: time.addingTimeInterval(60))
        #expect(registry.vessels.map(\.mmsi) == [7, 8])
        #expect(registry.vessels.first?.name == "NEWER")
        // A tie keeps the lower id.
        registry.apply(.update(target("other:7", seconds: 10, name: "TIE")), receivedAt: time.addingTimeInterval(60))
        #expect(registry.vessels.first?.name == "TIE")
    }

    // MARK: F7: the horizon is NaN with a zero field of view and a level camera

    /// F7. With `horizontalFOVDegrees` 0 the vertical FOV is 0 and `horizonY` divides tan(pitch) by tan(0): pitch 0
    /// gives 0/0 = NaN. CameraScreen.swift:463-476 clamps it with min/max (which pass NaN through) and then does
    /// `Int(room / ...)`, which traps.
    @Test func horizonIsFiniteForZeroFieldOfView() {
        let pose = CameraPose(headingDegrees: 0, pitchDegrees: 0, horizontalFOVDegrees: 0, viewWidth: 400,
                              viewHeight: 800)
        #expect(ARProjection.horizonY(pose: pose) == 400)
        let noHeight = CameraPose(headingDegrees: 0, pitchDegrees: .nan, horizontalFOVDegrees: 60, viewWidth: 400,
                                  viewHeight: 800)
        #expect(ARProjection.horizonY(pose: noHeight) == 400)
        let flat = CameraPose(headingDegrees: 0, pitchDegrees: 0, horizontalFOVDegrees: 60, viewWidth: 0,
                              viewHeight: 0)
        #expect(ARProjection.horizonY(pose: flat).isFinite)
    }

    /// F7 fix: `place` gives a finite y for a view with no vertical field of view.
    @Test func placeIsFiniteWithoutVerticalFieldOfView() {
        let pose = CameraPose(headingDegrees: 0, pitchDegrees: 0, horizontalFOVDegrees: 60, viewWidth: 400,
                              viewHeight: 0)
        guard case .onScreen(let x, let y) = ARProjection.place(bearingDegrees: 0, distanceMeters: 1_000, pose: pose)
        else { Issue.record("expected on screen"); return }
        #expect(x.isFinite && y.isFinite)
    }

    /// F7 fix: the camera's lane counts, moved from view math to BoatCore, are at least one and never trap.
    @Test func laneCountIsTotal() {
        #expect(LabelLayout.laneCount(room: 120, laneHeight: 52) == 3)
        #expect(LabelLayout.laneCount(room: -40, laneHeight: 52) == 1)
        #expect(LabelLayout.laneCount(room: .nan, laneHeight: 52) == 1)
        #expect(LabelLayout.laneCount(room: .infinity, laneHeight: 52) == 1)
        #expect(LabelLayout.laneCount(room: 100, laneHeight: -8) == 1)
    }

    // MARK: F8: zoom text traps on a non-finite zoom

    /// F8. `CameraZoom.text` does `String(Int(tenths))` once `tenths == tenths.rounded()`, which infinity satisfies.
    @Test func zoomTextDoesNotTrapOnNonFiniteZoom() async {
        await #expect(processExitsWith: .success) {
            _ = CameraZoom.text(.infinity)
            _ = CameraZoom.text(-.infinity)
            _ = CameraZoom.text(.nan)
            _ = CameraZoom.text(1e300)
        }
        #expect(CameraZoom.text(.infinity) == "")
        #expect(CameraZoom.text(.nan) == "")
        #expect(CameraZoom.text(2) == "2")
        #expect(CameraZoom.text(1.44) == "1.4")
    }
}
