import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    /// Add a "Layouts" menu to the main menu, rebuilt on demand from the saved set.
    func installLayoutsMenu() {
        menuInstaller.installBrowserMenus(delegate: self)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === recentFoldersMenu {
            populateRecentFoldersMenu()
            return
        }
        if menu === externalCommandsMenu {
            populateExternalCommandsMenu()
            return
        }
        if menu === bookmarksMenu {
            populateBookmarksMenu()
            return
        }
        if menu === savedViewsMenu {
            menu.removeAllItems()
            let save = menu.addItem(
                withTitle: L("bvc.saveViewMenuItem", "Save Current View As…"),
                action: #selector(saveViewPreset), keyEquivalent: "")
            save.target = self
            guard !viewPresets.presets.isEmpty else { return }
            menu.addItem(.separator())
            for preset in viewPresets.presets {
                let item = menu.addItem(
                    withTitle: preset.name, action: #selector(applyViewPresetMenu(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = preset.name
            }
            return
        }
        guard menu === layoutsMenu else { return }
        menu.removeAllItems()
        let save = menu.addItem(
            withTitle: L("bvc.saveLayoutMenuItem", "Save Layout…"),
            action: #selector(saveLayoutMenu), keyEquivalent: "")
        save.target = self
        guard !layouts.names.isEmpty else { return }
        menu.addItem(.separator())
        for name in layouts.names {
            let item = menu.addItem(
                withTitle: name, action: #selector(applyLayoutMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
        }
    }

    /// The Bookmarks menu lists the current remote site's saved paths, plus a
    /// "Bookmark This Folder…" item. Off a remote pane it shows a single hint.
    private func populateBookmarksMenu() {
        bookmarksMenu.removeAllItems()
        let add = bookmarksMenu.addItem(
            withTitle: L("bvc.bookmarkThisFolder", "Bookmark This Folder…"),
            action: #selector(addBookmarkMenu), keyEquivalent: "")
        add.target = self
        guard let ctx = activePane?.remoteContext else {
            add.action = nil  // greyed out: nothing to bookmark off a local pane
            let hint = bookmarksMenu.addItem(
                withTitle: L("bvc.bookmarksHint", "Connect to a server to add bookmarks."),
                action: nil, keyEquivalent: "")
            hint.isEnabled = false
            return
        }
        // Read the live connection so a just-added bookmark shows immediately.
        let bookmarks =
            connectionsController.connections.first { $0.id == ctx.connection.id }?.bookmarks
            ?? ctx.connection.bookmarks
        guard !bookmarks.isEmpty else { return }
        bookmarksMenu.addItem(.separator())
        for bookmark in bookmarks {
            let item = bookmarksMenu.addItem(
                withTitle: bookmark.name, action: #selector(jumpBookmarkMenu(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = bookmark.remotePath
            item.toolTip = bookmark.remotePath
        }
    }

    @objc private func addBookmarkMenu() { addBookmark() }

    @objc private func jumpBookmarkMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        jumpToBookmark(RemoteBookmark(name: sender.title, remotePath: path))
    }

    // MARK: - Recent folders (Go menu)

    private static var recentFoldersURL: URL? {
        appSupportDirectory()?.appendingPathComponent("recent-folders.json")
    }
    func loadRecentFolders() {
        let paths = loadConfig([String].self, from: Self.recentFoldersURL) ?? []
        recentFolders = paths.map { URL(fileURLWithPath: $0) }
    }
    private func saveRecentFolders() {
        saveConfig(recentFolders.map(\.path), to: Self.recentFoldersURL)
    }
    /// Push a folder to the front of the recents (deduped, capped at 20).
    func recordRecentFolder(_ url: URL) {
        guard url.isFileURL else { return }
        let standardized = url.standardizedFileURL
        recentFolders.removeAll { $0.standardizedFileURL == standardized }
        recentFolders.insert(standardized, at: 0)
        if recentFolders.count > 20 { recentFolders = Array(recentFolders.prefix(20)) }
        saveRecentFolders()
    }

    /// Add "Recent Folders" to the existing Go menu (built in PathemApp before the browser
    /// exists, so it's wired here once the menu bar is up).
    func installRecentFoldersMenu() {
        menuInstaller.installRecentFoldersMenu(delegate: self)
    }

    private func populateRecentFoldersMenu() {
        recentFoldersMenu.removeAllItems()
        guard !recentFolders.isEmpty else {
            let none = recentFoldersMenu.addItem(
                withTitle: L("menu.noRecentFolders", "No Recent Folders"), action: nil,
                keyEquivalent: "")
            none.isEnabled = false
            return
        }
        for url in recentFolders {
            let item = recentFoldersMenu.addItem(
                withTitle: url.lastPathComponent, action: #selector(openRecentFolder(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        recentFoldersMenu.addItem(.separator())
        let clear = recentFoldersMenu.addItem(
            withTitle: L("menu.clearMenu", "Clear Menu"), action: #selector(clearRecentFolders),
            keyEquivalent: "")
        clear.target = self
    }

    @objc private func openRecentFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        activePane?.navigate(to: url)
    }
    @objc private func clearRecentFolders() {
        recentFolders = []
        saveRecentFolders()
    }

    @objc private func saveLayoutMenu() { saveLayoutPrompt() }

    @objc private func applyLayoutMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let layout = layouts.named(name)
        else { return }
        applyLayout(layout)
    }

    func saveLayoutPrompt() {
        let alert = NSAlert()
        alert.messageText = L("bvc.saveLayoutTitle", "Save Layout")
        alert.informativeText = L(
            "bvc.saveLayoutBody", "Name this arrangement of folders and panes.")
        alert.addButton(withTitle: L("common.save", "Save"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = String(
            format: L("bvc.layoutDefaultName", "Layout %d"), layouts.names.count + 1)
        alert.accessoryView = field
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            self.layouts.save(self.captureLayout(name: name))
            self.saveLayouts()
        }
    }

    private func captureLayout(name: String) -> Layout {
        Layout(
            name: name,
            leftPath: leftTabs.activePane?.currentURL.path ?? "",
            rightPath: rightTabs.activePane?.currentURL.path ?? "",
            dividerFraction: splitLayout.firstPaneShare,
            stackedPanes: splitLayout.isStacked)
    }

    private func applyLayout(_ layout: Layout) {
        // Skip paths that no longer resolve to a folder (hand-edited, shared from
        // another machine, or since deleted) so a pane is never dropped onto the
        // process working directory or a missing path.
        if let url = Self.existingFolderURL(layout.leftPath) {
            leftTabs.activePane?.navigate(to: url)
        }
        if let url = Self.existingFolderURL(layout.rightPath) {
            rightTabs.activePane?.navigate(to: url)
        }
        if prefs.stackPanesVertically != layout.stackedPanes {
            prefs.stackPanesVertically = layout.stackedPanes
            applyPreferences()  // reorients the panes and persists the preference
        }
        setRightPaneFraction(1 - layout.dividerFraction)  // saved fraction is the left pane's share
    }

    private static func existingFolderURL(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Place the sidebar and pane dividers once, when a real width exists.
    /// Crucially this sets the sidebar to a fixed width and lets the panes take
    /// the rest; without it the sidebar's auto-layout could swallow the whole
    /// window (the "all I see is the sidebar" bug). Runs from whichever of
    /// viewDidLayout / viewDidAppear first has a laid-out width.
    func applyInitialSplitPositions() {
        guard !didSetInitialSplit, outerSplit.bounds.width > 200 else { return }
        outerSplit.setPosition(compactSidebar ? Self.compactSidebarWidth : 200, ofDividerAt: 0)  // sidebar width
        outerSplit.layoutSubtreeIfNeeded()  // give the panes area its real width
        splitLayout.setStacked(prefs.stackPanesVertically)
        setRightPaneFraction(0.5)  // even panes
        didSetInitialSplit = true
        // Restore the terminal drawer if it was open last session -- but never on an automation
        // launch (smoke / screenshot / E2E), which must start from a clean, deterministic layout.
        // Otherwise a run that left the drawer open (e.g. one that was killed mid-check) makes every
        // later automation launch start with the terminal eating half the height, squishing the
        // panes -- exactly the "pane pushes up / squished" symptom in the invariant checks.
        if !PathemApp.isAutomationLaunch,
            UserDefaults.standard.bool(forKey: "pathem.terminalVisible")
        {
            toggleTerminal()
        }
    }
}
