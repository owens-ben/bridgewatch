import Foundation
import Testing
@testable import BoatCore

@Suite struct VesselTargetTests {
    let timestamp = Date(timeIntervalSince1970: 1_794_319_200)

    @Test func mapsEveryField() throws {
        let target = Target(
            id: "vessel:367000001", kind: .vessel, source: "aisstream", name: "HARBOR LARK", lat: 40.7041, lon: -73.9952,
            speed: 14.2, course: 62.5, heading: 61, timestamp: timestamp,
            vessel: VesselDetails(mmsi: 367000001, shipType: 60))
        let vessel = try #require(Vessel(target))
        #expect(vessel.mmsi == 367000001)
        #expect(vessel.id == 367000001)
        #expect(vessel.name == "HARBOR LARK")
        #expect(vessel.shipType == 60)
        #expect(vessel.latitude == 40.7041)
        #expect(vessel.longitude == -73.9952)
        #expect(vessel.coordinate.latitude == 40.7041)
        #expect(vessel.coordinate.longitude == -73.9952)
        #expect(vessel.sog == 14.2)
        #expect(vessel.cog == 62.5)
        #expect(vessel.heading == 61)
        #expect(vessel.lastSeen == timestamp)
        #expect(vessel.positionTimestamp == timestamp)
    }

    @Test func omittedOptionalsStayNil() throws {
        let vessel = try #require(Vessel(vesselTarget(4, timestamp: timestamp)))
        #expect(vessel.name == nil)
        #expect(vessel.shipType == nil)
        #expect(vessel.sog == nil)
        #expect(vessel.cog == nil)
        #expect(vessel.heading == nil)
    }

    @Test func otherTargetsAreNotVessels() {
        #expect(Vessel(trainTarget("a", timestamp: timestamp)) == nil)
        let aircraft = Target(id: "aircraft:abc", kind: .unknown("aircraft"), source: "opensky", lat: 40.7, lon: -73.99,
                              timestamp: timestamp)
        #expect(Vessel(aircraft) == nil)
        // A vessel without its `vessel` object has no MMSI to be keyed by.
        let bare = Target(id: "vessel:3", kind: .vessel, source: "aisstream", lat: 40.7, lon: -73.99, timestamp: timestamp)
        #expect(Vessel(bare) == nil)
    }
}
