import AppKit
import PathemEngine

// Command / selection overlays: the command-and-search palette, the batch-rename sheet, and
// select-by-pattern. Split out of BrowserViewController to shrink the god-object (5.1).
extension BrowserViewController {
    /// Open the command/semantic overlay over the current window. `prefill` picks the
    /// opening mode: "" is explicitly requested semantic search, ">" is commands (Cmd-K); it's one
    /// widget and the prefix switches modes mid-flight. Chosen commands dispatch through
    /// the registry; search queries rank the active pane live.
    func showPalette(prefill: String = ">") {
        guard let window = view.window else { return }
        let items = commands.all.map { (id: $0.id, title: $0.title) }
        palette.present(
            commands: items,
            keywords: Dictionary(
                commands.all.filter { !$0.keywords.isEmpty }.map { ($0.id, $0.keywords) },
                uniquingKeysWith: { first, _ in first }),
            prefill: prefill,
            onRun: { [weak self] id in self?.commands.perform(id) },
            onNavigate: { [weak self] url in self?.activePane?.navigate(to: url) },
            onSemantic: { [weak self] query in self?.performSearch(query) },
            over: window)
    }

    /// Open the batch-rename sheet for the active pane's selection.
    func showBatchRename() {
        if blockedByRemoteOrSmart() { return }  // operates within one folder
        guard let window = view.window, let pane = activePane else { return }
        let names = pane.selectedEntries.map(\.name)
        guard !names.isEmpty else {
            NSSound.beep()
            return
        }
        let existing = Set(pane.entries.map(\.name))
        let directory = pane.currentURL
        batchRename.present(names: names, in: directory, existing: existing, over: window) {
            [weak self, weak pane] performed in
            pane?.reloadIfShowingListing()
            self?.registerBatchRenameUndo(performed, in: directory)
        }
    }

    private func registerBatchRenameUndo(_ performed: [RenamePair], in directory: URL) {
        guard !performed.isEmpty else { return }
        let inverse = performed.map { RenamePair(original: $0.renamed, renamed: $0.original) }
        let paths = Set(
            performed.flatMap {
                [
                    directory.appendingPathComponent($0.original).path,
                    directory.appendingPathComponent($0.renamed).path,
                ]
            })
        actionHistory.record(
            name: L("rename.panelTitle", "Batch Rename"), footprint: paths, undoFootprint: paths
        ) { [weak self] in
            guard let self else { return }
            let outcome = BatchRename.perform(in: directory, pairs: inverse)
            self.reloadBothSides()
            self.registerBatchRenameUndo(outcome.performed, in: directory)
            if !outcome.failures.isEmpty {
                self.presentInfo(
                    L("rename.panelTitle", "Batch Rename"),
                    outcome.failures.prefix(8).joined(separator: "\n"))
            }
        }
    }

    /// Select items in the active pane by a name pattern (glob / regex / substring),
    /// replacing, extending, or trimming the current selection.
    func selectByPattern() {
        guard let pane = activePane, let window = view.window else {
            NSSound.beep()
            return
        }
        SelectByPatternSheet.present(over: window) { query, mode in
            pane.applySelection(query, mode: mode)
        }
    }

    /// Deselect items in the active pane by a name pattern (the same sheet, subtract only).
    func deselectByPattern() {
        guard let pane = activePane, let window = view.window else {
            NSSound.beep()
            return
        }
        SelectByPatternSheet.present(over: window, deselect: true) { query, _ in
            pane.applySelection(query, mode: .subtract)
        }
    }

    /// The Edit > Select commands that need only the active pane's listing.
    enum SelectCommand { case invert, allFiles, allFolders, sameExtension, sameKind }

    func runSelectCommand(_ command: SelectCommand) {
        guard let pane = activePane else { return }
        let entries = pane.entries
        let focus = pane.selectedEntries.last
        let names: Set<String>
        switch command {
        case .invert:
            names = SelectionCommands.invert(
                entries, selected: Set(pane.selectedEntries.map(\.name)))
        case .allFiles: names = SelectionCommands.allFiles(entries)
        case .allFolders: names = SelectionCommands.allFolders(entries)
        case .sameExtension:
            guard let focus else { return NSSound.beep() }
            names = SelectionCommands.sameExtension(as: focus, in: entries)
        case .sameKind:
            guard let focus else { return NSSound.beep() }
            names = SelectionCommands.sameKind(as: focus, in: entries)
        }
        pane.selectEntries(named: names)
        reportSelectionResult(pane, count: names.count)
    }

    /// Select Unique / Newer / Different against the other pane, naming files the way the
    /// volume does (case and Unicode normalization from `BatchRename`).
    func compareSelect(_ mode: SelectionCommands.Comparison) {
        guard let pane = activePane, let other = otherPane, other !== pane else {
            NSSound.beep()
            return
        }
        let caseSensitive =
            pane.isRemote || BatchRename.supportsCaseSensitiveNames(in: pane.currentURL)
        let names = SelectionCommands.compare(
            mode, pane.entries, with: other.entries, caseSensitive: caseSensitive)
        pane.selectEntries(named: names)
        reportSelectionResult(pane, count: names.count)
    }

    private func reportSelectionResult(_ pane: PaneController, count: Int) {
        pane.flashStatus(
            count == 1
                ? L("select.resultOne", "1 item selected")
                : String(format: L("select.resultMany", "%d items selected"), count))
    }
}
