import AppKit
import PathemEngine

// The Pathem-trashed-items origin ledger and the Trash-specific commands built on it
// (Put Back, Delete Immediately, Empty Trash, and the trash undo/redo pair), split out
// of BrowserViewController.
@MainActor
extension BrowserViewController {
    // MARK: - Trash: origins ledger, Put Back, Delete Immediately, Empty Trash

    private static var trashOriginsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("trash-origins.json")
    }
    func loadTrashOrigins() {
        trashOrigins = loadConfig([String: String].self, from: Self.trashOriginsURL) ?? [:]
    }
    func recordTrashOrigins(_ trashed: [FileOperations.Trashed]) {
        guard !trashed.isEmpty else { return }
        for item in trashed { trashOrigins[item.trashed.path] = item.original.path }
        saveConfig(trashOrigins, to: Self.trashOriginsURL)
    }

    /// Restore the selected trashed items to their original locations (recorded when Pathem
    /// trashed them). Items with no recorded origin (e.g. trashed by Finder) are reported.
    func putBackSelection() {
        guard let pane = activePane, !pane.isRemote else {
            NSSound.beep()
            return
        }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        var failures: [FileOperations.Failure] = []
        for url in urls {
            guard let originalPath = trashOrigins[url.path] else {
                failures.append(
                    .init(
                        name: url.lastPathComponent,
                        reason: L(
                            "bvc.putBackUnknown",
                            "Original location unknown (not trashed by Pathem).")))
                continue
            }
            let destination = uniqueLocalURL(URL(fileURLWithPath: originalPath))
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: destination)
                trashOrigins[url.path] = nil
            } catch {
                failures.append(
                    .init(name: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        saveConfig(trashOrigins, to: Self.trashOriginsURL)
        reloadBothSides()
        if !failures.isEmpty {
            presentFailures(failures, title: L("bvc.putBackFailed", "Couldn’t put back"))
        }
    }

    /// Permanently delete the selection, bypassing the Trash (Finder's Delete Immediately).
    func deleteImmediatelySelection() {
        guard !fileOperationBusy else { return }
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty, view.window != nil else {
            NSSound.beep()
            return
        }
        fileConfirmationPending = true
        Task { @MainActor in
            defer { fileConfirmationPending = false }
            let message =
                urls.count == 1
                ? L("bvc.deleteNowOne", "Permanently delete this item?")
                : String(format: L("bvc.deleteNowMany", "Permanently delete %d items?"), urls.count)
            let choice = await self.cursorConfirm.ask(
                message: message, info: L("bvc.cantBeUndone", "This can’t be undone."),
                buttons: [L("common.delete", "Delete"), L("common.cancel", "Cancel")],
                over: self.view)
            guard choice == 0 else { return }
            var failures: [FileOperations.Failure] = []
            for url in urls {
                do { try FileManager.default.removeItem(at: url) } catch {
                    failures.append(
                        .init(name: url.lastPathComponent, reason: error.localizedDescription))
                }
                self.trashOrigins[url.path] = nil
            }
            saveConfig(self.trashOrigins, to: Self.trashOriginsURL)
            self.reloadBothSides()
            if !failures.isEmpty {
                self.presentFailures(failures, title: L("bvc.deleteFailed", "Delete failed"))
            }
        }
    }

    /// Permanently erase everything in the (home) Trash, after a confirmation at the pointer.
    func emptyTrash(then completion: (() -> Void)? = nil) {
        guard !fileOperationBusy else { return }
        let items =
            (try? FileManager.default.contentsOfDirectory(
                at: homeTrashURL, includingPropertiesForKeys: nil)) ?? []
        guard !items.isEmpty, view.window != nil else {
            NSSound.beep()
            return
        }
        fileConfirmationPending = true
        Task { @MainActor in
            defer { fileConfirmationPending = false }
            let choice = await self.cursorConfirm.ask(
                message: String(
                    format: L("bvc.emptyTrashTitle", "Permanently erase %d item(s) in the Trash?"),
                    items.count),
                info: L("bvc.cantBeUndone", "This can’t be undone."),
                buttons: [L("bvc.emptyTrashAction", "Empty Trash"), L("common.cancel", "Cancel")],
                over: self.view)
            guard choice == 0 else { return }
            var failed = 0
            for item in items {
                do { try FileManager.default.removeItem(at: item) } catch { failed += 1 }
                self.trashOrigins[item.path] = nil
            }
            saveConfig(self.trashOrigins, to: Self.trashOriginsURL)
            self.reloadBothSides()
            completion?()
            if failed > 0 {
                self.presentInfo(
                    L("bvc.emptyTrashPartialTitle", "Some items couldn’t be erased"),
                    L("bvc.emptyTrashPartialBody", "They may be locked or in use."))
            }
        }
    }

    func registerTrashUndo(_ trashed: [FileOperations.Trashed]) {
        let paths = Set(trashed.flatMap { [$0.original.path, $0.trashed.path] })
        actionHistory.record(
            name: L("bvc.moveToTrashAction", "Move to Trash"), footprint: paths,
            undoFootprint: paths
        ) { [weak self] in
            guard let self else { return }
            let outcome = FileOperations.untrash(trashed)
            self.reloadBothSides()
            if !outcome.failures.isEmpty {
                self.presentFailures(outcome.failures, title: L("bvc.undoFailed", "Undo failed"))
            }
            // Redo re-trashes exactly where each item was restored (which may differ from its
            // original path if that was reoccupied), not the recorded original path.
            self.registerTrashRedo(outcome.restored)
        }
    }

    private func registerTrashRedo(_ restored: [URL]) {
        let paths = Set(restored.map(\.path))
        actionHistory.record(
            name: L("bvc.moveToTrashAction", "Move to Trash"), footprint: paths,
            undoFootprint: paths
        ) { [weak self] in
            guard let self else { return }
            let result = FileOperations.trash(urls: restored)
            self.reloadBothSides()
            if !result.failures.isEmpty {
                self.presentFailures(result.failures, title: L("bvc.redoFailed", "Redo failed"))
            }
            if !result.trashed.isEmpty { self.registerTrashUndo(result.trashed) }
        }
    }

    // MARK: - Trash the selection

    func trashSelection() {
        guard !fileOperationBusy else { return }
        guard let pane = activePane else { return }
        if pane.isRemote {
            let entries = pane.selectedEntries
            guard !entries.isEmpty else {
                NSSound.beep()
                return
            }
            // A non-UTF-8 name only round-trips by its raw bytes; acting on the lossy
            // String could hit the wrong file, so refuse it for now.
            guard entries.allSatisfy({ $0.rawName == nil }) else {
                presentInfo(
                    L("bvc.cantDeleteTitle", "Can’t delete this item"),
                    L(
                        "bvc.cantDeleteBody",
                        "Its name isn’t valid UTF-8, which remote operations don’t support yet."))
                return
            }
            // Remote delete is permanent (no Trash, no undo): confirm explicitly, at the pointer.
            let host = pane.remoteContext?.connection.host ?? L("bvc.theServer", "the server")
            let message =
                entries.count == 1
                ? String(
                    format: L("bvc.remoteDeleteOne", "Permanently delete this item on %@?"), host)
                : String(
                    format: L("bvc.remoteDeleteMany", "Permanently delete %d items on %@?"),
                    entries.count, host)
            let names = entries.map { ($0.name, $0.isDirectory) }
            fileConfirmationPending = true
            Task { @MainActor in
                defer { fileConfirmationPending = false }
                let choice = await self.cursorConfirm.ask(
                    message: message, info: L("bvc.cantBeUndone", "This can’t be undone."),
                    buttons: [L("common.delete", "Delete"), L("common.cancel", "Cancel")],
                    over: self.view)
                guard choice == 0 else { return }
                fileConfirmationPending = false
                self.performRemoteOp(pane, verb: L("bvc.deleteVerb", "Delete")) {
                    provider, connection, path, password in
                    for (name, isDir) in names {
                        try await provider.remove(
                            connection, path: PaneController.joinRemote(path, name),
                            isDirectory: isDir,
                            password: password)
                    }
                }
            }
            return
        }
        let urls = pane.selectedLocalURLs()  // location-aware: trashes the real files in smart views
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        guard prefs.confirmBeforeDelete, view.window != nil else {
            performLocalTrash(urls)
            return
        }
        fileConfirmationPending = true
        Task { @MainActor in
            defer { fileConfirmationPending = false }
            let choice = await cursorConfirm.ask(
                message: urls.count > 1
                    ? String(
                        format: L("bvc.confirmTrashCount", "Move %d selected items to the Trash?"),
                        urls.count)
                    : L("bvc.confirmTrashTitle", "Move the selected items to the Trash?"),
                info: L("bvc.confirmTrashBody", "You can put them back from the Trash."),
                buttons: [
                    urls.count > 1
                        ? L("bvc.moveAllToTrash", "Move All to Trash")
                        : L("bvc.moveToTrashAction", "Move to Trash"), L("common.cancel", "Cancel"),
                ],
                over: view)
            if choice == 0 { self.performLocalTrash(urls) }
        }
    }

    func performLocalTrash(_ urls: [URL]) {
        #if DEBUG
        if let debugTrashHandler {
            debugTrashHandler(urls)
            return
        }
        #endif
        let result = FileOperations.trash(urls: urls)
        reloadBothSides()  // the trashed files may have lived in either visible folder
        pruneSmartEntries(Set(result.trashed.map(\.original.path)))  // drop stale rows in smart views
        recordTrashOrigins(result.trashed)  // remember where each came from, for Put Back
        if !result.trashed.isEmpty { registerTrashUndo(result.trashed) }
        Self.recordActivity(
            "trash", sources: urls, completed: result.trashed.count, failures: result.failures,
            undo: result.trashed.isEmpty ? nil : actionHistory.undoStack.last?.id)
        if !result.failures.isEmpty {
            presentFailures(
                result.failures, title: L("bvc.moveToTrashFailed", "Move to Trash failed"))
        }
    }

    // MARK: - Trash home location and selection state

    var homeTrashURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    }
    var trashHasItems: Bool {
        !((try? FileManager.default.contentsOfDirectory(atPath: homeTrashURL.path)) ?? []).isEmpty
    }
    /// True when the whole selection lives inside the Trash (so Put Back / Delete Immediately apply).
    var selectionIsInTrash: Bool {
        guard let pane = activePane, !pane.isRemote else { return false }
        let trashPrefix = homeTrashURL.path + "/"
        let selected = pane.selectedLocalURLs()
        return !selected.isEmpty && selected.allSatisfy { $0.path.hasPrefix(trashPrefix) }
    }
}
