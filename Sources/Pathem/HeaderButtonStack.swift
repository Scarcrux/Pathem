import AppKit

/// The pane header row: a horizontal stack whose buttons the user can reorder by Cmd-dragging
/// them, the same gesture the window toolbar uses for its own items. A plain click still goes
/// to the button; only a click with Cmd held is captured here (hitTest) and tracked as a
/// reorder. Hidden (show/hide-customized) buttons are skipped while computing positions.
@MainActor
final class HeaderButtonStack: NSStackView {
    /// Fired when a reorder drag ends, with the arranged views in their new order.
    var onReorderEnded: (([NSView]) -> Void)?

    private var dragging: NSView?
    private var didMove = false

    private var visibleArranged: [NSView] { arrangedSubviews.filter { !$0.isHidden } }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Capture Cmd-clicks that land on one of our buttons so the reorder can track them.
        guard NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return visibleArranged.contains { $0.frame.contains(local) } ? self : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.mouseDown(with: event) }
        let local = convert(event.locationInWindow, from: nil)
        dragging = visibleArranged.first { $0.frame.contains(local) }
        didMove = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return super.mouseDragged(with: event) }
        let x = convert(event.locationInWindow, from: nil).x
        let order = visibleArranged
        guard let from = order.firstIndex(of: dragging) else { return }
        // Move past a neighbor once the pointer crosses that neighbor's midpoint.
        var to = from
        if from > 0, x < order[from - 1].frame.midX { to = from - 1 }
        if from < order.count - 1, x > order[from + 1].frame.midX { to = from + 1 }
        guard to != from else { return }
        let target = order[to]
        guard let targetIndex = arrangedSubviews.firstIndex(of: target) else { return }
        removeArrangedSubview(dragging)  // stays a subview; only the arrangement changes
        insertArrangedSubview(dragging, at: targetIndex)
        didMove = true
        layoutSubtreeIfNeeded()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragging = nil }
        guard dragging != nil else { return super.mouseUp(with: event) }
        if didMove { onReorderEnded?(arrangedSubviews) }
    }

    /// Programmatic reorder to a given arrangement (pref apply); keeps every view a subview.
    func arrange(_ views: [NSView]) {
        for view in arrangedSubviews { removeArrangedSubview(view) }
        for view in views { addArrangedSubview(view) }
    }
}
