#if DEBUG
import AppKit

/// A sidebar width the user chose by dragging the divider must survive things that have
/// nothing to do with it: an unrelated preference change, and compact mode on then off
/// (layout-matrix finding LM2-F1b).
extension BrowserViewController {
    func checkSidebarWidthKept(check: (String, Bool) -> Void, settle: (() -> Bool) -> Bool) {
        func sidebarWidth() -> CGFloat { outerSplit.arrangedSubviews.first?.frame.width ?? 0 }
        func near(_ value: CGFloat, _ target: CGFloat) -> Bool { abs(value - target) <= 2 }
        view.layoutSubtreeIfNeeded()
        let wasCompact = prefs.compactSidebar
        if wasCompact { toggleCompactSidebar() }
        let original = sidebarWidth()
        defer {
            outerSplit.setPosition(original, ofDividerAt: 0)
            if prefs.compactSidebar != wasCompact { toggleCompactSidebar() }
        }
        outerSplit.setPosition(250, ofDividerAt: 0)  // what a drag of the divider does
        check("sidebar-width-control-drag-takes", settle { near(sidebarWidth(), 250) })

        applyPreferences()  // any unrelated setting change runs this
        _ = settle { false == self.view.needsLayout }
        check("sidebar-width-kept-across-preference-change", near(sidebarWidth(), 250))
        print("SIDEBARWIDTH after-preferences=\(Int(sidebarWidth()))")

        outerSplit.setPosition(250, ofDividerAt: 0)
        toggleCompactSidebar()
        let compacted = settle { near(sidebarWidth(), Self.compactSidebarWidth) }
        toggleCompactSidebar()
        _ = settle { sidebarWidth() > 100 }
        check("sidebar-width-compact-mode-engages", compacted)
        check("sidebar-width-kept-across-compact-toggle", near(sidebarWidth(), 250))
        print("SIDEBARWIDTH after-compact=\(Int(sidebarWidth()))")
    }
}
#endif
