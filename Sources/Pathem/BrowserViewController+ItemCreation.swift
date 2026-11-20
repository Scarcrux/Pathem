import AppKit
import PathemEngine

extension Preferences {
    var effectiveNewFolderName: String {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == Self.default.newFolderName
            ? L("bvc.untitledFolder", "untitled folder") : name
    }

    var effectiveNewFileName: String {
        let name = newFileName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == Self.default.newFileName
            ? L("bvc.untitledFile", "untitled file") : name
    }
}

// Item creation: New Folder / New Folder with Selection / New File, batch-create,
// create-templates, and running a macOS Shortcut on the selection, plus their
// undo/redo registration helpers. Split out of BrowserViewController.
@MainActor
extension BrowserViewController {
    func newFolder() {
        guard let pane = activePane else { return }
        if pane.isShowingSmartResults {
            NSSound.beep()
            return
        }  // no single destination
        if pane.isRemote {
            Task { @MainActor in
                guard
                    let name = await self.promptForName(
                        title: L("bvc.newFolderPrompt", "New Folder"),
                        default: self.prefs.effectiveNewFolderName)
                else { return }
                self.performRemoteOp(pane, verb: L("bvc.newFolderVerb", "New Folder")) {
                    provider, connection, path, password in
                    try await provider.makeDirectory(
                        connection, path: PaneController.joinRemote(path, name), password: password)
                }
            }
            return
        }
        do {
            let name = try FileOperations.makeFolder(
                in: pane.currentURL, baseName: prefs.effectiveNewFolderName)
            pane.reloadIfShowingListing()
            // Select it once the (off-main) listing lands, then offer to name it right away, the way
            // Finder drops you straight into renaming a new folder.
            pane.selectWhenListed(name) { [weak self] in self?.renameSelection() }
            registerNewItemUndo(
                name: name, in: pane.currentURL, actionName: L("bvc.newFolderVerb", "New Folder"))
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

    /// Move the current selection into a fresh folder here, in one undoable action (Finder's
    /// Ctrl-Cmd-N "New Folder with Selection"). Falls back to a plain New Folder when nothing
    /// is selected.
    func newFolderWithSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let names = pane.selectedEntries.map(\.name)
        guard !names.isEmpty else {
            newFolder()
            return
        }
        let directory = pane.currentURL
        do {
            let folderName = try FileOperations.makeFolder(
                in: directory, baseName: L("bvc.newFolderWithItems", "New Folder With Items"))
            let outcome = FileOperations.move(
                names, from: directory, to: directory.appendingPathComponent(folderName),
                onConflict: .keepBoth)
            pane.reloadIfShowingListing()
            // Same as New Folder: select it once the async listing lands, then offer to name it.
            pane.selectWhenListed(folderName) { [weak self] in self?.renameSelection() }
            registerFolderWithSelectionUndo(
                folderName: folderName, in: directory, moved: outcome.performed)
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

    /// Undo of New Folder with Selection: move the items back out, then trash the emptied folder.
    private func registerFolderWithSelectionUndo(
        folderName: String, in directory: URL, moved: [FileOperations.Performed]
    ) {
        let paths = Self.paths(of: moved).union([directory.appendingPathComponent(folderName).path])
        actionHistory.record(
            name: L("bvc.newFolderWithSelectionAction", "New Folder with Selection"),
            footprint: paths, undoFootprint: paths
        ) { [weak self] in
            guard let self else { return }
            FileOperations.undo(moved)  // items back to their original spot in `directory`
            let trash = FileOperations.trash([folderName], in: directory)  // remove the now-empty folder
            self.reloadBothSides()
            if !trash.failures.isEmpty {
                self.presentFailures(trash.failures, title: L("bvc.undoFailed", "Undo failed"))
            }
            self.registerFolderWithSelectionRedo(
                folderName: folderName, in: directory, moved: moved)
        }
    }

    private func registerFolderWithSelectionRedo(
        folderName: String, in directory: URL, moved: [FileOperations.Performed]
    ) {
        let paths = Self.paths(of: moved).union([directory.appendingPathComponent(folderName).path])
        actionHistory.record(
            name: L("bvc.newFolderWithSelectionAction", "New Folder with Selection"),
            footprint: paths, undoFootprint: paths
        ) { [weak self] in
            guard let self else { return }
            let folderURL = directory.appendingPathComponent(folderName)
            try? FileManager.default.createDirectory(
                at: folderURL, withIntermediateDirectories: true)
            let names = moved.map { $0.source.lastPathComponent }
            let outcome = FileOperations.move(
                names, from: directory, to: folderURL, onConflict: .keepBoth)
            self.reloadBothSides()
            self.registerFolderWithSelectionUndo(
                folderName: folderName, in: directory, moved: outcome.performed)
        }
    }

    /// Create a new empty file (local panes only); the Finder pain point this app fixes.
    func newFile() {
        guard let pane = activePane else { return }
        if pane.isShowingSmartResults || pane.isRemote {
            NSSound.beep()
            return
        }
        do {
            let name = try FileOperations.makeFile(
                in: pane.currentURL, baseName: prefs.effectiveNewFileName)
            pane.reloadIfShowingListing()
            // Select it once the (off-main) listing lands, then offer to name it right away, like
            // New Folder does -- a plain select(name:) here is a no-op, since the row doesn't exist
            // yet. (applyPendingAfterListing then drops the redundant watcher reload so the inline
            // rename isn't cancelled the instant it begins.)
            pane.selectWhenListed(name) { [weak self, weak pane] in
                guard let self, let pane, self.activePane === pane else { return }
                // An empty new file has no contents to name. Preserve its immediate inline
                // editor instead of opening a modal AI sheet that also blocks later shortcuts.
                self.renameSelection(suggestions: false)
            }
            registerNewItemUndo(
                name: name, in: pane.currentURL, actionName: L("bvc.cmd.newFile", "New File"))
        } catch {
            presentFailures(
                [
                    FileOperations.Failure(
                        name: L("bvc.cmd.newFile", "New File"), reason: error.localizedDescription)
                ],
                title: L("bvc.couldntCreateFile", "Couldn’t create file"))
        }
    }

    // MARK: - Batch create + templates

    private static var templatesURL: URL? {
        appSupportDirectory()?.appendingPathComponent("create-templates.json")
    }

    func loadTemplates() {
        createTemplates = loadConfig([CreateTemplate].self, from: Self.templatesURL) ?? []
        registerTemplateCommands()
    }

    private func saveTemplates() {
        saveConfig(createTemplates, to: Self.templatesURL)
        registerTemplateCommands()
    }

    /// Register one command per template (and drop deleted ones) so each appears in
    /// the command palette and is bindable in Settings > Shortcuts.
    private func registerTemplateCommands() {
        for command in commands.all where command.id.hasPrefix("create.template.") {
            commands.unregister(command.id)
        }
        for template in createTemplates {
            commands.register(
                .init(
                    id: "create.template.\(template.id)",
                    title: String(format: L("templates.commandTitle", "New: %@"), template.name),
                    isEnabled: { [weak self] in
                        guard let pane = self?.activePane else { return false }
                        return !pane.isRemote && !pane.isShowingSmartResults
                    },
                    run: { [weak self] in self?.runTemplate(template) }))
        }
    }

    // MARK: - macOS Shortcuts (run a Shortcut on the selection)

    /// List installed shortcuts (off-main), then pick one and run it on the selection.
    func showShortcutPicker() {
        guard view.window != nil else { return }
        Task { @MainActor in
            let names = await Task.detached { ShortcutsRunner.list() }.value
            guard !names.isEmpty else {
                self.presentInfo(
                    L("shortcut.noneTitle", "No Shortcuts found"),
                    L(
                        "shortcut.noneBody",
                        "Create shortcuts in the Shortcuts app first (or the Shortcuts tool is unavailable)."
                    ))
                return
            }
            let (alert, popup) = Self.makeShortcutDialog(names: names)
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            self.runShortcut(names[popup.indexOfSelectedItem])
        }
    }

    private func runShortcut(_ name: String) {
        let files = activePane?.selectedLocalURLs() ?? []
        externalOutput.run(title: String(format: L("shortcut.title", "Shortcut: %@"), name)) {
            ShortcutsRunner.runOnFiles(name: name, files: files)
        }
    }

    func showBatchCreate() {
        guard let window = view.window, let pane = activePane, !pane.isRemote,
            !pane.isShowingSmartResults
        else {
            NSSound.beep()
            return
        }
        let folder = pane.currentURL
        batchCreate.present(
            over: window,
            create: { [weak self] names, kind in self?.runBatchCreate(names, kind: kind, in: folder)
            },
            saveTemplate: { [weak self] names, kind in self?.saveBatchAsTemplate(names, kind: kind)
            })
    }

    private func runBatchCreate(_ names: [String], kind: BatchCreate.Kind, in folder: URL) {
        let result = BatchCreate.create(names, kind: kind, in: folder)
        reloadBothSides()
        if let first = result.created.first { paneShowing(folder)?.select(name: first) }
        registerCreatedUndo(
            names: result.created, in: folder, actionName: L("batch.actionName", "Batch Create"))
        if !result.failures.isEmpty {
            presentFailures(
                result.failures, title: L("batch.someFailed", "Some items couldn’t be created"))
        }
    }

    private func saveBatchAsTemplate(_ names: [String], kind: BatchCreate.Kind) {
        Task { @MainActor in
            guard
                let name = await self.promptForName(
                    title: L("batch.saveTemplateTitle", "Save as Template"),
                    default: L("batch.templateDefaultName", "My Template"))
            else { return }
            let entries = names.map { kind == .folders ? "\($0)/" : $0 }
            self.createTemplates.append(
                CreateTemplate(id: UUID().uuidString, name: name, entries: entries))
            self.saveTemplates()
        }
    }

    func showTemplatesManager() {
        guard let window = view.window else { return }
        templatesManager.present(
            over: window, templates: createTemplates,
            onChange: { [weak self] templates in
                self?.createTemplates = templates
                self?.saveTemplates()
            },
            onRun: { [weak self] template in self?.runTemplate(template) })
    }

    private func runTemplate(_ template: CreateTemplate) {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else {
            NSSound.beep()
            return
        }
        let folder = pane.currentURL
        let result = template.instantiate(in: folder)
        reloadBothSides()
        if let first = result.created.first { paneShowing(folder)?.select(name: first) }
        registerCreatedUndo(
            names: result.created, in: folder,
            actionName: L("templates.actionName", "New from Template"))
        if !result.failures.isEmpty {
            presentFailures(
                result.failures, title: L("batch.someFailed", "Some items couldn’t be created"))
        }
    }

    /// Undo support for a set of freshly-created items: trashing them reverses it.
    func registerCreatedUndo(names: [String], in directory: URL, actionName: String) {
        guard !names.isEmpty else { return }
        let paths = Self.paths(names, in: directory)
        actionHistory.record(name: actionName, footprint: paths, undoFootprint: paths) {
            [weak self] in
            guard let self else { return }
            let result = FileOperations.trash(names, in: directory)
            self.reloadBothSides()
            if !result.failures.isEmpty {
                self.presentFailures(result.failures, title: L("bvc.undoFailed", "Undo failed"))
            }
            if !result.trashed.isEmpty {
                self.registerCreatedRedo(
                    names: names, in: directory, trashed: result.trashed, actionName: actionName)
            }
        }
    }

    private func registerCreatedRedo(
        names: [String], in directory: URL, trashed: [FileOperations.Trashed], actionName: String
    ) {
        let paths = Self.paths(names, in: directory)
        actionHistory.record(name: actionName, footprint: paths, undoFootprint: paths) {
            [weak self] in
            guard let self else { return }
            let result = FileOperations.untrash(trashed)
            self.reloadBothSides()
            if !result.failures.isEmpty {
                self.presentFailures(result.failures, title: L("bvc.redoFailed", "Redo failed"))
            }
            // An occupied original path causes untrash to choose a new name.
            // Never let the next Undo trash the unrelated occupant of the old name.
            let restoredNames = result.restored.map(\.lastPathComponent)
            if let first = restoredNames.first { self.paneShowing(directory)?.select(name: first) }
            self.registerCreatedUndo(names: restoredNames, in: directory, actionName: actionName)
        }
    }

    private func registerNewItemUndo(name: String, in directory: URL, actionName: String) {
        registerCreatedUndo(names: [name], in: directory, actionName: actionName)
    }
}

@MainActor
extension BrowserViewController {
    /// Production construction shared with isolated transient checks.
    static func makeShortcutDialog(names: [String]) -> (NSAlert, NSPopUpButton) {
        let alert = NSAlert()
        alert.messageText = L("shortcut.pickTitle", "Run Shortcut on Selection")
        alert.informativeText = L(
            "shortcut.pickBody", "The chosen shortcut runs once per selected file.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        popup.addItems(withTitles: names)
        alert.accessoryView = popup
        alert.addButton(withTitle: L("shortcut.run", "Run"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        return (alert, popup)
    }
}
