import AppKit

/// Tracks every open browser window so File ▸ New Window can spawn independent windows and the
/// app can wind them all down cleanly on quit. The first window is *primary*: it alone restores
/// and saves the persisted session, so additional windows can never clobber its tabs. A shared
/// tabbing identifier lets macOS merge Pathem windows and drag a tab out into its own window
/// natively (the OS adds "Merge All Windows" / "Move Tab to New Window" to the Window menu).
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    /// Retains a window together with its browser and acts as the window's delegate so a close
    /// tears down that window's embedded shell (and persists the primary session).
    private final class Host: NSObject, NSWindowDelegate {
        let window: NSWindow
        let browser: BrowserViewController
        init(window: NSWindow, browser: BrowserViewController) {
            self.window = window
            self.browser = browser
            super.init()
            window.delegate = self
        }
        func windowWillClose(_ notification: Notification) {
            WindowManager.shared.handleClose(self)
        }
    }

    private var hosts: [Host] = []
    /// Kept alive for the app's lifetime and shared with every window (Settings ▸ Updates).
    var updater: UpdaterController?

    static let tabbingIdentifier = "com.scarcrux.pathem.browserWindow"

    /// The session-owning window's browser (the first still open), used to save on quit.
    var primaryBrowser: BrowserViewController? { hosts.first?.browser }

    /// How many browser windows are currently open (used by the smoke check and menu gating).
    var windowCount: Int { hosts.count }

    /// Adopt the primary window built in `main()` so it joins tab-merging and teardown.
    func adoptPrimary(window: NSWindow, browser: BrowserViewController) {
        window.isReleasedWhenClosed = false  // Host owns the lifetime; the default extra release UAFs
        window.tabbingIdentifier = Self.tabbingIdentifier
        hosts.insert(Host(window: window, browser: browser), at: 0)
    }

    /// Open an independent browser window rooted at `start`. It neither restores nor persists the
    /// shared session, and cascades off the frontmost window so it doesn't cover it exactly.
    @discardableResult
    func openWindow(start: URL) -> BrowserViewController {
        let browser = BrowserViewController(start: start, persistsSession: false)
        browser.updater = updater
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // Host owns the lifetime; the default extra release UAFs on Cmd-W
        window.title = "Pathem"
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.contentViewController = browser
        window.contentMinSize = NSSize(width: 720, height: 420)
        window.setContentSize(NSSize(width: 1100, height: 700))
        if let front = NSApp.keyWindow ?? hosts.last?.window {
            window.cascadeTopLeft(from: NSPoint(x: front.frame.minX + 26, y: front.frame.maxY + 4))
        } else {
            window.center()
        }
        hosts.append(Host(window: window, browser: browser))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return browser
    }

    /// Terminate every window's embedded shell — called from applicationWillTerminate so no
    /// window leaves an orphaned login shell (and the job it launched) behind.
    func terminateAllTerminals() {
        for host in hosts { host.browser.terminateTerminal() }
    }

    /// Build a browser window for smoke/debug without ordering it on screen; returns the browser.
    /// Exercises the same construction path so a regression in it is caught headlessly.
    func debugMakeWindow(start: URL) -> BrowserViewController {
        let browser = BrowserViewController(start: start, persistsSession: false)
        return browser
    }

    private func handleClose(_ host: Host) {
        host.browser.saveSessionNow()  // a no-op unless this is the primary (session-owning) window
        host.browser.terminateTerminal()  // don't orphan the window's embedded shell
        host.browser.teardown()  // stop each pane's watcher, the device timer, and observers
        hosts.removeAll { $0 === host }
    }
}
