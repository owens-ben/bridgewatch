/// App-level hinge state, independent of UIKit so it can be mapped and tested without views.
public enum HingeState: Equatable, Sendable, CaseIterable {
    case closed
    case partiallyOpen
    case fullyOpen
    case unavailable
}

/// Pure mapping from hinge state to the text shown on the home screen.
public func hingeDisplayText(for state: HingeState) -> String {
    switch state {
    case .closed: "Closed"
    case .partiallyOpen: "Partially open"
    case .fullyOpen: "Fully open"
    case .unavailable: "Unavailable"
    }
}
