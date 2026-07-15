import AppKit
import PathemEngine

// Spotlight-backed smart locations (Recents, tag filters, saved smart folders): run the
// query off-main and show the cross-folder results in the active pane. Split out of
// BrowserViewController to keep that file focused.
extension BrowserViewController {
    /// Run a Spotlight-backed smart query (Recents / a tag filter) and show the results.
    func openSmart(_ query: SmartQuery) {
        guard let pane = activePane else { return }
        let scope = FileManager.default.homeDirectoryForCurrentUser
        let token = pane.beginContentRequest()  // detect navigation / a newer request
        Task {
            let urls: [URL]
            let title: String
            switch query {
            case .recents:
                urls = await SpotlightSearch.recentFiles(scope: scope, days: 30, limit: 200)
                title = L("bvc.recents", "Recents")
            case .tag(let color):
                urls = await SpotlightSearch.taggedFiles(color.label, scope: scope, limit: 500)
                title = String(format: L("bvc.tagTitle", "Tag: %@"), color.label)
            case .namedTag(let name):
                urls = await SpotlightSearch.taggedFiles(name, scope: scope, limit: 500)
                title = String(format: L("bvc.tagTitle", "Tag: %@"), name)
            }
            let entries = await Task.detached { urls.map { FileEntry(contentsOf: $0) } }.value
            guard self.activePane === pane, pane.isContentRequestCurrent(token) else { return }  // stale
            await self.presentSmartResults(entries, title: title, pane: pane, token: token)
        }
    }

    /// Run a saved smart folder's mdfind query and show its results in the active pane.
    func runSavedSearch(_ name: String, query: String) {
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        let token = pane.beginContentRequest()
        pane.showSmartResults([], title: String(format: L("bvc.searchingLoading", "Searching: %@…"), name))
        Task { @MainActor in
            let urls = await SpotlightSearch.matching(query, scope: nil, limit: 1000)
            let entries = await Task.detached { urls.map { FileEntry(contentsOf: $0) } }.value
            guard self.activePane === pane, pane.isContentRequestCurrent(token) else { return }
            let title = String(format: L("bvc.searchCount", "Search: %@ (%d)"), name, entries.count)
            await self.presentSmartResults(entries, title: title, pane: pane, token: token)
        }
    }

    /// Show smart-search results. When they're empty because Spotlight indexing is off (not
    /// because there are no matches), show a clear message instead of a silent empty pane --
    /// smart folders and search all rely on `mdfind`.
    func presentSmartResults(
        _ entries: [FileEntry], title: String, pane: PaneController, token: Int
    ) async {
        if entries.isEmpty {
            let indexed = await SpotlightSearch.indexingEnabled()
            guard activePane === pane, pane.isContentRequestCurrent(token) else { return }
            if !indexed {
                pane.showSmartResults(
                    [],
                    title: L(
                        "bvc.spotlightOff",
                        // The data volume, NOT "/": on modern macOS "/" is the sealed system volume
                        // and is always indexed, so "mdutil -i on /" would appear to succeed and
                        // change nothing. The user's files live on the Data volume.
                        "Spotlight indexing is off for your files. Smart folders and search need it. "
                            + "In Terminal: sudo mdutil -i on /System/Volumes/Data"))
                return
            }
        }
        pane.showSmartResults(entries, title: title)
    }
}
