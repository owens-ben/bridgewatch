import Foundation
import Testing
@testable import BoatCore

@Suite struct VesselMapTests {
    // MARK: Course wedge

    @Test(arguments: [
        (10.0, 0.0, 0.0, 0.0), (10, 90, 0, 90), (10, 359.9, 0, 359.9), (0.51, 245, 0, 245),
        // A rotated map: the wedge turns against the map's heading.
        (10, 90, 30, 60), (10, 10, 30, 340), (10, 720, 0, 0), (10, -90, 0, 270),
    ])
    func wedgeFollowsTheCourse(_ speed: Double, _ course: Double, _ mapHeading: Double, _ degrees: Double) throws {
        let rotation = try #require(VesselMap.courseArrowDegrees(speedKnots: speed, courseDegrees: course,
                                                                 mapHeading: mapHeading))
        #expect(abs(rotation - degrees) < 1e-9)
        #expect(rotation >= 0 && rotation < 360)
    }

    @Test(arguments: [
        (0.0, 90.0), (0.5, 90), (0.2, 90), (-3, 90), (.nan, 90), (10, .nan), (.infinity, 90),
    ] as [(Double?, Double?)] + [(nil, 90), (10, nil), (nil, nil)])
    func wedgeHiddenWhenStoppedOrUnknown(_ speed: Double?, _ course: Double?) {
        #expect(VesselMap.courseArrowDegrees(speedKnots: speed, courseDegrees: course) == nil)
    }

    // MARK: Type labels

    @Test func typeLabelsOnceZoomedInAndAlwaysWhenSelected() {
        #expect(VesselMap.showsTypeLabel(visibleSpanMeters: 2_500, selected: false))
        #expect(VesselMap.showsTypeLabel(visibleSpanMeters: 1_200, selected: false))
        #expect(!VesselMap.showsTypeLabel(visibleSpanMeters: 2_501, selected: false))
        #expect(!VesselMap.showsTypeLabel(visibleSpanMeters: 9_000, selected: false))
        #expect(VesselMap.showsTypeLabel(visibleSpanMeters: 9_000, selected: true))
    }

    // MARK: Map card text

    let now = Date(timeIntervalSince1970: 1_794_319_200)
    let observer = (latitude: 40.7046, longitude: -73.9913)

    @Test func vesselCard() throws {
        let vessel = Vessel(Target(
            id: "vessel:367000002", kind: .vessel, source: "aisstream", name: "ANNABEL K", lat: 40.7068, lon: -73.9890,
            speed: 6.8, course: 245, timestamp: now,
            vessel: VesselDetails(mmsi: 367000002, shipType: 52, destination: "PIER 6", navStatus: 0)))!
        let row = VesselRow(vessel: vessel, observer: .init(latitude: observer.latitude, longitude: observer.longitude),
                            now: now)
        let card = row.mapCard
        #expect(card.title == "ANNABEL K")
        #expect(card.subtitle == "Tug · 6.8\u{00A0}kn")
        #expect(card.status == "Under way using engine · to PIER 6")
        #expect(card.distance?.hasPrefix("0.2\u{00A0}mi · NE ") == true, "\(card.distance ?? "nil")")
        #expect(card.accessibilityLabel.hasPrefix("ANNABEL K, tug, Under way using engine · to PIER 6, 0.2 miles northeast"))
        #expect(card.accessibilityLabel.hasSuffix("7 knots"))
    }

    @Test func vesselCardWithoutLocationOrSpeed() {
        let row = VesselRow(vessel: testVessel(mmsi: 9, shipType: 50, lat: 40.7, lon: -74, timestamp: now),
                            observer: nil, now: now)
        #expect(row.mapCard.subtitle == "Pilot")
        #expect(row.mapCard.distance == nil)
        #expect(row.mapCard.status == nil)
        #expect(row.mapCard.title == "Unnamed boat")
    }

    @Test func trainCard() throws {
        let train = try #require(Train(trainTarget("Q1", route: "Q", destination: "96 St", lat: 40.7075, lon: -73.9905,
                                                   altitude: 41, speed: 18, course: 340, timestamp: now)))
        let row = TrainRow(train: train, observer: nil, now: now)
        #expect(row.mapCard.title == "Q to 96 St")
        #expect(row.mapCard.subtitle == "Q train")
        #expect(row.mapCard.status == "Manhattan Bridge · 21\u{00A0}mph")
        #expect(row.mapCard.distance == nil)
        #expect(row.mapCard.accessibilityLabel == row.accessibilityLabel())
    }

    // MARK: Drawing order and selection

    @Test func selectedMarkerIsDrawnLast() {
        let ids = ["u1", "u2", "q", "m", "boat1", "boat2"]
        #expect(MapMarkerOrder.selectedLast(ids) { $0 == "q" } == ["u1", "u2", "m", "boat1", "boat2", "q"])
        #expect(MapMarkerOrder.selectedLast(ids) { $0 == "boat2" } == ids)
        #expect(MapMarkerOrder.selectedLast(ids) { _ in false } == ids)
        #expect(MapMarkerOrder.selectedLast([String]()) { _ in true }.isEmpty)
    }

    @Test func aSelectionIsClearedOnceItsTargetIsGone() throws {
        let boat = testVessel(mmsi: 5, lat: 40.7, lon: -74, timestamp: now)
        #expect(SelectionCheck.vesselIsShown(mmsi: 5, in: [boat], now: now.addingTimeInterval(600)))
        #expect(!SelectionCheck.vesselIsShown(mmsi: 5, in: [boat], now: now.addingTimeInterval(601)))
        #expect(!SelectionCheck.vesselIsShown(mmsi: 6, in: [boat], now: now))
        let train = try #require(Train(trainTarget("Q1", timestamp: now)))
        #expect(SelectionCheck.trainIsShown(id: "train:nyct:Q1", in: [train], now: now.addingTimeInterval(30)))
        #expect(!SelectionCheck.trainIsShown(id: "train:nyct:Q1", in: [train], now: now.addingTimeInterval(61)))
        // Hidden in Settings: not in the list passed in.
        #expect(!SelectionCheck.trainIsShown(id: "train:nyct:Q1", in: [], now: now))
    }

    // MARK: Key

    @Test func keySampleTrains() {
        let above = MapKey.sampleTrain(underground: false)
        let below = MapKey.sampleTrain(underground: true)
        #expect(!above.underground && below.underground)
        #expect(above.bullet == "Q" && above.line == .broadway)
        #expect(MapKey.categories.count == 6)
    }
}
