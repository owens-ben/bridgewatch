import CoreLocation
import Foundation
import Testing
@testable import BoatCore

/// Local test location: the DUMBO waterfront, inside the dev box.
let testObserver = CLLocationCoordinate2D(latitude: 40.7046, longitude: -73.9913)

@Suite struct DistanceTests {
    @Test func oneDegreeOfLatitudeIsAbout111km() {
        let d = distance(from: .init(latitude: 40, longitude: -74), to: .init(latitude: 41, longitude: -74))
        #expect(abs(d - 111_195) < 10)
    }

    @Test func samePointIsZero() {
        #expect(distance(from: testObserver, to: testObserver) == 0)
    }

    @Test func acrossTheDevBoxIsAboutTenKilometers() {
        let box = devBoundingBox
        let d = distance(
            from: .init(latitude: box.minLatitude, longitude: box.minLongitude),
            to: .init(latitude: box.maxLatitude, longitude: box.maxLongitude))
        #expect(d > 9_000 && d < 11_000)
    }

    @Test func testObserverIsInsideDevBox() {
        let box = devBoundingBox
        #expect((box.minLatitude...box.maxLatitude).contains(testObserver.latitude))
        #expect((box.minLongitude...box.maxLongitude).contains(testObserver.longitude))
    }
}

@Suite struct VesselTextTests {
    @Test(arguments: [
        (0.0, "N 0°", "north"), (22.4, "N 22°", "north"), (22.5, "NE 23°", "northeast"),
        (90, "E 90°", "east"), (180, "S 180°", "south"), (247, "SW 247°", "southwest"),
        (318, "NW 318°", "northwest"), (359.6, "N 0°", "north"), (-45, "NW 315°", "northwest"),
    ])
    func bearings(degrees: Double, shown: String, spoken: String) {
        #expect(VesselText.bearing(degrees: degrees) == shown)
        #expect(VesselText.spokenBearing(degrees: degrees) == spoken)
    }

    /// A plain space would let "14.2 kn" wrap between the number and the unit on the narrow Duo cover; VoiceOver reads
    /// the spoken forms, which have no such problem.
    @Test func shownUnitsAreGluedToTheirNumbers() {
        let shown = [Units.standard.speed(knots: 14.2, kind: .vessel), Units.standard.distance(meters: 100),
                     Units.standard.distance(meters: 322), VesselText.roundMiles(3)]
        for text in shown {
            #expect(!text.contains(" "), "\(text) has a breaking space")
            #expect(text.contains("\u{00A0}"), "\(text) has no non-breaking space")
        }
        let spoken = [Units.standard.spokenSpeed(knots: 14.2, kind: .vessel), Units.standard.spokenDistance(meters: 100),
                      Units.standard.spokenDistance(meters: 322), VesselText.spokenRoundMiles(3)]
        for text in spoken {
            #expect(!text.contains("\u{00A0}"), "\(text) should read with ordinary spaces")
        }
    }

    @Test(arguments: [
        (12.0, "12 s ago", "12 seconds ago"), (1, "1 s ago", "1 second ago"),
        (60, "1 min ago", "1 minute ago"), (190, "3 min ago", "3 minutes ago"),
        (7_200, "2 h ago", "2 hours ago"), (-5, "0 s ago", "0 seconds ago"),
    ])
    func ages(seconds: TimeInterval, shown: String, spoken: String) {
        #expect(VesselText.age(seconds: seconds) == shown)
        #expect(VesselText.spokenAge(seconds: seconds) == spoken)
    }

    @Test func counts() {
        #expect(VesselText.count(0) == "0 vessels")
        #expect(VesselText.count(1) == "1 vessel")
        #expect(VesselText.count(4) == "4 vessels")
    }
}

@Suite struct VesselListTests {
    let now = Date(timeIntervalSince1970: 1_794_319_200)
    let observer = testObserver
    /// Nothing in the way: these tests are about ordering and text, not sightlines (see SightlineTests).
    let open = Sightlines(surface: .flat)

    /// A vessel `meters` due north or east of the observer (approximate, fine for ordering).
    func vessel(_ mmsi: Int, north meters: Double = 0, east: Double = 0, name: String? = nil, type: Int? = nil,
                sog: Double? = nil, age: TimeInterval = 5) -> Vessel {
        var v = testVessel(
            mmsi: mmsi, name: name, shipType: type,
            lat: observer.latitude + meters / 111_195,
            lon: observer.longitude + east / (111_195 * cos(observer.latitude * .pi / 180)),
            sog: sog, timestamp: now.addingTimeInterval(-age))
        v.lastSeen = now.addingTimeInterval(-age)
        return v
    }

    @Test func sortsNearestFirstAndSplitsClosest() {
        let list = VesselList(
            vessels: [vessel(1, north: 900), vessel(2, east: 300), vessel(3, north: 600)],
            observer: observer, now: now, sightlines: open)
        #expect(list.rows.map(\.vessel.mmsi) == [2, 3, 1])
        #expect(list.closest?.vessel.mmsi == 2)
        #expect(list.others.map(\.vessel.mmsi) == [3, 1])
    }

    @Test func equalDistancesBreakTiesByMMSI() {
        let list = VesselList(vessels: [vessel(9, north: 500), vessel(4, north: 500)], observer: observer, now: now, sightlines: open)
        #expect(list.rows.map(\.vessel.mmsi) == [4, 9])
    }

    @Test func dropsExpiredVessels() {
        let list = VesselList(vessels: [vessel(1, north: 100), vessel(2, north: 50, age: 601)], observer: observer, now: now, sightlines: open)
        #expect(list.rows.map(\.vessel.mmsi) == [1])
    }

    @Test func emptyList() {
        let list = VesselList(vessels: [], observer: observer, now: now, sightlines: open)
        #expect(list.isEmpty)
        #expect(list.closest == nil)
        #expect(list.others.isEmpty)
    }

    @Test func rowTextForNamedFerry() throws {
        let list = VesselList(
            vessels: [vessel(367000001, north: 230, east: -200, name: "HARBOR LARK", type: 60, sog: 14.2)],
            observer: observer, now: now, sightlines: open)
        let row = try #require(list.closest)
        #expect(row.title == "HARBOR LARK")
        #expect(row.category == .passenger)
        #expect(row.detail == "Passenger · 14.2\u{00A0}kn")
        #expect(row.distanceText == "0.2\u{00A0}mi")
        #expect(row.bearingText?.hasPrefix("NW ") == true)
        #expect(row.accessibilityLabel() == "HARBOR LARK, passenger, 0.2 miles northwest, 14 knots")
    }

    @Test func rowWithoutStaticDataOrSpeed() throws {
        let row = try #require(VesselList(vessels: [vessel(367000004, east: 400)], observer: observer, now: now, sightlines: open).closest)
        #expect(row.title == "Unnamed boat")
        #expect(row.category == .other)
        #expect(row.detail == "Vessel")
        #expect(row.speedText == nil)
        #expect(row.accessibilityLabel() == "Unnamed boat, vessel, 0.2 miles east")
    }

    @Test func staleRowsAndOfflineRowsSayTheirAge() throws {
        let stale = try #require(VesselList(vessels: [vessel(1, north: 100, age: 190)], observer: observer, now: now, sightlines: open).closest)
        #expect(stale.freshness == .stale)
        #expect(stale.ageText == "3 min ago")
        #expect(stale.accessibilityLabel().hasSuffix(", last report 3 minutes ago"))

        let live = try #require(VesselList(vessels: [vessel(2, north: 100, age: 12)], observer: observer, now: now, sightlines: open).closest)
        #expect(!live.accessibilityLabel().contains("last report"))
        #expect(live.accessibilityLabel(includeAge: true).hasSuffix(", last report 12 seconds ago"))
    }

    @Test func lookupByMMSI() {
        let list = VesselList(vessels: [vessel(1, north: 100), vessel(2, north: 200)], observer: observer, now: now, sightlines: open)
        #expect(list.row(mmsi: 2)?.vessel.mmsi == 2)
        #expect(list.row(mmsi: 3) == nil)
    }

    @Test func withoutObserverLocationThereAreNoDistances() throws {
        let list = VesselList(
            vessels: [vessel(3, north: 100, name: "WREN"), vessel(1, north: 900, name: "ANNABEL K"), vessel(2, east: 50)],
            observer: nil, now: now)
        #expect(!list.hasDistances)
        #expect(list.closest == nil)
        // Sorted by name; unnamed vessels show their MMSI.
        #expect(list.rows.map(\.title) == ["ANNABEL K", "Unnamed boat", "WREN"])
        #expect(list.others.count == 3)
        let row = try #require(list.row(mmsi: 3))
        #expect(row.distanceMeters == nil)
        #expect(row.distanceText == nil)
        #expect(row.bearingText == nil)
        #expect(row.accessibilityLabel() == "WREN, vessel")
    }
}
