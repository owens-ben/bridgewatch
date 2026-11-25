import Foundation

/// The list's collapsible sections (docs/DESIGN.md, List). Each header shows its count and remembers whether it is
/// open (`storageKey`).
public enum ListSection: String, Sendable, CaseIterable {
    case boatsInSight
    case boatsOutOfSight
    case trainsInSight
    case trainsOutOfSight
    case trainsUnderground

    /// Open until the user closes it, except the two long or unseen groups, as before.
    public var expandedByDefault: Bool {
        switch self {
        case .boatsInSight, .trainsInSight, .trainsOutOfSight: true
        case .boatsOutOfSight, .trainsUnderground: false
        }
    }

    /// UserDefaults key for whether it's open.
    public var storageKey: String { "listSection.\(rawValue).expanded" }

    /// "In sight · 4", "Out of sight · 12", "Underground · 60". Without a location there are no sightlines: boats
    /// are "All boats", trains above ground "Above ground".
    public func title(count: Int, hasDistances: Bool = true) -> String {
        let name = switch self {
        case .boatsInSight: hasDistances ? "In sight" : "All boats"
        case .trainsInSight: hasDistances ? "In sight" : "Above ground"
        case .boatsOutOfSight, .trainsOutOfSight: "Out of sight"
        case .trainsUnderground: "Underground"
        }
        return "\(name) · \(count)"
    }

    /// The title as VoiceOver reads it, no middle dot: "In sight, 4", "Underground, 60".
    public func spokenTitle(count: Int, hasDistances: Bool = true) -> String {
        title(count: count, hasDistances: hasDistances).replacingOccurrences(of: " · ", with: ", ")
    }

    /// What VoiceOver adds after the title: what the group holds, the range in the user's unit.
    public func hint(units: Units) -> String {
        switch self {
        case .boatsInSight: "Boats you can see from here"
        case .boatsOutOfSight: "Boats behind land or more than \(units.sightRangeText) away"
        case .trainsInSight: "Trains above ground you can see from here"
        case .trainsOutOfSight: "Trains above ground behind buildings or too far"
        case .trainsUnderground: "Trains in tunnels and underground stations"
        }
    }

    /// UI-test identifier of its header. The two that collapsed before keep their names.
    public var headerIdentifier: String {
        switch self {
        case .boatsOutOfSight: "outOfSightToggle"
        case .trainsUnderground: "undergroundToggle"
        default: "\(rawValue)Toggle"
        }
    }
}
