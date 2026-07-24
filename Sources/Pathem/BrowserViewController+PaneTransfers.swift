import AppKit
import PathemEngine

// Inter-pane file operations: copy/move the selection to the other pane (F5/F6), accept files
// dropped onto a pane, and the "Open in This/Other Pane" commands (browse a folder, or view a
// PDF/image in place). All share the one off-main transfer + undo path. Split out of
// BrowserViewController. The `pendingDropContext` holder and the sidebar tag-drop stay on core.
@MainActor
extension BrowserViewController {
    /// Copy or move the active pane's selection into the other pane's folder (F5 / F6). If names
    /// already exist there, ask how to resolve (replace, keep both, or skip), then register an undo
    /// for whatever was performed (DESIGN.md §6.5).
    func transfer(move: Bool) {
        if blockedByRemote() { return }
        guard !transferInFlight else { NSSound.beep(); return }  // don't prompt for a refused op
        guard let source = activePane, let activeSide else { return }
        let otherSide = (activeSide === leftTabs) ? rightTabs : leftTabs
        guard let destination = otherSide.activePane else { NSSound.beep(); return }
        let urls = source.selectedLocalURLs()  // location-aware: sources may span folders (smart view)
        guard !urls.isEmpty else { NSSound.beep(); return }

        let destinationURL = destination.currentURL
        let conflicts = FileOperations.conflicts(urls: urls, into: destinationURL)
        resolveThenTransfer(urls: urls, into: destinationURL, move: move, conflictCount: conflicts.count) {
            [weak self] outcome in
            guard let self else { return }
            if move { source.reloadIfShowingListing() }
            destination.reloadIfShowingListing()
            self.revealDropped(outcome.performed, into: destinationURL)  // reveal what landed
            if move {  // sources moved away: drop their rows from any smart view
                self.pruneSmartEntries(Set(outcome.performed.map(\.source.path)))
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

    /// Copy or move files dropped onto a pane into `destination`, reusing the same off-main progress
    /// + undo path as the transfer commands. Refuses to nest a folder inside itself or a descendant.
    func dropFiles(_ allURLs: [URL], move: Bool, into destination: URL) {
        guard !transferInFlight else { NSSound.beep(); return }
        // Never copy/move a folder into itself or one of its own descendants. Resolve symlinks and
        // compare case-insensitively so a different spelling of the same folder is still caught (the
        // engine has a final backstop).
        let destPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let urls = allURLs.filter {
            let src = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return destPath.compare(src, options: .caseInsensitive) != .orderedSame
                && !destPath.lowercased().hasPrefix(src.lowercased() + "/")
        }
        guard !urls.isEmpty else { NSSound.beep(); return }
        let fm = FileManager.default
        let conflicts = urls.filter {
            fm.fileExists(atPath: destination.appendingPathComponent($0.lastPathComponent).path)
        }
        resolveThenTransfer(urls: urls, into: destination, move: move, conflictCount: conflicts.count) { [weak self] outcome in
            guard let self else { return }
            self.leftTabs.activePane?.reloadIfShowingListing()
            self.rightTabs.activePane?.reloadIfShowingListing()
            self.revealDropped(outcome.performed, into: destination)  // select + scroll to what landed
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

    /// After a drop lands, select and scroll to the items in whichever pane is showing the
    /// destination folder, so you actually see where they landed (a plain reload keeps the old scroll,
    /// leaving a new item stranded off-screen -- the "the drop didn't do anything" bug).
    private func revealDropped(_ performed: [FileOperations.Performed], into destination: URL) {
        let names = performed.map { $0.destination.lastPathComponent }.sorted()
        guard let first = names.first else { return }
        let dest = destination.standardizedFileURL
        for side in [leftTabs, rightTabs] {
            if let pane = side.activePane, pane.currentURL.standardizedFileURL == dest {
                pane.select(name: first)
            }
        }
    }

    /// The single selected local file/folder eligible for Open in Other Pane (a folder to browse
    /// to, or a PDF/image to view in place), when there is an other pane. Nil disables the command.
    func openInOtherPaneTarget() -> URL? {
        guard otherPane != nil, let url = activePane?.singleSelectedURL else { return nil }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return (isDir || DocumentPreviewView.isViewable(url)) ? url : nil
    }

    /// Open the selection in the other pane: navigate there for a folder, or show a document viewer
    /// (PDF/image) so the dual-pane becomes files-on-one-side, live-document-on-the-other.
    func openInOtherPane() {
        guard let other = otherPane, let url = openInOtherPaneTarget() else { NSSound.beep(); return }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDir {
            other.navigate(to: url)
        } else {
            other.presentViewer(url)
        }
    }

    /// The single selected viewable file (PDF/image) for Open in This Pane. Nil disables the command.
    func openInThisPaneTarget() -> URL? {
        guard let url = activePane?.singleSelectedURL, DocumentPreviewView.isViewable(url) else { return nil }
        return url
    }

    /// View a supported file (PDF/image) in the active pane itself, without launching another app.
    func openInThisPane() {
        guard let pane = activePane, let url = openInThisPaneTarget() else { NSSound.beep(); return }
        pane.presentViewer(url)
    }
}
