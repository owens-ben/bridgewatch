import CoreLocation
import Foundation
import Testing
@testable import BoatCore

@Suite struct NightModeTests {
    let river = CLLocationCoordinate2D(latitude: 40.7046, longitude: -73.9913)
    let noon = try! Date("2026-11-10T17:00:00Z", strategy: .iso8601)
    let midnight = try! Date("2026-11-11T05:00:00Z", strategy: .iso8601)

    @Test func automaticFollowsTheSun() {
        #expect(!NightModeSetting.automatic.isActive(at: noon, location: river))
        #expect(NightModeSetting.automatic.isActive(at: midnight, location: river))
    }

    @Test func automaticWithoutLocationStaysOff() {
        #expect(!NightModeSetting.automatic.isActive(at: midnight, location: nil))
    }

    @Test func manualOverridesIgnoreTheSun() {
        #expect(NightModeSetting.on.isActive(at: noon, location: river))
        #expect(NightModeSetting.on.isActive(at: noon, location: nil))
        #expect(!NightModeSetting.off.isActive(at: midnight, location: river))
    }

    @Test func storedAsStableRawValues() {
        #expect(NightModeSetting.allCases.map(\.rawValue) == ["automatic", "on", "off"])
        #expect(NightModeSetting(rawValue: "on") == .on)
    }
}
