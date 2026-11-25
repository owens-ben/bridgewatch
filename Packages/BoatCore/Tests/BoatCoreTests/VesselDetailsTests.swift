import Foundation
import Testing
@testable import BoatCore

/// The AIS details on a vessel target (relay/PROTOCOL.md, "Vessels"), with the relay's generated details fixtures:
/// every detail, AIS sentinels and invalid values the relay dropped, dirty text it cleaned, and later messages that
/// leave fields out.
@Suite struct VesselDetailsDecodingTests {
    /// The clock the relay used for relay-v2-details-snapshot.json.
    let snapshotTime = try! date("2026-11-10T14:12:00.000Z")

    func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func snapshot(_ name: String) throws -> [Target] {
        guard case .snapshot(let targets) = try RelayMessage.decode(fixture(name)) else {
            Issue.record("\(name).json is not a snapshot")
            return []
        }
        return targets
    }

    func vessels(_ name: String) throws -> [Int: Vessel] {
        Dictionary(uniqueKeysWithValues: try snapshot(name).compactMap(Vessel.init).map { ($0.mmsi, $0) })
    }

    @Test func detailsSnapshotDecodesEveryTargetAndDetail() throws {
        let targets = try snapshot("relay-v2-details-snapshot")
        #expect(targets.count == 5)
        let vessels = try vessels("relay-v2-details-snapshot")
        let queen = try #require(vessels[367000010])
        #expect(queen.name == "EAST RIVER QUEEN")
        #expect(queen.shipType == 69)
        #expect(queen.imo == 9123453)
        #expect(queen.callSign == "WDB1234")
        #expect(queen.destination == "PIER 11 WALL ST")
        #expect(queen.eta == VesselETA(month: 11, day: 10, hour: 18, minute: 45))
        #expect(queen.length == 158)
        #expect(queen.beam == 28)
        #expect(queen.draught == 6.4)
        #expect(queen.navStatus == 5)

        // Every detail was a sentinel: only the type is left.
        let sentinel = try #require(vessels[367000011])
        #expect(sentinel.imo == nil && sentinel.callSign == nil && sentinel.destination == nil && sentinel.eta == nil)
        #expect(sentinel.length == nil && sentinel.beam == nil && sentinel.draught == nil && sentinel.navStatus == nil)

        // Dirty text, cleaned by the relay; no beam, no ETA, no status.
        let dirty = try #require(vessels[367000012])
        #expect(dirty.callSign == "WD C 99")
        #expect(dirty.destination == "NEW YORK HARBOR ANCH")
        #expect(dirty.length == 12 && dirty.beam == nil && dirty.draught == 1.3 && dirty.eta == nil)

        // A whole-number draught arrives as an integer.
        #expect(vessels[367000013]?.draught == 3)
        #expect(vessels[367000013]?.navStatus == 0)

        // Details without a name or a type.
        let nameless = try #require(vessels[367000014])
        #expect(nameless.name == nil && nameless.shipType == nil)
        #expect(nameless.destination == "DUMBO" && nameless.navStatus == 8 && nameless.imo == 9222222)
    }

    /// The details stream played into an empty registry ends where the relay's snapshot does: later messages that
    /// leave a detail out don't lose it (the relay merges; the app takes each target whole).
    @Test func detailsStreamAppliedGivesTheDetailsSnapshot() throws {
        let messages = try RelayJSON.decoder().decode([RelayMessage].self, from: fixture("relay-v2-details-stream"))
        #expect(messages.count == 15)
        var registry = TargetRegistry()
        for message in messages { registry.apply(message) }
        registry.prune(now: snapshotTime)
        #expect(registry.targets == (try snapshot("relay-v2-details-snapshot")))
        // TWO STEP's destination changed on the way: the newest wins.
        #expect(registry.vessels.first { $0.mmsi == 367000013 }?.destination == "GOVERNORS IS")
    }

    /// The main fixture's boats carry the details the synthetic sample's static messages give them.
    @Test func mainSnapshotCarriesDetails() throws {
        let vessels = try vessels("relay-v2-snapshot")
        #expect(vessels.count == 4)
        let first = try #require(vessels[367000001])
        #expect(first.callSign == "WDA0000" && first.destination == "WALL ST" && first.navStatus == 0)
        #expect(first.eta == VesselETA(month: 11, day: 10, hour: 15, minute: 0))
        #expect(first.length == 30 && first.beam == 8 && first.draught == 2.1 && first.imo == nil)
        // Only a status from its position reports.
        let bare = try #require(vessels[367000004])
        #expect(bare.navStatus == 0)
        #expect(bare.imo == nil && bare.callSign == nil && bare.destination == nil && bare.eta == nil)
        #expect(bare.length == nil && bare.beam == nil && bare.draught == nil)
    }

    func decodeVessel(_ details: String) throws -> Target {
        let json = #"{"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"aisstream","lat":40.7,"#
            + #""lon":-74,"timestamp":"2026-11-10T14:00:00.000Z","vessel":{"mmsi":1,\#(details)}}}"#
        guard case .update(let target) = try RelayMessage.decode(Data(json.utf8)) else {
            Issue.record("not an update")
            throw CancellationError()
        }
        return target
    }

    /// A detail of the wrong type is left out; the target and the other details stay.
    @Test func aWrongTypeDropsOnlyThatDetail() throws {
        let target = try decodeVessel(
            #""shipType":52,"imo":"9123453","callSign":42,"destination":"PIER 6","eta":{"month":"11","day":1},"#
                + #""length":12.5,"beam":true,"draught":"deep","navStatus":5"#)
        let details = try #require(target.vessel)
        #expect(details.shipType == 52)
        #expect(details.imo == nil && details.callSign == nil && details.eta == nil)
        #expect(details.length == nil && details.beam == nil && details.draught == nil)
        #expect(details.destination == "PIER 6")
        #expect(details.navStatus == 5)
    }

    @Test func absentDetailsDecodeAsNil() throws {
        let details = try #require(try decodeVessel(#""shipType":60"#).vessel)
        #expect(details == VesselDetails(mmsi: 1, shipType: 60))
    }

    /// Encoding leaves unknown details out, never `null` (relay/PROTOCOL.md), and decodes back the same.
    @Test func encodesOnlyKnownDetails() throws {
        let details = VesselDetails(mmsi: 1, shipType: 60, destination: "DUMBO",
                                    eta: VesselETA(month: 1, day: 2, hour: 3, minute: 4), draught: 2.5)
        let data = try JSONEncoder().encode(details)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("null"))
        #expect(!text.contains("imo"))
        #expect(try JSONDecoder().decode(VesselDetails.self, from: data) == details)
    }
}

@Suite struct VesselDetailTextTests {
    let us = Locale(identifier: "en_US")

    func utc(_ iso: String) throws -> Date { try date(iso) }

    // MARK: Navigational status

    @Test(arguments: [
        (0, "Under way using engine"), (1, "At anchor"), (2, "Not under command"), (3, "Restricted manoeuvrability"),
        (4, "Constrained by draught"), (5, "Moored"), (6, "Aground"), (7, "Fishing"), (8, "Under way sailing"),
        (9, "Other"), (10, "Other"), (11, "Towing astern"), (12, "Pushing ahead or towing alongside"),
        (13, "Other"), (14, "Emergency beacon active"),
    ])
    func navStatusWords(_ code: Int, _ words: String) {
        #expect(VesselDetailText.navStatus(code) == words)
    }

    @Test(arguments: [15, 16, -1, 100])
    func undefinedNavStatusIsNil(_ code: Int) {
        #expect(VesselDetailText.navStatus(code) == nil)
    }

    // MARK: ETA

    @Test func etaInTheUsersLocaleInUTC() throws {
        let now = try utc("2026-11-10T14:12:00.000Z")
        let eta = VesselETA(month: 11, day: 17, hour: 14, minute: 30)
        #expect(VesselDetailText.eta(eta, now: now, locale: us) == "Nov 17, 14:30 UTC")
        #expect(VesselDetailText.eta(eta, now: now, locale: Locale(identifier: "en_GB")) == "17 Nov, 14:30 UTC")
        #expect(VesselDetailText.eta(VesselETA(month: 1, day: 5, hour: 0, minute: 0), now: now, locale: us)
            == "Jan 5, 00:00 UTC")
        // The day is the UTC day, whatever the device's zone: 23:30 UTC on the 17th stays the 17th.
        #expect(VesselDetailText.eta(VesselETA(month: 11, day: 17, hour: 23, minute: 30), now: now, locale: us)
            == "Nov 17, 23:30 UTC")
    }

    @Test func pastETAsSaySo() throws {
        let now = try utc("2026-11-10T14:12:00.000Z")
        #expect(VesselDetailText.eta(VesselETA(month: 11, day: 10, hour: 14, minute: 0), now: now, locale: us)
            == "Nov 10, 14:00 UTC (past)")
        #expect(VesselDetailText.eta(VesselETA(month: 11, day: 3, hour: 9, minute: 5), now: now, locale: us)
            == "Nov 3, 09:05 UTC (past)")
        // A minute ahead is still to come.
        #expect(VesselDetailText.eta(VesselETA(month: 11, day: 10, hour: 14, minute: 13), now: now, locale: us)
            == "Nov 10, 14:13 UTC")
    }

    @Test func lookupURLFromTheMMSIOnly() {
        #expect(VesselDetailText.marineTrafficURL(mmsi: 367000010)
            == "https://www.marinetraffic.com/en/ais/details/ships/mmsi:367000010")
        #expect(VesselDetailText.marineTrafficURL(mmsi: 0) == nil)
        #expect(VesselDetailText.marineTrafficURL(mmsi: -5) == nil)
    }

    @Test func etaYearRollsOverToTheNearest() throws {
        // Seen in late December, a January ETA is next year.
        let december = try utc("2026-12-20T12:00:00.000Z")
        #expect(VesselDetailText.etaDate(VesselETA(month: 1, day: 2, hour: 8, minute: 0), now: december)
            == (try utc("2027-01-02T08:00:00.000Z")))
        // Seen in early January, a late-December ETA is the one just past.
        let january = try utc("2027-01-03T12:00:00.000Z")
        #expect(VesselDetailText.etaDate(VesselETA(month: 12, day: 30, hour: 8, minute: 0), now: january)
            == (try utc("2026-12-30T08:00:00.000Z")))
        // Otherwise the nearest: September just past is this year's, June next year's (5 months on, not 7 back).
        #expect(VesselDetailText.etaDate(VesselETA(month: 9, day: 1, hour: 0, minute: 0), now: december)
            == (try utc("2026-09-01T00:00:00.000Z")))
        #expect(VesselDetailText.etaDate(VesselETA(month: 6, day: 1, hour: 0, minute: 0), now: december)
            == (try utc("2027-06-01T00:00:00.000Z")))
    }

    @Test func february29NeedsALeapYearNearby() throws {
        let eta = VesselETA(month: 2, day: 29, hour: 12, minute: 0)
        #expect(VesselDetailText.etaDate(eta, now: try utc("2027-11-10T00:00:00.000Z"))
            == (try utc("2028-02-29T12:00:00.000Z")))
        // 2025, 2026 and 2027 have no February 29.
        #expect(VesselDetailText.eta(eta, now: try utc("2026-11-10T00:00:00.000Z"), locale: us) == nil)
    }

    @Test(arguments: [
        VesselETA(month: 0, day: 1, hour: 0, minute: 0), VesselETA(month: 13, day: 1, hour: 0, minute: 0),
        VesselETA(month: 1, day: 0, hour: 0, minute: 0), VesselETA(month: 1, day: 32, hour: 0, minute: 0),
        VesselETA(month: 1, day: 1, hour: 24, minute: 0), VesselETA(month: 1, day: 1, hour: 0, minute: 60),
        VesselETA(month: 1, day: 1, hour: -1, minute: 0), VesselETA(month: 2, day: 30, hour: 0, minute: 0),
        VesselETA(month: 4, day: 31, hour: 0, minute: 0),
    ])
    func invalidETAsAreNil(_ eta: VesselETA) throws {
        #expect(VesselDetailText.eta(eta, now: try utc("2026-11-10T00:00:00.000Z"), locale: us) == nil)
    }

    // MARK: Size

    @Test func sizeInFeetAndMeters() {
        let nbsp = "\u{00A0}"
        #expect(VesselDetailText.size(length: 158, beam: 28, units: .imperial) == "518 × 92\(nbsp)ft")
        #expect(VesselDetailText.size(length: 158, beam: 28, units: .metric) == "158 × 28\(nbsp)m")
        #expect(VesselDetailText.size(length: 12, beam: nil, units: .imperial) == "39\(nbsp)ft long")
        #expect(VesselDetailText.size(length: 12, beam: nil, units: .metric) == "12\(nbsp)m long")
        #expect(VesselDetailText.size(length: nil, beam: 10, units: .imperial) == "33\(nbsp)ft wide")
        #expect(VesselDetailText.size(length: 0, beam: 10, units: .metric) == "10\(nbsp)m wide")
        #expect(VesselDetailText.size(length: nil, beam: nil) == nil)
        #expect(VesselDetailText.size(length: 0, beam: -3) == nil)
        // Clamped: a bad value doesn't overflow the feet conversion.
        #expect(VesselDetailText.size(length: Int.max, beam: Int.max, units: .imperial) == "3281 × 3281\(nbsp)ft")
        #expect(VesselDetailText.size(length: 5_000, beam: nil, units: .metric) == "1000\(nbsp)m long")
        // The app's convention is feet, like its distances.
        #expect(VesselDetailText.appUnits == .imperial)
    }

    @Test func draughtInFeetAndMeters() {
        let nbsp = "\u{00A0}"
        #expect(VesselDetailText.draught(6.4, units: .imperial) == "21\(nbsp)ft")
        #expect(VesselDetailText.draught(6.4, units: .metric) == "6.4\(nbsp)m")
        #expect(VesselDetailText.draught(3, units: .metric) == "3.0\(nbsp)m")
        #expect(VesselDetailText.draught(25.5, units: .imperial) == "84\(nbsp)ft")
        #expect(VesselDetailText.draught(nil) == nil)
        #expect(VesselDetailText.draught(0) == nil)
        #expect(VesselDetailText.draught(-1) == nil)
        // Under 10 ft one decimal; under 0.1 m nothing (not "0 ft"); clamped at 100 m.
        #expect(VesselDetailText.draught(1.3, units: .imperial) == "4.3\(nbsp)ft")
        #expect(VesselDetailText.draught(0.1, units: .imperial) == "0.3\(nbsp)ft")
        #expect(VesselDetailText.draught(0.04, units: .imperial) == nil)
        #expect(VesselDetailText.draught(0.04, units: .metric) == nil)
        #expect(VesselDetailText.draught(1e300, units: .imperial) == "328\(nbsp)ft")
        #expect(VesselDetailText.draught(.infinity) == nil)
        #expect(VesselDetailText.draught(.nan) == nil)
    }

    @Test func coordinateWithHemispheres() {
        #expect(VesselDetailText.coordinate(latitude: 40.7011, longitude: -73.9899) == "40.70110° N, 73.98990° W")
        #expect(VesselDetailText.coordinate(latitude: -33.5, longitude: 151.25) == "33.50000° S, 151.25000° E")
    }

    // MARK: Untrusted text

    @Test(arguments: [
        ("PIER 11 WALL ST", "PIER 11 WALL ST"),
        ("@@WD C 99@@@", "WD C 99"),
        ("  NEW\nYORK\r\nHARBOR  ", "NEW YORK HARBOR"),
        ("A\t\tB   C", "A B C"),
        ("\u{202E}EVIL\u{202C} BOAT", "EVIL BOAT"),
        ("ZERO\u{200B}WIDTH", "ZEROWIDTH"),
        ("**BOLD** [link](x)", "**BOLD** [link](x)"),
        ("NUL\u{0000}BYTE\u{0007}", "NUL BYTE"),
    ])
    func plainTextIsOneCleanLine(_ raw: String, _ clean: String) {
        #expect(VesselDetailText.plain(raw) == clean)
    }

    @Test(arguments: ["", "@@@@@@@", "   ", "\u{200B}\u{202E}", "\n\n"] as [String])
    func plainTextOfNothingIsNil(_ raw: String) {
        #expect(VesselDetailText.plain(raw) == nil)
        #expect(VesselDetailText.plain(nil) == nil)
    }

    @Test func dirtyNamesAreCleanedInTheTitle() throws {
        let now = try utc("2026-11-10T14:00:00.000Z")
        let row = VesselRow(vessel: testVessel(mmsi: 7, name: "@@\u{202E}EVIL\nBOAT@@", lat: 40.7, lon: -74, timestamp: now),
                            observer: nil, now: now)
        #expect(row.title == "EVIL BOAT")
        let blank = VesselRow(vessel: testVessel(mmsi: 8, name: "@@@@", lat: 40.7, lon: -74, timestamp: now),
                              observer: nil, now: now)
        #expect(blank.title == "Unnamed boat")
    }

    // MARK: Detail sheet and map card

    func detailsVessels() throws -> [Int: VesselRow] {
        let url = try #require(Bundle.module.url(forResource: "relay-v2-details-snapshot", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        guard case .snapshot(let targets) = try RelayMessage.decode(Data(contentsOf: url)) else { return [:] }
        let now = try utc("2026-11-10T14:12:00.000Z")
        return Dictionary(uniqueKeysWithValues: targets.compactMap(Vessel.init).map {
            ($0.mmsi, VesselRow(vessel: $0, observer: nil, now: now))
        })
    }

    @Test func detailItemsInOrderLeavingOutWhatIsUnknown() throws {
        let rows = try detailsVessels()
        let now = try utc("2026-11-10T14:12:00.000Z")
        let nbsp = "\u{00A0}"
        let queen = try #require(rows[367000010]).detailItems(now: now, locale: us, units: .imperial)
        #expect(queen.map(\.id) == ["status", "destination", "eta", "size", "draught", "heading", "position", "imo",
                                    "callSign"])
        #expect(queen.map(\.value) == [
            "Moored", "PIER 11 WALL ST", "Nov 10, 18:45 UTC", "518 × 92\(nbsp)ft", "21\(nbsp)ft", "E 91°",
            "40.70110° N, 73.98990° W", "9123453", "WDB1234",
        ])
        #expect(queen.filter(\.copyable).map(\.id) == ["position", "imo", "callSign"])

        let sentinel = try #require(rows[367000011]).detailItems(now: now, locale: us)
        #expect(sentinel.map(\.id) == ["heading", "position"])
    }

    @Test func cardStatusFromNavStatusAndDestination() throws {
        let rows = try detailsVessels()
        #expect(rows[367000010]?.cardStatus == "Moored · to PIER 11 WALL ST")
        #expect(rows[367000014]?.cardStatus == "Under way sailing · to DUMBO")
        #expect(rows[367000012]?.cardStatus == "to NEW YORK HARBOR ANCH")
        #expect(rows[367000011]?.cardStatus == nil)
    }
}
