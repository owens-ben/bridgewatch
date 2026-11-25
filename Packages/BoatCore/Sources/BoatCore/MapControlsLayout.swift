import Foundation

/// Where the map's buttons go (docs/DESIGN.md, Map buttons). The top trailing corner, unless the system draws a
/// column down the screen's trailing side (the iPhone Duo's status column: time, Wi-Fi and the ring that opens
/// Control Center, folded and unfolded), which shows as a trailing safe-area inset wider than the leading one: then
/// the top leading corner, well away from it. A phone in landscape has equal insets on both sides and keeps the
/// trailing corner.
public enum MapControlsLayout {
    /// A trailing inset at least this much wider than the leading one is a system column, points.
    public static let sideColumnMinimum = 20.0

    public static func hasTrailingSystemColumn(leadingInset: Double, trailingInset: Double) -> Bool {
        let leading = leadingInset.isFinite ? max(0, leadingInset) : 0
        let trailing = trailingInset.isFinite ? max(0, trailingInset) : 0
        return trailing - leading >= sideColumnMinimum
    }

    /// True for the top leading corner.
    public static func buttonsOnLeadingSide(windowLeadingInset: Double, windowTrailingInset: Double) -> Bool {
        hasTrailingSystemColumn(leadingInset: windowLeadingInset, trailingInset: windowTrailingInset)
    }
}
