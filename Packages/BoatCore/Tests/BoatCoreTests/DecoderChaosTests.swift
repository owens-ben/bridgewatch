import Foundation
import Testing
@testable import BoatCore

/// Fuzzes `RelayMessage.decode`: valid v2 frames broken in every way a bad relay, a proxy or a bit flip could break
/// them. The only rule: decode or throw, never trap. Replay with `BOATAR_CHAOS_SEED`; `BOATAR_CHAOS_TRACE=1` prints
/// each input to stderr before it runs, so a trap names its input.
@Suite(.timeLimit(.minutes(1))) struct DecoderChaosTests {
    static func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    /// Valid frames to start from: the relay's fixtures (a snapshot, and every message of each stream) and frames
    /// built from the test targets.
    static let bases: [Data] = {
        var frames: [Data] = []
        for name in ["relay-v2-snapshot", "relay-v2-details-snapshot"] { frames.append(fixture(name)) }
        for name in ["relay-v2-stream", "relay-v2-details-stream"] {
            if case .array(let items)? = ChaosJSON.parse(fixture(name)) {
                frames += items.prefix(40).map { Data($0.render().utf8) }
            }
        }
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let targets = [
            vesselTarget(367_000_001, name: "HARBOR LARK", shipType: 60, speed: 6, course: 90, heading: 91, timestamp: t0),
            trainTarget("101100_Q..S36R", destination: "Coney Island-Stillwell Av", timestamp: t0),
            trainTarget("x", stretch: nil, timestamp: t0),
            Target(id: "aircraft:abc", kind: .unknown("aircraft"), source: "adsb", lat: 40.7, lon: -74, timestamp: t0),
        ]
        let encoder = RelayJSON.encoder()
        for message in [RelayMessage.snapshot(targets), .update(targets[0]), .update(targets[1]), .update(targets[3]),
                        .remove(id: "vessel:367000001")] {
            frames.append(try! encoder.encode(message))
        }
        return frames
    }()

    static let hostileNumbers = [
        "1e308", "-1e308", "1e309", "-1e309", "-0", "-0.0", "0", "1e-400", "9223372036854775807", "9223372036854775808",
        "-9223372036854775808", "-9223372036854775809", "18446744073709551616", "1e300", "-1e300", "91", "181", "-91",
        "NaN", "Infinity", "-Infinity", "00012", "1.", "+5", ".5", "1e", "0x10", "1_000", "1e18", "-720", "4.9e-324",
        "1.7976931348623157e308", "123456789012345678901234567890",
    ]

    static let hostileStrings: [String] = [
        "", " ", "\u{0}", "\n\r\t", String(repeating: "A", count: 10_000), String(repeating: "\u{1F6A2}", count: 3_000),
        "\u{202E}RTL\u{202C} override", "\u{200F}\u{05E9}\u{05DC}\u{05D5}\u{05DD}", "line one\nline two\u{2028}three",
        "\u{1}\u{2}\u{7}\u{1B}[31mred", "e\u{301}\u{301}\u{301}\u{301}\u{301}\u{301}", "\u{FEFF}bom", "@@@@@@@@@@@@@@@@",
        "vessel:", "train:nyct:", "{\"nested\":true}", "[\"x\"]", "unknown", "aircraft", "vessel", "train", "snapshot",
        "update", "remove", "tunnel", "manhattan-bridge", "no-such-stretch", "2026-11-10T14:12:00.000Z",
        "0000-00-00T00:00:00Z", "9999-12-31T23:59:59.999Z", "-0001-01-01T00:00:00Z", "1970-01-01", "yesterday",
    ]

    static let rawTokens = [
        "null", "true", "false", "[]", "{}", "\"\\ud800\"", "\"\\udc00\\ud800\"", "\"\\u0000\"", "\"\\uFFFF\"", "[[[[[]]]]]",
        "{\"a\":{\"b\":{\"c\":{}}}}", "\"unterminated", "{", "]", "\"a\"\"b\"",
    ]

    static let renameKeys = ["type", "targets", "target", "id", "kind", "source", "name", "lat", "lon", "altitude", "speed",
                             "course", "heading", "timestamp", "vessel", "train", "mmsi", "shipType", "route", "direction",
                             "underground", "stretch", "eta", "vessels", "latitude", "longitude"]

    /// A v1 frame (relay/PROTOCOL.md, /v1/vessels): the shapes an app of this version must survive, not read.
    static let v1Frames = [
        #"{"type":"snapshot","vessels":[{"mmsi":367000001,"name":"X","latitude":40.7,"longitude":-74,"sog":3,"cog":90,"heading":91,"lastSeen":"2026-11-10T14:02:05.000Z"}]}"#,
        #"{"type":"update","vessel":{"mmsi":367000001,"latitude":40.7,"longitude":-74}}"#,
        #"{"vessels":[]}"#, #"{"type":"snapshot","vessels":null}"#, #"{"type":"snapshot","targets":{"vessel:1":{}}}"#,
        #"{"type":"snapshot","targets":[1,"two",null,[],{}]}"#, #"{"type":"update","target":null}"#, #"{"type":null}"#,
        #"{"type":["snapshot"]}"#, #"[]"#, #"null"#, #"7"#, #""snapshot""#, #"{"type":"remove"}"#, #"{"type":"remove","id":7}"#,
    ]

    static func mutateTree(_ tree: ChaosJSON, _ rng: inout SplitMix64) -> ChaosJSON {
        let paths = tree.paths()
        let path = rng.pick(paths)
        switch rng.int(0...9) {
        case 0: return tree.replacing(at: path) { _, _ in .raw(rng.pick(hostileNumbers)) }
        case 1: return tree.replacing(at: path) { _, _ in .string(rng.pick(hostileStrings)) }
        case 2: return tree.replacing(at: path) { _, _ in .raw(rng.pick(rawTokens)) }
        case 3: return tree.replacing(at: path) { _, _ in nil }
        case 4: // Swap types: scalar to string, string to number, object to array, array to object.
            return tree.replacing(at: path) { node, _ in
                switch node {
                case .raw(let token): .string(token)
                case .string(let text): .raw(text)
                case .object(let pairs): .array(pairs.map(\.value))
                case .array(let items): .object(items.enumerated().map { ("\($0.offset)", $0.element) })
                }
            }
        case 5: // Duplicate a key or an element.
            return tree.replacing(at: Array(path.dropLast())) { node, _ in
                guard let last = path.last else { return node }
                switch node {
                case .object(var pairs) where last < pairs.count: pairs.insert(pairs[last], at: last); return .object(pairs)
                case .array(var items) where last < items.count: items.insert(items[last], at: last); return .array(items)
                default: return node
                }
            }
        case 6: // A key that isn't one of ours.
            return tree.replacing(at: path) { node, _ in
                guard case .object(var pairs) = node, !pairs.isEmpty else { return node }
                pairs[rng.int(0...pairs.count - 1)].key = rng.pick(renameKeys)
                return .object(pairs)
            }
        case 7: // Deep nesting in place of a value.
            let depth = rng.pick([2, 10, 100, 600, 3_000])
            let shape = rng.int(0...1)
            return tree.replacing(at: path) { _, _ in
                .raw(shape == 0 ? String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
                     : String(repeating: "{\"a\":", count: depth) + "1" + String(repeating: "}", count: depth))
            }
        case 8: // A name of every kind, in the places a name goes.
            return tree.replacing(at: path) { node, key in
                if key == "name" || key == "destination" || key == "callSign" { return .string(rng.pick(hostileStrings)) }
                return node
            }
        default: // An unknown kind, type or stretch where a known one was.
            return tree.replacing(at: path) { node, key in
                if let key, ["kind", "type", "stretch", "direction", "source"].contains(key) {
                    return .string(rng.pick(hostileStrings))
                }
                return node
            }
        }
    }

    static func mutateBytes(_ data: Data, _ rng: inout SplitMix64) -> Data {
        var bytes = Array(data)
        guard !bytes.isEmpty else { return Data([UInt8(rng.int(0...255))]) }
        switch rng.int(0...8) {
        case 0: bytes = Array(bytes.prefix(rng.int(0...bytes.count)))
        case 1:
            let start = rng.int(0...bytes.count - 1)
            bytes.removeSubrange(start..<min(bytes.count, start + rng.int(1...16)))
        case 2:
            let start = rng.int(0...bytes.count - 1)
            let end = min(bytes.count, start + rng.int(1...64))
            bytes.insert(contentsOf: bytes[start..<end], at: rng.int(0...bytes.count))
        case 3: for _ in 0..<rng.int(1...8) { bytes[rng.int(0...bytes.count - 1)] ^= UInt8(1 << rng.int(0...7)) }
        case 4: bytes.insert(contentsOf: rng.pick([[0xFF], [0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF8, 0x88, 0x80, 0x80, 0x80], [0x80]]),
                             at: rng.int(0...bytes.count))
        case 5: bytes.insert(contentsOf: (0..<rng.int(1...32)).map { _ in UInt8(rng.int(0...255)) }, at: rng.int(0...bytes.count))
        case 6: bytes = [0xEF, 0xBB, 0xBF] + bytes
        case 7: bytes = bytes + [0x00] + bytes
        default: bytes = Array(bytes.prefix(max(1, bytes.count / 2)))
        }
        return Data(bytes)
    }

    @Test func fuzzedFramesDecodeOrThrow() {
        var rng = Chaos.rng("fuzzedFramesDecodeOrThrow")
        let trace = ProcessInfo.processInfo.environment["BOATAR_CHAOS_TRACE"] != nil
        var decoded = 0, thrown = 0
        for iteration in 0..<12_000 {
            let base = rng.pick(Self.bases)
            var data: Data
            if rng.chance(0.08) {
                data = Data(rng.pick(Self.v1Frames).utf8)
            } else if let tree = ChaosJSON.parse(base) {
                var mutated = tree
                for _ in 0..<rng.int(0...4) { mutated = Self.mutateTree(mutated, &rng) }
                data = Data(mutated.render().utf8)
            } else {
                data = base
            }
            if rng.chance(0.35) { for _ in 0..<rng.int(1...3) { data = Self.mutateBytes(data, &rng) } }
            if trace { FileHandle.standardError.write(Data("[chaos \(Chaos.seed) #\(iteration)] \(data.prefix(2_000).map { String(format: "%02x", $0) }.joined())\n".utf8)) }

            do {
                let message = try RelayMessage.decode(data)
                decoded += 1
                var registry = TargetRegistry()
                registry.apply(message)
                registry.prune(now: Date(timeIntervalSince1970: 1_700_000_000))
                let held = registry.count
                #expect(registry.targets.count == held, Chaos.context("fuzz", iteration: iteration, String(decoding: data, as: UTF8.self)))
                #expect(registry.vessels.count + registry.trains.count <= held,
                        Chaos.context("fuzz", iteration: iteration, String(decoding: data, as: UTF8.self)))
            } catch {
                thrown += 1
            }
        }
        // The fuzzer reached both outcomes, so it is breaking frames some of the time and not all of the time.
        #expect(decoded > 500 && thrown > 500, "seed=\(Chaos.seed) decoded=\(decoded) thrown=\(thrown)")
    }

    /// Pure byte noise, and truncations of every length of one real frame.
    @Test func noiseAndEveryTruncationNeverTrap() throws {
        var rng = Chaos.rng("noiseAndEveryTruncationNeverTrap")
        for iteration in 0..<3_000 {
            let noise = Data((0..<rng.int(0...200)).map { _ in UInt8(rng.int(0...255)) })
            _ = try? RelayMessage.decode(noise)
            _ = iteration
        }
        let frame = Self.bases[0]
        for length in stride(from: 0, to: frame.count, by: 7) { _ = try? RelayMessage.decode(frame.prefix(length)) }
        for length in 0..<min(frame.count, 600) { _ = try? RelayMessage.decode(frame.prefix(length)) }
    }

    /// Specific hostile values in the places that matter, one at a time (not a random hit): each decodes or throws.
    @Test func hostileValuesInEveryField() {
        let template = #"{"type":"update","target":{"id":"vessel:1","kind":"vessel","source":"s","name":"N","lat":40.7,"lon":-74,"speed":3,"course":90,"heading":91,"timestamp":"2026-11-10T14:02:05.000Z","vessel":{"mmsi":1,"shipType":60,"imo":2,"callSign":"C","destination":"D","eta":{"month":1,"day":2,"hour":3,"minute":4},"length":5,"beam":6,"draught":7.5,"navStatus":0}}}"#
        let fields = ["\"lat\":40.7", "\"lon\":-74", "\"speed\":3", "\"course\":90", "\"heading\":91", "\"mmsi\":1", "\"shipType\":60",
                      "\"imo\":2", "\"length\":5", "\"beam\":6", "\"draught\":7.5", "\"navStatus\":0", "\"month\":1", "\"day\":2",
                      "\"hour\":3", "\"minute\":4"]
        for field in fields {
            let key = field.split(separator: ":")[0]
            for value in Self.hostileNumbers {
                let frame = template.replacingOccurrences(of: field, with: "\(key):\(value)")
                if let message = try? RelayMessage.decode(Data(frame.utf8)) {
                    var registry = TargetRegistry()
                    registry.apply(message)
                    _ = registry.vessels
                }
            }
        }
        for name in Self.hostileStrings {
            for field in ["\"name\":\"N\"", "\"callSign\":\"C\"", "\"destination\":\"D\"", "\"source\":\"s\"", "\"id\":\"vessel:1\"", "\"timestamp\":\"2026-11-10T14:02:05.000Z\"", "\"kind\":\"vessel\""] {
                let key = field.split(separator: ":")[0]
                let frame = template.replacingOccurrences(of: field, with: "\(key):\(ChaosJSON.quote(name))")
                _ = try? RelayMessage.decode(Data(frame.utf8))
            }
        }
    }

    @Test(arguments: [10, 400, 511, 512, 513, 5_000, 100_000]) func deepNestingThrowsNotCrashes(depth: Int) {
        let open = String(repeating: "[", count: depth), close = String(repeating: "]", count: depth)
        let objects = String(repeating: "{\"a\":", count: depth) + "1" + String(repeating: "}", count: depth)
        for frame in [
            "{\"type\":\"snapshot\",\"targets\":\(open)\(close)}",
            "{\"type\":\"snapshot\",\"targets\":[\(open)\(close)]}",
            "{\"type\":\"update\",\"target\":\(objects)}",
            "{\"type\":\"remove\",\"id\":\(open)\(close)}",
            open + close, objects,
        ] {
            _ = try? RelayMessage.decode(Data(frame.utf8))
        }
    }

    /// The 10k-character, emoji, right-to-left, control-character and newline names, through decode and on into the
    /// registry, the list rows and the plain-text cleanup: nothing traps, and a row's title is one clean line.
    @Test func hostileNamesSurviveDecodeAndRows() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for (index, name) in Self.hostileStrings.enumerated() {
            let frame = #"{"type":"update","target":{"id":"vessel:\#(index + 1)","kind":"vessel","source":"s","name":\#(ChaosJSON.quote(name)),"lat":40.7,"lon":-74,"timestamp":"2023-11-14T22:13:20.000Z","vessel":{"mmsi":\#(index + 1),"callSign":\#(ChaosJSON.quote(name)),"destination":\#(ChaosJSON.quote(name))}}}"#
            let message = try RelayMessage.decode(Data(frame.utf8))
            var registry = TargetRegistry()
            registry.apply(message)
            let vessel = try #require(registry.vessels.first)
            let row = VesselRow(vessel: vessel, observer: nil, now: now)
            let context = Comment("seed=\(Chaos.seed) name=\(name.prefix(80).debugDescription)")
            #expect(!row.title.isEmpty, context)
            let titleHasNewline = row.title.contains { $0.isNewline }
            #expect(!titleHasNewline, context)
            #expect(!row.title.unicodeScalars.contains { $0.properties.generalCategory == .control }, context)
            _ = row.accessibilityLabel()
            _ = row.mapCard
            _ = row.detailItems(now: now)
            for item in row.detailItems(now: now) where item.id == "destination" || item.id == "callSign" {
                let hasNewline = item.value.contains { $0.isNewline }
                #expect(!hasNewline, context)
            }
        }
    }
}
