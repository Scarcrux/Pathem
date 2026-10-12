import AppKit
import PathemEngine

// Per-folder view formats: remember each folder's view mode/sort, set the default, and
// apply a view to a subtree. Split out of BrowserViewController.
extension BrowserViewController {
    // MARK: - Per-folder view formats

    private static var folderFormatsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("formats.json")
    }

    func loadFolderFormats() {
        if let saved = loadConfig(FolderFormats.self, from: Self.folderFormatsURL) {
            folderFormats = saved
            // Preserve the effective saved view, not stale UI defaults from the other store.
            synchronizeDefaultViewPreferences()
        } else {
            folderFormats.defaultFormat.viewMode = prefs.defaultViewMode
            folderFormats.defaultFormat.sortKey = prefs.defaultSortKey
            folderFormats.defaultFormat.ascending = prefs.defaultSortAscending
        }
    }

    private func saveFolderFormats() {
        saveConfig(folderFormats, to: Self.folderFormatsURL)
    }

    /// Settings edits only these three fields; grouping/hidden policy and rules stay intact.
    func applyDefaultViewPreferences() {
        let previous = folderFormats.defaultFormat
        folderFormats.defaultFormat.viewMode = prefs.defaultViewMode
        folderFormats.defaultFormat.sortKey = prefs.defaultSortKey
        folderFormats.defaultFormat.ascending = prefs.defaultSortAscending
        if folderFormats.defaultFormat != previous { saveFolderFormats() }
    }

    /// The menu command and startup reconciliation must also update the Settings model.
    private func synchronizeDefaultViewPreferences() {
        let format = folderFormats.defaultFormat
        let changed =
            prefs.defaultViewMode != format.viewMode
            || prefs.defaultSortKey != format.sortKey
            || prefs.defaultSortAscending != format.ascending
        prefs.defaultViewMode = format.viewMode
        prefs.defaultSortKey = format.sortKey
        prefs.defaultSortAscending = format.ascending
        if changed { saveConfig(prefs, to: Self.preferencesURL) }
        if settingsPanel != nil { settings.synchronizeDefaultFormat(format) }
    }

    /// Auto-remember: the active folder gets its own exact-path format.
    func rememberFormat(_ url: URL, _ format: ViewFormat) {
        folderFormats.setExact(url.path, format)
        saveFolderFormats()
    }

    /// Make the active pane's current view (mode + sort) the global default for
    /// folders that don't have their own remembered format.
    func useCurrentViewAsDefault() {
        guard let pane = activePane else { return }
        folderFormats.defaultFormat = pane.format
        saveFolderFormats()
        synchronizeDefaultViewPreferences()
        leftTabs.activePane?.reloadIfShowingListing()
        rightTabs.activePane?.reloadIfShowingListing()
    }

    /// Apply the active pane's current view to its whole subtree, then refresh
    /// both panes so any visible descendants pick up the new format. Descendant
    /// exact rules are cleared first, otherwise they would shadow the new subtree
    /// rule and silently keep their old view.
    func applyViewToSubfolders() {
        guard let pane = activePane else { return }
        folderFormats.clearExactRulesUnder(pane.currentURL.path)
        folderFormats.setSubtree(pane.currentURL.path, pane.format)
        saveFolderFormats()
        leftTabs.activePane?.reloadIfShowingListing()
        rightTabs.activePane?.reloadIfShowingListing()
    }
}
