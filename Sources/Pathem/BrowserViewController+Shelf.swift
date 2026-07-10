import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {

    // MARK: - Stash shelf / drop stack

    func configureShelf() {
        shelf.onChanged = { [weak self] in
            guard let self else { return }
            if !self.shelf.isEmpty, self.shelf.view.isHidden { self.setShelfVisible(true) }  // auto-show on first add
        }
        shelf.onCopyHere = { [weak self] urls in self?.shelfTransfer(urls, move: false) }
        shelf.onMoveHere = { [weak self] urls in self?.shelfTransfer(urls, move: true) }
        shelf.onTrash = { [weak self] urls in self?.shelfTrash(urls) }
        shelf.onReveal = { urls in
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        shelf.onShare = { urls, from in
            guard !urls.isEmpty else { return }
            let picker = NSSharingServicePicker(items: urls)
            picker.show(relativeTo: from.bounds, of: from, preferredEdge: .minY)
        }
        shelf.onHide = { [weak self] in self?.setShelfVisible(false) }
    }

    func setShelfVisible(_ visible: Bool) {
        guard shelf.view.isHidden == visible else { return }
        shelf.view.isHidden = !visible
        shelfHiddenConstraint?.isActive = !visible
        shelfShownConstraint?.isActive = visible
    }

    func toggleShelf() { setShelfVisible(shelf.view.isHidden) }

    /// Add the active pane's selection to the shelf (location-aware, so smart-result
    /// rows contribute their real paths).
    func addSelectionToShelf() {
        guard let urls = activePane?.selectedLocalURLs(), !urls.isEmpty else { NSSound.beep(); return }
        shelf.add(urls)
    }

    /// Copy or move shelved items into the active pane's folder, reusing the same
    /// conflict-aware, undoable transfer path as F5/F6.
    func shelfTransfer(_ urls: [URL], move: Bool) {
        guard !transferInFlight else { NSSound.beep(); return }
        guard let destination = activePane else { NSSound.beep(); return }
        let destinationURL = destination.currentURL
        // Don't act on items that are already in (or are) the destination folder.
        let sources = urls.filter { $0.deletingLastPathComponent().standardizedFileURL != destinationURL.standardizedFileURL }
        guard !sources.isEmpty else { NSSound.beep(); return }

        let conflicts = FileOperations.conflicts(urls: sources, into: destinationURL)
        resolveThenTransfer(urls: sources, into: destinationURL, move: move, conflictCount: conflicts.count) {
            [weak self] outcome in
            guard let self else { return }
            self.reloadBothSides()
            if move {
                let moved = Set(outcome.performed.map(\.source.path))
                self.pruneSmartEntries(moved)
                self.shelf.itemsRemoved(outcome.performed.map(\.source))  // gone from source now
            }
            if !outcome.performed.isEmpty {
                self.registerUndo(outcome.performed, actionName: move ? L("bvc.moveAction", "Move") : L("bvc.copyAction", "Copy"))
            }
            if !outcome.failures.isEmpty {
                self.presentFailures(
                    outcome.failures,
                    title: move ? L("bvc.moveFailed", "Move failed") : L("bvc.copyFailed", "Copy failed"))
            }
        }
    }

    func shelfTrash(_ urls: [URL]) {
        let result = FileOperations.trash(urls: urls)
        reloadBothSides()
        pruneSmartEntries(Set(result.trashed.map(\.original.path)))
        shelf.itemsRemoved(result.trashed.map(\.original))  // trashed: drop from the shelf
        if !result.trashed.isEmpty { registerTrashUndo(result.trashed) }
        if !result.failures.isEmpty { presentFailures(result.failures, title: L("bvc.moveToTrashFailed", "Move to Trash failed")) }
    }
}
