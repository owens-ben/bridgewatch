import Foundation

/// Display group for an AIS ship type (docs/DESIGN.md, "Vessel types"). The raw value is stored (the camera filter's
/// hidden types, `CameraFilterOption.key`) and names UI-test identifiers, so it never changes: Service keeps "tug",
/// its name before the groups were renamed.
public enum VesselCategory: String, CaseIterable, Sendable {
    case passenger
    case cargo
    case service = "tug"
    /// Coast Guard, police, fire, rescue and military: split out of `service`.
    case firstResponder
    case pleasure
    case other

    /// - Parameter aisShipType: the AIS "Type of ship and cargo" code, nil when unknown.
    public init(aisShipType: Int?) {
        switch aisShipType ?? 0 {
        case 60...69: self = .passenger
        case 70...89: self = .cargo
        // Military ops, search and rescue, law enforcement, medical transport.
        case 35, 51, 55, 58: self = .firstResponder
        // Towing, dredging, diving, pilots, tugs, port tenders, pollution control, local-use codes, neutral state.
        case 31...34, 50...59: self = .service
        case 36...37: self = .pleasure
        default: self = .other
        }
    }

    /// SF Symbol drawn on the type circle.
    public var symbolName: String {
        switch self {
        case .passenger: "ferry.fill"
        case .cargo: "shippingbox.fill"
        case .service: "wrench.fill"
        case .firstResponder: "light.beacon.max.fill"
        case .pleasure: "sailboat.fill"
        case .other: "circle.fill"
        }
    }

    /// Letter shown instead of color in night mode. Service keeps the T it had as "Tug / service": S is Pleasure's
    /// (sail).
    public var nightLetter: String {
        switch self {
        case .passenger: "P"
        case .cargo: "C"
        case .service: "T"
        case .firstResponder: "R"
        case .pleasure: "S"
        case .other: "?"
        }
    }

    /// The group's name: the map key, the camera filter. One or two words, no slashes.
    public var name: String {
        switch self {
        case .passenger: "Passenger"
        case .cargo: "Cargo"
        case .service: "Service"
        case .firstResponder: "First responder"
        case .pleasure: "Pleasure"
        case .other: "Other"
        }
    }

    /// The name in a row's detail ("Passenger · 14.2 kn"): `name`, except "Vessel" for Other, which on its own says
    /// nothing about one boat (most are boats that haven't sent a type yet).
    public var detailName: String {
        self == .other ? AISShipType.unknown : name
    }

    /// Word used in VoiceOver labels ("HARBOR LARK, service boat, 0.2 miles northwest").
    public var spokenName: String {
        switch self {
        case .passenger: "passenger"
        case .cargo: "cargo"
        case .service: "service boat"
        case .firstResponder: "first responder"
        case .pleasure: "pleasure craft"
        case .other: "vessel"
        }
    }

    /// What the group covers, for the map key.
    public var coverage: String {
        switch self {
        case .passenger: "Ferries and passenger ships"
        case .cargo: "Cargo ships and tankers"
        case .service: "Tugs, towing, dredging, diving, pilots and port tenders"
        case .firstResponder: "Coast Guard, police, fire, rescue and military"
        case .pleasure: "Sailboats and pleasure craft"
        case .other: "Fishing boats, high-speed craft and boats that don't send a type"
        }
    }
}

/// The finer name of an AIS "Type of ship and cargo" code (ITU-R M.1371, table 53): "Pilot", "Tanker", ... Text only:
/// the six `VesselCategory` groups stay the visual grouping (colors, icons, night letters).
public enum AISShipType {
    /// The name for `code`; "Vessel" when unknown (nil, 0, reserved codes, anything outside 1-99).
    public static func name(_ code: Int?) -> String {
        guard let code else { return unknown }
        switch code {
        case 20...29: return "Wing in ground"
        case 30: return "Fishing"
        case 31, 32: return "Towing"
        case 33: return "Dredging"
        case 34: return "Diving"
        case 35: return "Military"
        case 36: return "Sailing"
        case 37: return "Pleasure craft"
        case 40...49: return "High-speed craft"
        case 50: return "Pilot"
        case 51: return "Search and rescue"
        case 52: return "Tug"
        case 53: return "Port tender"
        case 54: return "Pollution control"
        case 55: return "Law enforcement"
        case 58: return "Medical transport"
        case 59: return "Neutral state vessel"
        case 60...69: return "Passenger"
        case 70...79: return "Cargo"
        case 80...89: return "Tanker"
        case 90...99: return "Other"
        default: return unknown
        }
    }

    /// No type, or a code reserved for future use.
    public static let unknown = "Vessel"
}

/// How recent a target's last report is (docs/DESIGN.md, "Data states").
public enum ReportFreshness: Sendable, Equatable {
    /// Recent (a vessel's under a minute old, a train's under `Train.liveSeconds`): full opacity.
    case live
    /// Older, up to its kind's max age (a vessel's one to ten minutes old): drawn at half opacity.
    case stale
    /// Older than its kind's max age (`TargetRegistry.vesselMaxAge`, `.trainMaxAge`): removed.
    case expired

    /// A vessel report's freshness: live under a minute, stale up to `TargetRegistry.vesselMaxAge`.
    public init(lastSeen: Date, now: Date) {
        self.init(lastSeen: lastSeen, now: now, liveFor: 60, maxAge: TargetRegistry.vesselMaxAge)
    }

    /// Live while younger than `liveFor` seconds, stale up to `maxAge` seconds, expired after.
    public init(lastSeen: Date, now: Date, liveFor: TimeInterval, maxAge: TimeInterval) {
        let age = now.timeIntervalSince(lastSeen)
        if age < liveFor {
            self = .live
        } else if age <= maxAge {
            self = .stale
        } else {
            self = .expired
        }
    }

    /// A train position's freshness: live under `Train.liveSeconds`, stale up to `TargetRegistry.trainMaxAge`.
    public static func train(lastSeen: Date, now: Date) -> ReportFreshness {
        ReportFreshness(lastSeen: lastSeen, now: now, liveFor: Train.liveSeconds, maxAge: TargetRegistry.trainMaxAge)
    }
}
