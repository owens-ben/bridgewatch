import Testing
@testable import BoatCore

struct FeedTextTests {
    @Test func plainWordsWithoutJargon() {
        for problem in [FeedText.Problem.unreachable, .rejected] {
            for custom in [false, true] {
                let all = [FeedText.title(problem), FeedText.message(problem, customAddress: custom),
                           FeedText.cameraNotice(problem)].joined(separator: " ")
                for word in ["relay", "Relay", "Tailscale", "ws://", "401", "token"] {
                    #expect(!all.contains(word), "\(problem) custom=\(custom): \(all)")
                }
            }
        }
    }

    @Test func wording() {
        #expect(FeedText.title(.unreachable) == "Can't reach the server")
        #expect(FeedText.message(.unreachable, customAddress: false) == "Showing the last positions. Trying again…")
        #expect(FeedText.message(.unreachable, customAddress: true).hasSuffix("Check the address in Settings."))
        #expect(FeedText.title(.rejected) != FeedText.title(.unreachable))
        #expect(FeedText.message(.rejected, customAddress: false).contains("Update the app"))
    }
}
