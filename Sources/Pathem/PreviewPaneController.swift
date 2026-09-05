import AppKit
import PathemEngine

/// Owns the Quick Look preview pane docked at the far right of the window: its view,
/// visibility, the width pin that keeps it (and the panes) from collapsing, and the
/// "we auto-showed it" flag.
///
/// This is a god-object dissolution slice (5.6): the state moves out of
/// BrowserViewController instead of just the methods. The controller doesn't reach back
/// into the panes or the sidebar directly -- the host supplies the current selection URL
/// and the sidebar width via closures at init -- so it stays a self-contained view/state
/// cluster, the way DeviceWatcher (5.9) did.
@MainActor
final class PreviewPaneController {
    /// The preview view itself; the host still hands this to Quick Look drivers.
    let view = DocumentPreviewView()
    /// Whether the pane is currently docked.
    private(set) var isVisible = false
    /// Set by the host when it auto-shows the pane, so syncAuto() knows to take it back down.
    var autoShown = false

    private let outerSplit: NSSplitView
    private let selectedURL: () -> URL?
    private let sidebarWidth: () -> CGFloat
    private var widthConstraint: NSLayoutConstraint?

    /// - Parameters:
    ///   - outerSplit: the [sidebar | panes] split the preview appends itself to as a third pane.
    ///   - selectedURL: the active pane's single selected file (nil when not exactly one).
    ///   - sidebarWidth: the sidebar's pinned width, handed back to the panes when the preview closes.
    init(
        outerSplit: NSSplitView, selectedURL: @escaping () -> URL?,
        sidebarWidth: @escaping () -> CGFloat
    ) {
        self.outerSplit = outerSplit
        self.selectedURL = selectedURL
        self.sidebarWidth = sidebarWidth
    }

    /// Show/hide the preview pane docked at the right of the window.
    func toggle() {
        isVisible.toggle()
        if isVisible {
            // Auto-layout, like the sidebar and panes -- a TAMIC arranged subview in an
            // auto-layout NSSplitView breaks the split's width distribution and collapses
            // the panes to zero (blanking both panes).
            view.translatesAutoresizingMaskIntoConstraints = false
            outerSplit.addArrangedSubview(view)  // [sidebar | panes | preview]
            outerSplit.setHoldingPriority(NSLayoutConstraint.Priority(255), forSubviewAt: 2)
            // Durably pin the preview to a sane width so the panes always keep the rest. A
            // bare setPosition() is transient in an auto-layout split and lets the preview
            // (and the panes with it) collapse to zero; this constraint stays put and is
            // still draggable (its priority is below the divider-drag priority).
            let width = widthConstraint ?? view.widthAnchor.constraint(equalToConstant: 300)
            width.priority = NSLayoutConstraint.Priority(255)
            width.isActive = true
            widthConstraint = width
            // Seed the divider once so the split gives the preview its width now; the
            // constraint then holds it durably across resizes and view swaps.
            outerSplit.layoutSubtreeIfNeeded()
            outerSplit.setPosition(
                outerSplit.bounds.width - 300, ofDividerAt: outerSplit.arrangedSubviews.count - 2)
            update()
        } else {
            view.show(nil)
            widthConstraint?.isActive = false
            outerSplit.removeArrangedSubview(view)
            view.removeFromSuperview()
            // Hand the freed width back to the panes now: pin the sidebar|panes divider at the
            // sidebar width so the panes fill the rest (removeArrangedSubview leaves a stale
            // divider position otherwise, stranding the freed strip as dead space).
            outerSplit.layoutSubtreeIfNeeded()
            outerSplit.setPosition(sidebarWidth(), ofDividerAt: 0)
            outerSplit.layoutSubtreeIfNeeded()
        }
    }

    /// Point the preview at the active pane's single selected file (when visible).
    func update() {
        guard isVisible else { return }
        view.show(selectedURL())
    }

    /// Keep a manually-opened preview pane pointed at the current selection.
    ///
    /// Gallery and column both render their own inline preview now (gallery is a big Quick Look
    /// over a filmstrip; column draws a preview column), so auto-opening the SEPARATE preview pane
    /// just duplicated the selected file -- and because that pane docks at the far right of the
    /// window, a left-pane gallery's preview landed clear across the window, over the unrelated
    /// right pane (the reported bug). So nothing auto-opens the pane any more; if a prior state
    /// auto-showed it, take it down. A pane the user opened by hand still tracks the selection.
    func syncAuto() {
        if autoShown {
            if isVisible { toggle() }
            autoShown = false
        }
        update()
    }
}
