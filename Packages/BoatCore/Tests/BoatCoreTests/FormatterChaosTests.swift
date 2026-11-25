import CoreGraphics
import CoreLocation
import Foundation
import Testing
@testable import BoatCore

/// Text a number turned into must read as a number: not empty, no "nan" or "inf", no "-0", and (for the texts that
/// drop their sign or can't be negative) no minus sign.
func isCleanNumberText(_ text: String, allowMinus: Bool = false) -> Bool {
    let lower = text.lowercased()
    return !text.isEmpty && !lower.contains("nan") && !lower.contains("inf") && !lower.contains("-0")
        && (allowMinus || !text.contains("-")) && !text.contains("−")
}

/// Wide random doubles: log-uniform magnitudes from 1e-12 to 1e30, either sign, and now and then a special.
func chaosDouble(_ rng: inout SplitMix64, specials: Bool = true) -> Double {
    if specials, rng.chance(0.08) {
        return rng.pick([.nan, .infinity, -.infinity, 0, -0.0, 1e300, -1e300, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
                         .leastNonzeroMagnitude, Double(Int.max), Double(Int.min), 9.3e18, -9.3e18])
    }
    let magnitude = pow(10, rng.double(-12...30))
    return rng.chance(0.5) ? magnitude : -magnitude
}

/// The text formatters under random and hostile numbers: no trap, clean text. The values that used to trap (C2, C3)
/// are checked at the end.
@Suite(.timeLimit(.minutes(1))) struct FormatterChaosTests {
    static let allPreferences: [UnitPreferences] = SpeedChoice.allCases.flatMap { speed in
        DistanceChoice.allCases.flatMap { distance in
            HeightChoice.allCases.map { UnitPreferences(speed: speed, distance: distance, height: $0) }
        }
    }
    static let regions: [MeasurementUnits] = [.imperial, .metric]

    // MARK: Units

    @Test func everyUnitsCombinationHandlesAnyDouble() {
        var rng = Chaos.rng("everyUnitsCombinationHandlesAnyDouble")
        // Every combination once with the nasty values, then random ones.
        let nasty: [Double] = [.nan, .infinity, -.infinity, 0, -0.0, 1e300, -1e300, .greatestFiniteMagnitude, .leastNonzeroMagnitude,
                               Double(Int.max), Double(Int.min), 0.04, 0.0499, 0.05, 9.99, 10, 99.9, 100, 1e5, 1e7, 2e7, 20_000_000.1]
        var inputs: [(UnitPreferences, MeasurementUnits, Double)] = []
        for preferences in Self.allPreferences { for region in Self.regions { for value in nasty { inputs.append((preferences, region, value)) } } }
        for _ in 0..<10_000 { inputs.append((rng.pick(Self.allPreferences), rng.pick(Self.regions), chaosDouble(&rng))) }
        for (iteration, (preferences, region, value)) in inputs.enumerated() {
            let units = Units(preferences: preferences, region: region)
            let context = Chaos.context("units", iteration: iteration, "\(preferences) \(region) \(value)")
            for kind in VehicleKind.allCases {
                for spoken in [false, true] {
                    let speed = units.format(value, .speed, kind: kind, spoken: spoken)
                    #expect(isCleanNumberText(speed), context)
                }
                #expect(isCleanNumberText(units.speed(knots: value, kind: kind)), context)
                #expect(isCleanNumberText(units.spokenSpeed(knots: value, kind: kind)), context)
            }
            for spoken in [false, true] {
                #expect(isCleanNumberText(units.format(value, .distance, kind: .vessel, spoken: spoken)), context)
                #expect(isCleanNumberText(units.format(value, .height, kind: .vessel, spoken: spoken)), context)
            }
            #expect(isCleanNumberText(units.distance(meters: value)), context)
            #expect(isCleanNumberText(units.spokenDistance(meters: value)), context)
            #expect(isCleanNumberText(units.height(meters: value)), context)
            #expect(isCleanNumberText(units.height(meters: value, spoken: true)), context)
            #expect(isCleanNumberText(Units.format(value, .distance, kind: .train, preferences: preferences, region: region)), context)
        }
    }

    @Test func unitNotesAndRoundDistancesStayClean() {
        var rng = Chaos.rng("unitNotesAndRoundDistancesStayClean")
        for iteration in 0..<3_000 {
            let units = Units(preferences: rng.pick(Self.allPreferences), region: rng.pick(Self.regions))
            let meters = pow(10, rng.double(2...7)), miles = rng.pick([0.5, 1, 2, 3, 5, 10, 25, 100])
            let context = Chaos.context("units notes", iteration: iteration, "\(units) \(meters) \(miles)")
            #expect(isCleanNumberText(units.roundDistance(meters: meters, miles: miles)), context)
            #expect(isCleanNumberText(units.spokenRoundDistance(meters: meters, miles: miles)), context)
            #expect(!units.standardSpeedNote.isEmpty && !units.sightRangeText.isEmpty && !units.outOfSightNote.isEmpty, context)
            #expect(!units.unitsFooter.isEmpty, context)
            for radius in CameraRadius.allCases {
                #expect(isCleanNumberText(radius.text(units: units)), context)
                #expect(isCleanNumberText(radius.spokenText(units: units)), context)
            }
            #expect(!MapKey.courseWedge(units: units).isEmpty)
        }
    }

    /// Bigger is never smaller within a unit, up to the clamp: a longer distance never reads as a shorter one.
    @Test func distanceTextIsMonotonicWithinAUnit() {
        var rng = Chaos.rng("distanceTextIsMonotonicWithinAUnit")
        for iteration in 0..<3_000 {
            let units = Units(preferences: UnitPreferences(distance: rng.pick([.miles, .kilometers, .nauticalMiles])), region: rng.pick(Self.regions))
            let a = pow(10, rng.double(1...6.5)), b = a * rng.double(1...3)
            let number = { (text: String) -> Double? in Double(text.split(separator: "\u{00A0}").first ?? "") }
            // Compare within the same display unit only (feet vs miles switch under a tenth of the unit).
            let ta = units.distance(meters: a), tb = units.distance(meters: b)
            if ta.hasSuffix(tb.split(separator: "\u{00A0}").last.map(String.init) ?? "?"), let na = number(ta), let nb = number(tb) {
                #expect(na <= nb, Chaos.context("monotonic", iteration: iteration, "\(units.distanceUnit) \(a) -> \(ta), \(b) -> \(tb)"))
            }
        }
    }

    // MARK: TrainText and VesselDetailText

    @Test func trainTextHandlesAnyFiniteHeightAndStaysClean() {
        var rng = Chaos.rng("trainTextHandlesAnyFiniteHeightAndStaysClean")
        for iteration in 0..<10_000 {
            let meters = chaosDouble(&rng, specials: false)
            let units = rng.pick(Self.regions), estimated = rng.chance(0.5)
            let context = Chaos.context("trainText", iteration: iteration, "\(meters) \(units) \(estimated)")
            for text in [TrainText.relativeHeight(meters: meters, estimated: estimated, units: units),
                         TrainText.spokenRelativeHeight(meters: meters, estimated: estimated, units: units),
                         TrainText.belowStreet(meters: meters, estimated: estimated, units: units),
                         TrainText.spokenBelowStreet(meters: meters, estimated: estimated, units: units),
                         TrainText.compactDepth(meters: meters, estimated: estimated, units: units)] {
                #expect(isCleanNumberText(text), context)
            }
            #expect(TrainText.count(rng.int(-5...100_000)).hasSuffix("trains") || TrainText.count(1) == "1 train")
            #expect(!TrainText.emptyNote(offline: rng.chance(0.5)).isEmpty)
        }
    }

    /// NaN or infinite heights (a sensor's, or a derived figure) through `TrainText`: never a trap. The relative
    /// height has no figure to show for one (it used to read a made-up "0 ft down"), so it's empty; the depth texts
    /// stay clean.
    @Test func trainTextWithNaNAndInfinity() {
        for units in Self.regions {
            for meters in [Double.nan, .infinity, -.infinity] {
                for estimated in [false, true] {
                    #expect(TrainText.relativeHeight(meters: meters, estimated: estimated, units: units) == "")
                    #expect(TrainText.spokenRelativeHeight(meters: meters, estimated: estimated, units: units) == "")
                }
                for text in [TrainText.belowStreet(meters: meters, estimated: false, units: units),
                             TrainText.compactDepth(meters: meters, estimated: true, units: units),
                             TrainText.spokenBelowStreet(meters: meters, estimated: true, units: units)] {
                    #expect(isCleanNumberText(text), "seed=\(Chaos.seed) \(meters) -> \(text)")
                }
            }
        }
    }

    @Test func detailTextHandlesAnyNumbers() {
        var rng = Chaos.rng("detailTextHandlesAnyNumbers")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for iteration in 0..<10_000 {
            let context = Chaos.context("detailText", iteration: iteration, "")
            let length = rng.chance(0.3) ? rng.pick([Int.min, Int.max, -1, 0, 1, 1_000, 1_001, nil]) : rng.int(-100...2_000) as Int?
            let beam = rng.chance(0.3) ? rng.pick([Int.min, Int.max, -1, 0, 1, 1_000, 1_001, nil]) : rng.int(-100...2_000) as Int?
            for units in Self.regions {
                if let size = VesselDetailText.size(length: length, beam: beam, units: units) { #expect(isCleanNumberText(size), context) }
                let draught = chaosDouble(&rng)
                if let text = VesselDetailText.draught(draught, units: units) { #expect(isCleanNumberText(text), context) }
            }
            let eta = VesselETA(month: rng.int(-2...14), day: rng.int(-2...33), hour: rng.int(-2...26), minute: rng.int(-2...62))
            let text = VesselDetailText.eta(eta, now: now.addingTimeInterval(rng.double(-1e10...1e10)))
            if let text { #expect(!text.isEmpty && !text.lowercased().contains("nan"), context) }
            _ = VesselDetailText.navStatus(rng.int(-5...20))
            _ = VesselDetailText.marineTrafficURL(mmsi: rng.pick([Int.min, Int.max, -1, 0, 1, 367_000_001]))
            // Positions from the relay: finite, any size; "" past ±90 / ±180.
            let latitude = rng.double(-100...100), longitude = rng.double(-200...200)
            let coordinate = VesselDetailText.coordinate(latitude: latitude, longitude: longitude)
            if abs(latitude) <= 90, abs(longitude) <= 180 {
                #expect(isCleanNumberText(coordinate, allowMinus: false), context)
            } else {
                #expect(coordinate == "", context)
            }
        }
    }

    /// A position that can't be real reads "" (it used to print a 300-digit "Position" for 1e300 and "nan° N" for
    /// NaN); the edges of the range still read.
    @Test func coordinateTextIsEmptyForImpossiblePositions() {
        #expect(VesselDetailText.coordinate(latitude: 1e300, longitude: -1e300) == "")
        #expect(VesselDetailText.coordinate(latitude: .nan, longitude: .infinity) == "")
        #expect(VesselDetailText.coordinate(latitude: 40.7, longitude: .nan) == "")
        #expect(VesselDetailText.coordinate(latitude: 90.0001, longitude: 0) == "")
        #expect(VesselDetailText.coordinate(latitude: 0, longitude: -180.0001) == "")
        #expect(VesselDetailText.coordinate(latitude: -90, longitude: 180) == "90.00000° S, 180.00000° E")
    }

    // MARK: VesselText

    @Test func vesselTextHandlesFiniteInputsInTheirSafeRanges() {
        var rng = Chaos.rng("vesselTextHandlesFiniteInputsInTheirSafeRanges")
        for iteration in 0..<10_000 {
            let value = pow(10, rng.double(-6...17)) * (rng.chance(0.5) ? 1 : -1)
            let context = Chaos.context("vesselText", iteration: iteration, "\(value)")
            // Bearings and ages in any sign, up to where whole numbers still fit (1e17).
            let bearing = VesselText.bearing(degrees: value)
            #expect(bearing.range(of: #"^(N|NE|E|SE|S|SW|W|NW) \d{1,3}°$"#, options: .regularExpression) != nil, context)
            let whole = Int(bearing.split(separator: " ")[1].dropLast())!
            #expect((0..<360).contains(whole), context)
            #expect(!VesselText.spokenBearing(degrees: value).isEmpty, context)
            #expect(isCleanNumberText(VesselText.age(seconds: value)), context)
            #expect(isCleanNumberText(VesselText.spokenAge(seconds: value)), context)
            #expect(VesselText.age(seconds: value).hasSuffix(" ago"), context)
            #expect(!VesselText.count(rng.int(-3...1_000_000)).isEmpty)
        }
    }

    /// The boundary the loops stay inside: whole numbers up to 9e18 convert, so these don't trap.
    @Test func noTrap_atTheEdgeOfTheWholeNumberRange() {
        _ = VesselText.bearing(degrees: 9.0e18)
        _ = VesselText.bearing(degrees: -9.0e18)
        _ = VesselText.age(seconds: 9.0e18)
        _ = CompassStrip.ticks(pose: CameraPose(headingDegrees: 1e18, pitchDegrees: 0, horizontalFOVDegrees: 60, viewWidth: 400, viewHeight: 800))
        #expect(VesselText.bearing(degrees: -720) == "N 0°")
        #expect(VesselText.bearing(degrees: 359.6) == "N 0°")
    }

    /// The round setting distances are clamped like `Units`' other distances: NaN or a negative value reads 0, never
    /// "nan mi" or "-1 mi". (`VesselText`'s own unclamped distance and speed formatters are gone: `Units` replaced
    /// them.)
    @Test func roundDistancesAreClamped() {
        #expect(VesselText.roundMiles(.nan) == "0\u{00A0}mi")
        #expect(VesselText.roundMiles(-1) == "0\u{00A0}mi")
        #expect(VesselText.spokenRoundMiles(.infinity) == "12427.4 miles")
        #expect(VesselText.spokenRoundMiles(.nan) == "0 miles")
        for distance in [DistanceChoice.kilometers, .nauticalMiles] {
            let units = Units(preferences: UnitPreferences(distance: distance))
            for meters in [Double.nan, .infinity, -.infinity, -5] {
                #expect(isCleanNumberText(units.roundDistance(meters: meters, miles: 3)), "\(distance) \(meters)")
                #expect(isCleanNumberText(units.spokenRoundDistance(meters: meters, miles: 3)), "\(distance) \(meters)")
            }
            #expect(units.roundDistance(meters: .nan, miles: 3).hasPrefix("0\u{00A0}"))
        }
    }

    // MARK: Values that used to trap (C2, C3; fixed by the F2 sweep)

    /// NaN, infinity or a finite value past Int.max (a JSON `course` or `heading` can be 1e300) used to trap in
    /// `Int(degrees.rounded())`. Not finite reads ""; a huge finite value is brought into [0, 360) first.
    @Test func bearingOfNonFiniteIsEmptyAndHugeIsNormalized() {
        #expect(VesselText.bearing(degrees: .nan) == "")
        #expect(VesselText.bearing(degrees: .infinity) == "")
        #expect(VesselText.bearing(degrees: -.infinity) == "")
        #expect(VesselText.spokenBearing(degrees: .nan) == "")
        #expect(VesselText.spokenBearing(degrees: .infinity) == "")
        for degrees in [1e300, -1e19, 1e19, -1e300, Double.greatestFiniteMagnitude] {
            let text = VesselText.bearing(degrees: degrees)
            #expect(text.range(of: #"^(N|NE|E|SE|S|SW|W|NW) \d{1,3}°$"#, options: .regularExpression) != nil, "\(degrees) -> \(text)")
            #expect(!VesselText.spokenBearing(degrees: degrees).isEmpty, "\(degrees)")
        }
    }

    /// Report ages: NaN reads 0 s, a negative age 0 s, a huge one in hours (saturated), never a trap.
    @Test func ageOfNonFiniteOrHugeIsClamped() {
        #expect(VesselText.age(seconds: .nan) == "0 s ago")
        #expect(VesselText.age(seconds: -.infinity) == "0 s ago")
        #expect(VesselText.spokenAge(seconds: .nan) == "0 seconds ago")
        #expect(VesselText.age(seconds: 1e300).hasSuffix(" h ago"))
        #expect(VesselText.spokenAge(seconds: 1e300).hasSuffix(" hours ago"))
        #expect(isCleanNumberText(VesselText.age(seconds: 1e300)))
    }
}
