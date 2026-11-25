#if DEBUG
import SwiftUI
import UIKit

/// UI tests: what VoiceOver gets, as opposed to what XCUITest lists. XCUITest's tree also has elements VoiceOver
/// never reaches: `accessibilityHidden` views and the parts a button combines into one element. With
/// BOATAR_ACCESSIBILITY_PROBE=1 the app walks its window the way an assistive technology does (an accessibility
/// element ends the walk down; a container's `accessibilityElements`, else its subviews) and puts the labels it
/// finds, in order and joined by " | ", in the `accessibilityProbe` element's value. Debug builds only.
struct AccessibilityProbe: View {
    static let separator = " | "
    @State private var labels = ""

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("Accessibility probe")
            .accessibilityValue(labels)
            .accessibilityIdentifier("accessibilityProbe")
            .allowsHitTesting(false)
            .task {
                while !Task.isCancelled {
                    labels = Self.walk().joined(separator: Self.separator)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }

    @MainActor
    static func walk() -> [String] {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var labels: [String] = []
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 80, !object.accessibilityElementsHidden else { return }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }
            if object.isAccessibilityElement {
                let label = object.accessibilityLabel ?? ""
                if label != "Accessibility probe" { labels.append(label) }
                return
            }
            if let elements = object.accessibilityElements, !elements.isEmpty {
                elements.compactMap { $0 as? NSObject }.forEach { visit($0, depth: depth + 1) }
                return
            }
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
                    .forEach { visit($0, depth: depth + 1) }
                return
            }
            (object as? UIView)?.subviews.forEach { visit($0, depth: depth + 1) }
        }
        windows.filter { !$0.isHidden }.forEach { visit($0, depth: 0) }
        return labels
    }
}
#endif
