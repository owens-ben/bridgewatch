import BoatCore
import Foundation
import Testing
@testable import BoatAIS

@Suite struct FeedConfigurationTests {
    @Test(arguments: [
        "ws://relay-box.local:8080/v2/targets", "wss://relay.example.com/v2/targets", "  ws://192.0.2.5:8080/v2/targets\n",
        // Valid as typed; only the feed rewrites it (below).
        "ws://relay-box.local:8080/v1/vessels",
    ])
    func acceptsWebSocketURLs(_ string: String) throws {
        let url = try #require(FeedConfiguration.relayWebSocketURL(string))
        #expect(url.absoluteString == string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test(arguments: [nil, "", "   ", "http://relay-box.local:8080/v2/targets", "relay-box.local:8080", "ws://", "$(RELAY_URL)"])
    func treatsAnythingElseAsUnconfigured(_ string: String?) {
        #expect(FeedConfiguration.relayWebSocketURL(string) == nil)
        #expect(FeedConfiguration.feed(relayURL: string, replayJSON: nil) == nil)
    }

    @Test func relayURLGivesRelayFeed() throws {
        let feed = try #require(FeedConfiguration.feed(relayURL: "ws://relay-box.local:8080/v2/targets", replayJSON: nil))
        let relay = try #require(feed as? RelayVesselFeed)
        #expect(relay.url.host() == "relay-box.local")
    }

    // MARK: /v1/vessels addresses

    @Test(arguments: [
        ("ws://relay-box:8095/v1/vessels", "ws://relay-box:8095/v2/targets"),
        ("wss://relay.example.com/v1/vessels", "wss://relay.example.com/v2/targets"),
        ("ws://192.0.2.10:8095/v1/vessels", "ws://192.0.2.10:8095/v2/targets"),
        ("ws://relay-box.local/v1/vessels", "ws://relay-box.local/v2/targets"),
        ("ws://[fe80::1]:8095/v1/vessels", "ws://[fe80::1]:8095/v2/targets"),
        ("  ws://relay-box:8095/v1/vessels\n", "ws://relay-box:8095/v2/targets"),
    ])
    func connectsToTargetsInsteadOfVessels(_ configured: String, _ connected: String) throws {
        let feed = try #require(FeedConfiguration.feed(relayURL: configured, replayJSON: nil))
        #expect((feed as? RelayVesselFeed)?.url.absoluteString == connected)
    }

    @Test func keepsSchemeHostAndPortOfAVesselsAddress() throws {
        let url = try #require(FeedConfiguration.relayWebSocketURL("WSS://Relay.Example.com:8443/v1/vessels"))
        let rewritten = FeedConfiguration.targetsURL(for: url)
        #expect(rewritten.scheme?.lowercased() == "wss")
        #expect(rewritten.host()?.lowercased() == "relay.example.com")
        #expect(rewritten.port == 8443)
        #expect(rewritten.path == "/v2/targets")
    }

    @Test(arguments: [
        "ws://relay-box:8095/v2/targets",
        "ws://relay-box:8095/v1/vessels/",
        "ws://relay-box:8095/v1/vessels2",
        "ws://relay-box:8095/relay/v1/vessels",
        "ws://relay-box:8095/V1/VESSELS",
        "ws://relay-box:8095/custom",
        "ws://relay-box:8095/",
        "ws://relay-box:8095",
        "wss://relay.example.com/some/other/path",
    ])
    func usesAnyOtherPathAsIs(_ configured: String) throws {
        let feed = try #require(FeedConfiguration.feed(relayURL: configured, replayJSON: nil))
        #expect((feed as? RelayVesselFeed)?.url.absoluteString == configured)
    }

    @Test func rewritingKeepsTheQuery() throws {
        let url = try #require(FeedConfiguration.relayWebSocketURL("ws://relay-box:8095/v1/vessels?token=abc"))
        #expect(FeedConfiguration.targetsURL(for: url).absoluteString == "ws://relay-box:8095/v2/targets?token=abc")
    }

    @Test func aVesselsAddressTypedInSettingsAlsoConnectsToTargets() throws {
        let feed = try #require(FeedConfiguration.feed(
            environment: [:], relayURL: "ws://built-in:8080/v2/targets", userRelayURL: "ws://relay-box:8095/v1/vessels"))
        #expect((feed as? RelayVesselFeed)?.url.absoluteString == "ws://relay-box:8095/v2/targets")
    }

    @Test func replayJSONWinsOverRelayURL() throws {
        let json = "[\(snapshotFrame),\(updateFrame)]"
        let feed = try #require(FeedConfiguration.feed(relayURL: "ws://relay-box.local:8080/v2/targets", replayJSON: json))
        let replay = try #require(feed as? ReplayVesselFeed)
        #expect(replay.messages == [decoded(snapshotFrame), decoded(updateFrame)])
    }

    @Test func badReplayJSONFallsBackToRelay() {
        let feed = FeedConfiguration.feed(relayURL: "ws://relay-box.local:8080/v2/targets", replayJSON: "nope")
        #expect(feed is RelayVesselFeed)
    }

    @Test(.timeLimit(.minutes(1)))
    func replayFeedEmitsConnectedThenMessages() async {
        let feed = ReplayVesselFeed(messages: [decoded(snapshotFrame), decoded(updateFrame)])
        let events = await collect(feed.events()) { $0.count == 3 }
        #expect(events == [.connected, .message(decoded(snapshotFrame)), .message(decoded(updateFrame))])
    }

    @Test(.timeLimit(.minutes(1)))
    func offlineReplayEndsDisconnected() async throws {
        let feed = try #require(FeedConfiguration.feed(
            environment: ["BOATAR_REPLAY_FEED": "[\(snapshotFrame)]", "BOATAR_REPLAY_OFFLINE": "1"], relayURL: nil))
        let events = await collect(feed.events()) { $0.last == .disconnected }
        #expect(events == [.connected, .message(decoded(snapshotFrame)), .disconnected])
    }

    @Test func environmentWithoutReplayUsesRelay() {
        let feed = FeedConfiguration.feed(environment: ["BOATAR_REPLAY_OFFLINE": "1"], relayURL: "ws://relay-box:8095/v2/targets")
        #expect(feed is RelayVesselFeed)
    }

    @Test func userRelayURLOverridesTheBuiltInOne() throws {
        let feed = try #require(FeedConfiguration.feed(
            environment: [:], relayURL: "ws://built-in:8080/v2/targets", userRelayURL: "wss://relay.example.com/v2/targets"))
        #expect((feed as? RelayVesselFeed)?.url.host() == "relay.example.com")
    }

    @Test(arguments: [nil, "", "not a url", "http://relay.example.com"])
    func invalidUserRelayURLFallsBackToBuiltIn(_ user: String?) throws {
        let feed = try #require(FeedConfiguration.feed(
            environment: [:], relayURL: "ws://built-in:8080/v2/targets", userRelayURL: user))
        #expect((feed as? RelayVesselFeed)?.url.host() == "built-in")
    }

    @Test func userRelayURLWorksWithoutBuiltInOne() {
        let feed = FeedConfiguration.feed(environment: [:], relayURL: "", userRelayURL: "ws://relay-box:8095/v2/targets")
        #expect((feed as? RelayVesselFeed)?.url.host() == "relay-box")
    }

    @Test func replayStillWinsOverUserRelay() {
        let feed = FeedConfiguration.feed(
            environment: ["BOATAR_REPLAY_FEED": "[]"], relayURL: nil, userRelayURL: "ws://relay-box:8095/v2/targets")
        #expect(feed is ReplayVesselFeed)
    }

    // MARK: App Transport Security

    @Test(arguments: [
        "ws://relay-box:8095/v2/targets",
        "ws://localhost:8095/v2/targets",
        "ws://192.0.2.10:8095/v2/targets",
        "ws://192.0.2.20/v2/targets",
        "ws://[fe80::1]:8095/v2/targets",
        "ws://[::1]:8095/v2/targets",
        "ws://relay-box.local:8095/v2/targets",
        "WS://RELAY-BOX.LOCAL:8095/v2/targets",
        "ws://relay-box.local.:8095/v2/targets",
        "wss://relay-box.example.ts.net/v2/targets",
        "WSS://relay.example.com/v2/targets",
    ])
    func allowsWhatTransportSecurityAllows(_ string: String) throws {
        let url = try #require(FeedConfiguration.relayWebSocketURL(string))
        #expect(FeedConfiguration.transportSecurityProblem(for: url) == nil)
    }

    @Test(arguments: [
        "ws://relay-box.example.ts.net:8095/v2/targets",
        "ws://relay.example.com/v2/targets",
        "WS://Relay.Example.com/v2/targets",
        "ws://nas.lan:8095/v2/targets",
        "ws://relay-box.localdomain:8095/v2/targets",
        "ws://relay-box.example.com.:8095/v2/targets",
    ])
    func refusesPlainWebSocketToQualifiedHostNames(_ string: String) throws {
        let url = try #require(FeedConfiguration.relayWebSocketURL(string))
        let problem = try #require(FeedConfiguration.transportSecurityProblem(for: url))
        #expect(problem == "This address needs a secure connection: start it with wss:// instead of ws://.")
    }

    /// Settings shows these to testers: no private address (an IP, a LAN name) in either.
    @Test func placeholderAndHintShowNoPrivateAddress() {
        for text in [FeedConfiguration.exampleAddress, FeedConfiguration.addressFormatHint] {
            #expect(!text.contains("192.0.2") && !text.contains("relay-box") && !text.contains(":8095"), "\(text)")
        }
        #expect(FeedConfiguration.relayWebSocketURL(FeedConfiguration.exampleAddress) != nil)
        #expect(FeedConfiguration.addressFormatHint.contains(FeedConfiguration.exampleAddress))
    }
}
