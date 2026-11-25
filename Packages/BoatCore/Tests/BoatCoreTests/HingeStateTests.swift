import Testing
@testable import BoatCore

@Suite struct HingeStateTests {
    @Test(arguments: [
        (HingeState.closed, "Closed"),
        (.partiallyOpen, "Partially open"),
        (.fullyOpen, "Fully open"),
        (.unavailable, "Unavailable"),
    ])
    func displayText(state: HingeState, expected: String) {
        #expect(hingeDisplayText(for: state) == expected)
    }

    @Test func everyStateHasDistinctText() {
        let texts = HingeState.allCases.map(hingeDisplayText(for:))
        #expect(Set(texts).count == HingeState.allCases.count)
    }
}
