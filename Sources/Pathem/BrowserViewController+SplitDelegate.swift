import AppKit

/// Owns the browser's nested split views, divider policy, and pane-ratio state.
@MainActor
final class BrowserSplitLayoutController: NSObject, NSSplitViewDelegate {
    let split = NSSplitView()  // the two sides
    /// Split views size their arranged subviews by frame, and a frame-managed view carries
    /// that frame as required width/height constraints. Starting each at a nominal size
    /// instead of zero keeps the first layout pass satisfiable; the split replaces it.
    static let placeholderFrame = NSRect(x: 0, y: 0, width: 400, height: 400)
    /// The same for the window's content view, which starts at the default window size.
    static let initialHostFrame = NSRect(x: 0, y: 0, width: 1100, height: 700)

    let panesContainer = NSView(frame: placeholderFrame)  // wraps `split` so torrent detail can overlay it
    let outerSplit = NSSplitView()  // sidebar | panes
    let vSplit = NSSplitView()  // browser (top) | terminal (bottom)
    let mainStack = NSStackView()  // vSplit (top) + torrents drawer (bottom dock)

    private let paneRatioDelegate = PaneRatioSplitDelegate()
    private(set) var sidebarWidthConstraint: NSLayoutConstraint?
    var didSetInitialSplit = false
    var compactSidebar = false
    /// The sidebar's width outside compact mode, remembered so leaving compact mode returns
    /// to what the user had, not to the default.
    var expandedSidebarWidth: CGFloat = 200

    static let compactSidebarWidth: CGFloat = 60

    func configure(
        left: NSView, right: NSView, sidebar: NSView, terminal: NSView
    ) {
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = paneRatioDelegate
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        split.translatesAutoresizingMaskIntoConstraints = false
        panesContainer.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: panesContainer.topAnchor),
            split.leadingAnchor.constraint(equalTo: panesContainer.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: panesContainer.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: panesContainer.bottomAnchor),
        ])

        outerSplit.isVertical = true
        outerSplit.dividerStyle = .thin
        outerSplit.delegate = self
        outerSplit.translatesAutoresizingMaskIntoConstraints = false
        outerSplit.addArrangedSubview(sidebar)
        outerSplit.addArrangedSubview(panesContainer)
        outerSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        let width = sidebar.widthAnchor.constraint(equalToConstant: 200)
        width.priority = NSLayoutConstraint.Priority(260)
        width.isActive = true
        sidebarWidthConstraint = width

        vSplit.isVertical = false
        vSplit.dividerStyle = .thin
        vSplit.translatesAutoresizingMaskIntoConstraints = false
        vSplit.addArrangedSubview(outerSplit)
        vSplit.addArrangedSubview(terminal)
        vSplit.delegate = self
        vSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 1)
        terminal.isHidden = true
    }

    /// Set the panes' divider to `fraction` (the right pane's share) and lay them out now.
    /// The second pane (right, or bottom when stacked) gets this share.
    func setRightPaneFraction(_ fraction: Double) {
        paneRatioDelegate.fraction = max(0.15, min(0.85, fraction))
        relayoutPanes()
    }

    private func relayoutPanes() {
        paneRatioDelegate.layout(split)
        if let first = split.arrangedSubviews.first {
            split.setPosition(isStacked ? first.frame.height : first.frame.width, ofDividerAt: 0)
        }
        split.needsDisplay = true
    }

    /// Whether the file panes are stacked top and bottom.
    var isStacked: Bool { !split.isVertical }

    /// Switch the panes between side by side and stacked. The divider fraction carries over:
    /// the second pane keeps its share along the new axis.
    func setStacked(_ stacked: Bool) {
        guard stacked != isStacked else { return }
        split.isVertical = !stacked
        relayoutPanes()
    }

    /// The first (left or top) pane's share of the split along its axis, for saved Layouts.
    var firstPaneShare: Double {
        let total = isStacked ? split.bounds.height : split.bounds.width
        guard total > 0, let first = split.arrangedSubviews.first else { return 0.5 }
        return Double((isStacked ? first.frame.height : first.frame.width) / total)
    }

    var ownsSplitDelegates: Bool {
        split.delegate === paneRatioDelegate && outerSplit.delegate === self
            && vSplit.delegate === self
    }

    // Constrain the sidebar width (outer split) and the terminal drawer height
    // (vertical split) so neither the sidebar, the panes, nor the terminal can be
    // dragged away to nothing.
    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        // Compact mode lets the sidebar shrink to an icons-only width.
        if splitView === outerSplit, dividerIndex == 0 { return compactSidebar ? 52 : 140 }
        if splitView === vSplit, dividerIndex == 0 { return 160 }  // min browser height
        return proposedMin
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        if splitView === outerSplit, dividerIndex == 0 { return 320 }  // max sidebar width
        if splitView === vSplit, dividerIndex == 0 { return splitView.bounds.height - 120 }  // min terminal height
        return proposedMax
    }
}
