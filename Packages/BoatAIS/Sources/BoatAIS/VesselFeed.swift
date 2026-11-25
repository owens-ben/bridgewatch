import BoatCore

/// A source of relay messages. The app depends on this protocol; tests inject a fake.
public protocol VesselFeed: Sendable {
    /// Starts the feed. Cancelling the consuming task (or dropping the stream) stops it.
    func events() -> AsyncStream<FeedEvent>
}

public enum FeedEvent: Sendable, Equatable {
    /// Opening a connection.
    case connecting
    /// The first message of a connection arrived.
    case connected
    case message(RelayMessage)
    /// The connection ended or failed; the feed retries after a backoff delay.
    case disconnected
    /// The relay refused this app: it answered the WebSocket upgrade with HTTP 401 or 403 (a missing or wrong token,
    /// relay/PROTOCOL.md). Yielded instead of `.disconnected` for that attempt; the feed keeps retrying, at the
    /// backoff's cap (`RelayVesselFeed`), so a token fixed on the relay is picked up within a minute.
    case rejected
}

/// Replays a fixed list of messages once, then stays open, or drops the connection when `endsDisconnected`
/// (the offline state). Used by UI tests and previews.
public struct ReplayVesselFeed: VesselFeed {
    public let messages: [RelayMessage]
    public let endsDisconnected: Bool

    public init(messages: [RelayMessage], endsDisconnected: Bool = false) {
        self.messages = messages
        self.endsDisconnected = endsDisconnected
    }

    public func events() -> AsyncStream<FeedEvent> {
        AsyncStream { continuation in
            continuation.yield(.connected)
            for message in messages { continuation.yield(.message(message)) }
            if endsDisconnected { continuation.yield(.disconnected) }
        }
    }
}
