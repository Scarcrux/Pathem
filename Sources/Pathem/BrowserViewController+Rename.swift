import AppKit
import PathemEngine

// Renaming a single item: Finder-style in-place editing where possible, a sheet otherwise, a remote
// rename for remote panes, plus the undo/redo registration. Split out of BrowserViewController; the
// sheet and inline-edit paths both funnel through commitLocalRename so they behave identically.
extension BrowserViewController {
    func renameSelection(suggestions: Bool? = nil) {
        guard let pane = activePane, pane.selectedEntries.count == 1,
            let entry = pane.selectedEntries.first
        else { return }
        // Prefer Finder-style in-place editing (list view, local panes). Remote renames and views
        // that can't edit in place fall through to the sheet below.
        let offerSuggestions =
            !pane.isRemote && !entry.isDirectory
            && (suggestions ?? prefs.suggestFilenames) && AIAssistant.isAvailable
        if !offerSuggestions, !pane.isRemote, pane.beginInlineRename() { return }
        let directory = entry.location.map { URL(fileURLWithPath: $0) } ?? pane.currentURL
        let originRemote = pane.remoteContext
        let originRevision = pane.remoteSessionRevision
        let dialog = RenameDialogController(
            name: entry.name, url: directory.appendingPathComponent(entry.name),
            dataless: entry.isDataless, offerSuggestions: offerSuggestions)
        let alert = dialog.alert
        let field = dialog.field
        Task { @MainActor in
            defer { dialog.cancel() }
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != entry.name else { return }
            guard Self.renameContextMatches(originRemote, pane.remoteContext),
                originRemote == nil || pane.remoteSessionRevision == originRevision
            else { return }
            if originRemote != nil {
                guard entry.rawName == nil else {
                    self.presentInfo(
                        L("bvc.cantRenameTitle", "Can’t rename this item"),
                        L(
                            "bvc.cantRenameBody",
                            "Its name isn’t valid UTF-8, which remote operations don’t support yet."
                        ))
                    return
                }
                self.performRemoteOp(pane, verb: L("bvc.renameVerb", "Rename")) {
                    provider, connection, path, password in
                    try await provider.rename(
                        connection, from: PaneController.joinRemote(path, entry.name),
                        to: PaneController.joinRemote(path, newName), password: password)
                }
                return
            }
            // The sheet owns this URL even if the browser changed folders meanwhile.
            self.confirmLocalRename(entry, to: newName, in: directory, pane: pane)
        }
    }

    static func renameContextMatches(
        _ origin: (connection: RemoteConnection, path: String, password: String)?,
        _ current: (connection: RemoteConnection, path: String, password: String)?
    ) -> Bool {
        switch (origin, current) {
        case (nil, nil): return true
        case (.some(let origin), .some(let current)):
            return origin.connection == current.connection && origin.path == current.path
                && origin.password == current.password
        default: return false
        }
    }

    /// Perform a local rename (+ undo + reselect). Shared by the rename sheet and Finder-style
    /// in-place editing, so both take the same path.
    func commitLocalRename(_ entry: FileEntry, to newName: String, pane: PaneController) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else { return }
        // The file's real folder: its own location in a smart view, else current.
        let directory = entry.location.map { URL(fileURLWithPath: $0) } ?? pane.currentURL
        confirmLocalRename(entry, to: trimmed, in: directory, pane: pane)
    }

    private func confirmLocalRename(
        _ entry: FileEntry, to trimmed: String, in directory: URL, pane: PaneController
    ) {
        guard prefs.warnBeforeChangingExtension,
            RenamePolicy.changesExtension(
                from: entry.name, to: trimmed, isDirectory: entry.isDirectory)
        else {
            performLocalRename(entry, to: trimmed, in: directory, pane: pane)
            return
        }
        let alert = NSAlert()
        alert.messageText = L("rename.extensionTitle", "Change filename extension?")
        alert.informativeText = L(
            "rename.extensionHint",
            "Changing the extension can make this file open in a different app or stop opening correctly."
        )
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.addButton(withTitle: L("rename.changeExtension", "Change Extension"))
        Task { @MainActor in
            guard await presentSheet(alert) == .alertSecondButtonReturn else { return }
            performLocalRename(entry, to: trimmed, in: directory, pane: pane)
        }
    }

    private func performLocalRename(
        _ entry: FileEntry, to trimmed: String, in directory: URL, pane: PaneController
    ) {
        let source = directory.appendingPathComponent(entry.name)
        let destination = directory.appendingPathComponent(trimmed)
        do {
            try FileOperations.rename(entry.name, to: trimmed, in: directory)
            registerRenameUndo(from: trimmed, to: entry.name, in: directory)
            Self.recordActivity(
                "rename", sources: [source], destination: destination, completed: 1,
                undo: actionHistory.undoStack.last?.id)
            guard pane.currentURL == directory || pane.isShowingSmartResults else { return }
            pane.reloadIfShowingListing()
            // Carry identity into the fresh listing without revealing it: renaming
            // may re-sort the row, but must not move the user's viewport.
            pane.selectWhenListed(trimmed)
        } catch {
            let failure = FileOperations.Failure(
                name: entry.name, reason: error.localizedDescription)
            Self.recordActivity(
                "rename", sources: [source], destination: destination,
                completed: 0, failures: [failure])
            presentFailures([failure], title: L("bvc.renameFailed", "Rename failed"))
        }
    }

    func registerRenameUndo(from current: String, to original: String, in directory: URL) {
        let paths: Set<String> = [
            directory.appendingPathComponent(current).path,
            directory.appendingPathComponent(original).path,
        ]
        actionHistory.record(
            name: L("bvc.renameVerb", "Rename"), footprint: paths, undoFootprint: paths
        ) {
            [weak self] in
            guard let self else { return }
            do {
                try FileOperations.rename(current, to: original, in: directory)
                self.reloadBothSides()
                self.paneShowing(directory)?.selectWhenListed(original)
                self.registerRenameUndo(from: original, to: current, in: directory)  // redo
            } catch {
                self.presentFailures(
                    [FileOperations.Failure(name: current, reason: error.localizedDescription)],
                    title: L("bvc.undoFailed", "Undo failed"))
            }
        }
    }
}
