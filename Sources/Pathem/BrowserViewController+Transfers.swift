import AppKit
import PathemEngine

// Transfer plumbing (shared by drop, F5/F6, paste, shelf, and Copy To / Move To) plus the
// file-operation undo/redo it registers. Split out of BrowserViewController so the core file
// keeps to setup and navigation. Every copy/move funnels through `runTransfer`, and every
// destructive op registers undo through `registerUndo`.
extension BrowserViewController {
    static func conflictActionHint(move: Bool) -> String {
        move
            ? L("bvc.conflictMoveHint", "Choose how to handle the move.")
            : L("bvc.conflictCopyHint", "Choose how to handle the copy.")
    }

    /// Run a copy/move off the main thread with a deferred progress sheet (so the
    /// window never freezes and quick ops never flash a sheet), then hand the
    /// outcome back on the main actor. One transfer at a time.
    func runTransfer(
        urls: [URL], into destination: URL, move: Bool,
        resolution: FileOperations.ConflictResolution,
        completion: @escaping (FileOperations.Outcome) -> Void
    ) {
        guard !fileOperationBusy else {
            NSSound.beep()
            return
        }  // one transfer at a time
        // Central backstop: never copy/move a folder into itself or its own subtree. Every entry
        // point funnels through here (drop, F5/F6, clipboard paste, shelf), so guarding once
        // covers them all -- a folder dropped into its own descendant would otherwise recurse and
        // duplicate the tree into itself until the path length blows up.
        let urls = Self.dropSelfContaining(urls, destination: destination)
        guard !urls.isEmpty else {
            NSSound.beep()
            presentInfo(
                L("bvc.selfCopyTitle", "Can’t put a folder inside itself"),
                L(
                    "bvc.selfCopyBody",
                    "A folder can’t be copied or moved into itself or one of its own subfolders."))
            return
        }
        transferInFlight = true  // so Quit warns mid-transfer
        transferRunner.run(
            urls: urls, into: destination, move: move, resolution: resolution,
            verify: !move && prefs.verifyCopies, over: view.window
        ) { [weak self] outcome, bytes, canceled in
            self?.transferInFlight = false
            // Surface skipped items centrally (every transfer path funnels through here), so a
            // Skip resolution or a name clash never silently drops files with no feedback.
            if !outcome.skipped.isEmpty {
                self?.activePane?.flashStatus(
                    String(
                        format: L(
                            "bvc.transferSkipped", "%d item(s) skipped (name already in use)"),
                        outcome.skipped.count))
            }
            let previous = self?.actionHistory.undoStack.last?.id
            completion(outcome)
            let latest = self?.actionHistory.undoStack.last?.id
            Self.recordActivity(
                move ? "move" : "copy", sources: urls, destination: destination,
                completed: outcome.performed.count, failures: outcome.failures,
                skipped: outcome.skipped.count, bytes: bytes, canceled: canceled,
                undo: latest == previous ? nil : latest)
        }
    }

    /// Drop any source that is the destination folder itself or an ancestor of it, so a transfer
    /// can never nest a folder inside its own subtree. Symlink-resolved and case-insensitive
    /// (the same comparison dropFiles used, hoisted here to cover every caller).
    static func dropSelfContaining(_ urls: [URL], destination: URL) -> [URL] {
        let destPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        return urls.filter {
            let src = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return destPath.compare(src, options: .caseInsensitive) != .orderedSame
                && !destPath.lowercased().hasPrefix(src.lowercased() + "/")
        }
    }

    func askConflictResolution(conflictCount: Int, move: Bool) async
        -> FileOperations.ConflictResolution?
    {
        let message =
            conflictCount == 1
            ? L("bvc.conflictOne", "1 item already exists at the destination")
            : String(
                format: L("bvc.conflictMany", "%d items already exist at the destination"),
                conflictCount)
        let info =
            Self.conflictActionHint(move: move)
            + " "
            + L("bvc.conflictBatch", "Your choice applies to all conflicts in this operation.")
        // A popover at the pointer, near the drop -- not a sheet at the title bar.
        let choice = await cursorConfirm.ask(
            message: message, info: info,
            buttons: [
                L("bvc.replaceAll", "Replace All"), L("bvc.keepBothAll", "Keep Both for All"),
                L("bvc.skipAll", "Skip All"), L("common.cancel", "Cancel"),
            ], defaultIndex: 1, cancelIndex: 3, over: view)
        switch choice {
        case 0: return .replace
        case 1: return .keepBoth
        case 2: return .skip
        default: return nil
        }
    }

    /// Ask how to resolve the `conflictCount` conflicts (if any), then run the transfer --
    /// centralizing the conflict prompt so the transfer flows don't each repeat the
    /// ask-then-run dance. With no conflicts the resolution is moot, so it runs straight away.
    func resolveThenTransfer(
        urls: [URL], into destination: URL, move: Bool, conflictCount: Int,
        completion: @escaping (FileOperations.Outcome) -> Void
    ) {
        guard !fileOperationBusy else { return }
        func run(_ resolution: FileOperations.ConflictResolution) {
            runTransfer(
                urls: urls, into: destination, move: move, resolution: resolution,
                completion: completion)
        }
        guard conflictCount > 0 else { return run(.skip) }
        // A non-Ask default (Settings > General) skips the prompt and resolves automatically.
        if let preset = prefs.conflictDefault.resolution { return run(preset) }
        fileConfirmationPending = true
        Task { @MainActor in
            defer { fileConfirmationPending = false }
            guard let chosen = await askConflictResolution(conflictCount: conflictCount, move: move)
            else {
                return  // user cancelled
            }
            fileConfirmationPending = false  // atomic handoff to runTransfer on the main actor
            run(chosen)
        }
    }

    func registerUndo(_ performed: [FileOperations.Performed], actionName: String) {
        let paths = Self.paths(of: performed)
        actionHistory.record(name: actionName, footprint: paths, undoFootprint: paths) {
            [weak self] in
            guard let self else { return }
            let result = FileOperations.undo(performed)
            self.reloadBothSides()
            if !result.failures.isEmpty {
                self.presentFailures(result.failures, title: L("bvc.undoFailed", "Undo failed"))
            }
            // A refused/failed inverse must not become a Redo against a file
            // that never moved back. Keep only the successful forward-ordered set.
            if !result.performed.isEmpty {
                self.registerTransferRedo(result.performed, actionName: actionName)
            }
        }
    }

    private func registerTransferRedo(_ performed: [FileOperations.Performed], actionName: String) {
        let paths = Self.paths(of: performed)
        actionHistory.record(name: actionName, footprint: paths, undoFootprint: paths) {
            [weak self] in
            guard let self else { return }
            let result = FileOperations.redo(performed)
            self.reloadBothSides()
            if !result.failures.isEmpty {
                self.presentFailures(result.failures, title: L("bvc.redoFailed", "Redo failed"))
            }
            // Re-register undo for exactly what redo re-applied, with the fresh trash locations
            // redo recorded for any Replace. Using the stale original list would trash the wrong
            // file on the next undo when a replace was involved or an op failed.
            if !result.performed.isEmpty {
                self.registerUndo(result.performed, actionName: actionName)
            }
        }
    }

    /// A focused text field (inline rename) owns its own undo via the window's field editor;
    /// let it undo text first, else undo a file operation from the history.
    var isEditingText: Bool { view.window?.firstResponder is NSText }

    @objc func undo(_ sender: Any?) {
        if isEditingText, let um = view.window?.undoManager, um.canUndo {
            um.undo()
            return
        }
        guard actionHistory.canUndo else {
            NSSound.beep()
            return
        }
        actionHistory.undo()
    }

    @objc func redo(_ sender: Any?) {
        if isEditingText, let um = view.window?.undoManager, um.canRedo {
            um.redo()
            return
        }
        guard actionHistory.canRedo else {
            NSSound.beep()
            return
        }
        actionHistory.redo()
    }

    /// Open the recent-actions panel (Undo History) over the file-operation history.
    func showUndoHistory() {
        guard let window = view.window else { return }
        undoHistoryController.present(over: window, history: actionHistory)
    }
}
