import CoreLocation
import Foundation
import Testing
@testable import BoatCore

@Suite struct TrainMapTests {
    @Test func visibleSpanIsTheNarrowerSide() {
        // At DUMBO's latitude a degree of longitude is about 84.4 km.
        let tall = TrainMap.visibleSpanMeters(latitudeDelta: 0.05, longitudeDelta: 0.02, latitude: 40.7)
        #expect(abs(tall - 0.02 * 111_320 * cos(40.7 * .pi / 180)) < 1e-6)
        let wide = TrainMap.visibleSpanMeters(latitudeDelta: 0.01, longitudeDelta: 0.05, latitude: 40.7)
        #expect(abs(wide - 1_113.2) < 1e-6)
        #expect(TrainMap.visibleSpanMeters(latitudeDelta: -0.01, longitudeDelta: 0.05, latitude: 40.7) == wide)
    }

    @Test func undergroundTrainsShowOnlyZoomedIn() {
        #expect(TrainMap.showsUnderground(visibleSpanMeters: 800))
        #expect(TrainMap.showsUnderground(visibleSpanMeters: 3_000))
        #expect(!TrainMap.showsUnderground(visibleSpanMeters: 3_001))
        // The app's starting view, the whole area and a margin, is zoomed out.
        let start = TrainMap.visibleSpanMeters(latitudeDelta: devBoundingBox.latitudeSpan * 1.4,
                                               longitudeDelta: devBoundingBox.longitudeSpan * 1.4,
                                               latitude: devBoundingBox.center.latitude)
        #expect(!TrainMap.showsUnderground(visibleSpanMeters: start))
    }

    @Test func undergroundNote() {
        #expect(TrainMap.undergroundNote(count: 0) == nil)
        #expect(TrainMap.undergroundNote(count: 1) == "1 train underground · zoom in to see it")
        #expect(TrainMap.undergroundNote(count: 60) == "60 trains underground · zoom in to see them")
    }

    @Test func undergroundMarkerUnderAnotherIsBlockedFromTaps() {
        let bridge = CLLocationCoordinate2D(latitude: 40.7075, longitude: -73.9905)
        // 1200 m across 400 pt: 3 m per point. Targets 34 pt apart (22 + 12) overlap: 102 m.
        func north(_ meters: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: bridge.latitude + meters / 111_320, longitude: bridge.longitude)
        }
        let blocked = TrainMap.undergroundBlockedFromTaps(
            underground: [(id: "near", coordinate: north(30)), (id: "edge", coordinate: north(110)),
                          (id: "far", coordinate: north(500))],
            aboveGround: [bridge], visibleSpanMeters: 1_200, viewSidePoints: 400, overlapRadiusPoints: 34)
        #expect(blocked == ["near"])
    }

    @Test func zoomingOutBlocksMoreAndNothingAboveGroundBlocksNothing() {
        let a = CLLocationCoordinate2D(latitude: 40.7, longitude: -74.0)
        let b = CLLocationCoordinate2D(latitude: 40.7 + 300 / 111_320, longitude: -74.0)
        func blocked(span: Double) -> Set<Int> {
            TrainMap.undergroundBlockedFromTaps(underground: [(id: 1, coordinate: b)], aboveGround: [a],
                                                visibleSpanMeters: span, viewSidePoints: 400, overlapRadiusPoints: 34)
        }
        #expect(blocked(span: 1_200).isEmpty)  // 100 pt apart
        #expect(blocked(span: 3_000).isEmpty)  // 40 pt apart
        #expect(blocked(span: 4_000) == [1])  // 30 pt apart
        #expect(TrainMap.undergroundBlockedFromTaps(underground: [(id: 1, coordinate: b)], aboveGround: [],
                                                    visibleSpanMeters: 3_000, viewSidePoints: 400,
                                                    overlapRadiusPoints: 34).isEmpty)
        #expect(blocked(span: 0).isEmpty)
    }
}
