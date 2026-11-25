import Foundation

/// The kind of vehicle a speed belongs to: each has its own standard unit (`Units.speedUnit(for:)`).
public enum VehicleKind: String, Sendable, CaseIterable {
    case vessel
    case train
    /// Not shown yet: aircraft will get knots and altitudes in feet, the aviation standard.
    case aircraft
}

public enum SpeedUnit: String, Sendable, CaseIterable {
    case knots
    case milesPerHour
    case kilometersPerHour

    /// How many of this unit one knot is.
    var perKnot: Double {
        switch self {
        case .knots: 1
        case .milesPerHour: 1_852.0 / 1_609.344
        case .kilometersPerHour: 1.852
        }
    }

    var symbol: String {
        switch self {
        case .knots: "kn"
        case .milesPerHour: "mph"
        case .kilometersPerHour: "km/h"
        }
    }

    func spoken(_ whole: Int) -> String {
        let one = whole == 1
        return switch self {
        case .knots: one ? "1 knot" : "\(whole) knots"
        case .milesPerHour: one ? "1 mile per hour" : "\(whole) miles per hour"
        case .kilometersPerHour: one ? "1 kilometer per hour" : "\(whole) kilometers per hour"
        }
    }
}

public enum DistanceUnit: String, Sendable, CaseIterable {
    case miles
    case kilometers
    case nauticalMiles

    var meters: Double {
        switch self {
        case .miles: 1_609.344
        case .kilometers: 1_000
        case .nauticalMiles: 1_852
        }
    }

    var symbol: String {
        switch self {
        case .miles: "mi"
        case .kilometers: "km"
        case .nauticalMiles: "nmi"
        }
    }

    func spoken(_ text: String) -> String {
        let one = text == "1" || text == "1.0"
        return switch self {
        case .miles: one ? "1 mile" : "\(text) miles"
        case .kilometers: one ? "1 kilometer" : "\(text) kilometers"
        case .nauticalMiles: one ? "1 nautical mile" : "\(text) nautical miles"
        }
    }
}

public enum HeightUnit: String, Sendable, CaseIterable {
    case feet
    case meters

    /// As the older `MeasurementUnits` the size and depth texts take.
    public var system: MeasurementUnits { self == .feet ? .imperial : .metric }
}

/// Settings > Units > Speed. "Standard" is each vehicle's own unit; any other choice applies to every kind.
public enum SpeedChoice: String, Sendable, CaseIterable, Identifiable {
    case standard
    case knots
    case milesPerHour = "mph"
    case kilometersPerHour = "kmh"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Standard for each vehicle"
        case .knots: "Knots"
        case .milesPerHour: "mph"
        case .kilometersPerHour: "km/h"
        }
    }

    /// As VoiceOver reads the choice: "Miles per hour", not "m p h".
    public var spokenTitle: String {
        switch self {
        case .standard: "Standard for each vehicle"
        case .knots: "Knots"
        case .milesPerHour: "Miles per hour"
        case .kilometersPerHour: "Kilometers per hour"
        }
    }

    /// The fixed unit, or nil for standard.
    var unit: SpeedUnit? {
        switch self {
        case .standard: nil
        case .knots: .knots
        case .milesPerHour: .milesPerHour
        case .kilometersPerHour: .kilometersPerHour
        }
    }
}

/// Settings > Units > Distance. Automatic follows the device's region.
public enum DistanceChoice: String, Sendable, CaseIterable, Identifiable {
    case automatic
    case miles
    case kilometers
    case nauticalMiles

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .miles: "Miles"
        case .kilometers: "Kilometers"
        case .nauticalMiles: "Nautical miles"
        }
    }
}

/// Settings > Units > Height and depth. Automatic follows the device's region.
public enum HeightChoice: String, Sendable, CaseIterable, Identifiable {
    case automatic
    case feet
    case meters

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .feet: "Feet"
        case .meters: "Meters"
        }
    }
}

/// What the user picked in Settings > Units. The default is no choice at all: each vehicle's standard speed unit,
/// distances and heights from the device's region.
public struct UnitPreferences: Sendable, Equatable {
    public var speed: SpeedChoice
    public var distance: DistanceChoice
    public var height: HeightChoice

    public init(speed: SpeedChoice = .standard, distance: DistanceChoice = .automatic,
                height: HeightChoice = .automatic) {
        self.speed = speed
        self.distance = distance
        self.height = height
    }

    public static let `default` = UnitPreferences()

    /// UserDefaults keys (`@AppStorage`), each holding the choice's raw value.
    public static let speedKey = "units.speed"
    public static let distanceKey = "units.distance"
    public static let heightKey = "units.height"
}

/// A quantity `Units.format` can show.
public enum UnitQuantity: Sendable, Equatable {
    /// A speed over ground: the relay sends knots for every kind (relay/PROTOCOL.md).
    case speed
    /// How far something is, meters.
    case distance
    /// A height or depth, meters: rounded to 10 ft, or a whole meter.
    case height
}

/// Every unit the app shows, worked out from the user's choices (`UnitPreferences`) and the device's region (the
/// default for distances, heights and train speeds). All shown and spoken (VoiceOver) unit text goes through here;
/// views pass a `Units` in and add no unit logic. Numbers and units are joined by a non-breaking space in the shown
/// forms, so a narrow screen never wraps "14.2" and "kn" onto two lines.
public struct Units: Sendable, Equatable {
    public var preferences: UnitPreferences
    /// The device region's system: miles, feet and mph (the US, the UK), or kilometers, meters and km/h.
    public var region: MeasurementUnits

    public init(preferences: UnitPreferences = .default, region: MeasurementUnits = .imperial) {
        self.preferences = preferences
        self.region = region
    }

    /// The defaults in a US region: what the app showed before units could be chosen (except trains, now mph).
    public static let standard = Units()

    /// The region's system: metric unless the locale measures in US or UK units.
    public static func region(of locale: Locale) -> MeasurementUnits {
        locale.measurementSystem == .metric ? .metric : .imperial
    }

    private static let nbsp = "\u{00A0}"
    private static let feetPerMeter = 3.280_84

    /// What the texts show at most: a bad value (a garbled report, a test's 1e30) reads as this, never traps
    /// converting to a whole number. Speeds 1,000 kn, distances half the Earth's circumference, heights 100 km.
    public static let maxSpeedKnots = 1_000.0
    public static let maxDistanceMeters = 20_000_000.0
    public static let maxHeightMeters = 100_000.0

    /// `value` within 0...`limit`; NaN is 0.
    static func clamp(_ value: Double, to limit: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return min(max(value, 0), limit)
    }

    // MARK: Which unit

    /// The speed unit for a kind: the user's choice, or the kind's standard: knots on the water and in the air
    /// (nautical and aviation practice), mph for trains in a US or UK region and km/h elsewhere.
    public func speedUnit(for kind: VehicleKind) -> SpeedUnit {
        if let unit = preferences.speed.unit { return unit }
        switch kind {
        case .vessel, .aircraft: return .knots
        case .train: return region == .metric ? .kilometersPerHour : .milesPerHour
        }
    }

    /// Miles or kilometers from the region unless chosen. Nautical miles only when chosen: the user is on shore.
    public var distanceUnit: DistanceUnit {
        switch preferences.distance {
        case .automatic: region == .metric ? .kilometers : .miles
        case .miles: .miles
        case .kilometers: .kilometers
        case .nauticalMiles: .nauticalMiles
        }
    }

    /// Feet or meters from the region unless chosen. (Aircraft altitudes will be feet whatever this says.)
    public var heightUnit: HeightUnit {
        switch preferences.height {
        case .automatic: region == .metric ? .meters : .feet
        case .feet: .feet
        case .meters: .meters
        }
    }

    /// `heightUnit` as the size, draught and depth texts take it.
    public var heightSystem: MeasurementUnits { heightUnit.system }

    /// Settings' footer under Speed: what "Standard for each vehicle" means here, "Knots for boats, mph for trains"
    /// ("km/h for trains" in a metric region).
    public var standardSpeedNote: String {
        let train = Units(region: region).speedUnit(for: .train).symbol
        return "Knots for boats, \(train) for trains"
    }

    /// How far sightlines reach (`Sightlines.maxRangeMeters`, the camera's default radius) in words: "3 miles", "5
    /// kilometers", "2.7 nautical miles".
    public var sightRangeText: String {
        spokenRoundDistance(meters: Sightlines.maxRangeMeters, miles: CameraRadius.default.miles)
    }

    /// Under "No boats in sight from here": "The boats below are behind land or more than 3 miles away."
    public var outOfSightNote: String {
        "The boats below are behind land or more than \(sightRangeText) away."
    }

    /// Settings > Units' footer: "Standard speed: knots for boats, mph for trains. Automatic follows your region."
    public var unitsFooter: String {
        let note = standardSpeedNote
        return "Standard speed: \(note.prefix(1).lowercased() + note.dropFirst()). Automatic follows your region."
    }

    // MARK: The one entry point

    /// `value` (knots for a speed, meters otherwise) as shown, or as VoiceOver says it when `spoken`.
    public func format(_ value: Double, _ quantity: UnitQuantity, kind: VehicleKind, spoken: Bool = false) -> String {
        switch quantity {
        case .speed: spoken ? spokenSpeed(knots: value, kind: kind) : speed(knots: value, kind: kind)
        case .distance: spoken ? spokenDistance(meters: value) : distance(meters: value)
        case .height: height(meters: value, spoken: spoken)
        }
    }

    /// `format` for a one-off: the user's choices and the region's default, without making a `Units` first.
    public static func format(_ value: Double, _ quantity: UnitQuantity, kind: VehicleKind,
                              preferences: UnitPreferences, region: MeasurementUnits, spoken: Bool = false) -> String {
        Units(preferences: preferences, region: region).format(value, quantity, kind: kind, spoken: spoken)
    }

    // MARK: Speed

    /// "14.2 kn" for a boat (one decimal: boats are slow, a tenth matters), "18 mph" or "29 km/h" for a train (whole
    /// numbers: its speed is an average between stations anyway).
    public func speed(knots: Double, kind: VehicleKind) -> String {
        let unit = speedUnit(for: kind)
        let value = Self.clamp(knots, to: Self.maxSpeedKnots) * unit.perKnot
        let number = kind == .vessel ? String(format: "%.1f", value) : "\(Int(value.rounded()))"
        return number + Self.nbsp + unit.symbol
    }

    /// "14 knots", "1 mile per hour", "29 kilometers per hour": whole numbers for every kind.
    public func spokenSpeed(knots: Double, kind: VehicleKind) -> String {
        let unit = speedUnit(for: kind)
        return unit.spoken(Int((Self.clamp(knots, to: Self.maxSpeedKnots) * unit.perKnot).rounded()))
    }

    // MARK: Distance

    /// "0.2 mi", "1.4 km", "0.3 nmi" with one decimal; under a tenth of the unit, the small unit to the nearest 10:
    /// "350 ft" (miles), "90 m" (kilometers), feet or meters by the height unit (nautical miles).
    public func distance(meters: Double) -> String {
        let meters = Self.clamp(meters, to: Self.maxDistanceMeters)
        let unit = distanceUnit
        let value = meters / unit.meters
        if value < 0.1 { return smallDistance(meters, spoken: false) }
        return String(format: "%.1f", value) + Self.nbsp + unit.symbol
    }

    /// "0.2 miles", "1 kilometer", "0.3 nautical miles", "350 feet", "90 meters".
    public func spokenDistance(meters: Double) -> String {
        let meters = Self.clamp(meters, to: Self.maxDistanceMeters)
        let unit = distanceUnit
        let value = meters / unit.meters
        if value < 0.1 { return smallDistance(meters, spoken: true) }
        return unit.spoken(String(format: "%.1f", value))
    }

    private func smallDistance(_ meters: Double, spoken: Bool) -> String {
        let small: HeightUnit = switch distanceUnit {
        case .miles: .feet
        case .kilometers: .meters
        case .nauticalMiles: heightUnit
        }
        switch small {
        case .feet:
            let feet = Int((meters * Self.feetPerMeter / 10).rounded()) * 10
            return spoken ? "\(feet) feet" : "\(feet)\(Self.nbsp)ft"
        case .meters:
            let whole = Int((meters / 10).rounded()) * 10
            return spoken ? "\(whole) meters" : "\(whole)\(Self.nbsp)m"
        }
    }

    /// A setting's round distance (the camera radius): "½ mi", "3 mi" in miles (`miles` is the round figure it
    /// stands for); in kilometers or nautical miles the stored meters to a tenth, "0.8 km", "5 km", "2.7 nmi". Clamped
    /// like `distance` (NaN reads 0).
    public func roundDistance(meters: Double, miles: Double) -> String {
        switch distanceUnit {
        case .miles: VesselText.roundMiles(miles)
        case .kilometers, .nauticalMiles: Self.tenths(Self.clamp(meters, to: Self.maxDistanceMeters) / distanceUnit.meters) + Self.nbsp + distanceUnit.symbol
        }
    }

    /// "half a mile", "3 miles", "0.8 kilometers", "1.6 kilometers", "2.7 nautical miles".
    public func spokenRoundDistance(meters: Double, miles: Double) -> String {
        switch distanceUnit {
        case .miles: VesselText.spokenRoundMiles(miles)
        case .kilometers, .nauticalMiles: distanceUnit.spoken(Self.tenths(Self.clamp(meters, to: Self.maxDistanceMeters) / distanceUnit.meters))
        }
    }

    private static func tenths(_ value: Double) -> String {
        String(format: "%g", (value * 10).rounded() / 10)
    }

    // MARK: Height

    /// "40 ft" to the nearest 10 ft, or "12 m" to the nearest meter (spoken "40 feet", "12 meters"). Sign dropped:
    /// the caller says up, down or below.
    public func height(meters: Double, spoken: Bool = false) -> String {
        let meters = Self.clamp(abs(meters), to: Self.maxHeightMeters)
        switch heightUnit {
        case .feet:
            let feet = Int((abs(meters) * Self.feetPerMeter / 10).rounded()) * 10
            return spoken ? "\(feet) feet" : "\(feet)\(Self.nbsp)ft"
        case .meters:
            let whole = Int(abs(meters).rounded())
            return spoken ? (whole == 1 ? "1 meter" : "\(whole) meters") : "\(whole)\(Self.nbsp)m"
        }
    }
}
