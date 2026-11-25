import BoatCore

/// What the user selected or asked the camera to find: a boat by MMSI or a train by its target `id`.
enum TargetID: Hashable, Identifiable {
    case vessel(Int)
    case train(String)

    var id: Self { self }

    var vessel: Int? {
        if case .vessel(let mmsi) = self { return mmsi }
        return nil
    }

    var train: String? {
        if case .train(let id) = self { return id }
        return nil
    }
}

/// Settings > Trains: whether trains show at all, and whether the ones underground do.
enum TrainSettings {
    static let showTrainsKey = "showTrains"
    static let showUndergroundKey = "showUndergroundTrains"

    /// The trains the list, map and camera show.
    static func visible(_ trains: [Train], showTrains: Bool, showUnderground: Bool) -> [Train] {
        guard showTrains else { return [] }
        return showUnderground ? trains : trains.filter { !$0.underground }
    }
}
