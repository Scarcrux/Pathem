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

    /// Smallest pane extent in points when the panes are stacked, so neither can be dragged
    /// (or resized) down to a sliver that hides its header and a few rows.
    static let minStackedExtent: CGFloat = 120

    /// Whether the panes sit top and bottom (a horizontal divider) instead of side by side.
    private func isStacked(_ splitView: NSSplitView) -> Bool { !splitView.isVertical }

    /// The pane-axis length: height when stacked, width when side by side.
    private func axisLength(_ splitView: NSSplitView) -> CGFloat {
        isStacked(splitView) ? splitView.bounds.height : splitView.bounds.width
    }

    /// The allowed range for the second pane's share. Side by side keeps 15 percent either
    /// way; stacked also keeps `minStackedExtent` points, but never more than half.
    func bounds(forTotal total: CGFloat, stacked: Bool) -> ClosedRange<Double> {
        var low = 0.15
        if stacked, total > 1 { low = min(0.5, max(low, Double(Self.minStackedExtent / total))) }
        return low...(1 - low)
    }

    /// Frame both panes at the current ratio. Safe to call directly to re-apply after a
    /// fraction change (the split's bounds haven't changed, so it won't relayout on its own).
    /// Side by side the first pane is on the left; stacked it is on top (the split is flipped).
    func layout(_ splitView: NSSplitView) {
        let subviews = splitView.arrangedSubviews
        guard subviews.count == 2 else {
            splitView.adjustSubviews()
            return
        }
        let divider = splitView.dividerThickness
        let stacked = isStacked(splitView)
        let total = axisLength(splitView)
        guard total > 1 else { return }
        let range = bounds(forTotal: total, stacked: stacked)
        let clamped = max(range.lowerBound, min(range.upperBound, fraction))
        let second = (total - divider) * clamped
        let first = total - divider - second
        if stacked {
            let width = splitView.bounds.width
            subviews[0].frame = NSRect(x: 0, y: 0, width: width, height: first)
            subviews[1].frame = NSRect(x: 0, y: first + divider, width: width, height: second)
        } else {
            let height = splitView.bounds.height
            subviews[0].frame = NSRect(x: 0, y: 0, width: first, height: height)
            subviews[1].frame = NSRect(x: first + divider, y: 0, width: second, height: height)
        }
    }

    /// Track the user dragging the divider: adopt the new ratio so it sticks (and clamp so
    /// neither pane can be dragged away to nothing).
    func splitView(
        _ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let divider = splitView.dividerThickness
        let total = axisLength(splitView)
        guard total > 1 else { return proposedPosition }
        let range = bounds(forTotal: total, stacked: isStacked(splitView))
        let clampedFirst = max(
            total * range.lowerBound, min(total * range.upperBound, proposedPosition))
        fraction = (total - divider - clampedFirst) / total
        return clampedFirst
    }
}
