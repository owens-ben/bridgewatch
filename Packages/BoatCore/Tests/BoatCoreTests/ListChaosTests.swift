import CoreLocation
import Foundation
import Testing
@testable import BoatCore

/// Hostile numbers a relay frame can carry (finite ones: JSON has no NaN or infinity) through the models, rows, list
/// texts, map card and detail text, and the Browse builders under random scopes. The courses and headings that used
/// to trap (C1, fixed by F2) are checked end to end at the end.
@Suite(.timeLimit(.minutes(1))) struct ListChaosTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let observer = CLLocationCoordinate2D(latitude: 40.7035, longitude: -73.9945)

    // Past Int.max too: course and heading are normalized into [0, 360) on decode (F2).
    static let latitudes: [Double] = [40.7, 91, -91, 1e300, -1e300, 0, -0.0, 90, -90, 89.999, -73.99, 181, 1e-300, 40.700001]
    static let longitudes: [Double] = [-73.99, 181, -181, 1e300, -1e300, 0, -0.0, 180, -180, 179.999, 40.7, 360, 1e-300]
    static let speeds: [Double?] = [nil, 0, -0.0, 0.5, 0.49, 3, 102.2, 102.3, 200, 201, 1e300, -1e300, -1, 1e-300, 1_000, 1_000.1]
    static let angles: [Double?] = [nil, 0, -0.0, 90, 359.99, 360, 361, -1, -720, 720, 1e17, -1e17, 1e18, -1e18, 8e18, 1e19, 1e300, -1e300, 1e-300, 511]
    static let altitudes: [Double?] = [nil, 0, 20, -10, 1e300, -1e300, 1e-300]
    static let observers: [CLLocationCoordinate2D?] = [
        nil, observer, CLLocationCoordinate2D(latitude: 40.7, longitude: -73.99), CLLocationCoordinate2D(latitude: 0, longitude: 0),
        CLLocationCoordinate2D(latitude: 89.9, longitude: 10), CLLocationCoordinate2D(latitude: -90, longitude: 180),
        CLLocationCoordinate2D(latitude: 40.7, longitude: 179.9999),
    ]
    static let ages: [TimeInterval] = [0, -1, 5, 59, 61, 100, 601, 3_600, -3_600, 86_400 * 365 * 30, -86_400 * 365 * 30, 6e10, -6e10]

    static func hostileVesselTarget(_ rng: inout SplitMix64, mmsi: Int) -> Target {
        var t = vesselTarget(mmsi, name: rng.chance(0.5) ? nil : "Boat \(mmsi)", shipType: rng.pick([nil, 0, 30, 52, 60, 70, 80, 99, 1000, -5]),
                             lat: rng.pick(latitudes), lon: rng.pick(longitudes), speed: rng.pick(speeds), course: rng.pick(angles),
                             heading: rng.pick(angles), timestamp: now.addingTimeInterval(-rng.pick(ages)))
        t.vessel?.draught = rng.pick([nil, 0, 1e300, -1e300, 6.4, 0.05])
        t.vessel?.length = rng.pick([nil, 0, -5, Int.max, Int.min, 158])
        t.vessel?.beam = rng.pick([nil, 0, -5, Int.max, Int.min, 28])
        t.vessel?.eta = rng.pick([nil, VesselETA(month: 13, day: 40, hour: 25, minute: 61), VesselETA(month: 2, day: 30, hour: 0, minute: 0),
                                  VesselETA(month: Int.max, day: Int.min, hour: 0, minute: 0), VesselETA(month: 11, day: 17, hour: 14, minute: 30)])
        t.vessel?.navStatus = rng.pick([nil, -1, 0, 5, 15, 99, Int.max])
        t.vessel?.imo = rng.pick([nil, 0, -1, Int.max])
        t.vessel?.destination = rng.pick([nil, "PIER 11", "\u{202E}PIER", String(repeating: "x", count: 500)])
        return t
    }

    static func hostileTrainTarget(_ rng: inout SplitMix64, trip: Int) -> Target {
        let underground = rng.chance(0.5)
        var t = trainTarget("t\(trip)", route: rng.pick(["Q", "B", "6X", "FX", "S", "", "ZZ"]), direction: rng.pick([.north, .south]),
                            destination: rng.pick([nil, "Coney Island-Stillwell Av", "\u{202E}x"]),
                            stretch: underground ? nil : rng.pick(["manhattan-bridge", "williamsburg-bridge", "culver-viaduct", "franklin-av", "elsewhere"]),
                            lat: rng.pick(latitudes), lon: rng.pick(longitudes), speed: rng.pick(speeds.compactMap { $0 }),
                            course: rng.pick(angles.compactMap { $0 }), timestamp: now.addingTimeInterval(-rng.pick(ages) / 10))
        t.altitude = rng.pick(altitudes)
        if rng.chance(0.2) { t.speed = nil }
        if rng.chance(0.2) { t.course = nil }
        if rng.chance(0.2) { t.train?.altitudeEstimated = nil }
        return t
    }

    func checkRowTexts(_ row: VesselRow, _ context: Comment) {
        for text in [row.distanceText, row.speedText].compactMap({ $0 }) { #expect(isCleanNumberText(text), context) }
        for text in [row.bearingText, row.courseText].compactMap({ $0 }) {
            #expect(text.range(of: #"^(N|NE|E|SE|S|SW|W|NW) \d{1,3}°$"#, options: .regularExpression) != nil, context)
        }
        #expect(isCleanNumberText(row.ageText) && row.ageText.hasSuffix(" ago"), context)
        #expect(isCleanNumberText(row.cameraDetail) || row.cameraDetail.isEmpty, context)
        #expect(!row.detail.isEmpty && !row.title.isEmpty, context)
        let label = row.accessibilityLabel(includeAge: true)
        #expect(!label.isEmpty && !label.lowercased().contains("nan") && !label.contains("-0"), context)
        _ = row.accessibilityLabel()
        _ = row.mapCard
        #expect(row.mapCard.accessibilityLabel.lowercased().contains("nan") == false, context)
        _ = row.typeName
        #expect(row.ageSeconds >= 0, context)
        #expect(row.position.latitude.isFinite && row.position.longitude.isFinite, context)
        if let d = row.distanceMeters { #expect(!d.isNaN && d >= 0, context) }
        if let b = row.bearingDegrees { #expect(!b.isNaN && b >= 0 && b < 360, context) }
        _ = row.detailItems(now: Self.now, locale: Locale(identifier: "en_US"))
    }

    func checkTrainTexts(_ row: TrainRow, _ context: Comment) {
        for text in [row.distanceText, row.speedText, row.relativeHeightText].compactMap({ $0 }) {
            #expect(!text.isEmpty && !text.lowercased().contains("nan") && !text.lowercased().contains("inf") && !text.contains("-"), context)
        }
        for text in [row.bearingText, row.courseText].compactMap({ $0 }) {
            #expect(text.range(of: #"^(N|NE|E|SE|S|SW|W|NW) \d{1,3}°$"#, options: .regularExpression) != nil, context)
        }
        #expect(isCleanNumberText(row.ageText), context)
        #expect(!row.title.isEmpty && !row.detail.isEmpty && !row.cameraDetail.isEmpty || row.cameraDetail.isEmpty, context)
        let label = row.accessibilityLabel(includeAge: true)
        #expect(!label.lowercased().contains("nan") && !label.contains("-0"), context)
        _ = row.accessibilityLabel()
        _ = row.mapCard
        _ = (row.xrayDepthText, row.levelText, row.placeText, row.routeName, row.spokenRoute)
        #expect(!row.xrayDepthText.lowercased().contains("nan"), context)
        #expect(row.ageSeconds >= 0, context)
        if let d = row.distanceMeters { #expect(!d.isNaN && d >= 0, context) }
    }

    @Test func hostileVesselTargetsThroughModelRowsAndTexts() {
        var rng = Chaos.rng("hostileVesselTargetsThroughModelRowsAndTexts")
        for iteration in 0..<6_000 {
            let target = Self.hostileVesselTarget(&rng, mmsi: iteration)
            let context = Chaos.context("hostile vessel", iteration: iteration, "\(target)")
            guard let vessel = Vessel(target) else {
                // Rejected for a reason: a position that can't be real (D2, fixed by F2).
                #expect(!(abs(target.lat) <= 90 && abs(target.lon) <= 180), context)
                continue
            }
            // Speeds AIS can't send become no speed.
            if let sog = vessel.sog { #expect(sog >= 0 && sog <= Vessel.maxSpeedKnots, context) }
            let observer = rng.pick(Self.observers)
            let units = Units(preferences: rng.pick(FormatterChaosTests.allPreferences), region: rng.pick(FormatterChaosTests.regions))
            let row = VesselRow(vessel: vessel, observer: observer, eye: rng.pick([.altitude(nil), .altitude(1e300), .altitude(-1e300), .aboveGround(0), .aboveGround(1e300)]),
                                now: Self.now, rangeMeters: rng.pick([0, 800, 5_000, 16_000, 100_000]), units: units)
            checkRowTexts(row, context)
            _ = VesselMap.courseArrowDegrees(speedKnots: vessel.sog, courseDegrees: vessel.cog, mapHeading: rng.pick([0, 90, -720, 1e300]))
        }
    }

    @Test func hostileTrainTargetsThroughModelRowsAndTexts() {
        var rng = Chaos.rng("hostileTrainTargetsThroughModelRowsAndTexts")
        var made = 0, rejected = 0
        for iteration in 0..<6_000 {
            let target = Self.hostileTrainTarget(&rng, trip: iteration)
            let context = Chaos.context("hostile train", iteration: iteration, "\(target)")
            guard let train = Train(target) else {
                rejected += 1
                // Rejected for a reason: a position that can't be real, or a negative speed.
                #expect(!(abs(target.lat) <= 90 && abs(target.lon) <= 180) || (target.speed ?? 0) < 0 || !(target.altitude ?? 0).isFinite, context)
                continue
            }
            made += 1
            let observer = rng.pick(Self.observers)
            let units = Units(preferences: rng.pick(FormatterChaosTests.allPreferences), region: rng.pick(FormatterChaosTests.regions))
            let row = TrainRow(train: train, observer: observer, eye: rng.pick([.altitude(nil), .altitude(1e300), .aboveGround(3)]),
                               now: Self.now, rangeMeters: rng.pick([0, 800, 5_000, 100_000]), units: units)
            checkTrainTexts(row, context)
            if let observer {
                let list = TrainList(trains: [train], observer: observer, now: Self.now, units: units)
                let targets = TrainARTarget.targets(in: list, focus: train.id, undergroundRadiusMeters: 1_500, undergroundLimit: 5)
                for ar in targets.all {
                    for offset in [0.0, 1, 20, 1e6] {
                        let placement = ar.placement(at: Self.now.addingTimeInterval(offset))
                        #expect(!placement.bearing.isNaN, context)
                        _ = ar.place(at: Self.now.addingTimeInterval(offset), pose: CameraPose(headingDegrees: 0, pitchDegrees: 0, horizontalFOVDegrees: 60, viewWidth: 400, viewHeight: 800))
                    }
                }
            }
        }
        #expect(made > 500 && rejected > 500, "seed=\(Chaos.seed) made=\(made) rejected=\(rejected)")
    }

    /// A latitude of 91 or 1e300 is rejected for a vessel as for a train (D2, fixed by F2): it would list a boat with
    /// a made-up distance and hand MapKit an invalid coordinate.
    @Test func vesselsRejectPositionsThatCantBeReal() {
        for (lat, lon) in [(1e300, 0.0), (91, 0), (0, 181), (-73.99, 40.7), (-1e300, -1e300), (-90, 180), (90.000001, 0)] {
            let real = abs(lat) <= 90 && abs(lon) <= 180
            let vessel = Vessel(vesselTarget(1, lat: lat, lon: lon, timestamp: Self.now))
            #expect((vessel != nil) == real, "lat \(lat) lon \(lon)")
            let train = Train(trainTarget("x", lat: lat, lon: lon, timestamp: Self.now))
            #expect((train != nil) == real, "lat \(lat) lon \(lon)")
            var registry = TargetRegistry()
            registry.apply(.update(vesselTarget(1, lat: lat, lon: lon, timestamp: Self.now)), receivedAt: Self.now)
            #expect(registry.vessels.count == (real ? 1 : 0), "lat \(lat) lon \(lon)")
        }
        // The swapped pair is a real place (lat -73.99 is fine; lon 40.7 is fine): a vessel in Antarctica's sea.
        let swapped = VesselRow(vessel: Vessel(vesselTarget(1, lat: -73.99, lon: 40.7, timestamp: Self.now))!, observer: Self.observer, now: Self.now)
        #expect(swapped.lineOfSight == .tooFar)
        #expect((swapped.distanceMeters ?? 0) > 5_000_000, "listed under out of sight with a 10,000 km distance")
    }

    // MARK: Lists

    @Test func vesselAndTrainListsKeepTheirInvariants() {
        var rng = Chaos.rng("vesselAndTrainListsKeepTheirInvariants")
        for iteration in 0..<400 {
            let vessels = (0..<rng.int(0...25)).compactMap { Vessel(Self.hostileVesselTarget(&rng, mmsi: $0)) }
            let trains = (0..<rng.int(0...25)).compactMap { Train(Self.hostileTrainTarget(&rng, trip: $0)) }
            let observer = rng.pick(Self.observers)
            let units = Units(preferences: rng.pick(FormatterChaosTests.allPreferences), region: rng.pick(FormatterChaosTests.regions))
            let context = Chaos.context("lists", iteration: iteration, "observer=\(String(describing: observer)) vessels=\(vessels.count) trains=\(trains.count)")
            let list = VesselList(vessels: vessels, observer: observer, now: Self.now, units: units)
            let live = vessels.filter { ReportFreshness(lastSeen: $0.lastSeen, now: Self.now) != .expired }
            #expect(list.rows.count == live.count, context)
            #expect(Set(list.rows.map(\.id)).count == list.rows.count, context)
            #expect(list.hasDistances == (observer != nil), context)
            if observer != nil {
                // In sight plus out of sight is every row, once.
                #expect(list.inSight.count + list.outOfSight.count == list.rows.count, context)
                #expect(Set(list.inSight.map(\.id)).isDisjoint(with: list.outOfSight.map(\.id)), context)
                let distances = list.rows.compactMap(\.distanceMeters)
                #expect(distances == distances.sorted(), context)
                #expect(list.closest?.id == list.inSight.first?.id, context)
                #expect(list.others.count == max(0, list.inSight.count - 1), context)
            } else {
                #expect(list.inSight.isEmpty && list.outOfSight.isEmpty && list.closest == nil, context)
                #expect(list.others.count == list.rows.count, context)
            }
            for row in list.rows { #expect(list.row(mmsi: row.vessel.mmsi) != nil, context) }

            let trainList = TrainList(trains: trains, observer: observer, now: Self.now, units: units)
            let liveTrains = trains.filter { ReportFreshness.train(lastSeen: $0.timestamp, now: Self.now) != .expired }
            #expect(trainList.rows.count == liveTrains.count, context)
            #expect(Set(trainList.rows.map(\.id)).count == trainList.rows.count, context)
            #expect(trainList.underground.count == trainList.rows.filter(\.isUnderground).count, context)
            if observer != nil {
                #expect(trainList.inSight.count + trainList.outOfSight.count + trainList.underground.count == trainList.rows.count, context)
                #expect(trainList.aboveGround.count == trainList.rows.count - trainList.underground.count, context)
                let distances = trainList.rows.compactMap(\.distanceMeters)
                #expect(distances == distances.sorted(), context)
            } else {
                #expect(trainList.inSight.isEmpty && trainList.outOfSight.isEmpty, context)
                #expect(trainList.aboveGround.count == trainList.rows.count - trainList.underground.count, context)
            }
            // Counts of what's out there.
            #expect(BrowseScope.liveCount(vessels: vessels, now: Self.now) == live.count, context)
            #expect(BrowseScope.liveCount(trains: trains, now: Self.now) == liveTrains.count, context)
        }
    }

    // MARK: Browse

    static func randomRegion(_ rng: inout SplitMix64) -> MapRegion? {
        switch rng.int(0...7) {
        case 0: return nil
        case 1: return MapRegion(centerLatitude: rng.double(-90...90), centerLongitude: rng.double(-180...180), latitudeDelta: rng.pick([0, -1, .nan, .infinity, 1e300]), longitudeDelta: rng.pick([0, 0.01, 360, .nan]))
        case 2: return MapRegion(centerLatitude: 40.7, centerLongitude: -73.99, latitudeDelta: 360, longitudeDelta: 720)
        default: return MapRegion(centerLatitude: rng.double(40.6...40.8), centerLongitude: rng.double(-74.1 ... -73.9),
                                  latitudeDelta: rng.double(0.001...0.1), longitudeDelta: rng.double(0.001...0.2))
        }
    }

    /// `shared`: also the Settings train switches, which the app merges into the filter only for the menu (the stored
    /// filter and the scope never hold them).
    static func randomFilter(_ rng: inout SplitMix64, shared: Bool = false) -> BrowseFilter {
        var hidden = Set<CameraFilterOption>()
        for category in VesselCategory.allCases where rng.chance(0.2) { hidden.insert(.vessel(category)) }
        if shared, rng.chance(0.2) { hidden.insert(.trains) }
        if shared, rng.chance(0.2) { hidden.insert(.undergroundTrains) }
        return BrowseFilter(hidden: hidden, movingOnly: rng.chance(0.3), onlyOnMap: rng.chance(0.7))
    }

    @Test func browseResultKeepsItsCountsAndTheSelection() {
        var rng = Chaos.rng("browseResultKeepsItsCountsAndTheSelection")
        for iteration in 0..<600 {
            // Unique ids here: the duplicate-MMSI case is its own finding (RegistryChaosTests).
            let vessels = (0..<rng.int(0...30)).compactMap { Vessel(Self.hostileVesselTarget(&rng, mmsi: $0 + 1)) }
            let trains = (0..<rng.int(0...30)).compactMap { Train(Self.hostileTrainTarget(&rng, trip: $0)) }
            let scope = BrowseScope(filter: Self.randomFilter(&rng), region: Self.randomRegion(&rng))
            let keepVessel = rng.chance(0.5) ? vessels.randomElement(using: &rng)?.mmsi ?? 9_999 : nil
            let keepTrain = rng.chance(0.5) ? trains.randomElement(using: &rng)?.id ?? "train:none" : nil
            let observer = rng.pick(Self.observers)
            let result = BrowseResult(vessels: vessels, trains: trains, observer: observer, now: Self.now, scope: scope,
                                      keepVessel: keepVessel, keepTrain: keepTrain)
            let context = Chaos.context("browse", iteration: iteration, "scope=\(scope) keep=\(String(describing: keepVessel)),\(String(describing: keepTrain)) vessels=\(vessels.count) trains=\(trains.count)")

            // The model: what the scope says, worked out from the pieces.
            func onMap(_ c: CLLocationCoordinate2D) -> Bool { scope.region?.contains(c) ?? true }
            let expectedVessels = vessels.filter { v in
                ReportFreshness(lastSeen: v.lastSeen, now: Self.now) != .expired
                    && (v.mmsi == keepVessel || (scope.filter.shows(v) && onMap(DeadReckoning.position(of: v, at: Self.now))))
            }
            let expectedTrains = trains.filter { t in
                ReportFreshness.train(lastSeen: t.timestamp, now: Self.now) != .expired
                    && (t.id == keepTrain || (scope.filter.shows(t) && onMap(DeadReckoning.position(of: t, at: Self.now))))
            }
            #expect(Set(result.vessels.rows.map(\.id)) == Set(expectedVessels.map(\.mmsi)), context)
            #expect(Set(result.trains.rows.map(\.id)) == Set(expectedTrains.map(\.id)), context)
            #expect(Set(result.vessels.rows.map(\.id)).count == result.vessels.rows.count, context)
            #expect(Set(result.trains.rows.map(\.id)).count == result.trains.rows.count, context)

            // Shown plus hidden is everything live, per kind.
            let liveVessels = BrowseScope.liveCount(vessels: vessels, now: Self.now), liveTrains = BrowseScope.liveCount(trains: trains, now: Self.now)
            #expect(result.totalVessels == liveVessels && result.totalTrains == liveTrains, context)
            let hiddenVessels = result.totalVessels - result.vessels.rows.count, hiddenTrains = result.totalTrains - result.trains.rows.count
            #expect(hiddenVessels >= 0 && hiddenTrains >= 0, context)
            #expect(result.vessels.rows.count + hiddenVessels == result.totalVessels, context)
            // The filter alone shows at least what the region as well shows (the kept one aside).
            #expect(result.matchingVessels >= 0 && result.matchingTrains >= 0, context)
            if scope.isLimitedToMap {
                let keptExtra = (keepVessel != nil && result.vessels.row(mmsi: keepVessel!) != nil && !scope.withoutRegion.vessels(vessels, now: Self.now).contains { $0.mmsi == keepVessel }) ? 1 : 0
                #expect(result.matchingVessels + keptExtra >= result.vessels.rows.count, context)
            } else {
                #expect(result.matchingVessels == result.vessels.rows.count && result.matchingTrains == result.trains.rows.count, context)
            }
            // In sight plus out of sight is every row with a location.
            if observer != nil {
                #expect(result.vessels.inSight.count + result.vessels.outOfSight.count == result.vessels.rows.count, context)
                #expect(result.trains.inSight.count + result.trains.outOfSight.count + result.trains.underground.count == result.trains.rows.count, context)
            }
            // A selected boat or train that is still live is kept whatever the filter or the region says.
            if let keepVessel, let vessel = vessels.first(where: { $0.mmsi == keepVessel }),
               ReportFreshness(lastSeen: vessel.lastSeen, now: Self.now) != .expired {
                #expect(result.vessels.row(mmsi: keepVessel) != nil, context)
            }
            if let keepTrain, let train = trains.first(where: { $0.id == keepTrain }),
               ReportFreshness.train(lastSeen: train.timestamp, now: Self.now) != .expired {
                #expect(result.trains.row(id: keepTrain) != nil, context)
            }
            // The texts.
            #expect(!result.vesselCountText.isEmpty && !result.trainCountText.isEmpty, context)
            #expect(result.vesselCountText.hasSuffix("vessel") || result.vesselCountText.hasSuffix("vessels"), context)
            #expect(result.isNarrowed == (scope.isScoped && (result.vessels.rows.count < result.totalVessels || result.trains.rows.count < result.totalTrains)), context)
            #expect((result.scopeNote == nil) == !result.isNarrowed, context)
            for includeTrains in [true, false] {
                let reason = result.emptyReason(includeTrains: includeTrains)
                if reason != nil {
                    #expect(result.vessels.rows.count + (includeTrains ? result.trains.rows.count : 0) == 0, context)
                    #expect(!BrowseText.emptyTitle(reason!).isEmpty && !BrowseText.emptyAction(reason!, filtering: scope.filter.isFiltering).isEmpty, context)
                }
            }
            _ = (result.vesselNote, result.trainNote)
            // Nothing selected, nothing hidden by chance: with no scope everything live is shown.
            if !scope.isScoped {
                #expect(result.vessels.rows.count == liveVessels && result.trains.rows.count == liveTrains, context)
            }
        }
    }

    @Test func browseFilterStorageAndMenuLogic() {
        var rng = Chaos.rng("browseFilterStorageAndMenuLogic")
        for iteration in 0..<2_000 {
            var filter = Self.randomFilter(&rng, shared: true)
            let context = Chaos.context("filter", iteration: iteration, "\(filter)")
            // Stored text round-trips (the shared train switches are left out of it).
            let restored = BrowseFilter(rawValue: filter.rawValue)
            #expect(restored?.hidden == filter.hidden.filter { !$0.isSharedSetting }, context)
            #expect(restored?.movingOnly == filter.movingOnly && restored?.onlyOnMap == filter.onlyOnMap, context)
            #expect(filter.activeFilterCount >= 0 && filter.activeFilterCount <= VesselCategory.allCases.count + 1, context)
            #expect(filter.isFiltering == (filter.activeFilterCount > 0), context)
            for sideBySide in [true, false] {
                #expect(!filter.spokenSummary(sideBySide: sideBySide).isEmpty, context)
                _ = filter.canReset(sideBySide: sideBySide)
            }
            let trainsBefore = filter.hidden.filter(\.isSharedSetting)
            filter.reset()
            #expect(filter.isDefault && filter.hidden.filter(\.isSharedSetting) == trainsBefore, context)
            #expect(!filter.isFiltering, context)
        }
        // Whatever is in the stored text, the filter reads as something and never traps.
        for iteration in 0..<3_000 {
            let junk: String
            switch rng.int(0...3) {
            case 0: junk = String((0..<rng.int(0...80)).map { _ in Character(UnicodeScalar(UInt8(rng.int(32...126)))) })
            case 1: junk = #"{"hidden":["vessel.cargo","nope",7,null],"movingOnly":"yes","onlyOnMap":3}"#
            case 2: junk = #"{"hidden":"vessel.cargo"}"#
            default: junk = String(repeating: "{", count: rng.int(0...2_000))
            }
            let filter = BrowseFilter(rawValue: junk)
            #expect(filter != nil, Chaos.context("junk", iteration: iteration, junk))
            _ = filter?.rawValue
        }
    }

    // MARK: Values from a relay frame that used to trap (C1, C2; fixed by F2)

    static let frameTime = Date(timeIntervalSince1970: 1_700_000_000)

    static func registry(_ frame: String) throws -> TargetRegistry {
        var registry = TargetRegistry()
        registry.apply(try RelayMessage.decode(Data(frame.utf8)), receivedAt: frameTime)
        return registry
    }

    /// A vessel's `"course": 1e300` used to close the app in the Course tile; it's normalized on decode, so the
    /// course text is a plain bearing.
    @Test func hugeVesselCourseFromARelayFrameReadsAsABearing() throws {
        let frame = #"{"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"s","lat":40.7,"lon":-74,"speed":5,"course":1e300,"timestamp":"2023-11-14T22:13:20.000Z","vessel":{"mmsi":1}}}"#
        let vessel = try #require(try Self.registry(frame).vessels.first)
        let cog = try #require(vessel.cog)
        #expect(cog >= 0 && cog < 360)
        let row = VesselRow(vessel: vessel, observer: nil, now: Self.frameTime)
        let text = try #require(row.courseText)
        #expect(text.range(of: #"^(N|NE|E|SE|S|SW|W|NW) \d{1,3}°$"#, options: .regularExpression) != nil, "\(text)")
    }

    /// The same for `"heading": 1e300`, reached by the detail sheet's AIS section (`detailItems`).
    @Test func hugeVesselHeadingFromARelayFrameReadsAsABearing() throws {
        let frame = #"{"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"s","lat":40.7,"lon":-74,"heading":1e300,"timestamp":"2023-11-14T22:13:20.000Z","vessel":{"mmsi":1}}}"#
        let vessel = try #require(try Self.registry(frame).vessels.first)
        let heading = try #require(vessel.heading)
        #expect(heading >= 0 && heading < 360)
        let items = VesselRow(vessel: vessel, observer: nil, now: Self.frameTime).detailItems(now: Self.frameTime)
        #expect(!items.isEmpty)
        for item in items { #expect(!item.value.lowercased().contains("nan") && !item.value.isEmpty, "\(item)") }
    }

    /// And a train's `"course": 1e19`: the train sheet's Heading tile reads a plain bearing.
    @Test func hugeTrainCourseFromARelayFrameReadsAsABearing() throws {
        let frame = #"{"type":"update","target":{"id":"train:nyct:1","kind":"train","source":"s","lat":40.7,"lon":-74,"altitude":20,"speed":5,"course":1e19,"timestamp":"2023-11-14T22:13:20.000Z","train":{"route":"Q","direction":"S","stretch":"manhattan-bridge","underground":false}}}"#
        let train = try #require(try Self.registry(frame).trains.first)
        let text = try #require(TrainRow(train: train, observer: nil, now: Self.frameTime).courseText)
        #expect(text.range(of: #"^(N|NE|E|SE|S|SW|W|NW) \d{1,3}°$"#, options: .regularExpression) != nil, "\(text)")
    }

    /// The camera's compass strip: no ticks for a heading that isn't finite; a huge finite one (1e300) is brought
    /// into [0, 360) first instead of trapping `Int(...)` (it still did before this branch).
    @Test func compassStripTicksForNonFiniteOrHugeHeadings() {
        func pose(_ heading: Double) -> CameraPose {
            CameraPose(headingDegrees: heading, pitchDegrees: 0, horizontalFOVDegrees: 60, viewWidth: 400, viewHeight: 800)
        }
        for heading in [Double.nan, .infinity, -.infinity] {
            #expect(CompassStrip.ticks(pose: pose(heading)).isEmpty, "\(heading)")
        }
        // Such a heading means nothing (its remainder is as good as any), so only: no trap, sane marks.
        for heading in [1e300, -1e300, 1e19, Double.greatestFiniteMagnitude] {
            for tick in CompassStrip.ticks(pose: pose(heading)) {
                #expect((0..<360).contains(tick.degrees) && tick.x.isFinite, "\(heading)")
            }
        }
        // A heading that still has its precision gives the same ticks as its remainder.
        let far = CompassStrip.ticks(pose: pose(725)), near = CompassStrip.ticks(pose: pose(5))
        #expect(!far.isEmpty && far.map(\.degrees) == near.map(\.degrees))
    }
}
