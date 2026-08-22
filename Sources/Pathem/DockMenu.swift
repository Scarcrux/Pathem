import AppKit

// A Finder-style Dock menu (right-click the Dock icon): New Window, New Tab, and a live list of
// every open tab across all windows, above the standard items macOS appends (open windows,
// Options, Show All Windows, Quit). Without this the Dock menu shows only those defaults.
extension PathemAppDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        addItem(menu, L("dock.newWindow", "New Window"), #selector(dockNewWindow))
        addItem(menu, L("dock.newTab", "New Tab"), #selector(dockNewTab))

        // List every open tab (both panes, all windows), titled by its folder, so a tab is one
        // click away even though Pathem's tabs live inside a window (the OS only lists windows).
        var addedHeader = false
        for browser in WindowManager.shared.browsers {
            for tab in browser.dockTabList() {
                if !addedHeader {
                    menu.addItem(.separator())
                    let header = menu.addItem(
                        withTitle: L("dock.openTabs", "Open Tabs"), action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    addedHeader = true
                }
                let item = menu.addItem(
                    withTitle: tab.title, action: #selector(dockActivateTab(_:)), keyEquivalent: "")
                item.target = self
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                item.representedObject = DockTabRef(browser: browser, left: tab.left, index: tab.index)
            }
        }

        // Recent Folders: jump straight to a recently-visited folder (opens in a new tab), the way
        // Finder's Dock menu surfaces recent items. Pulled from the front window's history, so the
        // Dock menu is a real launcher, not just window/tab management.
        let recents = WindowManager.shared.frontBrowser?.dockRecentFolders() ?? []
        if !recents.isEmpty {
            menu.addItem(.separator())
            let header = menu.addItem(
                withTitle: L("dock.recentFolders", "Recent Folders"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            for url in recents {
                let item = menu.addItem(
                    withTitle: url.lastPathComponent, action: #selector(dockOpenRecentFolder(_:)),
                    keyEquivalent: "")
                item.target = self
                item.toolTip = url.path
                item.representedObject = url
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
        }
        return menu
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) {
        menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
    }

    @objc fileprivate func dockNewWindow() {
        WindowManager.shared.openWindow(start: FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc fileprivate func dockNewTab() {
        WindowManager.shared.frontBrowser?.dockOpenNewTab()
    }

    @objc fileprivate func dockActivateTab(_ sender: NSMenuItem) {
        (sender.representedObject as? DockTabRef)?.activate()
    }

    @objc fileprivate func dockOpenRecentFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        WindowManager.shared.frontBrowser?.dockOpenFolder(url)
    }
}

/// A menu item's handle back to a specific tab, held weakly so a closed window's tab can't keep
/// the browser alive or crash when picked after the window is gone.
@MainActor
private final class DockTabRef {
    weak var browser: BrowserViewController?
    let left: Bool
    let index: Int
    init(browser: BrowserViewController, left: Bool, index: Int) {
        self.browser = browser
        self.left = left
        self.index = index
    }
    func activate() { browser?.dockActivateTab(left: left, index: index) }
}

extension BrowserViewController {
    /// Every open tab (both panes), titled by its folder, for the Dock menu.
    func dockTabList() -> [(title: String, left: Bool, index: Int)] {
        var out: [(title: String, left: Bool, index: Int)] = []
        for (index, pane) in leftTabs.tabs.enumerated() {
            out.append((TabbedPaneController.title(for: pane.currentURL), true, index))
        }
        for (index, pane) in rightTabs.tabs.enumerated() {
            out.append((TabbedPaneController.title(for: pane.currentURL), false, index))
        }
        return out
    }

    /// Bring this window forward and select the given tab (Dock menu).
    func dockActivateTab(left: Bool, index: Int) {
        let side = left ? leftTabs : rightTabs
        guard side.tabs.indices.contains(index) else { return }
        side.selectTab(index)
        view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open a new tab on the active side and bring the window forward (Dock menu New Tab).
    func dockOpenNewTab() {
        (activeSide ?? leftTabs).newTab(duplicatingCurrent: true)
        view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The most recent folders (capped for the menu), for the Dock menu's Recent Folders section.
    func dockRecentFolders() -> [URL] { Array(recentFolders.prefix(10)) }

    /// Open `url` in a new tab on the active side and bring the window forward (Dock menu).
    func dockOpenFolder(_ url: URL) {
        (activeSide ?? leftTabs).openTab(at: url)
        view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
