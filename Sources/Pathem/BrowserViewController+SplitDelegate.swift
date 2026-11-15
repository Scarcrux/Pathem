import AppKit

/// Owns the browser's nested split views, divider policy, and pane-ratio state.
@MainActor
final class BrowserSplitLayoutController: NSObject, NSSplitViewDelegate {
    let split = NSSplitView()  // the two sides
    let panesContainer = NSView()  // wraps `split` so torrent detail can overlay it
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
    func setRightPaneFraction(_ fraction: Double) {
        paneRatioDelegate.fraction = max(0.15, min(0.85, fraction))
        paneRatioDelegate.layout(split)
        if let left = split.arrangedSubviews.first {
            split.setPosition(left.frame.width, ofDividerAt: 0)
        }
        split.needsDisplay = true
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
