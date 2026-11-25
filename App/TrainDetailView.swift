import BoatCore
import SwiftUI

/// A train's bullet, destination, route and level, then distance, speed, direction and the position's age, a note
/// that the position is an estimate, and "Find in Camera". Shown in a sheet (compact) or a floating card (regular),
/// like `VesselDetailView`.
struct TrainDetailView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let row: TrainRow
    let showsAge: Bool
    /// Switches to the camera with this train highlighted; nil hides the action.
    var findInCamera: (() -> Void)?
    /// Dismisses the details; nil hides the close button.
    var close: (() -> Void)?

    private var fades: Bool { !showsAge && row.freshness != .live }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            statGrid
                .fixedSize(horizontal: false, vertical: true)
                .staleFade(fades)

            Text("Positions are estimated from MTA's arrival predictions, so a train can be a few hundred feet off.")
                .font(.footnote)
                .foregroundStyle(.token(.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("trainEstimateNote")

            if let findInCamera {
                Button("Find in Camera", action: findInCamera)
                    .buttonStyle(.primary)
                    .disabled(row.bearingDegrees == nil)
                    .accessibilityHint(row.bearingDegrees == nil ? "Needs location" : "Shows this train in the camera view")
                    .accessibilityIdentifier("findInCamera")
                    .staleFade(fades)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trainDetail")
    }

    /// Bullet, destination, route and level beside the close button; at accessibility sizes the bullet and the close
    /// button share a row and the text runs full width below them, like the vessel details.
    @ViewBuilder private var header: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    RouteBullet(train: row.train, size: 44)
                        .staleFade(fades)
                    Spacer(minLength: 0)
                    if let close { CloseDetailsButton(action: close) }
                }
                nameBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("detailHeader")
                    .staleFade(fades)
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    RouteBullet(train: row.train, size: 44)
                    nameBlock
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("detailHeader")
                .staleFade(fades)
                if let close { CloseDetailsButton(action: close) }
            }
        }
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: row.title)
                .font(.title2.bold())
                .foregroundStyle(.token(.textPrimary))
                .accessibilityIdentifier("detailTitle")
            Text(row.routeName)
                .font(.subheadline)
                .foregroundStyle(.token(.textSecondary))
            Text(row.levelText)
                .font(.subheadline)
                .foregroundStyle(.token(.textSecondary))
                .monospacedDigit()
                .accessibilityIdentifier("trainLevel")
        }
    }

    @ViewBuilder private var statGrid: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 12) {
                distanceTile
                speedTile
                directionTile
                ageTile
            }
        } else {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    distanceTile
                    speedTile
                }
                GridRow {
                    directionTile
                    ageTile
                }
            }
        }
    }

    private var distanceTile: some View {
        StatTile(title: "Distance", value: row.distanceText ?? "—", caption: row.bearingText ?? "Location off")
    }

    private var speedTile: some View {
        StatTile(title: "Speed", value: row.speedText ?? "—", caption: nil)
    }

    private var directionTile: some View {
        StatTile(title: "Course", value: row.courseText ?? "—", caption: nil)
    }

    private var ageTile: some View {
        StatTile(title: "Last report", value: row.ageText, caption: nil)
    }
}
