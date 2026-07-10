import AppKit
import PathemEngine

// The file-onto-file drop menu: dropping items onto another file (not a folder, not blank space) is
// otherwise meaningless, so it pops a small menu offering the things you'd actually want -- move/copy
// here, group them into a new folder, archive them together, or replace the target.
@MainActor
extension BrowserViewController {
    func showDropOntoFileMenu(dragged: [URL], target: URL) {
        guard !dragged.isEmpty else { return }
        pendingDropContext = (dragged, target)
        let menu = NSMenu()
        menu.addItem(dropItem(L("drop.moveHere", "Move Here"), #selector(dropMoveHere)))
        menu.addItem(dropItem(L("drop.copyHere", "Copy Here"), #selector(dropCopyHere)))
        menu.addItem(.separator())
        menu.addItem(dropItem(L("drop.newFolder", "New Folder with Items"), #selector(dropNewFolder)))
        menu.addItem(dropItem(L("drop.archive", "Create Archive"), #selector(dropArchive)))
        if dragged.count == 1 {
            menu.addItem(dropItem(
                String(format: L("drop.replace", "Replace “%@”"), target.lastPathComponent), #selector(dropReplace)))
        }
        menu.addItem(.separator())
        menu.addItem(dropItem(L("common.cancel", "Cancel"), nil))
        popUpAtPointer(menu)
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
                registerUndo(outcome.performed, actionName: L("bvc.newFolderWithSelectionAction", "New Folder with Selection"))
            }
            if !outcome.failures.isEmpty {
                presentFailures(outcome.failures, title: L("bvc.moveIntoFolderFailed", "Couldn’t move some items into the folder"))
            }
        } catch {
            presentFailures(
                [FileOperations.Failure(name: L("bvc.newFolderVerb", "New Folder"), reason: error.localizedDescription)],
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
                self?.reportArchiveError(L("bvc.couldntCreateArchive", "Couldn’t create the archive"), error)
            }
        }
    }

    /// Replace the target file with the single dragged one (the target goes to the Trash).
    @objc private func dropReplace() {
        guard let (dragged, target) = pendingDropContext, let source = dragged.first else { return }
        do {
            try FileManager.default.trashItem(at: target, resultingItemURL: nil)
            try FileManager.default.moveItem(at: source, to: target)  // dragged takes the target's name/place
            reloadBothSides()
            activePane?.select(name: target.lastPathComponent)
        } catch {
            presentFailures(
                [FileOperations.Failure(name: target.lastPathComponent, reason: error.localizedDescription)],
                title: L("drop.replaceFailed", "Couldn’t replace the file"))
        }
    }
}
