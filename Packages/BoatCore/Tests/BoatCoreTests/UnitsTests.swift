import Foundation
import Testing
@testable import BoatCore

private let nbsp = "\u{00A0}"

@Suite struct UnitsChoiceTests {
    @Test func standardIsKnotsOnTheWaterAndInTheAirMphForTrains() {
        let us = Units.standard
        #expect(us.speedUnit(for: .vessel) == .knots)
        #expect(us.speedUnit(for: .train) == .milesPerHour)
        #expect(us.speedUnit(for: .aircraft) == .knots)
        let metric = Units(region: .metric)
        #expect(metric.speedUnit(for: .vessel) == .knots)
        #expect(metric.speedUnit(for: .train) == .kilometersPerHour)
        #expect(metric.speedUnit(for: .aircraft) == .knots)
    }

    @Test(arguments: [(SpeedChoice.knots, SpeedUnit.knots), (.milesPerHour, .milesPerHour),
                      (.kilometersPerHour, .kilometersPerHour)])
    func aSpeedChoiceAppliesToEveryKind(choice: SpeedChoice, unit: SpeedUnit) {
        for region in [MeasurementUnits.imperial, .metric] {
            let units = Units(preferences: UnitPreferences(speed: choice), region: region)
            for kind in VehicleKind.allCases {
                #expect(units.speedUnit(for: kind) == unit)
            }
        }
    }

    @Test func distanceAndHeightFollowTheRegionUnlessChosen() {
        #expect(Units(region: .imperial).distanceUnit == .miles)
        #expect(Units(region: .metric).distanceUnit == .kilometers)
        #expect(Units(region: .imperial).heightUnit == .feet)
        #expect(Units(region: .metric).heightUnit == .meters)
        let chosen = Units(preferences: UnitPreferences(distance: .nauticalMiles, height: .meters), region: .imperial)
        #expect(chosen.distanceUnit == .nauticalMiles)
        #expect(chosen.heightUnit == .meters)
        #expect(Units(preferences: UnitPreferences(distance: .miles, height: .feet), region: .metric).distanceUnit == .miles)
        // Never nautical miles unless asked: someone on shore reads distances in land units.
        #expect(DistanceChoice.allCases.filter { $0 != .nauticalMiles }.allSatisfy {
            Units(preferences: UnitPreferences(distance: $0)).distanceUnit != .nauticalMiles
        })
    }

    @Test func regionFromTheLocale() {
        #expect(Units.region(of: Locale(identifier: "en_US")) == .imperial)
        #expect(Units.region(of: Locale(identifier: "en_GB")) == .imperial)
        #expect(Units.region(of: Locale(identifier: "de_DE")) == .metric)
        #expect(Units.region(of: Locale(identifier: "fr_CA")) == .metric)
    }

    @Test func storedRawValuesStayPut() {
        // Persisted in UserDefaults: renaming a case would forget the user's choice.
        #expect(SpeedChoice.allCases.map(\.rawValue) == ["standard", "knots", "mph", "kmh"])
        #expect(DistanceChoice.allCases.map(\.rawValue) == ["automatic", "miles", "kilometers", "nauticalMiles"])
        #expect(HeightChoice.allCases.map(\.rawValue) == ["automatic", "feet", "meters"])
        #expect(SpeedChoice.standard.title == "Standard for each vehicle")
        #expect(Units.standard.standardSpeedNote == "Knots for boats, mph for trains")
        #expect(Units(preferences: UnitPreferences(speed: .knots), region: .metric).standardSpeedNote
                == "Knots for boats, km/h for trains")
    }
}

@Suite struct UnitsSpeedTests {
    @Test func boatsKeepOneDecimalInKnots() {
        #expect(Units.standard.speed(knots: 14.2, kind: .vessel) == "14.2\(nbsp)kn")
        #expect(Units.standard.spokenSpeed(knots: 14.2, kind: .vessel) == "14 knots")
        #expect(Units.standard.spokenSpeed(knots: 0.8, kind: .vessel) == "1 knot")
        // Unchanged from before units could be chosen.
        #expect(Units.standard.speed(knots: 0, kind: .vessel) == "0.0\(nbsp)kn")
        #expect(Units.standard.spokenSpeed(knots: 0.6, kind: .vessel) == "1 knot")
    }

    @Test func trainsAreWholeMphOrKmhNeverKnots() {
        // 18 kn = 20.7 mph = 33.3 km/h.
        #expect(Units.standard.speed(knots: 18, kind: .train) == "21\(nbsp)mph")
        #expect(Units.standard.spokenSpeed(knots: 18, kind: .train) == "21 miles per hour")
        #expect(Units(region: .metric).speed(knots: 18, kind: .train) == "33\(nbsp)km/h")
        #expect(Units(region: .metric).spokenSpeed(knots: 18, kind: .train) == "33 kilometers per hour")
        #expect(Units.standard.spokenSpeed(knots: 0.9, kind: .train) == "1 mile per hour")
        #expect(Units(region: .metric).spokenSpeed(knots: 0.5, kind: .train) == "1 kilometer per hour")
    }

    @Test func overridesConvertEveryKind() {
        let kmh = Units(preferences: UnitPreferences(speed: .kilometersPerHour))
        #expect(kmh.speed(knots: 10, kind: .vessel) == "18.5\(nbsp)km/h")
        #expect(kmh.speed(knots: 10, kind: .train) == "19\(nbsp)km/h")
        let mph = Units(preferences: UnitPreferences(speed: .milesPerHour))
        #expect(mph.speed(knots: 10, kind: .vessel) == "11.5\(nbsp)mph")
        #expect(mph.spokenSpeed(knots: 10, kind: .vessel) == "12 miles per hour")
        let knots = Units(preferences: UnitPreferences(speed: .knots))
        #expect(knots.speed(knots: 18.4, kind: .train) == "18\(nbsp)kn")
        #expect(knots.spokenSpeed(knots: 18.4, kind: .train) == "18 knots")
    }

    @Test func aircraftWillBeKnots() {
        #expect(Units.standard.speed(knots: 140, kind: .aircraft) == "140\(nbsp)kn")
        #expect(Units(region: .metric).spokenSpeed(knots: 140, kind: .aircraft) == "140 knots")
    }
}

@Suite struct UnitsDistanceTests {
    /// The same text as before units could be chosen (feet to the nearest 10 under a tenth of a mile).
    @Test(arguments: [
        (100.0, "330\u{00A0}ft", "330 feet"),
        (158.0, "520\u{00A0}ft", "520 feet"),
        (170.0, "0.1\u{00A0}mi", "0.1 miles"),
        (322.0, "0.2\u{00A0}mi", "0.2 miles"),
        (1_609.344, "1.0\u{00A0}mi", "1 mile"),
        (2_500.0, "1.6\u{00A0}mi", "1.6 miles"),
    ])
    func milesAsBefore(meters: Double, shown: String, spoken: String) {
        #expect(Units.standard.distance(meters: meters) == shown)
        #expect(Units.standard.spokenDistance(meters: meters) == spoken)
    }

    @Test func kilometersAndMeters() {
        let metric = Units(region: .metric)
        #expect(metric.distance(meters: 1_400) == "1.4\(nbsp)km")
        #expect(metric.distance(meters: 94) == "90\(nbsp)m")
        #expect(metric.spokenDistance(meters: 1_000) == "1 kilometer")
        #expect(metric.spokenDistance(meters: 400) == "0.4 kilometers")
        #expect(metric.spokenDistance(meters: 50) == "50 meters")
    }

    @Test func nauticalMilesOnlyWhenChosenSmallDistancesInTheHeightUnit() {
        let nmi = Units(preferences: UnitPreferences(distance: .nauticalMiles))
        #expect(nmi.distance(meters: 1_852) == "1.0\(nbsp)nmi")
        #expect(nmi.spokenDistance(meters: 1_852) == "1 nautical mile")
        #expect(nmi.spokenDistance(meters: 600) == "0.3 nautical miles")
        #expect(nmi.distance(meters: 100) == "330\(nbsp)ft")
        let nmiMeters = Units(preferences: UnitPreferences(distance: .nauticalMiles, height: .meters))
        #expect(nmiMeters.distance(meters: 100) == "100\(nbsp)m")
    }

    @Test func cameraRadiusLabelsFollowTheUnitStoredMetersDont() {
        let km = Units(preferences: UnitPreferences(distance: .kilometers))
        #expect(CameraRadius.allCases.map { $0.text(units: km) }
                == ["0.8", "1.6", "3.2", "5", "8", "16"].map { "\($0)\(nbsp)km" })
        #expect(CameraRadius.oneMile.spokenText(units: km) == "1.6 kilometers")
        let nmi = Units(preferences: UnitPreferences(distance: .nauticalMiles))
        #expect(CameraRadius.threeMiles.text(units: nmi) == "2.7\(nbsp)nmi")
        #expect(CameraRadius.allCases.map { $0.text(units: .standard) } == CameraRadius.allCases.map(\.text))
        #expect(CameraFilter(radius: .oneMile).emptyMessage(units: km) == "Nothing in sight within 1.6\(nbsp)km")
        #expect(CameraFilter.default.spokenSummary(units: km) == "Radius 5 kilometers, no filters on")
        // The stored value is meters whatever the unit.
        #expect(CameraFilter(radius: .oneMile).rawValue.contains("\"radius\":1600"))
    }
}

@Suite struct UnitsHeightTests {
    @Test func feetToTheNearestTenMetersWhole() {
        #expect(Units.standard.height(meters: 12) == "40\(nbsp)ft")
        #expect(Units.standard.height(meters: -12, spoken: true) == "40 feet")
        let meters = Units(preferences: UnitPreferences(height: .meters))
        #expect(meters.height(meters: 12.4) == "12\(nbsp)m")
        #expect(meters.height(meters: 1, spoken: true) == "1 meter")
    }

    @Test func oneFormatterForEveryQuantity() {
        let p = UnitPreferences(speed: .kilometersPerHour, distance: .nauticalMiles, height: .meters)
        #expect(Units.format(10, .speed, kind: .train, preferences: p, region: .imperial) == "19\(nbsp)km/h")
        #expect(Units.format(10, .speed, kind: .train, preferences: p, region: .imperial, spoken: true)
                == "19 kilometers per hour")
        #expect(Units.format(3_704, .distance, kind: .vessel, preferences: p, region: .imperial) == "2.0\(nbsp)nmi")
        #expect(Units.format(12, .height, kind: .train, preferences: p, region: .imperial, spoken: true) == "12 meters")
        #expect(Units.format(18, .speed, kind: .train, preferences: .default, region: .imperial) == "21\(nbsp)mph")
        #expect(Units.format(18, .speed, kind: .vessel, preferences: .default, region: .metric) == "18.0\(nbsp)kn")
    }

    @Test func rowsUseTheirUnits() {
        let now = Date(timeIntervalSince1970: 1_794_319_200)
        let metric = Units(region: .metric)
        let boat = VesselRow(vessel: testVessel(mmsi: 1, shipType: 60, lat: 40.71, lon: -73.99, sog: 10, cog: 90,
                                                timestamp: now),
                             observer: .init(latitude: 40.70, longitude: -73.99), now: now, units: metric)
        #expect(boat.speedText == "10.0\(nbsp)kn")
        #expect(boat.distanceText?.hasSuffix("km") == true)
        #expect(boat.accessibilityLabel().contains("kilometers"))
        let train = TrainRow(train: testTrain("t", stretch: "manhattan-bridge", speed: 18, timestamp: now),
                             observer: nil, now: now, units: metric)
        #expect(train.speedText == "33\(nbsp)km/h")
        #expect(train.accessibilityLabel().hasSuffix("33 kilometers per hour"))
        let stopped = TrainRow(train: testTrain("s", speed: 0, timestamp: now), observer: nil, now: now, units: metric)
        #expect(stopped.speedText == "Stopped")
    }
}

@Suite struct UnitsBadValueTests {
    @Test(arguments: [1e30, -5, .nan, .infinity, -.infinity, 1e308])
    func neverTraps(value: Double) {
        let all = [Units.standard, Units(region: .metric),
                   Units(preferences: UnitPreferences(speed: .kilometersPerHour, distance: .nauticalMiles,
                                                      height: .meters))]
        for units in all {
            for kind in VehicleKind.allCases {
                #expect(!units.speed(knots: value, kind: kind).isEmpty)
                #expect(!units.spokenSpeed(knots: value, kind: kind).isEmpty)
            }
            #expect(!units.distance(meters: value).isEmpty)
            #expect(!units.spokenDistance(meters: value).isEmpty)
            #expect(!units.height(meters: value).isEmpty)
            #expect(!units.height(meters: value, spoken: true).isEmpty)
        }
    }

    @Test func clampedValues() {
        #expect(Units.standard.speed(knots: 1e30, kind: .vessel) == "1000.0\u{00A0}kn")
        #expect(Units.standard.speed(knots: -3, kind: .train) == "0\u{00A0}mph")
        #expect(Units.standard.speed(knots: .nan, kind: .vessel) == "0.0\u{00A0}kn")
        #expect(Units.standard.height(meters: -1e30) == "328080\u{00A0}ft")
        #expect(Units.standard.distance(meters: -10) == "0\u{00A0}ft")
    }

    @Test func absurdSpeedsDecodeAsNoSpeed() {
        let now = Date(timeIntervalSince1970: 1_794_319_200)
        #expect(testTrain("fast", speed: 250, timestamp: now).speed == nil)
        #expect(testTrain("ok", speed: 40, timestamp: now).speed == 40)
        #expect(testVessel(mmsi: 1, lat: 40.7, lon: -74, sog: 300, timestamp: now).sog == nil)
        #expect(testVessel(mmsi: 2, lat: 40.7, lon: -74, sog: -1, timestamp: now).sog == nil)
        #expect(testVessel(mmsi: 3, lat: 40.7, lon: -74, sog: 14.2, timestamp: now).sog == 14.2)
    }
}

@Suite struct UnitsProseTests {
    @Test func rangeAndWedgeFollowTheUnits() {
        #expect(Units.standard.outOfSightNote == "The boats below are behind land or more than 3 miles away.")
        #expect(Units(region: .metric).outOfSightNote == "The boats below are behind land or more than 5 kilometers away.")
        #expect(ListSection.boatsOutOfSight.hint(units: .standard) == "Boats behind land or more than 3 miles away")
        #expect(MapKey.courseWedge(units: .standard).hasSuffix("(over 0.5\u{00A0}kn)"))
        #expect(MapKey.courseWedge(units: Units(preferences: UnitPreferences(speed: .kilometersPerHour)))
                .hasSuffix("(over 0.9\u{00A0}km/h)"))
        #expect(CameraRadius.default.meters == Sightlines.maxRangeMeters)
    }
}

@Suite struct UnitsSettingsTextTests {
    @Test func footerAndSpokenChoices() {
        #expect(Units.standard.unitsFooter == "Standard speed: knots for boats, mph for trains. Automatic follows your region.")
        #expect(Units(region: .metric).unitsFooter.hasPrefix("Standard speed: knots for boats, km/h for trains."))
        #expect(SpeedChoice.allCases.map(\.spokenTitle)
                == ["Standard for each vehicle", "Knots", "Miles per hour", "Kilometers per hour"])
    }

    @Test func resetOnlyWhenItChangesSomething() {
        let offMap = BrowseFilter(onlyOnMap: false)
        #expect(!offMap.canReset(sideBySide: false))
        #expect(offMap.canReset(sideBySide: true))
        var types = BrowseFilter.default
        types.movingOnly = true
        #expect(types.canReset(sideBySide: false))
        #expect(!BrowseFilter.default.canReset(sideBySide: true))
    }
}
