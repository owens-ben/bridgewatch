import CoreLocation
import Foundation
import Testing
@testable import BoatCore

@Suite struct CameraRadiusTests {
    @Test func theDefaultIsTheOldFixedRange() {
        #expect(CameraRadius.default.meters == 5_000)
        #expect(CameraRadius.default.meters == Sightlines.maxRangeMeters)
        #expect(CameraFilter.default.radius == .default)
    }

    @Test func choicesInOrderWithRoundMiles() {
        #expect(CameraRadius.allCases.map(\.rawValue) == [800, 1_600, 3_200, 5_000, 8_000, 16_000])
        #expect(CameraRadius.allCases.map(\.text)
                == ["½\u{00A0}mi", "1\u{00A0}mi", "2\u{00A0}mi", "3\u{00A0}mi", "5\u{00A0}mi", "10\u{00A0}mi"])
        #expect(CameraRadius.allCases.map(\.spokenText)
                == ["half a mile", "1 mile", "2 miles", "3 miles", "5 miles", "10 miles"])
    }

    /// Each choice is within a tenth of the miles it's shown as (5 km is "3 mi": 3.1).
    @Test(arguments: CameraRadius.allCases)
    func shownMilesAreClose(radius: CameraRadius) {
        let miles = radius.meters / 1_609.344
        #expect(abs(miles - radius.miles) / radius.miles < 0.1, "\(radius) is \(miles) mi")
    }
}

@Suite struct CameraFilterMatchingTests {
    let now = Date(timeIntervalSince1970: 1_794_319_200)

    func boat(_ category: VesselCategory, sog: Double? = 5) -> Vessel {
        let shipType: Int? = switch category {
        case .passenger: 60
        case .cargo: 70
        case .service: 52
        case .firstResponder: 55
        case .pleasure: 36
        case .other: nil
        }
        return testVessel(mmsi: 1, shipType: shipType, lat: 40.705, lon: -73.99, sog: sog, cog: 90, timestamp: now)
    }

    func train(underground: Bool, speed: Double = 15) -> Train {
        testTrain("t", stretch: underground ? nil : "manhattan-bridge", speed: speed, timestamp: now)
    }

    @Test func theDefaultShowsEverything() {
        for category in VesselCategory.allCases {
            #expect(CameraFilter.default.shows(boat(category)))
            #expect(CameraFilter.default.shows(boat(category, sog: nil)))
        }
        #expect(CameraFilter.default.shows(train(underground: false, speed: 0)))
        #expect(CameraFilter.default.shows(train(underground: true, speed: 0)))
    }

    @Test(arguments: VesselCategory.allCases)
    func hidingATypeHidesOnlyThatType(hiddenCategory: VesselCategory) {
        var filter = CameraFilter.default
        filter.setShown(.vessel(hiddenCategory), false)
        for category in VesselCategory.allCases {
            #expect(filter.shows(boat(category)) == (category != hiddenCategory))
        }
        // Boat types leave trains alone.
        #expect(filter.shows(train(underground: false)))
        #expect(filter.shows(train(underground: true)))
    }

    @Test func combinationsOfTypes() {
        let filter = CameraFilter(hidden: [.vessel(.cargo), .vessel(.service), .vessel(.other)])
        #expect(VesselCategory.allCases.filter { filter.shows(boat($0)) } == [.passenger, .firstResponder, .pleasure])
        var back = filter
        back.setShown(.vessel(.service), true)
        #expect(VesselCategory.allCases.filter { back.shows(boat($0)) }
            == [.passenger, .service, .firstResponder, .pleasure])
    }

    @Test func trainsAndUndergroundTrains() {
        let noUnderground = CameraFilter(hidden: [.undergroundTrains])
        #expect(noUnderground.shows(train(underground: false)))
        #expect(!noUnderground.shows(train(underground: true)))
        let noTrains = CameraFilter(hidden: [.trains])
        #expect(!noTrains.shows(train(underground: false)))
        #expect(!noTrains.shows(train(underground: true)))
        #expect(noTrains.isShown(.vessel(.cargo)))
        // Underground's switch depends on trains'.
        #expect(noTrains.isShown(.undergroundTrains))
        #expect(!noTrains.isAvailable(.undergroundTrains))
        #expect(noUnderground.isAvailable(.undergroundTrains))
        #expect(CameraFilter.default.isAvailable(.trains))
    }

    /// The same 0.5 kn floor as dead reckoning, for boats and trains; an unknown speed isn't moving.
    @Test func movingOnly() {
        let filter = CameraFilter(movingOnly: true)
        #expect(filter.shows(boat(.passenger, sog: 0.5)))
        #expect(!filter.shows(boat(.passenger, sog: 0.49)))
        #expect(!filter.shows(boat(.passenger, sog: nil)))
        #expect(filter.shows(train(underground: false, speed: 15)))
        #expect(!filter.shows(train(underground: true, speed: 0)), "a train standing at a station")
        #expect(DeadReckoning.isMoving(speedKnots: DeadReckoning.minimumSpeedKnots))
        #expect(!DeadReckoning.isMoving(speedKnots: nil))
    }

    @Test func candidatesKeepTheFocusWhateverTheCamerasOwnFilter() {
        let boats = [testVessel(mmsi: 1, shipType: 70, lat: 40.705, lon: -73.99, sog: 0, timestamp: now),
                     testVessel(mmsi: 2, shipType: 60, lat: 40.705, lon: -73.99, sog: 9, timestamp: now)]
        let filter = CameraFilter(hidden: [.vessel(.cargo)], movingOnly: true)
        #expect(filter.candidates(boats, focus: nil).map(\.id) == [2])
        #expect(filter.candidates(boats, focus: 1).map(\.id) == [1, 2])
        // A standing train the camera's "Moving only" leaves out is still found.
        let standing = [train(underground: true, speed: 0)]
        #expect(CameraFilter(movingOnly: true).candidates(standing, focus: nil).isEmpty)
        #expect(CameraFilter(movingOnly: true).candidates(standing, focus: "train:nyct:t").count == 1)
    }

    /// Trains off (or underground trains off) in Settings stay off in the camera, focused or not, as before the
    /// filter: those switches are Settings' state.
    @Test func sharedSwitchesHideEvenTheFocus() {
        let underground = [train(underground: true)]
        #expect(CameraFilter(hidden: [.trains]).candidates(underground, focus: nil).isEmpty)
        #expect(CameraFilter(hidden: [.trains]).candidates(underground, focus: "train:nyct:t").isEmpty)
        #expect(CameraFilter(hidden: [.undergroundTrains]).candidates(underground, focus: "train:nyct:t").isEmpty)
        let bridge = [train(underground: false)]
        #expect(CameraFilter(hidden: [.undergroundTrains]).candidates(bridge, focus: nil).count == 1)
    }

    @Test func theUndergroundRadiusIsTheSmallerOfTheCapAndTheRadius() {
        #expect(CameraFilter.default.undergroundRadiusMeters(cap: 1_500) == 1_500)
        #expect(CameraFilter(radius: .halfMile).undergroundRadiusMeters(cap: 1_500) == 800)
        #expect(CameraFilter(radius: .tenMiles).undergroundRadiusMeters(cap: 1_500) == 1_500)
    }

    /// Kinds are generic: every option has a key that reads back, and a menu section has more than one option.
    @Test func optionsAndSections() {
        let options = CameraFilter.sections.flatMap(\.options)
        #expect(options.count == 8)
        for option in options { #expect(CameraFilterOption(key: option.key) == option) }
        #expect(CameraFilterOption(key: "vessel.submarine") == nil)
        #expect(CameraFilterOption(key: "") == nil)
        #expect(CameraFilter.menuSections.map(\.title) == ["Boat types", "Trains"])
        #expect(options.map(\.title) == ["Passenger", "Cargo", "Service", "First responder", "Pleasure", "Other",
                                         "Trains", "Underground trains"])
    }
}

@Suite struct CameraFilterCountTests {
    @Test func theDefaultCountsNothing() {
        #expect(CameraFilter.default.isDefault)
        #expect(CameraFilter.default.activeFilterCount == 0)
        #expect(CameraFilter.default.filterCountText == "No filters on")
        #expect(CameraFilter.default.spokenSummary == "Radius 3 miles, no filters on")
        #expect(CameraFilter.default.emptyMessage == "Nothing in sight from here")
    }

    @Test func eachSectionCountsOnceAndTheRadiusNotAtAll() {
        let radius = CameraFilter(radius: .oneMile)
        #expect(!radius.isDefault)
        #expect(radius.activeFilterCount == 0)
        #expect(radius.spokenSummary == "Radius 1 mile, no filters on")

        let types = CameraFilter(hidden: [.vessel(.cargo), .vessel(.service)])
        #expect(types.activeFilterCount == 1)
        #expect(types.filterCountText == "1 filter on")

        let all = CameraFilter(radius: .halfMile, hidden: [.vessel(.cargo), .undergroundTrains], movingOnly: true)
        #expect(all.activeFilterCount == 2)
        #expect(all.spokenSummary == "Radius half a mile, 2 filters on")
    }

    /// The train switches are Settings': with only those off, the camera's filter is at its defaults (no dot, Reset
    /// off) and counts nothing.
    @Test func theSharedSwitchesDontCount() {
        for hidden: Set<CameraFilterOption> in [[.trains], [.undergroundTrains], [.trains, .undergroundTrains]] {
            let filter = CameraFilter(hidden: hidden)
            #expect(filter.isDefault)
            #expect(filter.activeFilterCount == 0)
            #expect(filter.filterCountText == "No filters on")
            #expect(filter.spokenSummary == "Radius 3 miles, no filters on")
        }
        let tugsToo = CameraFilter(hidden: [.trains, .vessel(.service)])
        #expect(!tugsToo.isDefault)
        #expect(tugsToo.activeFilterCount == 1)
        #expect(tugsToo.cameraOwn == CameraFilter(hidden: [.vessel(.service)]))
    }

    /// Every combination of trains (Settings) and the camera's own filters, shown and spoken. At the defaults it's
    /// the old message: "Nothing in sight from here" with trains, "No boats in sight from here" without.
    @Test(arguments: [
        // trains off in Settings, radius, camera's own filter on, shown, spoken
        (false, CameraRadius.threeMiles, false, "Nothing in sight from here", "Nothing in sight from here"),
        (true, .threeMiles, false, "No boats in sight from here", "No boats in sight from here"),
        (false, .oneMile, false, "Nothing in sight within 1\u{00A0}mi", "Nothing in sight within 1 mile"),
        (true, .oneMile, false, "No boats in sight within 1\u{00A0}mi", "No boats in sight within 1 mile"),
        (false, .tenMiles, false, "Nothing in sight within 10\u{00A0}mi", "Nothing in sight within 10 miles"),
        (false, .threeMiles, true, "Nothing matches your filters within 3\u{00A0}mi",
         "Nothing matches your filters within 3 miles"),
        (true, .threeMiles, true, "No boats match your filters within 3\u{00A0}mi",
         "No boats match your filters within 3 miles"),
        (false, .halfMile, true, "Nothing matches your filters within ½\u{00A0}mi",
         "Nothing matches your filters within half a mile"),
        (true, .oneMile, true, "No boats match your filters within 1\u{00A0}mi",
         "No boats match your filters within 1 mile"),
    ])
    func theEmptyMessageSaysWhy(trainsOff: Bool, radius: CameraRadius, filtered: Bool, shown: String, spoken: String) {
        var hidden: Set<CameraFilterOption> = trainsOff ? [.trains] : []
        if filtered { hidden.insert(.vessel(.cargo)) }
        let filter = CameraFilter(radius: radius, hidden: hidden)
        #expect(filter.emptyMessage == shown)
        #expect(filter.spokenEmptyMessage == spoken)
        // "Moving only" is a filter just like a hidden type.
        if filtered {
            let moving = CameraFilter(radius: radius, hidden: trainsOff ? [.trains] : [], movingOnly: true)
            #expect(moving.emptyMessage == shown)
        }
    }

    /// Underground trains off in Settings is still "Nothing": trains above ground are shown.
    @Test func undergroundOffKeepsNothing() {
        #expect(CameraFilter(hidden: [.undergroundTrains]).emptyMessage == "Nothing in sight from here")
    }

    @Test func resetGoesBackToTheDefaultButLeavesTheTrainSwitches() {
        var filter = CameraFilter(radius: .tenMiles, hidden: [.trains, .undergroundTrains, .vessel(.service)],
                                  movingOnly: true)
        filter.reset()
        #expect(filter == CameraFilter(hidden: [.trains, .undergroundTrains]))
        #expect(filter.isDefault)
        var plain = CameraFilter(radius: .halfMile, hidden: [.vessel(.cargo)])
        plain.reset()
        #expect(plain == .default)
    }
}

@Suite struct CameraFilterStorageTests {
    @Test func roundTrip() {
        let filter = CameraFilter(radius: .oneMile, hidden: [.vessel(.cargo), .vessel(.other)], movingOnly: true)
        #expect(filter.rawValue == #"{"hidden":["vessel.cargo","vessel.other"],"movingOnly":true,"radius":1600,"version":2}"#)
        #expect(CameraFilter(rawValue: filter.rawValue) == filter)
        #expect(CameraFilter(rawValue: CameraFilter.default.rawValue) == .default)
    }

    @Test(arguments: ["", "not json", "[1,2]", #"{"radius":"far"}"#, "{}"])
    func corruptValuesAreTheDefault(raw: String) {
        #expect(CameraFilter(rawValue: raw) == .default)
    }

    @Test func unknownRadiusAndOptionsFallBack() {
        let raw = #"{"hidden":["vessel.submarine","vessel.cargo","aircraft.jet"],"movingOnly":false,"radius":1234}"#
        #expect(CameraFilter(rawValue: raw) == CameraFilter(hidden: [.vessel(.cargo)]))
    }

    /// A filter stored before First responder was split out of Service ("Tug / service", no `version`): hiding
    /// Service hid those boats too, so they stay hidden; showing Service showed them, so they stay shown.
    @Test func filtersFromBeforeFirstResponderKeepTheirBoats() {
        let hidService = #"{"hidden":["vessel.cargo","vessel.tug"],"movingOnly":true,"radius":1600}"#
        let migrated = CameraFilter(rawValue: hidService)
        #expect(migrated == CameraFilter(radius: .oneMile, hidden: [.vessel(.cargo), .vessel(.service),
                                                                     .vessel(.firstResponder)], movingOnly: true))
        #expect(!migrated!.isShown(.vessel(.firstResponder)))
        let showedService = #"{"hidden":["vessel.cargo"],"movingOnly":false,"radius":5000}"#
        #expect(CameraFilter(rawValue: showedService) == CameraFilter(hidden: [.vessel(.cargo)]))
        #expect(CameraFilter(rawValue: showedService)!.isShown(.vessel(.firstResponder)))
        // The migrated filter is written back as version 2 with both groups.
        #expect(migrated!.rawValue
            == #"{"hidden":["vessel.cargo","vessel.firstResponder","vessel.tug"],"movingOnly":true,"radius":1600,"version":2}"#)
    }

    /// From version 2 the groups are separate: Service hidden with First responder shown stays that way.
    @Test func version2KeepsTheGroupsApart() {
        let filter = CameraFilter(hidden: [.vessel(.service)])
        #expect(filter.rawValue == #"{"hidden":["vessel.tug"],"movingOnly":false,"radius":5000,"version":2}"#)
        let back = CameraFilter(rawValue: filter.rawValue)
        #expect(back == filter)
        #expect(back!.isShown(.vessel(.firstResponder)))
        #expect(!back!.isShown(.vessel(.service)))
    }

    /// The train switches are Settings > Trains' own: never stored with the camera's filter, so the two can't
    /// disagree.
    @Test func sharedSettingsAreNotStored() {
        let filter = CameraFilter(hidden: [.trains, .undergroundTrains, .vessel(.service)])
        #expect(filter.rawValue == #"{"hidden":["vessel.tug"],"movingOnly":false,"radius":5000,"version":2}"#)
        #expect(CameraFilter(rawValue: #"{"hidden":["trains"]}"#) == .default)
    }

    @Test func mergingTheSharedSettings() {
        let stored = CameraFilter(radius: .twoMiles, hidden: [.vessel(.service)])
        let merged = stored.merging(shared: [.trains: true, .undergroundTrains: false])
        #expect(merged == CameraFilter(radius: .twoMiles, hidden: [.vessel(.service), .undergroundTrains]))
        #expect(merged.merging(shared: [.undergroundTrains: true]) == stored)
        // Only shared options are taken from settings.
        #expect(stored.merging(shared: [.vessel(.service): true]) == stored)
    }
}

/// The radius is the sightlines' range: a parameter that defaults to the old fixed 5 km.
@Suite struct CameraRangeTests {
    let now = Date(timeIntervalSince1970: 1_794_319_200)
    let open = Sightlines(surface: .flat)

    func boat(_ mmsi: Int, north: Double) -> Vessel {
        let c = moved(testObserver, east: 0, north: north)
        return testVessel(mmsi: mmsi, shipType: 60, lat: c.latitude, lon: c.longitude, timestamp: now)
    }

    @Test func lineOfSightTakesARange() {
        let sixKm = moved(testObserver, east: 0, north: 6_000)
        #expect(open.lineOfSight(from: testObserver, eye: .altitude(nil), to: sixKm) == .tooFar)
        #expect(open.lineOfSight(from: testObserver, eye: .altitude(nil), to: sixKm, maxRangeMeters: 8_000) == .inSight)
        let threeKm = moved(testObserver, east: 0, north: 3_000)
        #expect(open.lineOfSight(from: testObserver, eye: .altitude(nil), to: threeKm, maxRangeMeters: 1_600) == .tooFar)
    }

    @Test func vesselListTakesARange() {
        let boats = [boat(1, north: 500), boat(2, north: 3_000), boat(3, north: 6_000)]
        let normal = VesselList(vessels: boats, observer: testObserver, now: now, sightlines: open)
        #expect(normal.inSight.map(\.id) == [1, 2])
        #expect(normal.row(mmsi: 3)?.lineOfSight == .tooFar)
        let wide = VesselList(vessels: boats, observer: testObserver, now: now, sightlines: open,
                              rangeMeters: CameraRadius.fiveMiles.meters)
        #expect(wide.inSight.map(\.id) == [1, 2, 3])
        let narrow = VesselList(vessels: boats, observer: testObserver, now: now, sightlines: open,
                                rangeMeters: CameraRadius.oneMile.meters)
        #expect(narrow.inSight.map(\.id) == [1])
        #expect(narrow.outOfSight.map(\.id) == [2, 3])
    }

    @Test func trainListTakesARange() {
        let trains = [testTrain("near", north: 500, timestamp: now), testTrain("far", north: 6_000, timestamp: now)]
        let normal = TrainList(trains: trains, observer: testObserver, now: now, sightlines: open)
        #expect(normal.inSight.count == 1)
        let wide = TrainList(trains: trains, observer: testObserver, now: now, sightlines: open, rangeMeters: 8_000)
        #expect(wide.inSight.count == 2)
    }

    /// The default filter and range reproduce what the camera labelled before it had them: the relay's fixture boats
    /// and trains and the UI tests' fixture, over the real harbor grid, from the waterfront, the bridge and inland.
    @Test func theDefaultsChangeNothing() throws {
        let vesselTime = try date("2026-11-10T14:12:00.000Z")
        let url = try #require(Bundle.module.url(forResource: "relay-v2-snapshot", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        guard case .snapshot(let targets) = try RelayMessage.decode(Data(contentsOf: url)) else {
            Issue.record("relay-v2-snapshot.json is not a snapshot")
            return
        }
        let ui = [(1, 40.7062, -73.9931), (2, 40.7068, -73.9890), (3, 40.7054, -73.9971), (4, 40.7083, -73.9880),
                  (5, 40.7130, -74.0250), (6, 40.6760, -74.0420)]
            .map { testVessel(mmsi: $0.0, shipType: 60, lat: $0.1, lon: $0.2, sog: 3, timestamp: vesselTime) }
        let vessels = targets.compactMap(Vessel.init) + ui
        let trains = try fixtureTrains()
        #expect(vessels.count == 10 && trains.count == 68)

        let observers = [testObserver, CLLocationCoordinate2D(latitude: 40.7058, longitude: -73.9965),
                         CLLocationCoordinate2D(latitude: 40.6710, longitude: -73.9800)]
        let filter = CameraFilter.default
        for observer in observers {
            let before = VesselList(vessels: vessels, observer: observer, now: vesselTime)
            let after = VesselList(vessels: filter.candidates(vessels, focus: nil), observer: observer,
                                   now: vesselTime, rangeMeters: filter.radius.meters)
            #expect(before == after)
            #expect(VesselARTarget.targets(in: before) == VesselARTarget.targets(in: after))

            let trainsBefore = TrainList(trains: trains, observer: observer, now: fixtureTrainTime)
            let trainsAfter = TrainList(trains: filter.candidates(trains, focus: nil), observer: observer,
                                        now: fixtureTrainTime, rangeMeters: filter.radius.meters)
            #expect(trainsBefore == trainsAfter)
            #expect(TrainARTarget.targets(in: trainsBefore, undergroundRadiusMeters: 1_500, undergroundLimit: 8)
                    == TrainARTarget.targets(in: trainsAfter,
                                             undergroundRadiusMeters: filter.undergroundRadiusMeters(cap: 1_500),
                                             undergroundLimit: 8))
        }
    }

    /// "Find in Camera" labels the focused boat even when it's filtered out and beyond the radius.
    @Test func theFocusIsLabelledWhateverTheFilterAndRadius() {
        let boats = [boat(1, north: 500), boat(2, north: 3_000)]
        let filter = CameraFilter(radius: .oneMile, hidden: [.vessel(.passenger)])
        let list = VesselList(vessels: filter.candidates(boats, focus: 2), observer: testObserver, now: now,
                              sightlines: open, rangeMeters: filter.radius.meters)
        #expect(VesselARTarget.targets(in: list, focus: 2).map(\.id) == [2])
        let unfocused = VesselList(vessels: filter.candidates(boats, focus: nil), observer: testObserver, now: now,
                                   sightlines: open, rangeMeters: filter.radius.meters)
        #expect(VesselARTarget.targets(in: unfocused).isEmpty)

        // A standing underground train, 1 km away: beyond a half-mile radius and left out by "Moving only".
        let trains = [testTrain("u", north: 1_000, stretch: nil, speed: 0, timestamp: now)]
        let movingOnly = CameraFilter(radius: .halfMile, movingOnly: true)
        let trainList = TrainList(trains: movingOnly.candidates(trains, focus: "train:nyct:u"), observer: testObserver,
                                  now: now, sightlines: open, rangeMeters: movingOnly.radius.meters)
        let targets = TrainARTarget.targets(in: trainList, focus: "train:nyct:u",
                                            undergroundRadiusMeters: movingOnly.undergroundRadiusMeters(cap: 1_500),
                                            undergroundLimit: 8)
        #expect(targets.underground.map(\.id) == ["train:nyct:u"])
    }

    /// A half-mile radius pulls the x-ray labels in from 1.5 km to 800 m.
    @Test func theRadiusCapsTheUndergroundTrains() {
        let trains = [testTrain("u1", north: 600, stretch: nil, timestamp: now),
                      testTrain("u2", north: 1_200, stretch: nil, timestamp: now)]
        let list = TrainList(trains: trains, observer: testObserver, now: now, sightlines: open)
        for (radius, expected) in [(CameraRadius.halfMile, 1), (.default, 2)] {
            let filter = CameraFilter(radius: radius)
            let targets = TrainARTarget.targets(in: list, undergroundRadiusMeters: filter.undergroundRadiusMeters(cap: 1_500),
                                                undergroundLimit: 8)
            #expect(targets.underground.count == expected)
        }
    }
}

/// H2: the camera caps its candidates by distance before working out sightlines.
@Suite struct CameraNearestCandidatesTests {
    let now = Date(timeIntervalSince1970: 1_794_319_200)
    let observer = CLLocationCoordinate2D(latitude: 40.7035, longitude: -73.9945)

    /// `count` boats spread from 50 m to about 12 km away in every direction, stopped, MMSI 1...count.
    func crowd(_ count: Int) -> [Vessel] {
        (1...count).map { i in
            let meters = 50 + Double(i) * 12, angle = Double(i) * 2.399 // golden angle: spread around
            let at = moved(observer, east: meters * sin(angle), north: meters * cos(angle))
            return testVessel(mmsi: i, lat: at.latitude, lon: at.longitude, timestamp: now)
        }
    }

    func meters(_ vessel: Vessel) -> Double { distance(from: observer, to: vessel.coordinate) }

    @Test func aThousandTargetsGiveTheNearestWithinTheRadius() {
        let vessels = crowd(1_000).shuffled()
        let filter = CameraFilter(radius: .threeMiles)
        let kept = filter.nearestCandidates(vessels, observer: observer, now: now, focus: nil)
        #expect(kept.count == CameraFilter.candidateLimit)
        #expect(kept.map(meters) == kept.map(meters).sorted())
        // Exactly the nearest: the 60 lowest MMSIs are the 60 nearest by construction.
        #expect(Set(kept.map(\.mmsi)) == Set(1...CameraFilter.candidateLimit))
        #expect(kept.allSatisfy { meters($0) <= filter.radius.meters })
    }

    @Test func nothingBeyondTheRadiusAndFewerThanTheLimitAreAllKept() {
        let vessels = crowd(1_000)
        let filter = CameraFilter(radius: .halfMile)
        let kept = filter.nearestCandidates(vessels, observer: observer, now: now, focus: nil, limit: 10_000)
        let within = vessels.filter { meters($0) <= 800 }
        #expect(!within.isEmpty && kept.count == within.count)
        #expect(kept.allSatisfy { meters($0) <= 800 })
        // A limit of 0 keeps nothing but the focus.
        #expect(filter.nearestCandidates(vessels, observer: observer, now: now, focus: nil, limit: 0).isEmpty)
    }

    @Test func theFocusIsKeptWhateverItsDistance() {
        let vessels = crowd(1_000)
        let filter = CameraFilter(radius: .halfMile)
        let far = vessels[999]
        #expect(meters(far) > 10_000)
        let kept = filter.nearestCandidates(vessels, observer: observer, now: now, focus: far.mmsi, limit: 5)
        #expect(kept.count == 6)
        #expect(kept.last?.mmsi == far.mmsi)
        #expect(Array(kept.prefix(5).map(\.mmsi)) == [1, 2, 3, 4, 5])
        // A near focus isn't counted twice and sits in distance order.
        let near = filter.nearestCandidates(vessels, observer: observer, now: now, focus: 3, limit: 5)
        #expect(near.map(\.mmsi) == [1, 2, 3, 4, 5, 6])
    }

    @Test func theFilterStillApplies() {
        var filter = CameraFilter(radius: .tenMiles)
        filter.setShown(.vessel(.other), false)
        let vessels = crowd(100)
        #expect(filter.nearestCandidates(vessels, observer: observer, now: now, focus: nil).isEmpty)
        // The focused one is the exception, as in `candidates`.
        #expect(filter.nearestCandidates(vessels, observer: observer, now: now, focus: 50).map(\.mmsi) == [50])
    }

    /// Distances are to the dead-reckoned position: a boat reported 1 km away but heading here at 20 kn for two
    /// minutes (the most it's carried forward) is about 230 m away now.
    @Test func distanceIsToTheEstimatedPosition() {
        let start = moved(observer, east: 0, north: 1_000)
        let coming = testVessel(mmsi: 1, lat: start.latitude, lon: start.longitude, sog: 20, cog: 180,
                                timestamp: now.addingTimeInterval(-120))
        let parked = testVessel(mmsi: 2, lat: moved(observer, east: 500, north: 0).latitude,
                                lon: moved(observer, east: 500, north: 0).longitude, timestamp: now)
        let filter = CameraFilter(radius: .halfMile)
        #expect(filter.nearestCandidates([parked, coming], observer: observer, now: now, focus: nil).map(\.mmsi) == [1, 2])
        #expect(filter.nearestCandidates([parked, coming], observer: observer, now: now.addingTimeInterval(-120), focus: nil)
                .map(\.mmsi) == [2])
    }

    /// Without a location nothing is within the radius: only the focused one is kept.
    @Test func noObserverKeepsOnlyTheFocus() {
        let vessels = crowd(50)
        let filter = CameraFilter()
        #expect(filter.nearestCandidates(vessels, observer: nil, now: now, focus: nil).isEmpty)
        #expect(filter.nearestCandidates(vessels, observer: nil, now: now, focus: 7).map(\.mmsi) == [7])
    }

    @Test func trainsToo() {
        let trains = (0..<200).map { i in
            let at = moved(observer, east: Double(i) * 20, north: 0)
            return Train(trainTarget("t\(i)", stretch: i % 2 == 0 ? nil : "manhattan-bridge", lat: at.latitude, lon: at.longitude,
                                     speed: 0, timestamp: now))!
        }
        let kept = CameraFilter().nearestCandidates(trains.reversed(), observer: observer, now: now, focus: "train:nyct:t199")
        #expect(kept.count == CameraFilter.candidateLimit + 1)
        #expect(Array(kept.prefix(CameraFilter.candidateLimit).map(\.id)) == (0..<CameraFilter.candidateLimit).map { "train:nyct:t\($0)" })
        #expect(kept.last?.id == "train:nyct:t199")
    }
}
