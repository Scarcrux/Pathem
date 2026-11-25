import AppKit
import PathemEngine

/// The folder tree's commands: pin and unpin a folder as a tree root, reveal a folder in the
/// tree, and the pane markers. The tree itself lives in `FolderTreeController`.
extension BrowserViewController {
    /// The folder a pin or reveal command acts on: the single selected folder, the selected
    /// item's folder for a reveal, or the pane's own folder with nothing selected. Local only.
    func folderTreeTarget(forReveal: Bool) -> URL? {
        guard let pane = activePane, !pane.isRemote, pane.smartListingTitle == nil else {
            return nil
        }
        let selection = pane.selectedLocalURLs()
        if selection.isEmpty { return pane.currentURL }
        guard selection.count == 1 else { return nil }
        let url = selection[0]
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if isFolder { return url }
        return forReveal ? url.deletingLastPathComponent() : nil
    }

    var folderTreePinTarget: URL? { folderTreeTarget(forReveal: false) }

    func pinToFolderTree() {
        guard let folder = folderTreePinTarget else {
            NSSound.beep()
            return
        }
        if folderTree.isPinned(folder) {
            folderTree.unpin(folder)  // the context menu entry flips to Unpin; same command
        } else {
            showFolderTreeIfHidden()
            folderTree.pin(folder)
        }
    }

    func unpinFromFolderTree() {
        guard let folder = folderTreePinTarget, folderTree.isPinned(folder) else {
            NSSound.beep()
            return
        }
        folderTree.unpin(folder)
    }

    func revealInFolderTree() {
        guard let folder = folderTreeTarget(forReveal: true) else {
            NSSound.beep()
            return
        }
        showFolderTreeIfHidden()
        folderTree.reveal(folder)
    }

    private func showFolderTreeIfHidden() {
        guard !prefs.showFolderTree else { return }
        prefs.showFolderTree = true
        applyPreferences()
    }

    /// Pane locations for the tree's markers: the left or top pane is slot 0.
    func updateFolderTreeMarks() {
        var marks: [FolderTreeController.PaneMark] = []
        for (slot, side) in [leftTabs, rightTabs].enumerated() {
            guard let pane = side.activePane, !pane.isRemote, pane.smartListingTitle == nil else {
                continue
            }
            marks.append(
                .init(slot: slot, url: pane.currentURL, isActive: pane === activePane))
        }
        folderTree.setPaneMarks(marks, stacked: prefs.stackPanesVertically)
    }

    /// Wire the tree's callbacks that need the browser: drops, persistence, new tab.
    func configureFolderTree() {
        folderTree.onDropFiles = { [weak self] urls, folder, move in
            self?.dropFiles(urls, move: move, into: folder)
        }
        folderTree.onOpenInNewTab = { [weak self] url in self?.activeSide?.openTab(at: url) }
        folderTree.onStateChange = { [weak self] state in
            guard let self, prefs.folderTreeState != state else { return }
            prefs.folderTreeState = state
            saveConfig(prefs, to: Self.preferencesURL)
        }
    }
}
