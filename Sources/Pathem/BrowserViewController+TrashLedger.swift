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
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        var failures: [FileOperations.Failure] = []
        for url in urls {
            guard let originalPath = trashOrigins[url.path] else {
                failures.append(
                    .init(
                        name: url.lastPathComponent,
                        reason: L("bvc.putBackUnknown", "Original location unknown (not trashed by Pathem).")))
                continue
            }
            let destination = uniqueLocalURL(URL(fileURLWithPath: originalPath))
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: destination)
                trashOrigins[url.path] = nil
            } catch {
                failures.append(.init(name: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        saveConfig(trashOrigins, to: Self.trashOriginsURL)
        reloadBothSides()
        if !failures.isEmpty { presentFailures(failures, title: L("bvc.putBackFailed", "Couldn’t put back")) }
    }

    /// Permanently delete the selection, bypassing the Trash (Finder's Delete Immediately).
    func deleteImmediatelySelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty, view.window != nil else { NSSound.beep(); return }
        Task { @MainActor in
            let message =
                urls.count == 1
                ? L("bvc.deleteNowOne", "Permanently delete this item?")
                : String(format: L("bvc.deleteNowMany", "Permanently delete %d items?"), urls.count)
            let choice = await self.cursorConfirm.ask(
                message: message, info: L("bvc.cantBeUndone", "This can’t be undone."),
                buttons: [L("common.delete", "Delete"), L("common.cancel", "Cancel")], over: self.view)
            guard choice == 0 else { return }
            var failures: [FileOperations.Failure] = []
            for url in urls {
                do { try FileManager.default.removeItem(at: url) } catch {
                    failures.append(.init(name: url.lastPathComponent, reason: error.localizedDescription))
                }
                self.trashOrigins[url.path] = nil
            }
            saveConfig(self.trashOrigins, to: Self.trashOriginsURL)
            self.reloadBothSides()
            if !failures.isEmpty { self.presentFailures(failures, title: L("bvc.deleteFailed", "Delete failed")) }
        }
    }

    /// Permanently erase everything in the (home) Trash, after a confirmation at the pointer.
    func emptyTrash() {
        let items =
            (try? FileManager.default.contentsOfDirectory(
                at: homeTrashURL, includingPropertiesForKeys: nil)) ?? []
        guard !items.isEmpty, view.window != nil else { NSSound.beep(); return }
        Task { @MainActor in
            let choice = await self.cursorConfirm.ask(
                message: String(
                    format: L("bvc.emptyTrashTitle", "Permanently erase %d item(s) in the Trash?"), items.count),
                info: L("bvc.cantBeUndone", "This can’t be undone."),
                buttons: [L("bvc.emptyTrashAction", "Empty Trash"), L("common.cancel", "Cancel")], over: self.view)
            guard choice == 0 else { return }
            var failed = 0
            for item in items {
                do { try FileManager.default.removeItem(at: item) } catch { failed += 1 }
                self.trashOrigins[item.path] = nil
            }
            saveConfig(self.trashOrigins, to: Self.trashOriginsURL)
            self.reloadBothSides()
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
            name: L("bvc.moveToTrashAction", "Move to Trash"), footprint: paths, undoFootprint: paths
        ) { [weak self] in
            guard let self else { return }
            let failures = FileOperations.untrash(trashed)
            self.reloadBothSides()
            if !failures.isEmpty { self.presentFailures(failures, title: L("bvc.undoFailed", "Undo failed")) }
            self.registerTrashRedo(trashed)  // redo = move them back to the Trash
        }
    }

    private func registerTrashRedo(_ trashed: [FileOperations.Trashed]) {
        let paths = Set(trashed.flatMap { [$0.original.path, $0.trashed.path] })
        actionHistory.record(
            name: L("bvc.moveToTrashAction", "Move to Trash"), footprint: paths, undoFootprint: paths
        ) { [weak self] in
            guard let self else { return }
            // Trash by original URL so cross-folder selections redo correctly.
            let result = FileOperations.trash(urls: trashed.map(\.original))
            self.reloadBothSides()
            if !result.failures.isEmpty { self.presentFailures(result.failures, title: L("bvc.redoFailed", "Redo failed")) }
            if !result.trashed.isEmpty { self.registerTrashUndo(result.trashed) }
        }
    }
}
