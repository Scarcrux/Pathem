import AppKit
import PathemEngine

// File clipboard: cut / copy / paste of files via the pasteboard, routed from the
// Edit menu. Split out of BrowserViewController.
extension BrowserViewController {
    var filePasteboard: NSPasteboard {
        #if DEBUG
        if let debugFilePasteboard { return debugFilePasteboard }
        #endif
        return .general
    }
    // MARK: - File clipboard (cut / copy / paste)
    //
    // Routed via the Edit menu's cut:/copy:/paste:. When the search field is
    // focused the field editor handles them as text editing; when a pane's table
    // is focused they reach here and act on files.

    @objc func copy(_ sender: Any?) { writeSelectionToPasteboard(cut: false) }
    @objc func cut(_ sender: Any?) { writeSelectionToPasteboard(cut: true) }

    /// Open the clipboard viewer on the current file clipboard: the copied/cut items and
    /// whether a paste copies or moves them, with paste-here and clear.
    func showClipboard() {
        let pasteboard = filePasteboard
        let urls = FileDrag.readFileURLs(from: pasteboard) ?? []
        let isCut = pasteboard.data(forType: Self.cutPasteboardType) != nil
        clipboardViewer.present(
            items: urls, isCut: isCut, over: view.window,
            onPaste: { [weak self] in self?.paste(nil) },
            onClear: { [weak self] in
                guard let self else { return }
                pasteboard.clearContents()
                self.cutPaths = []
                self.applyCutPaths()
            })
    }

    @objc func paste(_ sender: Any?) {
        // Toolbar/registry commands can bypass the outline's responder action.
        if sidebar.hasKeyboardFocus {
            guard let folder = sidebar.selectedPasteFolder else {
                NSSound.beep()
                return
            }
            pasteFiles(into: folder)
        } else {
            pasteInto(activePane)
        }
    }

    /// Paste the file clipboard into a specific pane's folder: the active pane for the
    /// Edit-menu Paste, or the other pane for the quick-bar "Paste in Other Pane" follow-up.
    func pasteInto(_ pane: PaneController?) {
        guard let pane else {
            NSSound.beep()
            return
        }
        if pane.isRemote || pane.isShowingSmartResults {
            NSSound.beep()
            return
        }  // needs one dest folder
        pasteFiles(into: pane.currentURL)
    }

    func canPasteFiles(into destination: URL) -> Bool {
        destination.isFileURL && SidebarController.isDirectory(destination)
            && !transferInFlight && FileDrag.hasFileURLs(filePasteboard)
    }

    /// Sidebar menu targets are explicit folders, not the active pane or selected row.
    /// Share the clipboard semantics (cut marker, dimming, conflicts and undo) with pane Paste.
    func pasteFiles(into destination: URL) {
        guard canPasteFiles(into: destination) else {
            NSSound.beep()
            return
        }
        let pasteboard = filePasteboard
        let changeCount = pasteboard.changeCount
        let urls = FileDrag.readFileURLs(from: pasteboard) ?? []
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }

        let isMove = pasteboard.data(forType: Self.cutPasteboardType) != nil
        guard pasteboard.changeCount == changeCount else { return }

        let conflicts = FileOperations.conflicts(urls: urls, into: destination)
        resolveThenTransfer(
            urls: urls, into: destination, move: isMove, conflictCount: conflicts.count
        ) {
            [weak self] outcome in
            guard let self else { return }
            self.leftTabs.activePane?.reloadIfShowingListing()
            self.rightTabs.activePane?.reloadIfShowingListing()
            if !outcome.performed.isEmpty {
                self.registerUndo(
                    outcome.performed,
                    actionName: isMove ? L("bvc.moveAction", "Move") : L("bvc.copyAction", "Copy"))
            }
            if isMove {
                self.finishCutPaste(
                    urls: urls, pasteboard: pasteboard, changeCount: changeCount,
                    performed: outcome.performed)
                self.pruneSmartEntries(Set(outcome.performed.map(\.source.path)))  // drop moved rows
            }
            if !outcome.failures.isEmpty {
                self.presentFailures(outcome.failures, title: L("bvc.pasteFailed", "Paste failed"))
            }
        }
    }

    /// Consume only successful moves from the snapshot that started this Paste.
    /// Skipped/failed/cancelled members remain available; a later clipboard owner
    /// (including a newer cut in this window) must not have its contents/dimming erased.
    func finishCutPaste(
        urls: [URL], pasteboard: NSPasteboard, changeCount: Int,
        performed: [FileOperations.Performed]
    ) {
        guard pasteboard.changeCount == changeCount, !performed.isEmpty else { return }
        let moved = Set(performed.filter { $0.action == .moved }.map(\.source.path))
        guard !moved.isEmpty else { return }
        let remaining = urls.filter { !moved.contains($0.path) }
        pasteboard.clearContents()
        if !remaining.isEmpty {
            pasteboard.writeObjects(remaining as [NSURL])
            pasteboard.addTypes([Self.cutPasteboardType], owner: nil)
            pasteboard.setData(Data(), forType: Self.cutPasteboardType)
        }
        cutPaths = Set(remaining.map(\.path))
        applyCutPaths()
    }

    func writeSelectionToPasteboard(cut: Bool) {
        guard let pane = activePane else { return }
        // Copy/cut only writes URLs (no mutation), so it's safe in smart-result views;
        // selectedLocalURLs resolves each item to its real folder. Remote has no local URL.
        guard !pane.isRemote else {
            NSSound.beep()
            return
        }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let pasteboard = filePasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        if cut {
            pasteboard.addTypes([Self.cutPasteboardType], owner: nil)
            pasteboard.setData(Data(), forType: Self.cutPasteboardType)
        }
        cutPaths = cut ? Set(urls.map(\.path)) : []  // dim cut items; a copy clears any prior cut
        applyCutPaths()
    }

    /// Show the current cut-dimming in every pane.
    private func applyCutPaths() {
        for side in [leftTabs, rightTabs] {
            for pane in side.tabs { pane.setCutPaths(cutPaths) }
        }
    }
}
