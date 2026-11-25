import Foundation

/// What a target is (relay/PROTOCOL.md, "Target"). A kind this version doesn't know decodes as `.unknown`, so a
/// relay that gains a new source never breaks decoding; the registry ignores such targets.
public enum TargetKind: Sendable, Hashable {
    case vessel
    case train
    /// A kind from a newer relay, with its name as sent.
    case unknown(String)
}

extension TargetKind: Codable {
    public init(from decoder: any Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        switch name {
        case "vessel": self = .vessel
        case "train": self = .train
        default: self = .unknown(name)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .vessel: try container.encode("vessel")
        case .train: try container.encode("train")
        case .unknown(let name): try container.encode(name)
        }
    }
}

/// A vessel's estimated time of arrival as AIS sends it: UTC, no year (relay/PROTOCOL.md, "Vessels"). The relay sends
/// it only when all four parts are valid; `VesselDetailText.eta` checks them again.
public struct VesselETA: Codable, Sendable, Equatable {
    public var month: Int
    public var day: Int
    public var hour: Int
    public var minute: Int

    public init(month: Int, day: Int, hour: Int, minute: Int) {
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }
}

/// The `vessel` object of a vessel target. Everything but `mmsi` and `shipType` is an optional AIS detail
/// (relay/PROTOCOL.md, "Vessels"), decoded leniently: a detail of the wrong type is dropped, never the target.
/// `callSign` and `destination` are typed in by the crew: untrusted text, shown as plain text only.
public struct VesselDetails: Codable, Sendable, Equatable {
    public var mmsi: Int
    /// AIS type code 1-99.
    public var shipType: Int?
    /// IMO number.
    public var imo: Int?
    /// Radio call sign (untrusted text).
    public var callSign: String?
    /// Where the crew says it's going (untrusted text).
    public var destination: String?
    /// Estimated time of arrival, UTC, no year.
    public var eta: VesselETA?
    /// Meters, bow to stern.
    public var length: Int?
    /// Meters, port to starboard.
    public var beam: Int?
    /// Maximum static draught, meters.
    public var draught: Double?
    /// AIS navigational status 0-14.
    public var navStatus: Int?

    public init(
        mmsi: Int, shipType: Int? = nil, imo: Int? = nil, callSign: String? = nil, destination: String? = nil,
        eta: VesselETA? = nil, length: Int? = nil, beam: Int? = nil, draught: Double? = nil, navStatus: Int? = nil
    ) {
        self.mmsi = mmsi
        self.shipType = shipType
        self.imo = imo
        self.callSign = callSign
        self.destination = destination
        self.eta = eta
        self.length = length
        self.beam = beam
        self.draught = draught
        self.navStatus = navStatus
    }

    private enum CodingKeys: String, CodingKey {
        case mmsi, shipType, imo, callSign, destination, eta, length, beam, draught, navStatus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mmsi = try container.decode(Int.self, forKey: .mmsi)
        shipType = try container.decodeIfPresent(Int.self, forKey: .shipType)
        // The details came later and are only shown: one this version can't read is left out, the target kept.
        imo = try? container.decodeIfPresent(Int.self, forKey: .imo)
        callSign = try? container.decodeIfPresent(String.self, forKey: .callSign)
        destination = try? container.decodeIfPresent(String.self, forKey: .destination)
        eta = try? container.decodeIfPresent(VesselETA.self, forKey: .eta)
        length = try? container.decodeIfPresent(Int.self, forKey: .length)
        beam = try? container.decodeIfPresent(Int.self, forKey: .beam)
        draught = try? container.decodeIfPresent(Double.self, forKey: .draught)
        navStatus = try? container.decodeIfPresent(Int.self, forKey: .navStatus)
    }
}

/// NYCT's railroad direction (the stop ID suffix), not a compass direction.
public enum TrainDirection: String, Codable, Sendable, Equatable {
    case north = "N"
    case south = "S"
}

/// The `train` object of a train target (relay/PROTOCOL.md, "Trains").
public struct TrainDetails: Codable, Sendable, Equatable {
    /// Route ID from the feed: `B`, `D`, `FX` (the F express), ...
    public var route: String
    public var direction: TrainDirection
    /// Name of the trip's last stop.
    public var destination: String?
    /// The named above-ground stretch the train is on: `manhattan-bridge`, `williamsburg-bridge`, `culver-viaduct` or
    /// `franklin-av`. Nil when `underground`.
    public var stretch: String?
    /// True for every train not on a stretch: in a tunnel, or at a station below ground.
    public var underground: Bool
    /// True when the target's `altitude` follows rule-based figures (today every underground train, and the
    /// `franklin-av` stretch), false when it is published or measured. Nil from a relay older than the depth model,
    /// which doesn't send it (its underground altitude is a flat placeholder): `Train.altitudeEstimated` reads that as
    /// false.
    public var altitudeEstimated: Bool?

    public init(
        route: String, direction: TrainDirection, destination: String? = nil, stretch: String? = nil,
        underground: Bool, altitudeEstimated: Bool? = nil
    ) {
        self.route = route
        self.direction = direction
        self.destination = destination
        self.stretch = stretch
        self.underground = underground
        self.altitudeEstimated = altitudeEstimated
    }
}

/// One tracked object, whatever its source (relay/PROTOCOL.md, "Target"). Every relay message carries a target's
/// full state, so a newer one replaces an older one with nothing to merge.
public struct Target: Codable, Sendable, Equatable, Identifiable {
    /// `<kind>:<id within the kind>`, e.g. `vessel:367000001` or `train:nyct:101100_Q..S36R`.
    public var id: String
    public var kind: TargetKind
    /// The relay source that sent this state, e.g. `aisstream`.
    public var source: String
    public var name: String?
    public var lat: Double
    public var lon: Double
    /// Meters above sea level; absent for objects on the water.
    public var altitude: Double?
    /// Knots over ground.
    public var speed: Double?
    /// Direction of travel over ground, degrees true.
    public var course: Double?
    /// Where the object points (a ship's bow), degrees true.
    public var heading: Double?
    /// The time of the position.
    public var timestamp: Date
    /// Present for `kind` `vessel`.
    public var vessel: VesselDetails?
    /// Present for `kind` `train`.
    public var train: TrainDetails?

    public init(
        id: String, kind: TargetKind, source: String, name: String? = nil, lat: Double, lon: Double,
        altitude: Double? = nil, speed: Double? = nil, course: Double? = nil, heading: Double? = nil,
        timestamp: Date, vessel: VesselDetails? = nil, train: TrainDetails? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.name = name
        self.lat = lat
        self.lon = lon
        self.altitude = altitude
        self.speed = speed
        self.course = course
        self.heading = heading
        self.timestamp = timestamp
        self.vessel = vessel
        self.train = train
    }
}
