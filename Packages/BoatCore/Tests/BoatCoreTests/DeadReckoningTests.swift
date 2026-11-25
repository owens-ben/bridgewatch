import CoreLocation
import Foundation
import Testing
@testable import BoatCore

@Suite struct DeadReckoningTests {
    let reported = Date(timeIntervalSince1970: 1_794_319_200)

    func vessel(sog: Double?, cog: Double?) -> Vessel {
        testVessel(mmsi: 1, lat: testObserver.latitude, lon: testObserver.longitude, sog: sog, cog: cog,
                   timestamp: reported)
    }

    func moved(_ vessel: Vessel, after seconds: TimeInterval) -> (east: Double, north: Double) {
        offset(from: testObserver, to: DeadReckoning.position(of: vessel, at: reported.addingTimeInterval(seconds)))
    }

    @Test func coversSpeedTimesTimeAlongTheCourse() {
        // 10 knots due east for a minute: 308.7 m.
        let east = moved(vessel(sog: 10, cog: 90), after: 60)
        #expect(abs(east.east - 308.67) < 0.5)
        #expect(abs(east.north) < 0.5)
        let southwest = moved(vessel(sog: 10, cog: 225), after: 60)
        #expect(abs(southwest.east + 218.26) < 0.5)
        #expect(abs(southwest.north + 218.26) < 0.5)
    }

    @Test func stoppedOrUnknownStaysPut() {
        for v in [vessel(sog: 0.3, cog: 90), vessel(sog: nil, cog: 90), vessel(sog: 10, cog: nil)] {
            let offset = moved(v, after: 60)
            #expect(offset.east == 0 && offset.north == 0)
        }
    }

    @Test func carriedForwardAtMostTwoMinutes() {
        let v = vessel(sog: 10, cog: 0)
        #expect(abs(moved(v, after: 600).north - moved(v, after: 120).north) < 1e-6)
        #expect(abs(moved(v, after: 120).north - 617.33) < 0.5)
        #expect(DeadReckoning.extrapolation(for: v, at: reported.addingTimeInterval(600)) == 120)
    }

    @Test func neverBackwards() {
        // A report stamped a few seconds ahead of the phone's clock.
        let offset = moved(vessel(sog: 10, cog: 90), after: -5)
        #expect(offset.east == 0 && offset.north == 0)
    }

    @Test func rowsMeasureToTheEstimatedPosition() {
        // Heading straight away from the observer at 12 knots: a minute later it's ~370 m further.
        let v = vessel(sog: 12, cog: 90)
        let open = Sightlines(surface: .flat)
        let now = VesselRow(vessel: v, observer: testObserver, now: reported, sightlines: open)
        let later = VesselRow(vessel: v, observer: testObserver, now: reported.addingTimeInterval(60), sightlines: open)
        #expect((now.distanceMeters ?? -1) < 1)
        #expect(abs((later.distanceMeters ?? 0) - 370.4) < 1)
        #expect(abs((later.bearingDegrees ?? 0) - 90) < 0.1)
        // The report itself is untouched.
        #expect(later.vessel.coordinate.longitude == testObserver.longitude)
    }

    @Test func offsetAndMovedAreInverses() {
        let there = BoatCore.moved(testObserver, east: 1_234, north: -567)
        let back = offset(from: testObserver, to: there)
        #expect(abs(back.east - 1_234) < 1e-6)
        #expect(abs(back.north + 567) < 1e-6)
    }
}
