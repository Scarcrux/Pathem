import AppKit

// The demo workspace as a first-run tour. DemoWorkspace.build() (also used for marketing
// screenshots) writes a real, safe sample tree to a temp folder -- dual-pane Projects/Photos,
// tags, git-ish files, real thumbnails -- so a stranger's first launch can show what Pathem does
// instead of their bare home folder behind the Full Disk Access nag.
@MainActor
extension BrowserViewController {
    /// Build the demo workspace and open it in both panes (Projects on the left, Photos on the
    /// right, so the gallery + tags are visible straight away).
    func loadDemoWorkspace() {
        let layout = DemoWorkspace.build()
        FolderSizeSkipSettings.demoRoot = layout.root.path
        view.window?.makeKeyAndOrderFront(nil)
        leftTabs.activePane?.navigate(to: layout.leftStart)
        rightTabs.activePane?.navigate(to: layout.rightStart)
        activePane?.flashStatus(
            L("demo.loaded", "Loaded the demo workspace. Your real files are untouched."))
    }

    /// Offer the demo once, on first run, but only after Full Disk Access is granted so it never
    /// stacks on the FDA guide (and a user who grants access later still gets the offer). Declining
    /// still counts as offered, so it never nags twice.
    func maybeOfferDemoWorkspace() {
        guard !UserDefaults.standard.bool(forKey: Self.demoOfferedKey) else { return }
        guard FullDiskAccess.isGranted(), let window = view.window else { return }
        UserDefaults.standard.set(true, forKey: Self.demoOfferedKey)

        let alert = NSAlert()
        alert.messageText = L("demo.offerTitle", "New to Pathem?")
        alert.informativeText = L(
            "demo.offerBody",
            "Load a demo workspace to explore the dual panes, tags, and views with safe sample files. Nothing touches your real files."
        )
        alert.addButton(withTitle: L("demo.offerLoad", "Load Demo"))
        alert.addButton(withTitle: L("demo.offerSkip", "Not Now"))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.loadDemoWorkspace() }
        }
    }

    static let demoOfferedKey = "pathem.demoOffered"
}
