import AppKit
import PathemEngine

// The file-onto-file drop menu: dropping items onto another file (not a folder, not blank space) is
// otherwise meaningless, so it pops a small menu offering the things you'd actually want -- move/copy
// here, group them into a new folder, archive them together, or replace the target.
@MainActor
extension BrowserViewController {
    func showDropOntoFileMenu(dragged: [URL], target: URL) {
        withDropOntoFileMenu(dragged: dragged, target: target) { popUpAtPointer($0) }
    }

    /// Keep construction and the tracking lifetime together; tests use the same menu
    /// and handlers without needing a foreground native menu tracking loop.
    func withDropOntoFileMenu(dragged: [URL], target: URL, present: (NSMenu) -> Void) {
        guard !dragged.isEmpty else { return }
        pendingDropContext = (dragged, target)
        defer { pendingDropContext = nil }  // Escape, outside click and Cancel all end tracking.
        let menu = NSMenu()
        menu.addItem(dropItem(L("drop.moveHere", "Move Here"), #selector(dropMoveHere)))
        menu.addItem(dropItem(L("drop.copyHere", "Copy Here"), #selector(dropCopyHere)))
        menu.addItem(.separator())
        menu.addItem(
            dropItem(L("drop.newFolder", "New Folder with Items"), #selector(dropNewFolder)))
        menu.addItem(dropItem(L("drop.archive", "Create Archive"), #selector(dropArchive)))
        if dragged.count == 1 {
            menu.addItem(
                dropItem(
                    String(format: L("drop.replace", "Replace “%@”"), target.lastPathComponent),
                    #selector(dropReplace)))
        }
        menu.addItem(.separator())
        menu.addItem(dropItem(L("common.cancel", "Cancel"), nil))
        present(menu)
    }

    private func dropItem(_ title: String, _ action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func popUpAtPointer(_ menu: NSMenu) {
        guard let window = view.window else { return }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        menu.popUp(positioning: nil, at: view.convert(inWindow, from: nil), in: view)
    }

    private var dropFolder: URL? { pendingDropContext?.target.deletingLastPathComponent() }

    @objc private func dropMoveHere() {
        guard let (dragged, target) = pendingDropContext else { return }
        dropFiles(dragged, move: true, into: target.deletingLastPathComponent())
    }

    @objc private func dropCopyHere() {
        guard let (dragged, target) = pendingDropContext else { return }
        dropFiles(dragged, move: false, into: target.deletingLastPathComponent())
    }

    /// Group the dragged items and the target into a fresh folder here.
    @objc private func dropNewFolder() {
        guard let (dragged, target) = pendingDropContext else { return }
        let folder = target.deletingLastPathComponent()
        do {
            let name = try FileOperations.makeFolder(
                in: folder, baseName: L("bvc.newFolderWithItems", "New Folder With Items"))
            let newFolder = folder.appendingPathComponent(name)
            let outcome = FileOperations.move(
                urls: dragged + [target], into: newFolder, onConflict: .keepBoth,
                shouldCancel: { false }, report: { _ in })
            reloadBothSides()
            activePane?.select(name: name)
            if !outcome.performed.isEmpty {
                registerUndo(
                    outcome.performed,
                    actionName: L("bvc.newFolderWithSelectionAction", "New Folder with Selection"))
            }
            if !outcome.failures.isEmpty {
                presentFailures(
                    outcome.failures,
                    title: L("bvc.moveIntoFolderFailed", "Couldn’t move some items into the folder")
                )
            }
        } catch {
            presentFailures(
                [
                    FileOperations.Failure(
                        name: L("bvc.newFolderVerb", "New Folder"),
                        reason: error.localizedDescription)
                ],
                title: L("bvc.couldntCreateFolder", "Couldn’t create folder"))
        }
    }

    /// Zip the dragged items and the target together into a .zip here.
    @objc private func dropArchive() {
        guard let (dragged, target) = pendingDropContext else { return }
        let folder = target.deletingLastPathComponent()
        let items = dragged + [target]
        let dest = uniqueLocalURL(folder.appendingPathComponent("Archive.zip"))
        Task { @MainActor [weak self] in
            do {
                try await Archiver.compressItems(items, to: dest)  // handles items from different folders
                self?.reloadBothSides()
                self?.activePane?.select(name: dest.lastPathComponent)
            } catch {
                self?.reportArchiveError(
                    L("bvc.couldntCreateArchive", "Couldn’t create the archive"), error)
            }
        }
    }

    /// Replace the target file with the single dragged one (the target goes to the Trash and the
    /// dragged item takes its name and place). Rolls back if the move fails so a failed replace
    /// never leaves the target stranded in the Trash, guards against a concurrent transfer, and
    /// registers an undo that restores both files.
    @objc private func dropReplace() {
        guard let (dragged, target) = pendingDropContext, let source = dragged.first else { return }
        guard !transferInFlight else {
            NSSound.beep()
            return
        }
        let fm = FileManager.default
        var landed: NSURL?
        do {
            try fm.trashItem(at: target, resultingItemURL: &landed)
        } catch {
            presentFailures(
                [
                    FileOperations.Failure(
                        name: target.lastPathComponent, reason: error.localizedDescription)
                ],
                title: L("drop.replaceFailed", "Couldn’t replace the file"))
            return
        }
        do {
            try fm.moveItem(at: source, to: target)  // dragged takes the target's name/place
        } catch {
            if let trashed = landed as URL? { try? fm.moveItem(at: trashed, to: target) }  // restore the target
            presentFailures(
                [
                    FileOperations.Failure(
                        name: target.lastPathComponent, reason: error.localizedDescription)
                ],
                title: L("drop.replaceFailed", "Couldn’t replace the file"))
            return
        }
        reloadBothSides()
        activePane?.select(name: target.lastPathComponent)
        // Undo: put the dragged item back where it came from, and restore the original target from
        // the Trash. Only offered while the trashed original is still recoverable.
        if let trashed = landed as URL? {
            let footprint: Set<String> = [source.path, target.path, trashed.path]
            actionHistory.record(
                name: L("drop.replaceAction", "Replace"), footprint: footprint,
                undoFootprint: footprint
            ) { [weak self] in
                guard let self else { return }
                do {
                    try fm.moveItem(at: target, to: source)  // dragged back to its origin
                    try fm.moveItem(at: trashed, to: target)  // original restored from Trash
                    self.reloadBothSides()
                } catch {
                    self.presentFailures(
                        [
                            FileOperations.Failure(
                                name: target.lastPathComponent, reason: error.localizedDescription)
                        ],
                        title: L("bvc.undoFailed", "Undo failed"))
                }
            }
        }
    }
}
