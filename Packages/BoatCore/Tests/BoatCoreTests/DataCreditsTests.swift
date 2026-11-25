import Foundation
import Testing
@testable import BoatCore

struct DataCreditsTests {
    private var allText: String { DataCredits.sections.flatMap(\.paragraphs).joined(separator: "\n") }

    @Test func requiredSentencesVerbatim() {
        #expect(allText.contains("Boat positions come from AIS, the radio signal boats broadcast, by way of aisstream.io."))
        #expect(allText.contains("Train positions are estimated from the MTA's real-time arrival predictions."))
        #expect(allText.contains("Transit data: MTA. Not affiliated with or endorsed by the MTA. "
                                 + "Data provided as is and may be inaccurate, incomplete or delayed."))
        #expect(allText.contains("Positions can be late or wrong. Don't use this app for navigation or safety."))
        #expect(DataCredits.onboardingLine == "Positions come from public feeds and can be late or wrong.")
    }

    @Test func creditsNameTheBundledData() {
        for name in ["Apple Maps", "NYC Open Data", "TIGER/Line Shapefiles", "U.S. Census Bureau",
                     "U.S. Geological Survey", "OpenStreetMap contributors"] {
            #expect(allText.contains(name), "\(name)")
        }
    }

    @Test func linksPointAtTheProviders() {
        let links = DataCredits.sections.flatMap(\.links).map(\.url.absoluteString)
        #expect(links.contains("https://aisstream.io"))
        #expect(links.contains("https://www.mta.info/developers"))
        #expect(DataCredits.sections.first { $0.id == "boats" }?.links.first?.url == DataCredits.aisstreamURL)
        #expect(DataCredits.sections.first { $0.id == "trains" }?.links.first?.url == DataCredits.mtaURL)
    }

    @Test func plainWords() {
        for word in ["relay", "WebSocket", "GTFS", "/v2", "API"] {
            #expect(!allText.contains(word), "\(word)")
        }
    }
}
