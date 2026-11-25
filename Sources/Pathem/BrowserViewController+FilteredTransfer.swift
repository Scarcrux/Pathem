import AppKit
import PathemEngine

// Copy / Move / Trash Matching: the filter sheet, then the existing transfer, undo and Trash
// paths. The sheet is the confirmation for a trash (no second prompt), the Trash is never emptied,
// and the undo for a copy or move is the same entry a plain F5/F6 registers.
@MainActor
extension BrowserViewController {
    static var filterPresetsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("filter-presets.json")
    }

    /// Open the filter sheet for the active pane's selection (or, with nothing selected, the
    /// whole folder) and run `action` on what matches.
    func showFilteredTransfer(_ action: FilteredTransferSheet.Action) {
        if blockedByRemote() { return }
        guard !fileOperationBusy, let window = view.window, let pane = activePane else {
            NSSound.beep()
            return
        }
        var destination: PaneController?
        if action != .trash {
            guard let other = otherPane, !other.isRemote else {
                NSSound.beep()
                return
            }
            destination = other
        }
        var sources = pane.selectedLocalURLs()
        if sources.isEmpty {
            sources = pane.entries.map { pane.currentURL.appendingPathComponent($0.name) }
        }
        guard !sources.isEmpty else {
            NSSound.beep()
            return
        }
        filteredSheet.present(
            over: window, action: action, sources: sources,
            destinationName: destination?.currentURL.lastPathComponent,
            presetsURL: Self.filterPresetsURL
        ) { [weak self, weak pane] spec, result in
            guard let self, let pane else { return }
            let urls = result.matches.map(\.url)
            switch action {
            case .trash:
                self.performLocalTrash(urls)
            case .copy, .move:
                guard let destination else { return }
                self.runFilteredTransfer(
                    result.matches, spec: spec, move: action == .move, from: pane, to: destination)
            }
        }
    }

    /// Run the placement groups one after another (each is a normal off-main transfer with its
    /// own progress sheet), resolving name clashes once up front, then register one undo.
    private func runFilteredTransfer(
        _ matches: [FileFilterEnumerator.Match], spec: FileFilterSpec, move: Bool,
        from source: PaneController, to destination: PaneController
    ) {
        let root = destination.currentURL
        let groups = FileFilterPlan.groups(
            for: matches, into: root, keepStructure: spec.keepStructure)
        let conflictCount = groups.filter { !$0.keepBoth }.reduce(0) {
            $0 + FileOperations.conflicts(urls: $1.urls, into: $1.directory).count
        }
        let actionName = move ? L("bvc.moveAction", "Move") : L("bvc.copyAction", "Copy")

        func run(_ resolution: FileOperations.ConflictResolution) {
            var performed: [FileOperations.Performed] = []
            var failures: [FileOperations.Failure] = []
            func next(_ index: Int) {
                guard index < groups.count else {
                    if move { source.reloadIfShowingListing() }
                    destination.reloadIfShowingListing()
                    if move { self.pruneSmartEntries(Set(performed.map(\.source.path))) }
                    if !performed.isEmpty { self.registerUndo(performed, actionName: actionName) }
                    if !failures.isEmpty {
                        self.presentFailures(
                            failures,
                            title: move
                                ? L("bvc.moveFailed", "Move failed")
                                : L("bvc.copyFailed", "Copy failed"))
                    }
                    return
                }
                let group = groups[index]
                // Folders are made only now, for groups that have a matched file to put in them.
                try? FileManager.default.createDirectory(
                    at: group.directory, withIntermediateDirectories: true)
                self.runTransfer(
                    urls: group.urls, into: group.directory, move: move,
                    resolution: group.keepBoth ? .keepBoth : resolution
                ) { outcome in
                    performed += outcome.performed
                    failures += outcome.failures
                    next(index + 1)
                }
            }
            next(0)
        }

        guard conflictCount > 0 else { return run(.skip) }
        if let preset = prefs.conflictDefault.resolution { return run(preset) }
        fileConfirmationPending = true
        Task { @MainActor in
            defer { fileConfirmationPending = false }
            guard let chosen = await askConflictResolution(conflictCount: conflictCount, move: move)
            else { return }
            fileConfirmationPending = false
            run(chosen)
        }
    }
}

#if DEBUG
extension BrowserViewController {
    /// PATHEM_FILTER_SHOT: open Copy Matching over the demo Downloads folder, preview a filter,
    /// render the sheet, run the copy into the other pane (demo Photos) and report what landed.
    func runFilterShot(into directory: String, done: @escaping () -> Void) {
        guard let pane = activePane, let other = otherPane else { return done() }
        let source = pane.currentURL
        let target = other.currentURL
        showFilteredTransfer(.copy)
        let sheet = filteredSheet
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            sheet.debugSet(include: "*.pdf; *.zip; *.dmg", exclude: "Inter*")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            print("FILTERSHEET ready=\(sheet.debugPreviewReady) summary=\(sheet.debugSummary)")
            sheet.debugRender(to: directory + "/filter-sheet.png")
            sheet.debugRun()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            let fm = FileManager.default
            for name in [
                "Invoice 1042.pdf", "Statement October.pdf", "dataset.zip", "Pathem-1.0.dmg",
                "Inter-4.1.zip",
            ] {
                print(
                    "FILTERSHEET copied \(name)=\(fm.fileExists(atPath: target.appendingPathComponent(name).path)) source=\(fm.fileExists(atPath: source.appendingPathComponent(name).path))"
                )
            }
            done()
        }
    }
}
#endif
