import Foundation
import Testing
@testable import BoatCore

@Suite struct VesselCategoryTests {
    @Test(arguments: [60, 61, 65, 69])
    func passengerIs60to69(_ type: Int) {
        #expect(VesselCategory(aisShipType: type) == .passenger)
    }

    @Test(arguments: [70, 75, 79, 80, 84, 89])
    func cargoAndTankerAre70to89(_ type: Int) {
        #expect(VesselCategory(aisShipType: type) == .cargo)
    }

    @Test(arguments: [31, 32, 33, 34])
    func towingDredgingAndDivingAreService(_ type: Int) {
        #expect(VesselCategory(aisShipType: type) == .service)
    }

    /// Pilots, tugs, port tenders, pollution control, the local-use codes and neutral state vessels.
    @Test(arguments: [50, 52, 53, 54, 56, 57, 59])
    func otherSpecialCraftAreService(_ type: Int) {
        #expect(VesselCategory(aisShipType: type) == .service)
    }

    /// Military ops, search and rescue, law enforcement, medical transport.
    @Test(arguments: [35, 51, 55, 58])
    func emergencyAndEnforcementAreFirstResponders(_ type: Int) {
        #expect(VesselCategory(aisShipType: type) == .firstResponder)
    }

    @Test(arguments: [36, 37])
    func sailingAndPleasureAre36and37(_ type: Int) {
        #expect(VesselCategory(aisShipType: type) == .pleasure)
    }

    @Test(arguments: [nil, 0, 1, 20, 29, 30, 38, 39, 40, 49, 90, 99, 100, -1] as [Int?])
    func everythingElseIsOther(_ type: Int?) {
        #expect(VesselCategory(aisShipType: type) == .other)
    }

    @Test func symbolsAndNightLetters() {
        #expect(VesselCategory.allCases.map(\.symbolName)
            == ["ferry.fill", "shippingbox.fill", "wrench.fill", "light.beacon.max.fill", "sailboat.fill", "circle.fill"])
        #expect(VesselCategory.allCases.map(\.nightLetter) == ["P", "C", "T", "R", "S", "?"])
        // Night letters tell the groups apart on their own.
        #expect(Set(VesselCategory.allCases.map(\.nightLetter)).count == VesselCategory.allCases.count)
    }

    /// Stored in the camera filter and used in UI-test identifiers: renaming a group must not change these.
    @Test func rawValuesAreStable() {
        #expect(VesselCategory.allCases.map(\.rawValue)
            == ["passenger", "cargo", "tug", "firstResponder", "pleasure", "other"])
    }
}

@Suite struct ReportFreshnessTests {
    let now = Date(timeIntervalSince1970: 1_794_319_200)

    @Test(arguments: [
        (0.0, ReportFreshness.live), (59.9, .live),
        (60, .stale), (300, .stale), (600, .stale),
        (600.001, .expired), (3600, .expired),
    ])
    func boundaries(age: TimeInterval, expected: ReportFreshness) {
        #expect(ReportFreshness(lastSeen: now.addingTimeInterval(-age), now: now) == expected)
    }
}
