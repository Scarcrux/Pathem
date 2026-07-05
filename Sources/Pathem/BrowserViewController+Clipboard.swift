import AppKit
import PathemEngine

// File clipboard: cut / copy / paste of files via the pasteboard, routed from the
// Edit menu. Split out of BrowserViewController.
extension BrowserViewController {
    // MARK: - File clipboard (cut / copy / paste)
    //
    // Routed via the Edit menu's cut:/copy:/paste:. When the search field is
    // focused the field editor handles them as text editing; when a pane's table
    // is focused they reach here and act on files.

    @objc func copy(_ sender: Any?) { writeSelectionToPasteboard(cut: false) }
    @objc func cut(_ sender: Any?) { writeSelectionToPasteboard(cut: true) }

    @objc func paste(_ sender: Any?) {
        if blockedByRemoteOrSmart() { return }  // needs a single destination folder
        guard !transferInFlight else { NSSound.beep(); return }  // don't prompt for a refused op
        guard let pane = activePane else { return }
        let pasteboard = NSPasteboard.general
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
        guard !urls.isEmpty else { NSSound.beep(); return }

        let isMove = pasteboard.data(forType: Self.cutPasteboardType) != nil
        let destination = pane.currentURL

        let conflicts = FileOperations.conflicts(urls: urls, into: destination)
        resolveThenTransfer(urls: urls, into: destination, move: isMove, conflictCount: conflicts.count) {
            [weak self] outcome in
            guard let self else { return }
            self.leftTabs.activePane?.reloadIfShowingListing()
            self.rightTabs.activePane?.reloadIfShowingListing()
            if !outcome.performed.isEmpty {
                self.registerUndo(outcome.performed, actionName: isMove ? L("bvc.moveAction", "Move") : L("bvc.copyAction", "Copy"))
            }
            if isMove {
                pasteboard.clearContents()  // cut items are gone; don't move them twice
                self.cutPaths = []
                self.applyCutPaths()  // clear the dimming
                self.pruneSmartEntries(Set(outcome.performed.map(\.source.path)))  // drop moved rows
            }
            if !outcome.failures.isEmpty { self.presentFailures(outcome.failures, title: L("bvc.pasteFailed", "Paste failed")) }
        }
    }

    func writeSelectionToPasteboard(cut: Bool) {
        guard let pane = activePane else { return }
        // Copy/cut only writes URLs (no mutation), so it's safe in smart-result views;
        // selectedLocalURLs resolves each item to its real folder. Remote has no local URL.
        guard !pane.isRemote else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let pasteboard = NSPasteboard.general
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
