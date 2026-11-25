import CoreLocation
import Foundation

/// The part of the map on screen, as MapKit's region gives it: a center and spans in degrees.
public struct MapRegion: Sendable, Equatable {
    public var centerLatitude: Double
    public var centerLongitude: Double
    public var latitudeDelta: Double
    public var longitudeDelta: Double

    public init(centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }

    /// The smallest region holding every one of `corners` (the visible map's four corners, which a rotated map
    /// doesn't line up with north): latitudes by their range, longitudes unwrapped around the first corner, so a map
    /// across the antimeridian works. Nil without corners, with a coordinate that isn't finite, or when the corners
    /// span no area (all one point, or a line): such a "region" would hold nothing and empty the list.
    public static func bounding(_ corners: [CLLocationCoordinate2D]) -> MapRegion? {
        guard let first = corners.first,
              corners.allSatisfy({ $0.latitude.isFinite && $0.longitude.isFinite }) else { return nil }
        let lats = corners.map(\.latitude)
        let east = corners.map { corner -> Double in
            var d = (corner.longitude - first.longitude).truncatingRemainder(dividingBy: 360)
            if d >= 180 { d -= 360 }
            if d < -180 { d += 360 }
            return d
        }
        let minE = east.min()!, maxE = east.max()!
        var center = first.longitude + (minE + maxE) / 2
        center = (center + 180).truncatingRemainder(dividingBy: 360)
        if center < 0 { center += 360 }
        guard lats.max()! - lats.min()! > 0, maxE - minE > 0 else { return nil }
        return MapRegion(centerLatitude: (lats.min()! + lats.max()!) / 2, centerLongitude: center - 180,
                         latitudeDelta: lats.max()! - lats.min()!, longitudeDelta: maxE - minE)
    }

    /// Added to each side, as a share of the span: a marker whose center sits just past the edge still shows half its
    /// disc, so it counts as on the map. 3% of a 2 km span is 60 m, about a marker's radius at that zoom.
    public static let edgeMargin = 0.03

    /// Whether a coordinate is on the map (with `margin` on each side). Longitudes are compared the short way round
    /// the globe, so a region across the antimeridian (180°) works; a span of 360° or more is the whole world. A
    /// region with spans that aren't finite and positive holds nothing.
    public func contains(_ coordinate: CLLocationCoordinate2D, margin: Double = edgeMargin) -> Bool {
        contains(latitude: coordinate.latitude, longitude: coordinate.longitude, margin: margin)
    }

    public func contains(latitude: Double, longitude: Double, margin: Double = edgeMargin) -> Bool {
        guard latitudeDelta.isFinite, longitudeDelta.isFinite, latitudeDelta > 0, longitudeDelta > 0,
              latitude.isFinite, longitude.isFinite, centerLatitude.isFinite, centerLongitude.isFinite
        else { return false }
        let margin = max(0, margin)
        guard abs(latitude - centerLatitude) <= latitudeDelta * (0.5 + margin) else { return false }
        if longitudeDelta >= 360 { return true }
        // The difference folded into -180..<180: the short way round.
        var east = (longitude - centerLongitude).truncatingRemainder(dividingBy: 360)
        if east >= 180 { east -= 360 }
        if east < -180 { east += 360 }
        return abs(east) <= longitudeDelta * (0.5 + margin)
    }
}

/// What the list and the map show (docs/DESIGN.md, Filters): boat types, "Moving only", and, side by side with the
/// map, only what's on it. Its own setting, apart from the camera's (`CameraFilter`, which has a radius); the train
/// switches are Settings' (`CameraFilterOption.isSharedSetting`), shared with the camera's menu and Settings, so
/// they aren't stored here, don't count as filters and aren't touched by `reset()`. A selected boat or train is
/// shown whatever the filter says (`BrowseScope`).
public struct BrowseFilter: Sendable, Equatable {
    /// Options left out (boat types; the shared train switches when merged in for the menu).
    public var hidden: Set<CameraFilterOption>
    /// Only boats and trains making `DeadReckoning.minimumSpeedKnots` or more.
    public var movingOnly: Bool
    /// Side by side with the map: the list holds only what's in the map's visible region. On by default; ignored
    /// where no map is beside the list.
    public var onlyOnMap: Bool

    public init(hidden: Set<CameraFilterOption> = [], movingOnly: Bool = false, onlyOnMap: Bool = true) {
        self.hidden = hidden
        self.movingOnly = movingOnly
        self.onlyOnMap = onlyOnMap
    }

    public static let `default` = BrowseFilter()
    /// UserDefaults key (`@AppStorage`).
    public static let storageKey = "browseFilter"

    /// Boat types or Moving only narrow things down: the filter button's dot and the count line's "with filters on".
    /// "Only what's on the map" isn't one: the count line says "on the map" for it.
    public var isFiltering: Bool { activeFilterCount > 0 }

    /// One for any boat type hidden, one for Moving only.
    public var activeFilterCount: Int {
        CameraFilter.sections.count { section in
            section.options.contains { !$0.isSharedSetting && hidden.contains($0) }
        } + (movingOnly ? 1 : 0)
    }

    /// The parts this filter owns are at their defaults: Reset has nothing to do.
    public var isDefault: Bool { own == .default }

    /// Whether Reset can change anything that shows. Not side by side, "Only what's on the map" isn't offered (and
    /// does nothing), so it doesn't count: Reset is never on while the button says "No filters on" there.
    public func canReset(sideBySide: Bool) -> Bool {
        sideBySide ? !isDefault : isFiltering
    }

    private var own: BrowseFilter {
        BrowseFilter(hidden: hidden.filter { !$0.isSharedSetting }, movingOnly: movingOnly, onlyOnMap: onlyOnMap)
    }

    public func isShown(_ option: CameraFilterOption) -> Bool { !hidden.contains(option) }

    /// False when the option depends on one that's off (underground trains with trains off).
    public func isAvailable(_ option: CameraFilterOption) -> Bool {
        option.requires.map(isShown) ?? true
    }

    public mutating func setShown(_ option: CameraFilterOption, _ shown: Bool) {
        if shown { hidden.remove(option) } else { hidden.insert(option) }
    }

    /// Whether the type and Moving only filters let this through (the map region is `BrowseScope`'s).
    public func shows(_ item: some CameraFilterable) -> Bool {
        item.cameraFilterOptions.allSatisfy(isShown)
            && (!movingOnly || DeadReckoning.isMoving(speedKnots: item.cameraFilterSpeedKnots))
    }

    /// This filter with the app-wide train switches set from Settings, for the menu.
    public func merging(shared: [CameraFilterOption: Bool]) -> BrowseFilter {
        var filter = self
        for (option, shown) in shared where option.isSharedSetting { filter.setShown(option, shown) }
        return filter
    }

    /// Every boat type, not only moving, only what's on the map. The train switches stay as Settings has them.
    public mutating func reset() {
        self = BrowseFilter(hidden: hidden.filter(\.isSharedSetting))
    }

    /// The menu button's VoiceOver value: "No filters on", "2 filters on, only what's on the map".
    public func spokenSummary(sideBySide: Bool) -> String {
        let count = switch activeFilterCount {
        case 0: "No filters on"
        case 1: "1 filter on"
        case let n: "\(n) filters on"
        }
        return sideBySide && onlyOnMap ? "\(count), only what's on the map" : count
    }
}

/// Stored as JSON text for `@AppStorage`; the shared train switches aren't stored. Anything that doesn't decode is
/// the default, and an option the app no longer knows is dropped (shown).
extension BrowseFilter: RawRepresentable {
    private struct Stored: Codable {
        var hidden: [String]?
        var movingOnly: Bool?
        var onlyOnMap: Bool?
    }

    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            self = .default
            return
        }
        self.init(hidden: Set((stored.hidden ?? []).compactMap(CameraFilterOption.init(key:))
                    .filter { !$0.isSharedSetting }),
                  movingOnly: stored.movingOnly ?? false, onlyOnMap: stored.onlyOnMap ?? true)
    }

    public var rawValue: String {
        let stored = Stored(hidden: hidden.filter { !$0.isSharedSetting }.map(\.key).sorted(), movingOnly: movingOnly,
                            onlyOnMap: onlyOnMap)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(stored), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

/// Applies the list's and map's filter (and, side by side, the map's region) to the boats and trains, before the
/// lists sort and sight them. The selected boat or train always stays.
public struct BrowseScope: Sendable, Equatable {
    public var filter: BrowseFilter
    /// The map's visible region while the list follows it (side by side, "Only what's on the map" on, the map
    /// settled); nil for no limit.
    public var region: MapRegion?

    public init(filter: BrowseFilter = .default, region: MapRegion? = nil) {
        self.filter = filter
        self.region = region
    }

    /// The region to limit to: the map's, only side by side with "Only what's on the map" on.
    public static func region(_ mapRegion: MapRegion?, filter: BrowseFilter, sideBySide: Bool) -> MapRegion? {
        sideBySide && filter.onlyOnMap ? mapRegion : nil
    }

    public var isLimitedToMap: Bool { region != nil }
    /// True when anything narrows what's shown: the count line then says "12 of 42".
    public var isScoped: Bool { isLimitedToMap || filter.isFiltering }

    /// The boats to show: those the filter lets through, on the map (where the estimate puts them now, as the
    /// markers do), plus `keep`.
    public func vessels(_ vessels: [Vessel], now: Date, keep: Int? = nil) -> [Vessel] {
        if isEverything { return vessels }
        return vessels.filter { vessel in
            vessel.mmsi == keep || (filter.shows(vessel) && onMap { DeadReckoning.position(of: vessel, at: now) })
        }
    }

    /// The trains to show, the same way. Underground trains follow the same rule: on the map is on the map, drawn or
    /// not at this zoom (the list keeps them in their collapsed group).
    public func trains(_ trains: [Train], now: Date, keep: String? = nil) -> [Train] {
        if isEverything { return trains }
        return trains.filter { train in
            train.id == keep || (filter.shows(train) && onMap { DeadReckoning.position(of: train, at: now) })
        }
    }

    /// No region and nothing filtered: every boat and train passes, with no work per item.
    private var isEverything: Bool { region == nil && !filter.isFiltering }

    /// This scope without the map's region: what the filter alone shows.
    public var withoutRegion: BrowseScope { BrowseScope(filter: filter) }

    /// The position is only worked out when there's a region to check it against.
    private func onMap(_ coordinate: () -> CLLocationCoordinate2D) -> Bool {
        guard let region else { return true }
        return region.contains(coordinate())
    }

    /// Boats the list would show without any scope: those not yet aged out.
    public static func liveCount(vessels: [Vessel], now: Date) -> Int {
        vessels.count { ReportFreshness(lastSeen: $0.lastSeen, now: now) != .expired }
    }

    /// Trains the list would show without any scope (after the Settings switches).
    public static func liveCount(trains: [Train], now: Date) -> Int {
        trains.count { ReportFreshness.train(lastSeen: $0.timestamp, now: now) != .expired }
    }
}

/// Why the list is empty although there are boats or trains about.
public enum BrowseEmptyReason: Sendable, Equatable {
    /// The filter shows some, but none are on this part of the map: "Show the whole list" turns the limit off.
    case offMap
    /// The filter hides everything: "Reset filters".
    case filtered
}

/// The list's count line and empty states when it doesn't show everything.
public enum BrowseText {
    /// "12 of 42 vessels" when scoped, else "42 vessels" (`VesselText.count`); "0 vessels", never "0 of 0".
    public static func vesselCount(shown: Int, total: Int, scoped: Bool) -> String {
        scoped && total > 0 ? "\(shown) of \(total) \(total == 1 ? "vessel" : "vessels")" : VesselText.count(total)
    }

    /// "9 of 101 trains" when scoped, else "101 trains"; "0 trains", never "0 of 0".
    public static func trainCount(shown: Int, total: Int, scoped: Bool) -> String {
        scoped && total > 0 ? "\(shown) of \(total) \(total == 1 ? "train" : "trains")" : TrainText.count(total)
    }

    /// Ahead of the counts, so "1 of 4" can't be read as all there is: "On the map:", "With filters on:", "On the
    /// map, with filters on:"; nil when not scoped.
    public static func scopeNote(_ scope: BrowseScope) -> String? {
        switch (scope.isLimitedToMap, scope.filter.isFiltering) {
        case (true, true): "On the map, with filters on:"
        case (true, false): "On the map:"
        case (false, true): "With filters on:"
        case (false, false): nil
        }
    }

    /// The whole status line as VoiceOver reads it, one element: "Live. On the map: 1 of 4 vessels, 0 of 6 trains",
    /// "Live, 4 vessels, 6 trains" unscoped. No middle dots.
    public static func spokenStatusLine(status: String, vessels: String, trains: String?, scope: String?) -> String {
        let counts = ([vessels] + (trains.map { [$0] } ?? [])).joined(separator: ", ")
        guard let scope else { return "\(status), \(counts)" }
        return "\(status). \(scope) \(counts)"
    }

    /// Why nothing at all is listed, or nil when something is or nothing is about.
    /// - Parameters:
    ///   - shown: boats and trains listed.
    ///   - matchingWithoutRegion: those the filter alone would list.
    ///   - total: every live boat and train.
    public static func emptyReason(shown: Int, matchingWithoutRegion: Int, total: Int,
                                   scope: BrowseScope) -> BrowseEmptyReason? {
        guard shown == 0, total > 0 else { return nil }
        if scope.isLimitedToMap, matchingWithoutRegion > 0 { return .offMap }
        return scope.filter.isFiltering ? .filtered : nil
    }

    public static func emptyTitle(_ reason: BrowseEmptyReason) -> String {
        switch reason {
        case .offMap: "Nothing on this part of the map"
        case .filtered: "Nothing matches your filters"
        }
    }

    /// The way back. Off the map it turns "Only what's on the map" off and nothing else, so with boat types or
    /// Moving only on it says the filters stay: "Show all that match your filters".
    public static func emptyAction(_ reason: BrowseEmptyReason, filtering: Bool = false) -> String {
        switch reason {
        case .offMap: filtering ? "Show all that match your filters" : "Show the whole list"
        case .filtered: "Reset filters"
        }
    }

    /// A kind's own section when it alone is empty: "No boats on this part of the map", "No trains match your
    /// filters". Nil when it isn't scoped away (nothing about, or not scoped).
    public static func noneNote(kind: VehicleKind, shown: Int, matchingWithoutRegion: Int, total: Int,
                                scope: BrowseScope) -> String? {
        guard shown == 0, total > 0, scope.isScoped else { return nil }
        let things = switch kind {
        case .vessel: "boats"
        case .train: "trains"
        case .aircraft: "aircraft"
        }
        if scope.isLimitedToMap, matchingWithoutRegion > 0 { return "No \(things) on this part of the map" }
        return scope.filter.isFiltering ? "No \(things) match your filters" : nil
    }
}

/// Everything the list shows for a scope: the boats and trains (sorted and sighted), the counts against everything
/// about, and the texts for the count line and empty states. Views only lay it out.
public struct BrowseResult: Sendable, Equatable {
    public let vessels: VesselList
    public let trains: TrainList
    public let scope: BrowseScope
    /// Every live boat and train, unscoped (trains after the Settings switches).
    public let totalVessels: Int
    public let totalTrains: Int
    /// Those the filter alone shows, without the map's region.
    public let matchingVessels: Int
    public let matchingTrains: Int

    /// - Parameters:
    ///   - trains: the trains after the Settings switches (`TrainSettings.visible`).
    ///   - keepVessel, keepTrain: the selection, shown whatever the scope says.
    public init(vessels: [Vessel], trains: [Train], observer: CLLocationCoordinate2D?, eye: EyeHeight = .altitude(nil),
                now: Date, units: Units = .standard, scope: BrowseScope, keepVessel: Int? = nil,
                keepTrain: String? = nil, sightlines: Sightlines = .harbor) {
        self.scope = scope
        let shownVessels = scope.vessels(vessels, now: now, keep: keepVessel)
        let shownTrains = scope.trains(trains, now: now, keep: keepTrain)
        self.vessels = VesselList(vessels: shownVessels, observer: observer, eye: eye, now: now,
                                  sightlines: sightlines, units: units)
        self.trains = TrainList(trains: shownTrains, observer: observer, eye: eye, now: now, sightlines: sightlines,
                                units: units)
        totalVessels = BrowseScope.liveCount(vessels: vessels, now: now)
        totalTrains = BrowseScope.liveCount(trains: trains, now: now)
        if scope.isLimitedToMap {
            matchingVessels = BrowseScope.liveCount(vessels: scope.withoutRegion.vessels(vessels, now: now), now: now)
            matchingTrains = BrowseScope.liveCount(trains: scope.withoutRegion.trains(trains, now: now), now: now)
        } else {
            matchingVessels = self.vessels.rows.count
            matchingTrains = self.trains.rows.count
        }
    }

    /// The scope leaves something out: the count line then says "12 of 42". A scope that happens to leave
    /// everything in (the whole area on the map) reads like no scope.
    public var isNarrowed: Bool {
        scope.isScoped && (vessels.rows.count < totalVessels || trains.rows.count < totalTrains)
    }

    /// "12 of 42 vessels", or "42 vessels" when nothing is left out.
    public var vesselCountText: String {
        BrowseText.vesselCount(shown: vessels.rows.count, total: totalVessels, scoped: isNarrowed)
    }

    /// "9 of 101 trains", or "101 trains" when nothing is left out.
    public var trainCountText: String {
        BrowseText.trainCount(shown: trains.rows.count, total: totalTrains, scoped: isNarrowed)
    }

    /// "on the map", "with filters on"; nil when nothing is left out.
    public var scopeNote: String? { isNarrowed ? BrowseText.scopeNote(scope) : nil }

    /// Why nothing at all is listed though something is about. Trains count only when `includeTrains` (on in
    /// Settings).
    public func emptyReason(includeTrains: Bool) -> BrowseEmptyReason? {
        let shown = vessels.rows.count + (includeTrains ? trains.rows.count : 0)
        return BrowseText.emptyReason(shown: shown,
                                      matchingWithoutRegion: matchingVessels + (includeTrains ? matchingTrains : 0),
                                      total: totalVessels + (includeTrains ? totalTrains : 0), scope: scope)
    }

    /// "No boats on this part of the map" when only the boats are scoped away.
    public var vesselNote: String? {
        BrowseText.noneNote(kind: .vessel, shown: vessels.rows.count, matchingWithoutRegion: matchingVessels,
                            total: totalVessels, scope: scope)
    }

    /// "No trains match your filters" when only the trains are scoped away.
    public var trainNote: String? {
        BrowseText.noneNote(kind: .train, shown: trains.rows.count, matchingWithoutRegion: matchingTrains,
                            total: totalTrains, scope: scope)
    }
}
