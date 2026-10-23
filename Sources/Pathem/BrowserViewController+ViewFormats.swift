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

    func synchronizeViewDefaults() {
        saveFolderFormats()
        synchronizeDefaultViewPreferences()
        applyPreferences()
    }

    func rememberSubtreeView(_ url: URL, _ format: ViewFormat) {
        folderFormats.clearRulesUnder(url.path)
        folderFormats.setSubtree(url.path, format)
        saveFolderFormats()
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
        if settingsPanel != nil { settings.synchronizeDefaultFormat(format, shared: prefs) }
    }

    /// Both default-setting entry points leave shared Settings as the authority.
    func setDefaultViewFormat(_ format: ViewFormat) {
        folderFormats.defaultFormat = format
        prefs.fontSize = format.options.fontSize ?? prefs.fontSize
        prefs.dateDisplay = format.options.dateDisplay ?? prefs.dateDisplay
        prefs.iconZoom = format.options.iconScale ?? prefs.iconZoom
        prefs.calculateFolderSizes =
            format.options.calculateFolderSizes ?? prefs.calculateFolderSizes
        folderFormats.defaultFormat.options.fontSize = nil
        folderFormats.defaultFormat.options.dateDisplay = nil
        folderFormats.defaultFormat.options.iconScale = nil
        folderFormats.defaultFormat.options.calculateFolderSizes = nil
        saveConfig(prefs, to: Self.preferencesURL)
        synchronizeViewDefaults()
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
        setDefaultViewFormat(pane.format)
        leftTabs.activePane?.reloadIfShowingListing()
        rightTabs.activePane?.reloadIfShowingListing()
    }

    /// Apply the active pane's current view to its whole subtree, then refresh
    /// both panes so any visible descendants pick up the new format. Descendant
    /// rules are cleared first, otherwise they would shadow the new subtree
    /// rule and silently keep their old view.
    func applyViewToSubfolders() {
        guard let pane = activePane else { return }
        rememberSubtreeView(pane.viewOptionsURL, pane.format)
        leftTabs.activePane?.reloadIfShowingListing()
        rightTabs.activePane?.reloadIfShowingListing()
    }
}
