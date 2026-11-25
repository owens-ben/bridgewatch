import Foundation
import Testing
@testable import BoatCore

/// Every row of ITU-R M.1371's "Type of ship" table the app names, and the edges.
@Suite struct AISShipTypeTests {
    @Test(arguments: [
        (20, "Wing in ground"), (25, "Wing in ground"), (29, "Wing in ground"),
        (30, "Fishing"), (31, "Towing"), (32, "Towing"), (33, "Dredging"), (34, "Diving"), (35, "Military"),
        (36, "Sailing"), (37, "Pleasure craft"),
        (40, "High-speed craft"), (45, "High-speed craft"), (49, "High-speed craft"),
        (50, "Pilot"), (51, "Search and rescue"), (52, "Tug"), (53, "Port tender"), (54, "Pollution control"),
        (55, "Law enforcement"), (58, "Medical transport"), (59, "Neutral state vessel"),
        (60, "Passenger"), (64, "Passenger"), (69, "Passenger"),
        (70, "Cargo"), (79, "Cargo"), (80, "Tanker"), (89, "Tanker"),
        (90, "Other"), (99, "Other"),
    ])
    func namesEachRow(_ code: Int, _ name: String) {
        #expect(AISShipType.name(code) == name)
    }

    /// Unknown, not used, reserved (1-19, 38-39, 56-57) and out of range all read "Vessel".
    @Test(arguments: [nil, 0, 1, 10, 19, 38, 39, 56, 57, 100, 255, -1, Int.min, Int.max] as [Int?])
    func unknownAndReservedAreVessel(_ code: Int?) {
        #expect(AISShipType.name(code) == "Vessel")
    }

    @Test func rowsKeepTheirTypeNameOnTheVesselRow() throws {
        let now = Date(timeIntervalSince1970: 1_794_319_200)
        let pilot = VesselRow(vessel: testVessel(mmsi: 1, shipType: 50, lat: 40.7, lon: -74, timestamp: now),
                              observer: nil, now: now)
        #expect(pilot.typeName == "Pilot")
        #expect(pilot.category == .service)
        // The list's text stays the group's name.
        #expect(pilot.detail == "Service")
        let police = VesselRow(vessel: testVessel(mmsi: 2, shipType: 55, lat: 40.7, lon: -74, timestamp: now),
                               observer: nil, now: now)
        #expect(police.typeName == "Law enforcement")
        #expect(police.category == .firstResponder)
        #expect(police.detail == "First responder")
        #expect(police.accessibilityLabel().hasPrefix("Unnamed boat, first responder"))
    }

    @Test func groupsHaveKeyText() {
        #expect(VesselCategory.allCases.map(\.name)
            == ["Passenger", "Cargo", "Service", "First responder", "Pleasure", "Other"])
        #expect(VesselCategory.allCases.allSatisfy { !$0.coverage.isEmpty })
        // The key's text has no slashes (the owner's ask, "get rid of all the slashes").
        let keyText = VesselCategory.allCases.flatMap { [$0.name, $0.coverage, $0.spokenName] }
            + [MapKey.trainAboveGround, MapKey.trainUnderground,
                  MapKey.courseWedge(units: .standard), MapKey.courseWedge(units: Units(region: .metric))]
        #expect(keyText.allSatisfy { !$0.contains("/") })
    }
}
