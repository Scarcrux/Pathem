import AppKit
import PathemEngine

// Navigation, sync-browsing, and the window title: keeping the chrome (sidebar, title, terminal,
// mirrored pane) in step as folders change. Split out of BrowserViewController to shrink the
// god-object (5.1). Transfer/undo plumbing lives in BrowserViewController+Transfers.
extension BrowserViewController {
    /// Open the "find files everywhere" palette; revealing a result navigates the active pane to
    /// its folder and selects it.
    func showGlobalSearch() {
        showFileSearch(everywhere: true)
    }

    func showFileSearch(everywhere: Bool = false, mode: GlobalSearchController.Mode = .filename) {
        guard let window = view.window else { return }
        let folder = activePane.map { !$0.isRemote ? $0.currentURL : nil } ?? nil
        globalSearchController.present(
            over: window, currentFolder: folder ?? FileManager.default.homeDirectoryForCurrentUser,
            everywhere: everywhere, mode: mode,
            folderIsLocal: !(activePane?.isRemote ?? false),
            onReveal: { [weak pane = activePane] url in pane?.reveal(url) },
            onOpen: { [weak self] url in self?.applyOpen(url) })
    }

    /// A pane's folder changed (navigation or on-disk edit): drop a stale semantic
    /// index for it and keep the chrome (sidebar, title, terminal) in step.
    func directoryChanged(_ pane: PaneController, _ url: URL) {
        // A disk edit to a folder we've already indexed makes the index stale, so drop it; the
        // next search rebuilds it. We don't eagerly (re)index on navigation: reading and embedding
        // up to 5000 files' content on every folder visit costs seconds of CPU + disk for a search
        // the user usually never runs. Indexing now happens lazily on first search (rank ->
        // ensureIndex), so opening a folder stays cheap.
        if semanticSearch.cachedDirectory == url { semanticSearch.invalidate() }
        if pane === activePane {
            // Keep the sidebar tracking the current folder, like Finder; a smart listing (Network,
            // search results) is not that folder, so nothing stays highlighted for it.
            sidebar.highlightFolder(pane.smartListingTitle == nil ? url : nil)
            updateWindowTitle()
            // The terminal follows the active folder only when the user opted in
            // and the drawer is open (changeDirectory itself ignores TUIs).
            if terminalFollows, !terminal.view.isHidden { terminal.changeDirectory(to: url) }
            mirrorNavigationIfSyncing(to: url)
            followPairedFolderIfNeeded(pane: pane, url: url)
        }
        saveSessionSoon()
    }

    /// Where a new tab should open per the "New tab opens to" preference: nil = the current
    /// folder (browser-style), else Home or the configured fixed folder (if it exists).
    func preferredNewTabFolder() -> URL? {
        switch prefs.newTabLocation {
        case .lastFolder: return nil
        case .home: return FileManager.default.homeDirectoryForCurrentUser
        case .fixed:
            let path = prefs.fixedStartFolder
            var isDir: ObjCBool = false
            guard !path.isEmpty,
                FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
            else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    /// A breadcrumb ancestor's right-click action: open that folder into a pane or a new tab,
    /// or copy its path.
    func handleBreadcrumbAction(_ folder: URL, _ action: BreadcrumbBar.Action) {
        switch action {
        case .newTab: activeSide?.openTab(at: folder)
        case .leftPane: leftTabs.activePane?.navigate(to: folder)
        case .rightPane: rightTabs.activePane?.navigate(to: folder)
        case .leftPaneNewTab: leftTabs.openTab(at: folder)
        case .rightPaneNewTab: rightTabs.openTab(at: folder)
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(folder.path, forType: .string)
        }
    }

    /// Sync browsing: replay the active pane's relative move on the other side's pane,
    /// so two different roots track together. Descending into a subfolder moves the
    /// other pane into its same-named subfolder (if it exists); rising moves both up.
    /// The other pane holds still when the mirrored folder doesn't exist.
    private func mirrorNavigationIfSyncing(to url: URL) {
        guard let active = activePane else { return }
        let here = url.standardizedFileURL
        let key = ObjectIdentifier(active)
        let previous = syncBrowseAnchors[key]
        syncBrowseAnchors[key] = here  // keep the driver's anchor current for the next hop

        guard syncBrowsing, !isSyncingPanes, !active.isRemote, let previous else { return }
        let other = activeSide === leftTabs ? rightTabs : leftTabs
        guard let otherPane = other.activePane, !otherPane.isRemote,
            !otherPane.isShowingSmartResults
        else { return }
        let otherHere = otherPane.currentURL.standardizedFileURL
        guard
            let targetPath = SyncBrowse.mirroredPath(
                driverFrom: previous.path, driverTo: here.path, otherAt: otherHere.path)
        else { return }
        let target = URL(fileURLWithPath: targetPath).standardizedFileURL
        guard target != otherHere else { return }  // already there
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir),
            isDir.boolValue
        else { return }  // no mirror folder over there: hold still
        isSyncingPanes = true
        syncBrowseAnchors[ObjectIdentifier(otherPane)] = target  // so its own callback won't mirror back
        otherPane.navigate(to: target)
        isSyncingPanes = false
    }

    /// The window title: folder name by default (like Finder), full POSIX path
    /// when the preference is on, or the server location for a remote pane. Also
    /// sets representedURL so the title gets a proxy icon and path popup.
    func updateWindowTitle() {
        syncFolderTree()
        updateCommanderPrompt()  // keep the commander prompt in sync with the active folder
        guard let window = view.window else { return }
        guard let pane = activePane else {
            window.title = "Pathem"
            window.representedURL = nil
            return
        }
        if let ctx = pane.remoteContext {
            window.representedURL = nil
            window.title = "\(ctx.connection.host)\(ctx.path)"
            return
        }
        if let smart = pane.smartListingTitle {
            window.representedURL = nil
            window.title = smart
            return
        }
        let url = pane.currentURL
        window.representedURL = url
        let name = url.lastPathComponent
        window.title = prefs.showFullPathInTitle ? url.path : (name.isEmpty ? url.path : name)
    }
}
