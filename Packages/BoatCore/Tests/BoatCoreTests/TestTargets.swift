import Foundation
@testable import BoatCore

func date(_ iso: String) throws -> Date {
    try Date(iso, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

/// A vessel target as the relay sends it (relay/PROTOCOL.md, "Vessels").
func vesselTarget(
    _ mmsi: Int, name: String? = nil, shipType: Int? = nil, lat: Double = 40.705, lon: Double = -73.99,
    speed: Double? = nil, course: Double? = nil, heading: Double? = nil, timestamp: Date, source: String = "aisstream"
) -> Target {
    Target(
        id: "vessel:\(mmsi)", kind: .vessel, source: source, name: name, lat: lat, lon: lon,
        speed: speed, course: course, heading: heading, timestamp: timestamp,
        vessel: VesselDetails(mmsi: mmsi, shipType: shipType))
}

/// A train target as the relay sends it (relay/PROTOCOL.md, "Trains"): on a stretch (20 m, measured), or underground
/// (`stretch` nil; -10 m, estimated, as the relay marks every underground altitude). `altitudeEstimated` overrides.
func trainTarget(
    _ trip: String, route: String = "Q", direction: TrainDirection = .south, destination: String? = nil,
    stretch: String? = "manhattan-bridge", lat: Double = 40.7, lon: Double = -73.99, altitude: Double? = nil,
    speed: Double = 15, course: Double = 157, altitudeEstimated: Bool? = nil, timestamp: Date
) -> Target {
    Target(
        id: "train:nyct:\(trip)", kind: .train, source: "mta-subway", lat: lat, lon: lon,
        altitude: altitude ?? (stretch == nil ? -10 : 20), speed: speed, course: course, timestamp: timestamp,
        train: TrainDetails(
            route: route, direction: direction, destination: destination, stretch: stretch,
            underground: stretch == nil, altitudeEstimated: altitudeEstimated ?? (stretch == nil)))
}

/// A vessel with the given state, for tests of what the app does with vessels.
func testVessel(
    mmsi: Int, name: String? = nil, shipType: Int? = nil, lat: Double, lon: Double,
    sog: Double? = nil, cog: Double? = nil, heading: Double? = nil, timestamp: Date
) -> Vessel {
    Vessel(vesselTarget(
        mmsi, name: name, shipType: shipType, lat: lat, lon: lon, speed: sog, course: cog, heading: heading,
        timestamp: timestamp))!
}
