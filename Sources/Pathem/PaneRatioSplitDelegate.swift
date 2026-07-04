import AppKit

/// Lays out a two-pane vertical NSSplitView at a fixed ratio, taking over its sizing so a
/// content-light view (e.g. gallery, which wants almost no width) can't make the split
/// re-divide and shrink its pane. The panes use the frame model (TAMIC=true), where width
/// constraints are ignored; controlling the frames here is the reliable way to hold a ratio.
@MainActor
final class PaneRatioSplitDelegate: NSObject, NSSplitViewDelegate {
    /// The right pane's share of the split width (0.15...0.85).
    var fraction: Double = 0.5

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        layout(splitView)
    }

    /// Frame both panes at the current ratio. Safe to call directly to re-apply after a
    /// fraction change (the split's bounds haven't changed, so it won't relayout on its own).
    func layout(_ splitView: NSSplitView) {
        let subviews = splitView.arrangedSubviews
        guard subviews.count == 2 else { splitView.adjustSubviews(); return }
        let divider = splitView.dividerThickness
        let total = splitView.bounds.width
        let height = splitView.bounds.height
        guard total > 1 else { return }
        let clamped = max(0.15, min(0.85, fraction))
        let rightWidth = (total - divider) * clamped
        let leftWidth = total - divider - rightWidth
        subviews[0].frame = NSRect(x: 0, y: 0, width: leftWidth, height: height)
        subviews[1].frame = NSRect(x: leftWidth + divider, y: 0, width: rightWidth, height: height)
    }

    /// Track the user dragging the divider: adopt the new ratio so it sticks (and clamp so
    /// neither pane can be dragged away to nothing).
    func splitView(
        _ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let divider = splitView.dividerThickness
        let total = splitView.bounds.width
        guard total > 1 else { return proposedPosition }
        let minLeft = total * 0.15
        let maxLeft = total * 0.85
        let clampedLeft = max(minLeft, min(maxLeft, proposedPosition))
        fraction = (total - divider - clampedLeft) / total
        return clampedLeft
    }
}
