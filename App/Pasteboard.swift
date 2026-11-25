import SwiftUI
import UIKit

/// The one place the app writes to the pasteboard (views don't touch UIKit directly).
enum Pasteboard {
    @MainActor
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}

extension View {
    /// Text that can be copied: a long press offers Copy (`textSelection`), and VoiceOver gets a "Copy" action that
    /// puts `text` on the pasteboard. Nil leaves the view as it is.
    @ViewBuilder
    func copyable(_ text: String?) -> some View {
        if let text {
            textSelection(.enabled)
                .accessibilityAction(named: "Copy") { Pasteboard.copy(text) }
        } else {
            self
        }
    }
}
