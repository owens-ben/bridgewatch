import BoatCore
import Foundation

/// UI tests (chaos scenarios): plays a timeline of feed events instead of connecting: messages, drops and reconnects
/// at set times, and generated crowds of boats and trains. The app reads it from `BOATAR_SCRIPTED_FEED` only in debug
/// builds (`FeedConfiguration`, through `BoatARApp.testHooks`, which is empty in a Release build).
///
/// The script is a JSON array of steps, each run `after` seconds after the previous one:
/// - `{"after":0,"event":"connect"}` / `{"after":5,"event":"disconnect"}`: `.connecting` + `.connected`, or
///   `.disconnected` (the store's offline state).
/// - `{"after":0,"event":"reject"}`: `.connecting` + `.rejected`, one attempt the relay refused (401/403, a wrong
///   token); with `"repeat"` and an `after` it plays the feed retrying and being refused again.
/// - `{"after":1,"message":{...relay message...},"age":8}`: a relay message; with `age`, every target in it is
///   restamped `age` seconds before the moment it's sent (negative: ahead of the clock), so a script written once
///   never goes stale however slowly the simulator runs.
/// - `{"after":1,"frame":"<raw text>","age":8}`: a raw frame decoded the way `RelayVesselFeed` decodes the socket's
///   (`RelayMessage.decode`); one that doesn't decode is skipped, like a bad frame from the relay.
/// - `{"after":1,"synthetic":{"vessels":500,"trains":500,"nameLength":200,"seed":1,"age":0}}`: a snapshot of that
///   many generated boats and trains spread over the dev area (`devBoundingBox`).
/// - `"repeat": n` on any step runs it n times, `after` apart.
/// The stream stays open after the last step (like `ReplayVesselFeed`).
public struct ScriptedVesselFeed: VesselFeed {
    public struct Synthetic: Decodable, Sendable, Equatable {
        public var vessels: Int = 0
        public var trains: Int = 0
        /// Characters per name (emoji and right-to-left text included); 0 for short names.
        public var nameLength: Int = 0
        public var seed: UInt64 = 1
        /// Seconds before now each target is stamped (negative: ahead of the clock).
        public var age: Double = 0
        /// First MMSI / trip number, so two crowds can differ.
        public var idOffset: Int = 0

        private enum CodingKeys: String, CodingKey { case vessels, trains, nameLength, seed, age, idOffset }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            vessels = try c.decodeIfPresent(Int.self, forKey: .vessels) ?? 0
            trains = try c.decodeIfPresent(Int.self, forKey: .trains) ?? 0
            nameLength = try c.decodeIfPresent(Int.self, forKey: .nameLength) ?? 0
            seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? 1
            age = try c.decodeIfPresent(Double.self, forKey: .age) ?? 0
            idOffset = try c.decodeIfPresent(Int.self, forKey: .idOffset) ?? 0
        }
    }

    public struct Step: Decodable, Sendable {
        public var after: Double = 0
        public var event: String?
        public var message: RelayMessage?
        public var frame: String?
        public var age: Double?
        public var synthetic: Synthetic?
        public var `repeat`: Int?

        private enum CodingKeys: String, CodingKey { case after, event, message, frame, age, synthetic, `repeat` }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            after = try c.decodeIfPresent(Double.self, forKey: .after) ?? 0
            event = try c.decodeIfPresent(String.self, forKey: .event)
            message = try c.decodeIfPresent(RelayMessage.self, forKey: .message)
            frame = try c.decodeIfPresent(String.self, forKey: .frame)
            age = try c.decodeIfPresent(Double.self, forKey: .age)
            synthetic = try c.decodeIfPresent(Synthetic.self, forKey: .synthetic)
            `repeat` = try c.decodeIfPresent(Int.self, forKey: .repeat)
        }
    }

    public let steps: [Step]

    public init(steps: [Step]) {
        self.steps = steps
    }

    /// Nil when the JSON isn't a valid script.
    public init?(json: String) {
        guard let steps = try? RelayJSON.decoder().decode([Step].self, from: Data(json.utf8)) else { return nil }
        self.steps = steps
    }

    public func events() -> AsyncStream<FeedEvent> {
        let steps = steps
        return AsyncStream { continuation in
            let task = Task {
                for step in steps {
                    for _ in 0..<max(1, step.repeat ?? 1) {
                        if step.after > 0 { try? await Task.sleep(for: .seconds(step.after)) }
                        if Task.isCancelled { return }
                        for event in Self.events(for: step, now: Date()) { continuation.yield(event) }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func events(for step: Step, now: Date) -> [FeedEvent] {
        var events: [FeedEvent] = []
        switch step.event {
        case "connect": events += [.connecting, .connected]
        case "disconnect": events.append(.disconnected)
        case "reject": events += [.connecting, .rejected]
        default: break
        }
        let decoded = step.frame.flatMap { try? RelayMessage.decode(Data($0.utf8)) }
        if let message = step.message ?? decoded {
            events.append(.message(step.age.map { restamp(message, at: now.addingTimeInterval(-$0)) } ?? message))
        }
        if let synthetic = step.synthetic {
            events.append(.message(.snapshot(crowd(synthetic, now: now))))
        }
        return events
    }

    static func restamp(_ message: RelayMessage, at date: Date) -> RelayMessage {
        func stamped(_ target: Target) -> Target {
            var target = target
            target.timestamp = date
            return target
        }
        switch message {
        case .snapshot(let targets): return .snapshot(targets.map(stamped))
        case .update(let target): return .update(stamped(target))
        case .remove: return message
        }
    }

    /// Generated boats and trains, the same for the same seed.
    public static func crowd(_ spec: Synthetic, now: Date) -> [Target] {
        var state = spec.seed
        func next() -> Double {
            // SplitMix64.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        let box = devBoundingBox
        let stamp = now.addingTimeInterval(-spec.age)
        func name(_ base: String) -> String {
            guard spec.nameLength > 0 else { return base }
            // Latin, emoji, Arabic (right to left) and CJK, cut to the length in characters.
            let filler = " 🚢⚓️ مركب النهر 東河 FERRY ✨"
            var text = base
            while text.count < spec.nameLength { text += filler }
            return String(text.prefix(spec.nameLength))
        }
        var targets: [Target] = []
        for i in 0..<max(0, spec.vessels) {
            let mmsi = 368_000_000 + spec.idOffset + i
            let types = [60, 70, 52, 35, 36, 30]
            targets.append(Target(
                id: "vessel:\(mmsi)", kind: .vessel, source: "aisstream", name: name("CROWD \(spec.idOffset + i)"),
                lat: box.minLatitude + next() * box.latitudeSpan, lon: box.minLongitude + next() * box.longitudeSpan,
                speed: (next() * 20).rounded() / 2, course: (next() * 360).rounded(), timestamp: stamp,
                vessel: VesselDetails(mmsi: mmsi, shipType: types[Int(next() * Double(types.count)) % types.count])))
        }
        let routes = ["Q", "B", "D", "N", "F", "A", "C", "2", "3", "4", "5", "6X", "G", "L", "J", "M"]
        for i in 0..<max(0, spec.trains) {
            let underground = next() < 0.7
            targets.append(Target(
                id: "train:nyct:CROWD\(spec.idOffset + i)", kind: .train, source: "mta-subway",
                lat: box.minLatitude + next() * box.latitudeSpan, lon: box.minLongitude + next() * box.longitudeSpan,
                altitude: underground ? -10 - next() * 20 : 30 + next() * 15, speed: (next() * 30).rounded(),
                course: (next() * 360).rounded(), timestamp: stamp,
                train: TrainDetails(route: routes[Int(next() * Double(routes.count)) % routes.count],
                                    direction: next() < 0.5 ? .north : .south,
                                    destination: name("Crowd \(spec.idOffset + i) St"),
                                    stretch: underground ? nil : "manhattan-bridge", underground: underground,
                                    altitudeEstimated: underground)))
        }
        return targets
    }
}
