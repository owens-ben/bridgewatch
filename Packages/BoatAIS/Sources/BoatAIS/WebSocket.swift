import Foundation

/// Opens WebSocket connections. Abstracted so tests can script connections without a network.
public protocol WebSocketConnecting: Sendable {
    /// Throws `WebSocketError.rejected` when the server refuses the upgrade with 401 or 403 (a connector may also
    /// report that from the connection's first `receive()`).
    func connect(to url: URL) async throws -> any WebSocketConnection
}

/// Failures the feed tells apart from an outage.
public enum WebSocketError: Error, Equatable, Sendable {
    /// The server answered the upgrade request with HTTP `status` 401 or 403: it refuses this client.
    case rejected(status: Int)

    /// The HTTP statuses that mean the server refuses this client, not that it's unreachable.
    public static let rejectionStatuses: Set<Int> = [401, 403]
}

/// One open WebSocket.
public protocol WebSocketConnection: Sendable {
    /// The next frame's payload (text frames as UTF-8). Throws when the connection ends, and
    /// `WebSocketError.rejected` when the server refused the upgrade.
    func receive() async throws -> Data
    /// Sends a ping and returns when the pong arrives. Throws when the connection ends first, and (with
    /// `CancellationError`) as soon as the calling task is cancelled.
    func ping() async throws
    func close()
}

public struct URLSessionWebSocketConnector: WebSocketConnecting {
    /// The largest message accepted: URLSession's default is 1 MiB, and a bigger snapshot would fail every
    /// connection before its first message, forever (docs/CRASH-HUNT.md, F10). A snapshot is about 400 bytes per
    /// target, so this is about 20,000 targets; the relay warns in its log past 512 KiB.
    public static let maximumMessageSize = 8 * 1024 * 1024

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(to url: URL) async throws -> any WebSocketConnection {
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = Self.maximumMessageSize
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

struct URLSessionWebSocketConnection: WebSocketConnection {
    let task: URLSessionWebSocketTask

    func receive() async throws -> Data {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            // URLSession opens the socket lazily: a refused upgrade fails the first receive (NSURLErrorBadServerResponse),
            // with the server's HTTP response on the task.
            throw Self.rejection(response: task.response) ?? error
        }
        switch message {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: throw URLError(.cannotDecodeContentData)
        }
    }

    /// `WebSocketError.rejected` when `response` is an HTTP 401 or 403, else nil.
    static func rejection(response: URLResponse?) -> WebSocketError? {
        guard let status = (response as? HTTPURLResponse)?.statusCode,
              WebSocketError.rejectionStatuses.contains(status) else { return nil }
        return .rejected(status: status)
    }

    func ping() async throws {
        // URLSession calls the handler once (with an error if the connection ends first), but it doesn't observe
        // task cancellation: ResumeOnce lets cancellation answer first and drops whatever comes after.
        let once = ResumeOnce<Result<Void, any Error>>()
        try await withTaskCancellationHandler {
            try await withCheckedContinuation { continuation in
                once.arm(continuation)
                task.sendPing { error in once.resume(error.map { .failure($0) } ?? .success(())) }
            }.get()
        } onCancel: {
            once.resume(.failure(CancellationError()))
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
