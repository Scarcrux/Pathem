import AppKit
import PathemEngine
import PathemTerminal

// Loading, saving, and restoring the browser's persisted state: the generic Codable config
// helpers, saved Layouts, the customized sidebar (plus the privacy-safe demo workspace), the
// terminal theme, and the window session. Split out of BrowserViewController.
@MainActor
extension BrowserViewController {
    /// Decode config from `url`. A missing file returns nil (use defaults). A
    /// present-but-undecodable file (corrupt, hand-edit typo, newer schema) is
    /// moved aside to <name>.corrupt and returns nil, so the next save cannot
    /// silently overwrite and destroy still-recoverable config.
    func loadConfig<T: Decodable>(_ type: T.Type, from url: URL?) -> T? {
        ConfigStore.load(type, from: url)
    }

    func saveConfig<T: Encodable>(_ value: T, to url: URL?) {
        ConfigStore.save(value, to: url)
    }

    // MARK: - Layouts

    private static var layoutsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("layouts.json")
    }

    func loadLayouts() {
        if let saved = loadConfig(Layouts.self, from: Self.layoutsURL) { layouts = saved }
    }

    func saveLayouts() {
        saveConfig(layouts, to: Self.layoutsURL)
    }

    // MARK: - Customizable sidebar

    private static var sidebarURL: URL? {
        appSupportDirectory()?.appendingPathComponent("sidebar.json")
    }

    /// Add Finder's own sidebar favorites to ours (the folders you already keep there), skipping any
    /// we already have. Reads Finder's LSSharedFileList file; nothing is removed, so running it
    /// twice is harmless.
    func importFinderFavorites() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let found = FinderFavorites.folders()
        guard !found.isEmpty else {
            presentInfo(
                L("sidebar.importNoneTitle", "No Finder favorites found"),
                L(
                    "sidebar.importNoneBody",
                    "Pathem couldn’t read Finder’s sidebar favorites, or none of them point at folders that still exist."
                ))
            return
        }
        var model = sidebar.model
        if model.groups.isEmpty {
            model.groups = [
                Sidebar.Group(title: L("sidebar.favoritesDefaultName", "Favorites"), items: [])
            ]
        }
        let existing = Set(
            model.groups.flatMap(\.items).map { ($0.path as NSString).standardizingPath })
        var added = 0
        for url in found {
            let path = (url.path as NSString).standardizingPath
            guard !existing.contains(path) else { continue }  // already in the sidebar: leave it alone
            model.groups[0].items.append(
                Sidebar.Item(
                    name: url.lastPathComponent, icon: Sidebar.suggestedIcon(for: url, home: home),
                    path: url.path))
            added += 1
        }
        guard added > 0 else {
            presentInfo(
                L("sidebar.importAllPresentTitle", "Nothing new to import"),
                L(
                    "sidebar.importAllPresentBody",
                    "Every Finder favorite is already in your sidebar."))
            return
        }
        sidebar.model = model  // rebuilds the sidebar; it does not persist on its own
        saveSidebar(model)
        presentInfo(
            String(format: L("sidebar.importedTitle", "Imported %d favorite(s)"), added),
            L(
                "sidebar.importedBody",
                "They were added to your Favorites. Drag to reorder or rename them."))
    }

    func loadSidebar() {
        if let demoLayout {  // fake favorites/cloud/volumes; no real accounts, hosts, or paths
            applyDemoSidebar(demoLayout)
            return
        }
        if let saved = loadConfig(Sidebar.self, from: Self.sidebarURL) {
            sidebar.model = saved
        } else {
            sidebar.model = .makeDefault(home: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    private func applyDemoSidebar(_ layout: DemoWorkspace.Layout) {
        sidebar.demoMode = true
        sidebar.demoCloud = layout.cloud
        sidebar.demoVolumes = layout.volumes
        sidebar.model = Sidebar(groups: [
            Sidebar.Group(
                title: L("sidebar.favoritesDefaultName", "Favorites"),
                items: layout.favorites.map {
                    Sidebar.Item(name: $0.name, icon: $0.icon, path: $0.url.path)
                })
        ])
        BreadcrumbBar.demoRoot = layout.root  // clean "Home ▸ …" path, hiding the temp prefix
    }

    var isDemoMode: Bool { demoLayout != nil }

    /// Toggle privacy-safe demo mode from the View menu, live (no relaunch).
    func toggleDemoMode() {
        if demoLayout == nil {
            savedRealSidebar = sidebar.model
            savedPaneFolders = (leftTabs.activePane?.currentURL, rightTabs.activePane?.currentURL)
            let layout = DemoWorkspace.build()
            demoLayout = layout
            applyDemoSidebar(layout)
            // resetHistory, not navigate: keep the throwaway temp path out of Back, and
            // don't leave the user's real folder reachable via Back during a privacy demo.
            leftTabs.activePane?.resetHistory(to: layout.leftStart)
            rightTabs.activePane?.resetHistory(to: layout.rightStart)
        } else {
            demoLayout = nil
            sidebar.demoMode = false
            sidebar.demoCloud = []
            sidebar.demoVolumes = []
            BreadcrumbBar.demoRoot = nil
            sidebar.model =
                savedRealSidebar
                ?? .makeDefault(home: FileManager.default.homeDirectoryForCurrentUser)
            // resetHistory so the (about-to-be-deleted) demo temp path can't be reached
            // via Back after we leave demo mode.
            if let url = savedPaneFolders?.left { leftTabs.activePane?.resetHistory(to: url) }
            if let url = savedPaneFolders?.right { rightTabs.activePane?.resetHistory(to: url) }
        }
    }

    func saveSidebar(_ model: Sidebar) {
        saveConfig(model, to: Self.sidebarURL)
    }

    // MARK: - Terminal theme

    static var terminalThemeURL: URL? {
        appSupportDirectory()?.appendingPathComponent("terminal.json")
    }

    func loadTerminalTheme() {
        if let saved = loadConfig(TerminalTheme.self, from: Self.terminalThemeURL) {
            terminal.theme = saved
        }
    }

    // MARK: - Window state (session, workspaces, styles)

    static var automationRulesURL: URL? {
        appSupportDirectory()?.appendingPathComponent("automation-rules.json")
    }

    /// Reopen the last session's tabs/folders, or open initial tabs if none.
    func restoreSession() {
        isRestoringSession = true
        defer { isRestoringSession = false }
        if demoLayout != nil {  // demo mode: fresh tabs on the fake workspace, never the real session
            // Open the tabs on the run loop, not synchronously in viewDidLoad (early navigation
            // deadlocks Launch Services); demo sessions are never persisted.
            DispatchQueue.main.async { [self] in
                leftTabs.openInitialTab()
                rightTabs.openInitialTab()
                if let pane = leftTabs.activePane { setActiveSide(leftTabs, pane: pane) }
            }
            return
        }
        if persistsSession, let session = windowState.loadSession(),
            !(session.left.isEmpty && session.right.isEmpty)
        {
            leftTabs.restoreTabs(
                session.left, active: session.leftActive, locked: session.leftLocked)
            rightTabs.restoreTabs(
                session.right, active: session.rightActive, locked: session.rightLocked)
            let side = session.leftIsActive ? leftTabs : rightTabs
            if let pane = (side.activePane ?? leftTabs.activePane) {
                setActiveSide(side.activePane != nil ? side : leftTabs, pane: pane)
            }
        } else {
            leftTabs.openInitialTab()
            rightTabs.openInitialTab()
            if let pane = leftTabs.activePane { setActiveSide(leftTabs, pane: pane) }
        }
    }

    /// Persist the session a moment after a change (coalesces navigation bursts).
    func saveSessionSoon() {
        guard persistsSession, !isRestoringSession else { return }
        windowState.scheduleSessionSave { [weak self] in self?.captureSession() }
    }

    /// Persist the session immediately (called on quit).
    func saveSessionNow() {
        guard persistsSession else { return }
        guard let state = captureSession() else { return }
        windowState.saveSession(state)
    }

    /// The current dual-pane, multi-tab layout as a Session, or nil in demo mode (which is
    /// never persisted over the real session).
    private func captureSession() -> WindowStateStore.Session? {
        guard demoLayout == nil else { return nil }
        return WindowStateStore.Session(
            left: leftTabs.tabFolders, leftActive: leftTabs.activeTabIndex,
            right: rightTabs.tabFolders, rightActive: rightTabs.activeTabIndex,
            leftIsActive: activeSide === leftTabs,
            leftLocked: leftTabs.tabLocks, rightLocked: rightTabs.tabLocks)
    }
}
