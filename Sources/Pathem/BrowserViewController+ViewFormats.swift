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
        if let saved = loadConfig(FolderFormats.self, from: Self.folderFormatsURL) { folderFormats = saved }
    }

    private func saveFolderFormats() {
        saveConfig(folderFormats, to: Self.folderFormatsURL)
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
