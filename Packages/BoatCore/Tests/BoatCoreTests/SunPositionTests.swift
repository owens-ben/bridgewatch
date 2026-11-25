import CoreLocation
import Foundation
import Testing
@testable import BoatCore

/// Reference values from the `astral` Python library (an independent implementation) for the test location.
@Suite struct SunPositionTests {
    let river = CLLocationCoordinate2D(latitude: 40.7046, longitude: -73.9913)
    let tromso = CLLocationCoordinate2D(latitude: 69.65, longitude: 18.96)

    func utc(_ iso: String) -> Date {
        try! Date(iso, strategy: .iso8601)
    }

    @Test(arguments: [
        ("2026-11-10T17:00:00Z", 31.85),
        ("2026-11-10T03:00:00Z", -58.08),
        ("2026-06-21T16:55:00Z", 72.73),
    ])
    func elevationMatchesReference(time: String, expected: Double) {
        #expect(abs(SunPosition.elevation(at: utc(time), coordinate: river) - expected) < 0.3)
    }

    @Test(arguments: [
        // after, expected transition, becomes night
        ("2026-11-10T00:00:00Z", "2026-11-10T11:37:09Z", false),
        ("2026-11-10T12:00:00Z", "2026-11-10T21:42:05Z", true),
        ("2026-03-20T05:00:00Z", "2026-03-20T10:59:27Z", false),
        ("2026-03-20T12:00:00Z", "2026-03-20T23:07:54Z", true),
        ("2026-12-21T05:00:00Z", "2026-12-21T12:16:45Z", false),
        ("2026-12-21T13:00:00Z", "2026-12-21T21:31:31Z", true),
    ])
    func sunriseAndSunsetMatchReference(after: String, expected: String, becomesNight: Bool) throws {
        let next = try #require(SunPosition.nextTransition(after: utc(after), coordinate: river))
        #expect(abs(next.date.timeIntervalSince(utc(expected))) < 60, "got \(next.date)")
        #expect(next.becomesNight == becomesNight)
    }

    @Test func nightAndDayAtTheRiver() {
        #expect(!SunPosition.isNight(at: utc("2026-11-10T17:00:00Z"), coordinate: river))
        #expect(SunPosition.isNight(at: utc("2026-11-10T03:00:00Z"), coordinate: river))
        // Two minutes either side of sunset.
        #expect(!SunPosition.isNight(at: utc("2026-11-10T21:40:00Z"), coordinate: river))
        #expect(SunPosition.isNight(at: utc("2026-11-10T21:44:00Z"), coordinate: river))
    }

    @Test func polarDayAndNightHaveNoTransition() {
        #expect(SunPosition.elevation(at: utc("2026-06-21T00:00:00Z"), coordinate: tromso) > 3)
        #expect(SunPosition.nextTransition(after: utc("2026-06-21T00:00:00Z"), coordinate: tromso, within: 24 * 3_600) == nil)
        #expect(SunPosition.isNight(at: utc("2026-12-21T12:00:00Z"), coordinate: tromso))
        #expect(SunPosition.nextTransition(after: utc("2026-12-21T00:00:00Z"), coordinate: tromso, within: 24 * 3_600) == nil)
    }
}
