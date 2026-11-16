import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    /// Search file contents under the active folder (grep/ripgrep), open a match.
    func showFindInFiles() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            let window = view.window
        else {
            NSSound.beep()
            return
        }
        let folder = pane.currentURL
        findInFiles.present(
            over: window, folderName: folder.lastPathComponent,
            search: { query, regex, caseSensitive in
                await ContentSearch.searchOutcome(
                    query, in: folder, regex: regex, caseSensitive: caseSensitive)
            },
            open: { [weak self] match in self?.applyOpen(URL(fileURLWithPath: match.path)) },
            replace: { query, replacement, regex, caseSensitive in
                await ContentSearch.replaceAll(
                    query, with: replacement, in: folder, regex: regex, caseSensitive: caseSensitive
                )
            })
    }

    /// Scan the active folder's subtree for content duplicates (off-main) and show
    /// them as one cross-folder list (per-group adjacency), so the extras can be
    /// selected and trashed.
    func findDuplicates() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let root = pane.currentURL
        // Open the grouped resolver (keep one per set, trash the rest, with a reclaimable total)
        // rather than dumping a flat list of every duplicate file.
        duplicatesController.onTrash = { [weak self] urls in self?.performLocalTrash(urls) }
        duplicatesController.onReveal = { [weak self] url in
            self?.activePane?.navigate(to: url.deletingLastPathComponent())
            self?.activePane?.select(name: url.lastPathComponent)
        }
        duplicatesController.present(root: root, over: view.window)
    }

    /// Group files in the folder whose names are semantically similar (via the on-device
    /// embedder) and show them as smart results — the near-duplicate complement to Find
    /// Duplicates (which matches byte-identical content). Runs off the main thread.
    func findSimilarNames() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let root = pane.currentURL
        let entries = pane.entries
        let token = pane.beginContentRequest()
        pane.showSmartResults(
            [],
            title: String(
                format: L("bvc.findingSimilar", "Finding similar names in %@…"),
                root.lastPathComponent))
        Task { @MainActor [weak self] in
            let groups = await Task.detached { SemanticDedup.similarGroups(entries) }.value
            guard let self, self.activePane === pane, pane.isContentRequestCurrent(token) else {
                return
            }
            let files = groups.flatMap { $0.files }
            let title =
                groups.isEmpty
                ? String(
                    format: L("bvc.noSimilar", "No similar names in %@"), root.lastPathComponent)
                : "Similar names: \(groups.count) group\(groups.count == 1 ? "" : "s"), \(files.count) files"
            pane.showSmartResults(files, title: title)
        }
    }

    /// Find visually near-duplicate photos in the folder (bursts, near-identical shots), show the
    /// clusters, and offer to move all but the sharpest of each cluster to the Trash. Runs off-main.
    func cullNearDuplicatePhotos() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let root = pane.currentURL
        let entries = pane.entries
        let imageURLs =
            entries
            .filter { !$0.isDirectory && Self.isImageName($0.name) }
            .map { root.appendingPathComponent($0.name) }
        guard imageURLs.count >= 2 else {
            NSSound.beep()
            return
        }
        let token = pane.beginContentRequest()
        pane.showSmartResults(
            [],
            title: String(
                format: L("bvc.findingNearDup", "Finding near-duplicate photos in %@…"),
                root.lastPathComponent))
        Task { @MainActor [weak self] in
            let groups = await Task.detached { NearDuplicatePhotos.groups(of: imageURLs) }.value
            guard let self, self.activePane === pane, pane.isContentRequestCurrent(token) else {
                return
            }
            guard !groups.isEmpty else {
                pane.showSmartResults(
                    [],
                    title: String(
                        format: L("bvc.noNearDup", "No near-duplicate photos in %@"),
                        root.lastPathComponent))
                return
            }
            let clusteredNames = Set(groups.flatMap { $0.urls.map(\.lastPathComponent) })
            let shown = entries.filter { clusteredNames.contains($0.name) }
            let extras = groups.flatMap(\.extras)
            pane.showSmartResults(
                shown,
                title: String(
                    format: L("bvc.nearDupFound", "Near-duplicates: %d group(s), %d to remove"),
                    groups.count, extras.count))
            self.confirmCull(extras: extras, groupCount: groups.count)
        }
    }

    private func confirmCull(extras: [URL], groupCount: Int) {
        guard !extras.isEmpty, view.window != nil else { return }
        let alert = NSAlert()
        alert.messageText = L("bvc.cullTitle", "Move near-duplicates to the Trash?")
        alert.informativeText = String(
            format: L(
                "bvc.cullBody",
                "Keep the sharpest of each of the %d group(s) and move the other %d photo(s) to the Trash. You can Put Back from the Trash."
            ),
            groupCount, extras.count)
        alert.addButton(withTitle: L("bvc.cullConfirm", "Move to Trash"))
        alert.addButton(withTitle: L("bvc.cullKeep", "Keep All"))
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            self.performLocalTrash(extras)
        }
    }

    /// Flat / recursive view: list every item under the current folder, flattened into one
    /// location-aware smart-result view (each row carries its own subfolder). Runs off the main
    /// thread; navigating away discards it, like the other smart views.
    func flattenFolder() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let root = pane.currentURL
        let includingHidden = pane.showHiddenByDefault
        let token = pane.beginContentRequest()
        pane.showSmartResults(
            [],
            title: String(
                format: L("bvc.flatteningLoading", "Listing everything in %@…"),
                root.lastPathComponent))
        Task { @MainActor [weak self] in
            let result = await Task.detached {
                FlatEnumerator.entries(
                    of: root, includingHidden: includingHidden, includeFolders: true)
            }.value
            guard let self, self.activePane === pane, pane.isContentRequestCurrent(token) else {
                return
            }
            let count = result.entries.count
            let title =
                result.truncated
                ? String(
                    format: L("bvc.flatCountTruncated", "All items in %@: %d+ (truncated)"),
                    root.lastPathComponent, count)
                : String(
                    format: L("bvc.flatCount", "All items in %@: %d"), root.lastPathComponent, count
                )
            pane.showSmartResults(result.entries, title: title)
        }
    }
}
