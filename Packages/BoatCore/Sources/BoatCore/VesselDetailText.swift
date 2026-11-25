import Foundation

/// Units for a vessel's size. The app shows feet and miles everywhere (`VesselText`), so `appUnits` is imperial;
/// metric is kept for the day it follows the user's locale.
public enum MeasurementUnits: Sendable, Equatable {
    case imperial
    case metric
}

/// One line of the detail sheet's AIS section: "Status: Moored". `value` may hold text typed in by a crew
/// (destination, call sign): it is already passed through `VesselDetailText.plain`, and the view still shows it
/// verbatim (never as markdown or a localization key).
public struct VesselDetailItem: Sendable, Equatable, Identifiable {
    /// Stable key, also the UI-test identifier suffix: `status`, `destination`, `eta`, `size`, `draught`, `heading`,
    /// `position`, `imo`, `callSign`.
    public let id: String
    public let title: String
    public let value: String
    /// MMSI-like numbers and the position: offered for copying.
    public let copyable: Bool

    public init(id: String, title: String, value: String, copyable: Bool = false) {
        self.id = id
        self.title = title
        self.value = value
        self.copyable = copyable
    }
}

/// Text for the AIS details the relay sends (relay/PROTOCOL.md, "Vessels"): navigational status in words, the ETA,
/// size and draught, the position, and plain-text cleanup of what crews type in.
public enum VesselDetailText {
    public static let appUnits = MeasurementUnits.imperial
    private static let feetPerMeter = 3.280_84
    private static let nbsp = "\u{00A0}"

    // MARK: Navigational status

    /// AIS navigational status (ITU-R M.1371, message 1 "Navigational status") in words; nil for 15 (not defined)
    /// and anything out of range. 9, 10 and 13 are reserved for future use: "Other".
    public static func navStatus(_ code: Int) -> String? {
        switch code {
        case 0: "Under way using engine"
        case 1: "At anchor"
        case 2: "Not under command"
        case 3: "Restricted manoeuvrability"
        case 4: "Constrained by draught"
        case 5: "Moored"
        case 6: "Aground"
        case 7: "Fishing"
        case 8: "Under way sailing"
        case 11: "Towing astern"
        case 12: "Pushing ahead or towing alongside"
        case 14: "Emergency beacon active"
        case 9, 10, 13: "Other"
        default: nil
        }
    }

    // MARK: ETA

    private static let utc = TimeZone(identifier: "UTC")!

    /// The ETA as a date: the year (AIS sends none) is the one of last year, this year and next year, in UTC, that
    /// puts it nearest `now`, so a January ETA seen in December is next January. Nil when the parts are out of
    /// range or make no real date in any of those years (February 30; February 29 with no leap year among them).
    public static func etaDate(_ eta: VesselETA, now: Date) -> Date? {
        guard (1...12).contains(eta.month), (1...31).contains(eta.day), (0...23).contains(eta.hour),
              (0...59).contains(eta.minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let year = calendar.component(.year, from: now)
        let candidates = (year - 1...year + 1).compactMap { year -> Date? in
            let parts = DateComponents(year: year, month: eta.month, day: eta.day, hour: eta.hour, minute: eta.minute)
            // `date(from:)` rolls February 30 over into March: only keep a date that reads back the same.
            guard let date = calendar.date(from: parts),
                  calendar.dateComponents([.month, .day], from: date) == DateComponents(month: eta.month, day: eta.day)
            else { return nil }
            return date
        }
        return candidates.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }

    /// "Nov 17, 14:30 UTC" (the detail row is titled "Arrival"): month and day in the user's locale ("17 Nov" in
    /// British English), the time in 24-hour UTC. AIS gives no time zone for the destination, so the time stays in
    /// UTC rather than pretending to be local. An ETA already gone by (`etaDate` before `now`) adds " (past)": crews
    /// often leave an old one set. Nil for an ETA that isn't a real date (`etaDate`).
    public static func eta(_ eta: VesselETA, now: Date, locale: Locale = .current) -> String? {
        guard let date = etaDate(eta, now: now) else { return nil }
        var day = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: utc)
        day = day.month(.abbreviated).day()
        let time = String(format: "%02d:%02d", eta.hour, eta.minute)
        return "\(date.formatted(day)), \(time) UTC" + (date < now ? " (past)" : "")
    }

    // MARK: Size

    /// Longest length or beam shown, meters: AIS can't send more than 1022 (511 + 511), and a bad value must not
    /// overflow the conversion to feet.
    public static let maxDimensionMeters = 1_000
    /// Deepest draught shown, meters (AIS tops out at 25.5).
    public static let maxDraughtMeters = 100.0
    /// Shallowest draught shown, meters: below it the number says nothing.
    public static let minDraughtMeters = 0.1

    /// "518 × 92 ft" (length × beam), "518 ft long", "92 ft wide", or in meters; nil when neither is known. Each is
    /// clamped to `maxDimensionMeters`.
    public static func size(length: Int?, beam: Int?, units: MeasurementUnits = appUnits) -> String? {
        let length = length.flatMap { $0 > 0 ? min($0, maxDimensionMeters) : nil }
        let beam = beam.flatMap { $0 > 0 ? min($0, maxDimensionMeters) : nil }
        let unit = units == .imperial ? "ft" : "m"
        func value(_ meters: Int) -> String {
            units == .imperial ? "\(Int((Double(meters) * feetPerMeter).rounded()))" : "\(meters)"
        }
        switch (length, beam) {
        case let (length?, beam?): return "\(value(length)) × \(value(beam))\(nbsp)\(unit)"
        case let (length?, nil): return "\(value(length))\(nbsp)\(unit) long"
        case let (nil, beam?): return "\(value(beam))\(nbsp)\(unit) wide"
        case (nil, nil): return nil
        }
    }

    /// "21 ft", "4.3 ft" (one decimal under 10 ft) or "6.4 m"; nil when unknown or under `minDraughtMeters`.
    /// Clamped to `maxDraughtMeters`.
    public static func draught(_ meters: Double?, units: MeasurementUnits = appUnits) -> String? {
        guard let meters, meters.isFinite, meters >= minDraughtMeters else { return nil }
        let clamped = min(meters, maxDraughtMeters)
        if units == .metric { return String(format: "%.1f", clamped) + nbsp + "m" }
        let feet = clamped * feetPerMeter
        if feet < 10 { return String(format: "%.1f", feet) + nbsp + "ft" }
        return "\(Int(feet.rounded()))\(nbsp)ft"
    }

    // MARK: Lookup

    /// The vessel's page on MarineTraffic, built only from the MMSI (a number, so nothing a crew typed gets into it):
    /// a plain link the user taps; the app sends no data and reads nothing back. Nil for an MMSI that isn't positive.
    public static func marineTrafficURL(mmsi: Int) -> String? {
        guard mmsi > 0 else { return nil }
        return "https://www.marinetraffic.com/en/ais/details/ships/mmsi:\(mmsi)"
    }

    // MARK: Position

    /// "40.70110° N, 73.98990° W": five decimals (about a meter), hemisphere letters instead of signs. "" for a
    /// position that can't be real (not finite, or past ±90° / ±180°).
    public static func coordinate(latitude: Double, longitude: Double) -> String {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else { return "" }
        let lat = String(format: "%.5f° %@", abs(latitude), latitude < 0 ? "S" : "N")
        let lon = String(format: "%.5f° %@", abs(longitude), longitude < 0 ? "W" : "E")
        return "\(lat), \(lon)"
    }

    // MARK: Untrusted text

    /// Text typed in by a crew (name, destination, call sign) made safe to show on one line: control characters
    /// (newlines included), bidirectional overrides and other invisible format characters removed, whitespace runs
    /// collapsed, `@` padding and spaces trimmed. The relay does the same (relay/PROTOCOL.md, "Vessels"); the app
    /// doesn't rely on it. Nil when nothing is left.
    public static func plain(_ text: String?) -> String? {
        guard let text else { return nil }
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            if category == .control || category == .format || category == .lineSeparator
                || category == .paragraphSeparator || category == .spaceSeparator || scalar == "\t" {
                // Line breaks and tabs are controls, but they did separate words.
                if category != .format, !lastWasSpace {
                    scalars.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            scalars.append(scalar)
            lastWasSpace = false
        }
        let trimmed = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension VesselRow {
    /// "NW 318°" where the bow points; nil when the vessel doesn't report a heading.
    public var headingText: String? {
        guard let heading = vessel.heading, heading.isFinite else { return nil }
        return VesselText.bearing(degrees: heading)
    }

    /// The navigational status in words; nil when not sent or not defined.
    public var navStatusText: String? { vessel.navStatus.flatMap(VesselDetailText.navStatus) }

    /// The map card's status line: "Moored · to PIER 11 WALL ST", from what's present; nil when neither is.
    public var cardStatus: String? {
        let parts = [navStatusText, VesselDetailText.plain(vessel.destination).map { "to \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The detail sheet's AIS section, in order, leaving out what isn't known: status, destination, ETA, size, draught,
    /// heading, position, IMO, call sign.
    /// - Parameter units: feet or meters for the size and draught; nil for the row's own (`units.heightSystem`).
    public func detailItems(now: Date, locale: Locale = .current,
                            units: MeasurementUnits? = nil) -> [VesselDetailItem] {
        let units = units ?? self.units.heightSystem
        var items: [VesselDetailItem] = []
        if let status = navStatusText {
            items.append(VesselDetailItem(id: "status", title: "Status", value: status))
        }
        if let destination = VesselDetailText.plain(vessel.destination) {
            items.append(VesselDetailItem(id: "destination", title: "Destination", value: destination))
        }
        if let eta = vessel.eta.flatMap({ VesselDetailText.eta($0, now: now, locale: locale) }) {
            items.append(VesselDetailItem(id: "eta", title: "Arrival", value: eta))
        }
        if let size = VesselDetailText.size(length: vessel.length, beam: vessel.beam, units: units) {
            items.append(VesselDetailItem(id: "size", title: "Length and width", value: size))
        }
        if let draught = VesselDetailText.draught(vessel.draught, units: units) {
            items.append(VesselDetailItem(id: "draught", title: "Draught", value: draught))
        }
        if let heading = headingText {
            items.append(VesselDetailItem(id: "heading", title: "Heading", value: heading))
        }
        items.append(VesselDetailItem(
            id: "position", title: "Position",
            value: VesselDetailText.coordinate(latitude: vessel.latitude, longitude: vessel.longitude),
            copyable: true))
        if let imo = vessel.imo, imo > 0 {
            items.append(VesselDetailItem(id: "imo", title: "IMO", value: String(imo), copyable: true))
        }
        if let callSign = VesselDetailText.plain(vessel.callSign) {
            items.append(VesselDetailItem(id: "callSign", title: "Call sign", value: callSign, copyable: true))
        }
        return items
    }
}
