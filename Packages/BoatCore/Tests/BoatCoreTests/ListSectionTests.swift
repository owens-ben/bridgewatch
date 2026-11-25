import CoreGraphics
import Foundation
import Testing
@testable import BoatCore

@Suite struct ListSectionTests {
    @Test func defaultsKeepTodaysStates() {
        #expect(!ListSection.boatsOutOfSight.expandedByDefault)
        #expect(!ListSection.trainsUnderground.expandedByDefault)
        #expect(ListSection.boatsInSight.expandedByDefault)
        #expect(ListSection.trainsInSight.expandedByDefault)
        #expect(ListSection.trainsOutOfSight.expandedByDefault)
        #expect(Set(ListSection.allCases.map(\.storageKey)).count == ListSection.allCases.count)
        #expect(Set(ListSection.allCases.map(\.headerIdentifier)).count == ListSection.allCases.count)
        #expect(ListSection.boatsOutOfSight.headerIdentifier == "outOfSightToggle")
        #expect(ListSection.trainsUnderground.headerIdentifier == "undergroundToggle")
    }

    @Test func titles() {
        #expect(ListSection.boatsInSight.title(count: 4) == "In sight · 4")
        #expect(ListSection.boatsInSight.title(count: 4, hasDistances: false) == "All boats · 4")
        #expect(ListSection.trainsInSight.title(count: 2, hasDistances: false) == "Above ground · 2")
        #expect(ListSection.trainsUnderground.title(count: 60) == "Underground · 60")
        #expect(ListSection.boatsInSight.spokenTitle(count: 4) == "In sight, 4")
        #expect(ListSection.trainsInSight.spokenTitle(count: 2, hasDistances: false) == "Above ground, 2")
    }
}
