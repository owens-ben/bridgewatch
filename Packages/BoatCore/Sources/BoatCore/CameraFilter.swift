import CoreLocation
import Foundation

/// How far the camera looks: the range of its sightlines for boats and trains above ground, and the cap on its
/// underground x-ray labels (docs/DESIGN.md, Camera). Raw values are meters.
public enum CameraRadius: Int, CaseIterable, Sendable, Identifiable {
    case halfMile = 800
    case oneMile = 1_600
    case twoMiles = 3_200
    /// `Sightlines.maxRangeMeters`, the range before the camera had a radius. Shown rounded, as "3 mi".
    case threeMiles = 5_000
    case fiveMiles = 8_000
    case tenMiles = 16_000

    public static let `default` = CameraRadius.threeMiles

    public var id: Int { rawValue }
    public var meters: Double { Double(rawValue) }

    /// The round number of miles it's shown as.
    public var miles: Double {
        switch self {
        case .halfMile: 0.5
        case .oneMile: 1
        case .twoMiles: 2
        case .threeMiles: 3
        case .fiveMiles: 5
        case .tenMiles: 10
        }
    }

    /// "½ mi", "3 mi".
    public var text: String { text(units: .standard) }
    /// "half a mile", "3 miles".
    public var spokenText: String { spokenText(units: .standard) }

    /// In the user's distance unit: "3 mi", "5 km", "2.7 nmi" (`Units.roundDistance`). Only the label changes: the
    /// stored radius is the same meters whatever the unit.
    public func text(units: Units) -> String { units.roundDistance(meters: meters, miles: miles) }
    /// "3 miles", "5 kilometers", "2.7 nautical miles".
    public func spokenText(units: Units) -> String { units.spokenRoundDistance(meters: meters, miles: miles) }
}

/// Something the camera can leave unlabelled: a boat type, trains, or underground trains. Another kind of target
/// (aircraft) adds cases here and a section to `CameraFilter.sections`, and the menu, the counts and the stored
/// setting pick them up; what each target is comes from `CameraFilterable`.
public enum CameraFilterOption: Hashable, Sendable {
    case vessel(VesselCategory)
    /// Every train.
    case trains
    /// Trains below ground (their x-ray labels). Only means anything with `trains` shown.
    case undergroundTrains

    /// Stable name for storage and UI-test identifiers: "vessel.cargo", "trains", "undergroundTrains".
    public var key: String {
        switch self {
        case .vessel(let category): "vessel.\(category.rawValue)"
        case .trains: "trains"
        case .undergroundTrains: "undergroundTrains"
        }
    }

    public init?(key: String) {
        if key.hasPrefix("vessel."), let category = VesselCategory(rawValue: String(key.dropFirst("vessel.".count))) {
            self = .vessel(category)
            return
        }
        switch key {
        case "trains": self = .trains
        case "undergroundTrains": self = .undergroundTrains
        default: return nil
        }
    }

    /// The name in the menu: a boat group's name, "Trains", "Underground trains".
    public var title: String {
        switch self {
        case .vessel(let category): category.name
        case .trains: "Trains"
        case .undergroundTrains: "Underground trains"
        }
    }

    /// The option this one depends on: underground trains show only with trains on.
    public var requires: CameraFilterOption? {
        self == .undergroundTrains ? .trains : nil
    }

    /// True for an option that is an app-wide setting rather than the camera's own (Settings > Trains). The camera
    /// menu reads and writes that setting, so the two always agree; the camera's stored filter leaves it out.
    public var isSharedSetting: Bool {
        switch self {
        case .vessel: false
        case .trains, .undergroundTrains: true
        }
    }
}

/// A group of options in the menu, one per kind of target.
public struct CameraFilterSection: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let options: [CameraFilterOption]
}

/// Anything the camera labels, described for its filter.
public protocol CameraFilterable {
    /// Every option that describes it; hiding any one of them hides it (an underground train is `trains` and
    /// `undergroundTrains`).
    var cameraFilterOptions: [CameraFilterOption] { get }
    /// Knots; nil when unknown (which counts as not moving).
    var cameraFilterSpeedKnots: Double? { get }
    /// Where it is estimated to be at `now` (`DeadReckoning`), as the lists place it.
    func cameraPosition(at now: Date) -> CLLocationCoordinate2D
}

extension Vessel: CameraFilterable {
    public var cameraFilterOptions: [CameraFilterOption] { [.vessel(VesselCategory(aisShipType: shipType))] }
    public var cameraFilterSpeedKnots: Double? { sog }
    public func cameraPosition(at now: Date) -> CLLocationCoordinate2D { DeadReckoning.position(of: self, at: now) }
}

extension Train: CameraFilterable {
    public var cameraFilterOptions: [CameraFilterOption] { underground ? [.trains, .undergroundTrains] : [.trains] }
    public var cameraFilterSpeedKnots: Double? { speed }
    public func cameraPosition(at now: Date) -> CLLocationCoordinate2D { DeadReckoning.position(of: self, at: now) }
}

/// What the camera labels: boats and trains in sight within a radius (and underground trains within the smaller of
/// it and the x-ray cap), of the kinds and types shown, optionally only moving ones. The default is what the camera
/// did before it had a filter: everything in sight within 5 km. The focused boat or train ("Find in Camera") is
/// labelled whatever the camera's own filter says. The list and the map ignore the radius and the boat types; the
/// train options are the app-wide Settings > Trains switches (`isSharedSetting`), so they apply there too. Those are
/// Settings' state, not the camera's: they don't count as filters, don't make the filter non-default, aren't touched
/// by `reset()`, and hide even the focused train, as Settings always has.
public struct CameraFilter: Sendable, Equatable {
    public var radius: CameraRadius
    /// Options left out. Stored as what's hidden, so a type or kind added later starts out shown.
    public var hidden: Set<CameraFilterOption>
    /// Only boats and trains making `DeadReckoning.minimumSpeedKnots` or more (a train at a station reports 0).
    public var movingOnly: Bool

    public init(radius: CameraRadius = .default, hidden: Set<CameraFilterOption> = [], movingOnly: Bool = false) {
        self.radius = radius
        self.hidden = hidden
        self.movingOnly = movingOnly
    }

    public static let `default` = CameraFilter()
    /// UserDefaults key (`@AppStorage`).
    public static let storageKey = "cameraFilter"

    /// Every kind's options, in menu order.
    public static let sections = [
        CameraFilterSection(id: "boatTypes", title: "Boat types", options: VesselCategory.allCases.map { .vessel($0) }),
        CameraFilterSection(id: "trains", title: "Trains", options: [.trains, .undergroundTrains]),
    ]

    /// The sections worth a place in the menu: one with a single option would just switch its whole kind off.
    public static var menuSections: [CameraFilterSection] {
        sections.filter { $0.options.count > 1 }
    }

    /// The camera's own parts (radius, boat types, moving only) are at their defaults: the menu's dot and Reset follow
    /// this. The shared train switches don't count.
    public var isDefault: Bool { cameraOwn == CameraFilter.default }

    /// This filter without the shared options: the part the camera owns and stores.
    public var cameraOwn: CameraFilter {
        CameraFilter(radius: radius, hidden: hidden.filter { !$0.isSharedSetting }, movingOnly: movingOnly)
    }

    /// Whether the option's switch is on (underground trains can be on with trains off; see `isAvailable`).
    public func isShown(_ option: CameraFilterOption) -> Bool {
        !hidden.contains(option)
    }

    /// False when the option depends on one that's off: its switch can't change anything then.
    public func isAvailable(_ option: CameraFilterOption) -> Bool {
        option.requires.map(isShown) ?? true
    }

    public mutating func setShown(_ option: CameraFilterOption, _ shown: Bool) {
        if shown { hidden.remove(option) } else { hidden.insert(option) }
    }

    /// The x-ray labels' reach: the radius, but never past `cap` (dozens of trains run under the area).
    public func undergroundRadiusMeters(cap: Double) -> Double {
        min(cap, radius.meters)
    }

    /// The camera's own filters on, not counting the radius: one for each section with any of its own options hidden,
    /// one for "Moving only". The shared train switches don't count.
    public var activeFilterCount: Int {
        Self.sections.count { section in
            section.options.contains { !$0.isSharedSetting && hidden.contains($0) }
        } + (movingOnly ? 1 : 0)
    }

    /// Whether the filter lets this be labelled. The radius isn't checked here: it's the lists' sightline range.
    public func shows(_ item: some CameraFilterable) -> Bool {
        item.cameraFilterOptions.allSatisfy(isShown)
            && (!movingOnly || DeadReckoning.isMoving(speedKnots: item.cameraFilterSpeedKnots))
    }

    /// What the camera works out sightlines for: everything the filter shows, plus the focused one ("Find in Camera"
    /// points the way even to a boat or train the camera's own filter leaves out), unless a shared switch hides it:
    /// trains turned off in Settings stay off, focused or not. The lists built from these, with `radius.meters` as
    /// their range, then hold exactly what the camera labels, and their own focus rule adds the focused one when it's
    /// behind land or beyond the radius.
    public func candidates<Item: CameraFilterable & Identifiable>(_ items: [Item], focus: Item.ID?) -> [Item] {
        items.filter { item in
            shows(item) || (item.id == focus
                            && item.cameraFilterOptions.allSatisfy { !$0.isSharedSetting || isShown($0) })
        }
    }

    /// How many boats, and separately trains, the camera works out sightlines for each second (`nearestCandidates`).
    /// A label is 200 x 52 pt (more at larger text sizes) and they stack in lanes between the horizon and the compass
    /// strip (`LabelLayout`, CameraScreen's `maxLanes`): about 6 lanes of 3-4 labels even on the Duo's inner screen, so
    /// some 24 labels at most on screen, nearest first. 60 nearest fill that more than twice over whichever way the
    /// camera points, while a busy harbor of 1,000 targets costs 120 sightline walks (up to 250 grid steps each) a
    /// second instead of 1,000 (H2, CHAOS-FINDINGS.md). The cost: in such a crowd a farther target in view can go
    /// unlabelled when 60 nearer ones are elsewhere around the user; normal traffic in the box is well under 60.
    public static let candidateLimit = 60

    /// `candidates(_:focus:)` capped by distance before any sightline is worked out (H2): only those whose estimated
    /// position at `now` is within `radius` of `observer`, and of those the `limit` nearest. The focused item is kept
    /// whatever its distance (when `candidates` keeps it), on top of the `limit`. Without an `observer` nothing can be
    /// within the radius, so only the focused item is returned: the camera labels nothing without a location anyway.
    /// Nearest first, the focused item where its distance puts it.
    public func nearestCandidates<Item: CameraFilterable & Identifiable>(
        _ items: [Item], observer: CLLocationCoordinate2D?, now: Date, focus: Item.ID?,
        limit: Int = CameraFilter.candidateLimit
    ) -> [Item] {
        let shown = candidates(items, focus: focus)
        guard let observer else { return shown.filter { $0.id == focus } }
        let maxMeters = radius.meters
        var near: [(item: Item, meters: Double)] = []
        var focused: (item: Item, meters: Double)?
        for item in shown {
            let meters = distance(from: observer, to: item.cameraPosition(at: now))
            if item.id == focus { focused = (item, meters.isNaN ? .infinity : meters); continue }
            if meters <= maxMeters { near.append((item, meters)) }
        }
        near.sort { $0.meters < $1.meters }
        var kept = Array(near.prefix(max(0, limit)))
        if let focused {
            let index = kept.firstIndex { $0.meters > focused.meters } ?? kept.endIndex
            kept.insert(focused, at: index)
        }
        return kept.map(\.item)
    }

    /// The camera's message when it has nothing to label, saying why when its own filter narrows things down:
    /// "No boats match your filters within 1 mi", "Nothing in sight within 1 mi". "Nothing" while trains are shown,
    /// "No boats" with them off in Settings; at the defaults it's the camera's old message, "Nothing in sight from
    /// here" or "No boats in sight from here".
    public var emptyMessage: String {
        emptyMessage(units: .standard)
    }

    /// `emptyMessage` as VoiceOver reads it: "within 1 mile".
    public var spokenEmptyMessage: String {
        spokenEmptyMessage(units: .standard)
    }

    /// `emptyMessage` with the radius in the user's distance unit ("within 1.6 km").
    public func emptyMessage(units: Units) -> String {
        emptyMessage(radius: radius.text(units: units))
    }

    /// `spokenEmptyMessage` in the user's distance unit ("within 1.6 kilometers").
    public func spokenEmptyMessage(units: Units) -> String {
        emptyMessage(radius: radius.spokenText(units: units))
    }

    private func emptyMessage(radius radiusText: String) -> String {
        let trains = isShown(.trains)
        if activeFilterCount > 0 {
            return trains ? "Nothing matches your filters within \(radiusText)"
                : "No boats match your filters within \(radiusText)"
        }
        let nothing = trains ? "Nothing" : "No boats"
        return radius == .default ? "\(nothing) in sight from here" : "\(nothing) in sight within \(radiusText)"
    }

    /// "No filters on", "1 filter on", "2 filters on".
    public var filterCountText: String {
        switch activeFilterCount {
        case 0: "No filters on"
        case 1: "1 filter on"
        case let n: "\(n) filters on"
        }
    }

    /// The menu button's VoiceOver value: "Radius 3 miles, no filters on".
    public var spokenSummary: String {
        spokenSummary(units: .standard)
    }

    /// `spokenSummary` in the user's distance unit.
    public func spokenSummary(units: Units) -> String {
        "Radius \(radius.spokenText(units: units)), \(filterCountText.lowercased())"
    }

    /// This filter with the app-wide options (`isSharedSetting`) set from their own settings.
    public func merging(shared: [CameraFilterOption: Bool]) -> CameraFilter {
        var filter = self
        for (option, shown) in shared where option.isSharedSetting { filter.setShown(option, shown) }
        return filter
    }

    /// The camera's own parts back to the default (3 mi, every boat type, not only moving). The shared train switches
    /// are Settings' and stay as they are.
    public mutating func reset() {
        self = CameraFilter(hidden: hidden.filter(\.isSharedSetting))
    }
}

/// Stored as JSON text, for `@AppStorage`. Options kept in their own app-wide setting (`isSharedSetting`) aren't
/// stored. A value that doesn't decode is the default; an unknown radius is the default radius, and an option the app
/// no longer knows is dropped (shown).
///
/// `version` says which boat groups the value was written with. Before version 2 (no `version`) First responder was
/// part of Service ("vessel.tug"), so a value from then that hides Service hides First responder too: those boats stay
/// as they were. From version 2 on the two are stored separately.
extension CameraFilter: RawRepresentable {
    private struct Stored: Codable {
        var radius: Int?
        var hidden: [String]?
        var movingOnly: Bool?
        var version: Int?
    }

    /// The version `rawValue` writes: 2 since First responder was split out of Service.
    public static let storageVersion = 2

    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            self = .default
            return
        }
        var hidden = Set((stored.hidden ?? []).compactMap(CameraFilterOption.init(key:)).filter { !$0.isSharedSetting })
        if (stored.version ?? 1) < 2, hidden.contains(.vessel(.service)) {
            hidden.insert(.vessel(.firstResponder))
        }
        self.init(radius: stored.radius.flatMap(CameraRadius.init(rawValue:)) ?? .default, hidden: hidden,
                  movingOnly: stored.movingOnly ?? false)
    }

    public var rawValue: String {
        let hidden = hidden.filter { !$0.isSharedSetting }.map(\.key).sorted()
        let stored = Stored(radius: radius.rawValue, hidden: hidden, movingOnly: movingOnly,
                            version: Self.storageVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(stored), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
