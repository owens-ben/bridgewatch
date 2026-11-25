import Foundation

/// The words of Settings > "Data and credits", and the one line on the first screen: where the data comes from, who
/// is credited, and what the app does not promise. They live here so tests can assert the sentences the data
/// providers' terms require; the view only lays them out. Plain words, no slashes or jargon.
public enum DataCredits {
    public struct Link: Sendable, Equatable {
        public let title: String
        public let url: URL
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        /// Paragraphs, in order.
        public let paragraphs: [String]
        public let links: [Link]
    }

    public static let screenTitle = "Data and credits"

    /// The short line on the first screen, above the permission reasons.
    public static let onboardingLine = "Positions come from public feeds and can be late or wrong."

    public static let boatsSentence = "Boat positions come from AIS, the radio signal boats broadcast, by way of aisstream.io."
    public static let trainsSentence = "Train positions are estimated from the MTA's real-time arrival predictions."
    /// MTA's developer terms: no implied endorsement, no promise the data is accurate, complete or timely.
    public static let mtaSentence = "Transit data: MTA. Not affiliated with or endorsed by the MTA. "
        + "Data provided as is and may be inaccurate, incomplete or delayed."
    public static let mapSentence = "Maps are Apple Maps. Sightlines use building heights from NYC Open Data "
        + "(Building Footprints, NYC OTI, data of November 8, 2026), simplified to a 50 m grid of the highest roof "
        + "per cell, and shorelines from the U.S. Census Bureau (TIGER/Line Shapefiles, 2024)."
    public static let terrainSentence = "Subway track heights and depths use data from the U.S. Geological Survey (3DEP). "
        + "Some station and tunnel positions are from © OpenStreetMap contributors."
    public static let warningSentence = "Positions can be late or wrong. Don't use this app for navigation or safety."

    public static let aisstreamURL = URL(string: "https://aisstream.io")!
    public static let mtaURL = URL(string: "https://www.mta.info/developers")!
    public static let openStreetMapURL = URL(string: "https://www.openstreetmap.org/copyright")!

    public static let sections: [Section] = [
        Section(id: "boats", title: "Boats", paragraphs: [boatsSentence],
                links: [Link(title: "aisstream.io", url: aisstreamURL)]),
        Section(id: "trains", title: "Trains", paragraphs: [trainsSentence, mtaSentence],
                links: [Link(title: "MTA developer resources", url: mtaURL)]),
        Section(id: "map", title: "Map and terrain", paragraphs: [mapSentence, terrainSentence],
                links: [Link(title: "OpenStreetMap copyright", url: openStreetMapURL)]),
        Section(id: "general", title: "Good to know", paragraphs: [warningSentence], links: []),
    ]
}
