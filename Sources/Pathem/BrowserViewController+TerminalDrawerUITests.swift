#if DEBUG
import AppKit

/// Showing the terminal drawer must leave both the browser and the terminal visible.
/// Found while staging a website screenshot: on macOS 27.2.1 the toggle left both halves of
/// the vertical split at zero height, a blank window.
extension BrowserViewController {
    func checkTerminalDrawer(check: (String, Bool) -> Void, settle: (() -> Bool) -> Bool) {
        view.layoutSubtreeIfNeeded()
        let full = outerSplit.frame.height
        check("terminal-drawer-control-browser-fills-window", terminal.view.isHidden && full > 300)
        toggleTerminal()
        let shown = settle {
            self.view.layoutSubtreeIfNeeded()
            return self.outerSplit.frame.height >= 160 && self.terminal.view.frame.height >= 120
        }
        check("terminal-drawer-show-keeps-browser-and-terminal", shown)
        print(
            "TERMINALDRAWER shown browser=\(Int(outerSplit.frame.height)) terminal=\(Int(terminal.view.frame.height)) of \(Int(vSplit.frame.height))"
        )
        toggleTerminal()
        check(
            "terminal-drawer-hide-returns-space",
            settle {
                self.view.layoutSubtreeIfNeeded()
                return self.terminal.view.isHidden && self.outerSplit.frame.height >= full - 2
            })
        terminateTerminal()
    }
}
#endif
