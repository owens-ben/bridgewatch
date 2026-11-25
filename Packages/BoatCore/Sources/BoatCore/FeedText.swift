/// What the app says when it can't get boat and train data (docs/DESIGN.md, Data states), in plain words: no
/// "relay", no network names. The list, the map and the camera say the same.
public enum FeedText {
    /// Why the data stopped.
    public enum Problem: Sendable, Equatable {
        /// The server can't be reached, or the connection dropped.
        case unreachable
        /// The server answered and turned this app away (a 401 or 403: an app token it doesn't accept).
        case rejected
    }

    /// The banner's first line.
    public static func title(_ problem: Problem) -> String {
        switch problem {
        case .unreachable: "Can't reach the server"
        case .rejected: "The server didn't accept this app"
        }
    }

    /// The banner's second line. `customAddress`: an address typed into Settings is in use, the likelier culprit.
    public static func message(_ problem: Problem, customAddress: Bool) -> String {
        switch (problem, customAddress) {
        case (.unreachable, false): "Showing the last positions. Trying again…"
        case (.unreachable, true): "Showing the last positions. Check the address in Settings."
        case (.rejected, false): "Showing the last positions. Update the app from TestFlight."
        case (.rejected, true): "Showing the last positions. Check the address in Settings."
        }
    }

    /// The camera's one-line notice, over the preview: shorter, the labels being what's stale.
    public static func cameraNotice(_ problem: Problem) -> String {
        switch problem {
        case .unreachable: "Can't reach the server · labels show the last positions"
        case .rejected: "The server didn't accept this app · labels show the last positions"
        }
    }
}
