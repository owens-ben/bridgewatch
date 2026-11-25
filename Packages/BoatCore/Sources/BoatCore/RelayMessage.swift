import Foundation

/// A frame from the relay's /v2/targets socket (relay/PROTOCOL.md, "/v2/targets").
public enum RelayMessage: Sendable, Equatable {
    /// Every current target; sent once per connection, and it replaces everything held.
    case snapshot([Target])
    /// A target's full state: it replaces the one held with the same `id`.
    case update(Target)
    /// The target with this `id` is gone.
    case remove(id: String)
}

extension RelayMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, targets, target, id
    }

    /// Fails for a `type` this version doesn't know (relay/PROTOCOL.md: clients skip those messages) and for an
    /// `update` whose target doesn't decode: the feed skips frames that don't decode. A snapshot leaves out each
    /// target that doesn't decode, so one bad target never costs the frame or the others.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "snapshot":
            let targets = try container.decode([SkippingUndecodable<Target>].self, forKey: .targets)
            self = .snapshot(targets.compactMap(\.value))
        case "update":
            self = .update(try container.decode(Target.self, forKey: .target))
        case "remove":
            self = .remove(id: try container.decode(String.self, forKey: .id))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown relay message type \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot(let targets):
            try container.encode("snapshot", forKey: .type)
            try container.encode(targets, forKey: .targets)
        case .update(let target):
            try container.encode("update", forKey: .type)
            try container.encode(target, forKey: .target)
        case .remove(let id):
            try container.encode("remove", forKey: .type)
            try container.encode(id, forKey: .id)
        }
    }

    /// Decodes one relay frame (UTF-8 JSON).
    public static func decode(_ data: Data) throws -> RelayMessage {
        try RelayJSON.decoder().decode(RelayMessage.self, from: data)
    }
}

/// One element of a JSON array that decodes to nil instead of failing the whole array.
private struct SkippingUndecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// JSON coding for the relay protocol: ISO 8601 timestamps with milliseconds.
public enum RelayJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? Date(string, strategy: Self.withFractionalSeconds) { return date }
            if let date = try? Date(string, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad ISO 8601 timestamp \(string)")
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.withFractionalSeconds))
        }
        return encoder
    }

    private static let withFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
