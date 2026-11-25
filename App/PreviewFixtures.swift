#if DEBUG
import BoatAIS
import BoatCore
import Foundation

/// Sample vessels for SwiftUI previews (made-up names, positions inside the dev box).
@MainActor
enum PreviewFixtures {
    /// Local test location for previews: the DUMBO waterfront, facing NW, compass ±5° ("lat,lon,heading,pitch,accuracy").
    static let sensors = "40.7046,-73.9913,318,0,5"

    /// A vessel target as the relay sends it.
    private static func vessel(
        _ mmsi: Int, name: String? = nil, shipType: Int? = nil, lat: Double, lon: Double,
        sog: Double? = nil, cog: Double? = nil, heading: Double? = nil, timestamp: Date
    ) -> Target {
        Target(
            id: "vessel:\(mmsi)", kind: .vessel, source: "aisstream", name: name, lat: lat, lon: lon,
            speed: sog, course: cog, heading: heading, timestamp: timestamp,
            vessel: VesselDetails(mmsi: mmsi, shipType: shipType))
    }

    /// A train target as the relay sends it: on a stretch (measured heights), or underground at a modelled rail
    /// altitude (`altitudeEstimated`, as the relay sends for every underground train).
    private static func train(
        _ trip: String, route: String, destination: String, stretch: String?, lat: Double, lon: Double,
        altitude: Double, speed: Double, course: Double, timestamp: Date
    ) -> Target {
        Target(
            id: "train:nyct:\(trip)", kind: .train, source: "mta-subway", lat: lat, lon: lon, altitude: altitude,
            speed: speed, course: course, timestamp: timestamp,
            train: TrainDetails(route: route, direction: .north, destination: destination, stretch: stretch,
                                underground: stretch == nil, altitudeEstimated: stretch == nil))
    }

    static func targets(now: Date = Date()) -> [Target] {
        [
            train("Q1", route: "Q", destination: "96 St", stretch: "manhattan-bridge", lat: 40.7075, lon: -73.9905,
                  altitude: 41, speed: 18, course: 340, timestamp: now.addingTimeInterval(-3)),
            train("M1", route: "M", destination: "Middle Village-Metropolitan Av", stretch: "williamsburg-bridge",
                  lat: 40.7141, lon: -73.9739, altitude: 42, speed: 15, course: 112, timestamp: now.addingTimeInterval(-4)),
            train("F1", route: "F", destination: "Jamaica-179 St", stretch: nil, lat: 40.7014, lon: -73.9867,
                  altitude: -14, speed: 0, course: 300, timestamp: now.addingTimeInterval(-5)),
            train("6X1", route: "6X", destination: "Pelham Bay Park", stretch: nil, lat: 40.7130, lon: -74.0040,
                  altitude: -4, speed: 20, course: 20, timestamp: now.addingTimeInterval(-2)),
            vessel(367000001, name: "HARBOR LARK", shipType: 60, lat: 40.7062, lon: -73.9931,
                   sog: 14.2, cog: 63, heading: 62, timestamp: now.addingTimeInterval(-8)),
            vessel(367000002, name: "ANNABEL K", shipType: 52, lat: 40.7068, lon: -73.9890,
                   sog: 6.8, cog: 245, timestamp: now.addingTimeInterval(-20)),
            vessel(367000003, name: "WREN", shipType: 36, lat: 40.7029, lon: -73.9971,
                   sog: 4.1, cog: 80, heading: 79, timestamp: now.addingTimeInterval(-190)),
            vessel(367000004, lat: 40.7102, lon: -73.9862, timestamp: now.addingTimeInterval(-40)),
            vessel(367000006, name: "EVERGREEN BAY", shipType: 79, lat: 40.7098, lon: -73.9905,
                   sog: 3.2, cog: 30, timestamp: now.addingTimeInterval(-12)),
            vessel(367000055, name: "NYPD HARBOR 1", shipType: 55, lat: 40.7060, lon: -73.9950,
                   sog: 8.4, cog: 200, timestamp: now.addingTimeInterval(-6)),
        ]
    }

    static func store(offline: Bool = false, empty: Bool = false) -> VesselStore {
        let store = VesselStore()
        store.start(feed: ReplayVesselFeed(
            messages: [.snapshot(empty ? [] : targets())], endsDisconnected: offline))
        return store
    }
}
#endif
