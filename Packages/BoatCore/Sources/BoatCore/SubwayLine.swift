import Foundation

/// The trunk line a subway route belongs to: routes on one trunk share its bullet color (the colors themselves are
/// `ColorToken`s in the app). Named after the trunk in Manhattan, as MTA does.
public enum SubwayLine: String, CaseIterable, Sendable {
    /// 1 2 3 (red).
    case broadwaySeventhAvenue
    /// 4 5 6 (green).
    case lexingtonAvenue
    /// 7 (purple).
    case flushing
    /// A C E (blue).
    case eighthAvenue
    /// B D F M (orange).
    case sixthAvenue
    /// G (light green).
    case crosstown
    /// J Z (brown).
    case nassau
    /// L (gray).
    case canarsie
    /// N Q R W (yellow).
    case broadway
    /// The shuttles: 42 St (`GS`, also sent as `S`), Franklin Av (`FS`) and Rockaway Park (`H`) (dark gray).
    case shuttle
    /// A route ID this version doesn't know.
    case unknown

    /// The trunk line of a route ID from the feed (relay/PROTOCOL.md, "Trains": `B`, `6X`, `FS`, ...).
    public init(route: String) {
        switch route.uppercased() {
        case "1", "2", "3": self = .broadwaySeventhAvenue
        case "4", "5", "6", "6X": self = .lexingtonAvenue
        case "7", "7X": self = .flushing
        case "A", "C", "E": self = .eighthAvenue
        case "B", "D", "F", "FX", "M": self = .sixthAvenue
        case "G": self = .crosstown
        case "J", "Z": self = .nassau
        case "L": self = .canarsie
        case "N", "Q", "R", "W": self = .broadway
        case "S", "GS", "FS", "H": self = .shuttle
        default: self = .unknown
        }
    }

    /// The text in a route's bullet: `6X` shows `6` (in a diamond, see `isDiamond(route:)`), `FX` shows `F`, every
    /// shuttle `S`. Any other route shows its ID.
    public static func bullet(route: String) -> String {
        let id = route.uppercased()
        if SubwayLine(route: id) == .shuttle { return "S" }
        if isDiamond(route: id) { return String(id.dropLast()) }
        return id
    }

    /// True for the express variants drawn in a diamond rather than a circle: `6X`, `7X`, `FX`.
    public static func isDiamond(route: String) -> Bool {
        ["6X", "7X", "FX"].contains(route.uppercased())
    }
}
