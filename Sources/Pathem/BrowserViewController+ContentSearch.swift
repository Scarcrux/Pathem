import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    /// Search file contents under the active folder (grep/ripgrep), open a match.
    func showFindInFiles() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults, let window = view.window
        else { NSSound.beep(); return }
        let folder = pane.currentURL
        findInFiles.present(
            over: window, folderName: folder.lastPathComponent,
            search: { query, regex, caseSensitive in
                await ContentSearch.search(query, in: folder, regex: regex, caseSensitive: caseSensitive)
            },
            open: { [weak self] match in self?.applyOpen(URL(fileURLWithPath: match.path)) },
            replace: { query, replacement, regex, caseSensitive in
                await ContentSearch.replaceAll(
                    query, with: replacement, in: folder, regex: regex, caseSensitive: caseSensitive)
            })
    }

    /// Scan the active folder's subtree for content duplicates (off-main) and show
    /// them as one cross-folder list (per-group adjacency), so the extras can be
    /// selected and trashed.
    func findDuplicates() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let root = pane.currentURL
        let token = pane.beginContentRequest()  // so navigating away discards stale results
        pane.showSmartResults([], title: String(format: L("bvc.findingDuplicates", "Finding duplicates in %@…"), root.lastPathComponent))
        Task { @MainActor [weak self] in
            let groups = await Task.detached { DuplicateFinder.find(in: [root]) }.value
            guard let self, self.activePane === pane, pane.isContentRequestCurrent(token) else { return }
            let files = groups.flatMap { $0.files }
            let title =
                groups.isEmpty
                ? String(format: L("bvc.noDuplicates", "No duplicates in %@"), root.lastPathComponent)
                : "Duplicates: \(groups.count) group\(groups.count == 1 ? "" : "s"), \(files.count) files"
            pane.showSmartResults(files, title: title)
        }
    }

    /// Group files in the folder whose names are semantically similar (via the on-device
    /// embedder) and show them as smart results — the near-duplicate complement to Find
    /// Duplicates (which matches byte-identical content). Runs off the main thread.
    func findSimilarNames() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let root = pane.currentURL
        let entries = pane.entries
        let token = pane.beginContentRequest()
        pane.showSmartResults([], title: String(format: L("bvc.findingSimilar", "Finding similar names in %@…"), root.lastPathComponent))
        Task { @MainActor [weak self] in
            let groups = await Task.detached { SemanticDedup.similarGroups(entries) }.value
            guard let self, self.activePane === pane, pane.isContentRequestCurrent(token) else { return }
            let files = groups.flatMap { $0.files }
            let title =
                groups.isEmpty
                ? String(format: L("bvc.noSimilar", "No similar names in %@"), root.lastPathComponent)
                : "Similar names: \(groups.count) group\(groups.count == 1 ? "" : "s"), \(files.count) files"
            pane.showSmartResults(files, title: title)
        }
    }

    /// Flat / recursive view: list every item under the current folder, flattened into one
    /// location-aware smart-result view (each row carries its own subfolder). Runs off the main
    /// thread; navigating away discards it, like the other smart views.
    func flattenFolder() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let root = pane.currentURL
        let includingHidden = pane.showHiddenByDefault
        let token = pane.beginContentRequest()
        pane.showSmartResults([], title: String(format: L("bvc.flatteningLoading", "Listing everything in %@…"), root.lastPathComponent))
        Task { @MainActor [weak self] in
            let result = await Task.detached {
                FlatEnumerator.entries(of: root, includingHidden: includingHidden, includeFolders: true)
            }.value
            guard let self, self.activePane === pane, pane.isContentRequestCurrent(token) else { return }
            let count = result.entries.count
            let title =
                result.truncated
                ? String(format: L("bvc.flatCountTruncated", "All items in %@: %d+ (truncated)"), root.lastPathComponent, count)
                : String(format: L("bvc.flatCount", "All items in %@: %d"), root.lastPathComponent, count)
            pane.showSmartResults(result.entries, title: title)
        }
    }
}
