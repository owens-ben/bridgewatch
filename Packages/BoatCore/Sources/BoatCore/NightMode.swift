import CoreLocation
import Foundation

/// The night mode choice in Settings (docs/DESIGN.md: automatic between sunset and sunrise, manual override).
public enum NightModeSetting: String, CaseIterable, Sendable {
    case automatic, on, off

    /// Whether the red-only night palette is in use. Automatic needs the user's location; without it the app stays
    /// in the normal palette (the user can still choose On).
    public func isActive(at date: Date, location: CLLocationCoordinate2D?) -> Bool {
        switch self {
        case .on: true
        case .off: false
        case .automatic: location.map { SunPosition.isNight(at: date, coordinate: $0) } ?? false
        }
    }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .on: "On"
        case .off: "Off"
        }
    }
}
