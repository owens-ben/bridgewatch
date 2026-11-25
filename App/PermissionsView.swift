import BoatCore
import SwiftUI

/// First launch: what location and camera are for. The app works list-only without either.
struct PermissionsView: View {
    @Environment(DeviceSensors.self) private var sensors
    @Environment(\.dynamicTypeSize) private var typeSize
    let done: () -> Void

    /// Pinned under the text, the buttons would cover most of the screen at accessibility text sizes: there they end
    /// the scroll content instead.
    private var actionsScroll: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bridgewatch")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.token(.textPrimary))
                        .accessibilityIdentifier("permissionsTitle")
                    Text("Name the boats and trains around the East River, from a list, a map, or your camera.")
                        .font(.body)
                        .foregroundStyle(.token(.textSecondary))
                    Text(DataCredits.onboardingLine)
                        .font(.subheadline)
                        .foregroundStyle(.token(.textSecondary))
                        .accessibilityIdentifier("permissionsDataLine")
                }
                reason(symbol: "location.fill", title: "Your location",
                       detail: "Measures how far away each boat and train is and which way it lies. Only while the app is open.")
                reason(symbol: "camera.viewfinder", title: "Camera",
                       detail: "Labels the boats and trains you point it at. Asked for when you first open the camera. Nothing is recorded or uploaded.")
                if actionsScroll {
                    actions
                        .padding(.bottom, Metrics.screenMargin)
                }
            }
            .padding(.horizontal, Metrics.screenMargin * 1.5)
            .padding(.top, 48)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if !actionsScroll {
                actions
                    .frame(maxWidth: 560)
                    .padding(Metrics.screenMargin)
                    .frame(maxWidth: .infinity)
                    // Solid, so the explanation scrolls underneath instead of showing through at large text sizes.
                    .background(.token(.bgBase))
            }
        }
        .background(.token(.bgBase))
    }

    private var actions: some View {
        VStack(spacing: 12) {
            // Never waits on a system prompt: the list appears right away and the location answer arrives later.
            Button("Continue") {
                sensors.requestPermissions()
                done()
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("permissionsContinue")
            Button("Not now — just the list", action: done)
                .font(.headline)
                .frame(minHeight: Metrics.minTouch)
                .accessibilityIdentifier("permissionsSkip")
        }
    }

    private func reason(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.token(.accent))
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.token(.textPrimary))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.token(.textSecondary))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
