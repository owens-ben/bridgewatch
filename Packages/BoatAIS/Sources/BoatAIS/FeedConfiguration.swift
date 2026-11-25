import BoatCore
import Foundation

/// Picks the app's vessel feed from its configuration.
public enum FeedConfiguration {
    /// Launch environment key for UI tests: a JSON array of relay messages to replay instead of connecting.
    public static let replayEnvironmentKey = "BOATAR_REPLAY_FEED"
    /// Launch environment key for UI tests: "1" makes the replay end disconnected (offline state).
    public static let replayOfflineEnvironmentKey = "BOATAR_REPLAY_OFFLINE"
    /// Launch environment key for UI tests (chaos scenarios): a timeline of feed steps (`ScriptedVesselFeed`). Takes
    /// precedence over the replay feed.
    public static let scriptedEnvironmentKey = "BOATAR_SCRIPTED_FEED"

    /// The feed for this process: a scripted or replay feed from the launch environment if set, else the relay the
    /// user entered in Settings (when it's a valid ws/wss URL), else the relay built into this version (Info.plist).
    /// The app passes an empty environment in Release builds.
    public static func feed(environment: [String: String], relayURL: String?, userRelayURL: String? = nil)
        -> (any VesselFeed)?
    {
        if let script = environment[scriptedEnvironmentKey], let feed = ScriptedVesselFeed(json: script) {
            return feed
        }
        let relay = relayWebSocketURL(userRelayURL) != nil ? userRelayURL : relayURL
        return feed(relayURL: relay, replayJSON: environment[replayEnvironmentKey],
                    replayOffline: environment[replayOfflineEnvironmentKey] == "1")
    }

    /// Info.plist key filled from the RELAY_URL build setting (Config/BoatAR.xcconfig).
    public static let relayURLInfoKey = "RelayURL"

    /// - Returns: a replay feed when `replayJSON` is set, else a relay feed for a valid ws/wss `relayURL`, else nil
    ///   (no relay configured: the app shows no vessels).
    public static func feed(relayURL: String?, replayJSON: String?, replayOffline: Bool = false) -> (any VesselFeed)? {
        if let replayJSON, let messages = try? RelayJSON.decoder().decode([RelayMessage].self, from: Data(replayJSON.utf8)) {
            return ReplayVesselFeed(messages: messages, endsDisconnected: replayOffline)
        }
        guard let url = relayWebSocketURL(relayURL) else { return nil }
        return RelayVesselFeed(url: targetsURL(for: url))
    }

    /// The relay's path for the app's protocol (relay/PROTOCOL.md, "/v2/targets") and for the one it replaced.
    public static let targetsPath = "/v2/targets"
    public static let legacyVesselsPath = "/v1/vessels"

    /// The URL to connect to for a configured relay URL. An address whose path is `/v1/vessels`, which is what this
    /// app used to be configured with (the build setting, or typed in Settings), is the same relay's `/v2/targets`
    /// on the same scheme, host and port. Any other path is used as is.
    public static func targetsURL(for url: URL) -> URL {
        // URLComponents.path is the path as written; URL.path drops a trailing slash.
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == legacyVesselsPath
        else { return url }
        components.path = targetsPath
        return components.url ?? url
    }

    /// A usable relay URL: ws or wss with a host. Empty or anything else is treated as not configured.
    public static func relayWebSocketURL(_ string: String?) -> URL? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "ws" || scheme == "wss",
              url.host() != nil
        else { return nil }
        return url
    }

    /// Why iOS would refuse to connect to `url`, or nil when it's fine. App Transport Security only lets plain `ws://`
    /// through to local hosts (the app enables NSAllowsLocalNetworking): IP addresses, unqualified names like "relay-box",
    /// and ".local" names. Any other host name needs `wss://`.
    public static func transportSecurityProblem(for url: URL) -> String? {
        guard url.scheme?.lowercased() == "ws", var host = url.host()?.lowercased() else { return nil }
        // A trailing dot only marks the name as absolute.
        if host.hasSuffix(".") { host.removeLast() }
        let isIPAddress = host.contains(":") || host.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
        let isLocal = !host.contains(".") || host.hasSuffix(".local")
        guard !isIPAddress, !isLocal else { return nil }
        return "This address needs a secure connection: start it with wss:// instead of ws://."
    }

    /// The Settings field's placeholder: the address's shape on a made-up public host (never a private address).
    public static let exampleAddress = "wss://example.com/v2/targets"

    /// What Settings says about an address it can't use: the format, with `exampleAddress`.
    public static let addressFormatHint = "Enter an address that starts with wss:// or ws://, like \(exampleAddress)."
}
