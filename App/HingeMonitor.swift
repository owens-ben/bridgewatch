import BoatCore
import Observation
import SwiftUI
import UIKit

/// Observes the device hinge via `UIHingeInteraction`. This file is the only place the app touches the hinge API;
/// views read `state` / `angle` from the environment.
@MainActor
@Observable
final class HingeMonitor {
    private(set) var state: HingeState = .unavailable
    /// Hinge angle in radians, or nil when no hinge is reporting.
    private(set) var angle: Double?

    @available(iOS 27.1, *)
    func apply(_ update: UIHingeInteraction.Update) {
        // A nil hinge means the interaction is outside a hierarchy that provides hinge updates (e.g. iPhone 18 Pro).
        guard let hinge = update.hinge else {
            state = .unavailable
            angle = nil
            return
        }
        angle = Double(hinge.angle)
        switch hinge.status {
        case .closed: state = .closed
        case .partiallyOpen: state = .partiallyOpen
        case .fullyOpen: state = .fullyOpen
        case .unknown: state = .unavailable
        @unknown default: state = .unavailable
        }
    }
}

/// Zero-size view that attaches a `UIHingeInteraction` feeding a `HingeMonitor`.
@available(iOS 27.1, *)
struct HingeObserver: UIViewRepresentable {
    let monitor: HingeMonitor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.addInteraction(UIHingeInteraction { [weak monitor] _, update in
            monitor?.apply(update)
        })
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
