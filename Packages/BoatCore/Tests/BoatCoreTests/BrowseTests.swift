import CoreGraphics
import CoreLocation
import Foundation
import Testing
@testable import BoatCore

@Suite struct MapRegionTests {
    /// About 2 km across, centered on DUMBO.
    let dumbo = MapRegion(centerLatitude: 40.704, centerLongitude: -73.99, latitudeDelta: 0.018, longitudeDelta: 0.024)

    @Test func insideAndOutside() {
        #expect(dumbo.contains(latitude: 40.704, longitude: -73.99))
        #expect(dumbo.contains(latitude: 40.712, longitude: -73.979))
        #expect(!dumbo.contains(latitude: 40.72, longitude: -73.99))
        #expect(!dumbo.contains(latitude: 40.704, longitude: -73.95))
    }

    @Test func aMarkerJustPastTheEdgeCounts() {
        // Half the latitude span is 0.009; the margin adds 3% of the span on each side.
        #expect(dumbo.contains(latitude: 40.704 + 0.0093, longitude: -73.99))
        #expect(!dumbo.contains(latitude: 40.704 + 0.0093, longitude: -73.99, margin: 0))
        #expect(!dumbo.contains(latitude: 40.704 + 0.0097, longitude: -73.99))
    }

    @Test func acrossTheAntimeridian() {
        let fiji = MapRegion(centerLatitude: -17, centerLongitude: 179.5, latitudeDelta: 4, longitudeDelta: 4)
        #expect(fiji.contains(latitude: -17, longitude: -179.5))
        #expect(fiji.contains(latitude: -17, longitude: 178))
        #expect(!fiji.contains(latitude: -17, longitude: -176))
        let west = MapRegion(centerLatitude: 0, centerLongitude: -179.5, latitudeDelta: 2, longitudeDelta: 2)
        #expect(west.contains(latitude: 0, longitude: 179.8))
        #expect(!west.contains(latitude: 0, longitude: 177))
    }

    @Test func boundingTheVisibleCorners() throws {
        func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
        let box = try #require(MapRegion.bounding([c(40.71, -74.0), c(40.71, -73.98), c(40.70, -73.98),
                                                  c(40.70, -74.0)]))
        #expect(abs(box.centerLatitude - 40.705) < 1e-9)
        #expect(abs(box.centerLongitude + 73.99) < 1e-9)
        #expect(abs(box.latitudeDelta - 0.01) < 1e-9)
        #expect(abs(box.longitudeDelta - 0.02) < 1e-9)
        let across = try #require(MapRegion.bounding([c(1, 179), c(-1, -179)]))
        #expect(abs(across.longitudeDelta - 2) < 1e-9)
        #expect(abs(abs(across.centerLongitude) - 180) < 1e-9)
        #expect(across.contains(latitude: 0, longitude: 179.5))
        #expect(across.contains(latitude: 0, longitude: -179.5))
        #expect(MapRegion.bounding([]) == nil)
        #expect(MapRegion.bounding([c(.nan, 0)]) == nil)
        // Corners that collapse to a point or a line hold nothing: no region, rather than an empty one.
        #expect(MapRegion.bounding([c(40.7, -74), c(40.7, -74), c(40.7, -74), c(40.7, -74)]) == nil)
        #expect(MapRegion.bounding([c(40.7, -74), c(40.8, -74), c(40.8, -74), c(40.7, -74)]) == nil)
        #expect(MapRegion.bounding([c(40.7, -74), c(40.7, -73.9)]) == nil)
    }

    @Test func wholeWorldAndBadSpans() {
        let world = MapRegion(centerLatitude: 0, centerLongitude: 0, latitudeDelta: 180, longitudeDelta: 360)
        #expect(world.contains(latitude: 40.7, longitude: -73.99))
        for bad in [0.0, -1, .nan, .infinity] {
            #expect(!MapRegion(centerLatitude: 40.7, centerLongitude: -73.99, latitudeDelta: bad, longitudeDelta: 0.1)
                .contains(latitude: 40.7, longitude: -73.99))
        }
        #expect(!dumbo.contains(latitude: .nan, longitude: -73.99))
    }
}

@Suite struct BrowseFilterTests {
    let now = Date(timeIntervalSince1970: 1_794_319_200)

    func boat(_ mmsi: Int, type: Int?, lat: Double = 40.705, lon: Double = -73.99, sog: Double? = 5) -> Vessel {
        testVessel(mmsi: mmsi, shipType: type, lat: lat, lon: lon, sog: sog, cog: 90, timestamp: now)
    }

    @Test func defaultsShowEverythingAndFollowTheMap() {
        let filter = BrowseFilter.default
        #expect(filter.onlyOnMap)
        #expect(!filter.isFiltering)
        #expect(filter.isDefault)
        #expect(filter.shows(boat(1, type: 70)))
        #expect(filter.shows(testTrain("t", speed: 0, timestamp: now)))
    }

    @Test func typesAndMovingOnly() {
        var filter = BrowseFilter.default
        filter.setShown(.vessel(.cargo), false)
        #expect(!filter.shows(boat(1, type: 70)))
        #expect(filter.shows(boat(2, type: 60)))
        #expect(filter.activeFilterCount == 1)
        filter.movingOnly = true
        #expect(!filter.shows(boat(3, type: 60, sog: 0.2)))
        #expect(!filter.shows(testTrain("t", speed: 0, timestamp: now)))
        #expect(filter.shows(testTrain("u", speed: 15, timestamp: now)))
        #expect(filter.activeFilterCount == 2)
        #expect(filter.spokenSummary(sideBySide: true) == "2 filters on, only what's on the map")
        #expect(filter.spokenSummary(sideBySide: false) == "2 filters on")
    }

    @Test func trainSwitchesAreSettingsNotFilters() {
        let merged = BrowseFilter.default.merging(shared: [.trains: false, .undergroundTrains: true])
        #expect(!merged.isShown(.trains))
        #expect(!merged.isFiltering)
        #expect(merged.isDefault)
        #expect(!merged.isAvailable(.undergroundTrains))
        var reset = merged
        reset.setShown(.vessel(.pleasure), false)
        reset.onlyOnMap = false
        #expect(!reset.isDefault)
        reset.reset()
        #expect(reset.onlyOnMap)
        #expect(reset.isShown(.vessel(.pleasure)))
        #expect(!reset.isShown(.trains), "Reset leaves Settings' train switch alone")
        #expect(!merged.rawValue.contains("trains"), "the train switches aren't stored")
    }

    @Test func storedRoundTripAndBadValues() {
        let filter = BrowseFilter(hidden: [.vessel(.cargo), .trains], movingOnly: true, onlyOnMap: false)
        let back = BrowseFilter(rawValue: filter.rawValue)
        #expect(back == BrowseFilter(hidden: [.vessel(.cargo)], movingOnly: true, onlyOnMap: false))
        #expect(BrowseFilter(rawValue: "nonsense") == .default)
        #expect(BrowseFilter(rawValue: #"{"hidden":["vessel.zeppelin"]}"#) == .default)
        #expect(BrowseFilter.storageKey != CameraFilter.storageKey)
    }

    @Test func scopeKeepsTheSelectionAndLimitsToTheRegion() {
        let region = MapRegion(centerLatitude: 40.705, centerLongitude: -73.99, latitudeDelta: 0.01,
                               longitudeDelta: 0.01)
        let inside = boat(1, type: 70)
        let outside = boat(2, type: 60, lat: 40.73)
        let selectedOutside = boat(3, type: 60, lat: 40.73)
        var filter = BrowseFilter.default
        filter.setShown(.vessel(.cargo), false)
        let scope = BrowseScope(filter: filter, region: region)
        #expect(scope.vessels([inside, outside, selectedOutside], now: now, keep: 3).map(\.mmsi) == [3])
        #expect(scope.withoutRegion.vessels([inside, outside], now: now).map(\.mmsi) == [2])
        #expect(BrowseScope(region: region).vessels([inside, outside], now: now).map(\.mmsi) == [1])
        // Underground or not, a train is on the map where it is.
        let under = testTrain("u", stretch: nil, speed: 0, timestamp: now)
        let unscoped = BrowseScope().trains([under], now: now)
        #expect(unscoped.count == 1)
    }

    @Test func regionOnlySideBySideWithTheToggleOn() {
        let region = MapRegion(centerLatitude: 40.7, centerLongitude: -74, latitudeDelta: 0.1, longitudeDelta: 0.1)
        #expect(BrowseScope.region(region, filter: .default, sideBySide: true) == region)
        #expect(BrowseScope.region(region, filter: .default, sideBySide: false) == nil)
        #expect(BrowseScope.region(region, filter: BrowseFilter(onlyOnMap: false), sideBySide: true) == nil)
        #expect(BrowseScope.region(nil, filter: .default, sideBySide: true) == nil)
    }

    @Test func liveCountsLeaveOutAgedOut() {
        let old = testVessel(mmsi: 9, lat: 40.7, lon: -73.99, timestamp: now.addingTimeInterval(-3_600))
        #expect(BrowseScope.liveCount(vessels: [boat(1, type: 60), old], now: now) == 1)
        #expect(BrowseScope.liveCount(trains: [testTrain("a", timestamp: now),
                                               testTrain("b", timestamp: now.addingTimeInterval(-120))], now: now) == 1)
    }
}

@Suite struct BrowseTextTests {
    let region = MapRegion(centerLatitude: 40.7, centerLongitude: -74, latitudeDelta: 0.1, longitudeDelta: 0.1)

    @Test func countLine() {
        #expect(BrowseText.vesselCount(shown: 12, total: 42, scoped: true) == "12 of 42 vessels")
        #expect(BrowseText.vesselCount(shown: 1, total: 1, scoped: true) == "1 of 1 vessel")
        #expect(BrowseText.vesselCount(shown: 42, total: 42, scoped: false) == "42 vessels")
        #expect(BrowseText.trainCount(shown: 9, total: 101, scoped: true) == "9 of 101 trains")
        #expect(BrowseText.trainCount(shown: 101, total: 101, scoped: false) == "101 trains")
        #expect(BrowseText.trainCount(shown: 0, total: 0, scoped: true) == "0 trains")
        var filtered = BrowseFilter.default
        filtered.movingOnly = true
        #expect(BrowseText.scopeNote(BrowseScope(region: region)) == "On the map:")
        #expect(BrowseText.scopeNote(BrowseScope(filter: filtered)) == "With filters on:")
        #expect(BrowseText.scopeNote(BrowseScope(filter: filtered, region: region)) == "On the map, with filters on:")
        #expect(BrowseText.scopeNote(BrowseScope()) == nil)
        #expect(BrowseText.spokenStatusLine(status: "Live", vessels: "1 of 4 vessels", trains: "0 of 6 trains",
                                            scope: "On the map:") == "Live. On the map: 1 of 4 vessels, 0 of 6 trains")
        #expect(BrowseText.spokenStatusLine(status: "Live", vessels: "4 vessels", trains: nil, scope: nil)
                == "Live, 4 vessels")
    }

    @Test func emptyStates() {
        var filtered = BrowseFilter.default
        filtered.setShown(.vessel(.cargo), false)
        let onMap = BrowseScope(region: region)
        #expect(BrowseText.emptyReason(shown: 0, matchingWithoutRegion: 5, total: 5, scope: onMap) == .offMap)
        #expect(BrowseText.emptyReason(shown: 0, matchingWithoutRegion: 0, total: 5,
                                       scope: BrowseScope(filter: filtered, region: region)) == .filtered)
        #expect(BrowseText.emptyReason(shown: 0, matchingWithoutRegion: 0, total: 0, scope: onMap) == nil)
        #expect(BrowseText.emptyReason(shown: 2, matchingWithoutRegion: 5, total: 5, scope: onMap) == nil)
        #expect(BrowseText.emptyTitle(.offMap) == "Nothing on this part of the map")
        #expect(BrowseText.emptyAction(.offMap) == "Show the whole list")
        #expect(BrowseText.emptyAction(.offMap, filtering: true) == "Show all that match your filters")
        #expect(BrowseText.emptyAction(.filtered) == "Reset filters")
        #expect(BrowseText.noneNote(kind: .vessel, shown: 0, matchingWithoutRegion: 3, total: 3, scope: onMap)
                == "No boats on this part of the map")
        #expect(BrowseText.noneNote(kind: .train, shown: 0, matchingWithoutRegion: 0, total: 3,
                                    scope: BrowseScope(filter: filtered)) == "No trains match your filters")
        #expect(BrowseText.noneNote(kind: .train, shown: 0, matchingWithoutRegion: 0, total: 0, scope: onMap) == nil)
        #expect(BrowseText.noneNote(kind: .vessel, shown: 0, matchingWithoutRegion: 0, total: 3,
                                    scope: BrowseScope()) == nil)
    }
}

@Suite struct BrowseResultTests {
    let now = Date(timeIntervalSince1970: 1_794_319_200)
    let observer = CLLocationCoordinate2D(latitude: 40.7046, longitude: -73.9913)
    let region = MapRegion(centerLatitude: 40.7062, centerLongitude: -73.9931, latitudeDelta: 0.004,
                           longitudeDelta: 0.004)

    var boats: [Vessel] {
        [testVessel(mmsi: 1, shipType: 60, lat: 40.7062, lon: -73.9931, sog: 14, timestamp: now),
         testVessel(mmsi: 2, shipType: 52, lat: 40.7200, lon: -73.9700, sog: 6, timestamp: now)]
    }

    @Test func unscopedCountsEverything() {
        let result = BrowseResult(vessels: boats, trains: [], observer: observer, now: now, scope: BrowseScope())
        #expect(result.vesselCountText == "2 vessels")
        #expect(result.scopeNote == nil)
        #expect(result.emptyReason(includeTrains: true) == nil)
    }

    @Test func onTheMap() {
        let result = BrowseResult(vessels: boats, trains: [], observer: observer, now: now,
                                  scope: BrowseScope(region: region))
        #expect(result.vessels.rows.map(\.id) == [1])
        #expect(result.vesselCountText == "1 of 2 vessels")
        #expect(result.trainCountText == "0 trains")
        #expect(result.scopeNote == "On the map:")
        let kept = BrowseResult(vessels: boats, trains: [], observer: observer, now: now,
                                scope: BrowseScope(region: region), keepVessel: 2)
        #expect(kept.vessels.rows.map(\.id).sorted() == [1, 2])
        // Everything on the map: counted as if unscoped.
        let whole = MapRegion(centerLatitude: 40.705, centerLongitude: -73.99, latitudeDelta: 0.1, longitudeDelta: 0.1)
        let all = BrowseResult(vessels: boats, trains: [], observer: observer, now: now,
                               scope: BrowseScope(region: whole))
        #expect(!all.isNarrowed)
        #expect(all.vesselCountText == "2 vessels")
        #expect(all.scopeNote == nil)
    }

    @Test func nothingHere() {
        let far = MapRegion(centerLatitude: 40.68, centerLongitude: -74.03, latitudeDelta: 0.002, longitudeDelta: 0.002)
        let result = BrowseResult(vessels: boats, trains: [], observer: observer, now: now,
                                  scope: BrowseScope(region: far))
        #expect(result.emptyReason(includeTrains: true) == .offMap)
        var filter = BrowseFilter.default
        filter.setShown(.vessel(.passenger), false)
        filter.setShown(.vessel(.service), false)
        let none = BrowseResult(vessels: boats, trains: [], observer: observer, now: now,
                                scope: BrowseScope(filter: filter))
        #expect(none.emptyReason(includeTrains: true) == .filtered)
        #expect(none.vesselNote == "No boats match your filters")
    }

    @Test func trainsInMphByDefault() {
        let train = testTrain("t", stretch: "manhattan-bridge", speed: 18, timestamp: now)
        let result = BrowseResult(vessels: [], trains: [train], observer: nil, now: now, scope: BrowseScope())
        #expect(result.trains.rows.first?.speedText == "21\u{00A0}mph")
    }
}
