#if DEBUG
import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    /// Mandatory part of sidebar-transfer E2E: a real window, private clipboard,
    /// disposable files/config, and the production history/transfer entry points.
    func checkFileSafety(
        root: URL, check: (String, Bool) -> Void, settle: (() -> Bool) -> Bool
    ) {
        let fm = FileManager.default
        guard let pane = leftTabs.activePane, let window = view.window else {
            check("safety-window", false)
            return
        }
        func dismissOwnSheets() {
            for sheet in window.sheets {
                window.endSheet(sheet)
                sheet.orderOut(nil)
            }
        }
        func bytes(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
        func write(_ value: String, to url: URL) throws { try Data(value.utf8).write(to: url) }
        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func focus(_ directory: URL, names: [String]) -> Bool {
            pane.navigate(to: directory)
            guard settle({ names.allSatisfy { pane.debugHasEntry($0) } }) else { return false }
            activePane = pane
            activeSide = leftTabs
            window.makeFirstResponder(pane.keyView)
            pane.debugSelectNames(names)
            return true
        }
        func cutFiles(_ directory: URL, names: [String]) -> Bool {
            guard focus(directory, names: names) else { return false }
            cut(nil)
            return FileDrag.readFileURLs(from: filePasteboard)?.count == names.count
                && cutPaths.count == names.count
                && filePasteboard.data(forType: Self.cutPasteboardType) != nil
        }
        func clipboardNames() -> Set<String> {
            Set((FileDrag.readFileURLs(from: filePasteboard) ?? []).map(\.lastPathComponent))
        }
        // The disjoint and prefix-sibling controls must stay independently undoable.
        for (label, older, newer, allowed) in [
            ("child", "/a/folder", "/a/folder/child", false),
            ("ancestor", "/a/folder/child", "/a/folder", false),
            ("equal", "/a/folder", "/a/folder", false),
            ("sibling-prefix", "/a/folder", "/a/folder2/child", true),
            ("disjoint", "/a", "/b", true),
            ("normalized", "/a/folder", "/a/other/../folder/child", false),
            ("root", "/", "/a/child", false),
            ("case", "/a/Folder", "/a/folder/child", false),
        ] {
            let history = ActionHistory()
            var executed = false
            history.record(name: "Older", footprint: [older], undoFootprint: [older]) {
                executed = true
            }
            history.record(name: "Newer", footprint: [newer], undoFootprint: [newer], perform: {})
            check("safety-selective-\(label)", history.isIndependentlyUndoable(at: 0) == allowed)
            check(
                "safety-selective-dispatch-\(label)",
                history.undo(at: 0) == allowed && executed == allowed)
        }
        do {
            // Both the batch-created and the real New File registration paths.
            for single in [false, true] {
                let directory = try folder("created-\(single)")
                let name = "created-\(UUID()).txt"
                let original = directory.appendingPathComponent(name)
                if single {
                    pane.navigate(to: directory)
                    activePane = pane
                    activeSide = leftTabs
                    prefs.newFileName = name
                    newFile()
                    check("safety-new-file-dispatched", settle { pane.debugHasEntry(name) })
                    window.makeFirstResponder(pane.keyView)
                    try write("CREATED", to: original)
                } else {
                    try write("CREATED", to: original)
                    registerCreatedUndo(names: [name], in: directory, actionName: "Create fixture")
                }
                actionHistory.undo()
                check("safety-created-undo-\(single)", !fm.fileExists(atPath: original.path))
                try write("UNRELATED", to: original)
                actionHistory.redo()
                dismissOwnSheets()
                let restored = try fm.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil
                )
                .first { bytes($0) == "CREATED" }
                check(
                    "safety-created-redo-\(single)",
                    restored != nil && bytes(original) == "UNRELATED")
                actionHistory.undo()
                dismissOwnSheets()
                check(
                    "safety-created-next-undo-\(single)",
                    bytes(original) == "UNRELATED"
                        && restored.map { !fm.fileExists(atPath: $0.path) } == true)
            }

            prefs.conflictDefault = .skip
            let source = try folder("clipboard-source")
            let destination = try folder("clipboard-dest")
            let moving = source.appendingPathComponent("moving.txt")
            let skipped = source.appendingPathComponent("skipped.txt")
            try write("MOVE", to: moving)
            try write("SKIP", to: skipped)
            try write("DESTINATION", to: destination.appendingPathComponent("skipped.txt"))
            check(
                "safety-partial-cut-delivered",
                cutFiles(source, names: ["moving.txt", "skipped.txt"]))
            pasteFiles(into: destination)
            check("safety-partial-completed", settle { !transferInFlight })
            check(
                "safety-partial-disk",
                !fm.fileExists(atPath: moving.path) && bytes(skipped) == "SKIP"
                    && bytes(destination.appendingPathComponent("moving.txt")) == "MOVE"
                    && bytes(destination.appendingPathComponent("skipped.txt")) == "DESTINATION")
            check(
                "safety-partial-retains-only-unmoved",
                clipboardNames() == ["skipped.txt"] && cutPaths == [skipped.path]
                    && filePasteboard.data(forType: Self.cutPasteboardType) != nil)

            check("safety-all-skipped-cut-delivered", cutFiles(source, names: ["skipped.txt"]))
            let skippedChangeCount = filePasteboard.changeCount
            pasteFiles(into: destination)
            check("safety-all-skipped-completed", settle { !transferInFlight })
            check(
                "safety-all-skipped-retains-clipboard",
                filePasteboard.changeCount == skippedChangeCount
                    && clipboardNames() == ["skipped.txt"] && cutPaths == [skipped.path])

            let retry = try folder("clipboard-retry")
            pasteFiles(into: retry)
            check("safety-retry-completed", settle { !transferInFlight })
            check(
                "safety-retry-moves-remaining",
                bytes(retry.appendingPathComponent("skipped.txt")) == "SKIP"
                    && !fm.fileExists(atPath: skipped.path) && cutPaths.isEmpty
                    && (filePasteboard.types ?? []).isEmpty)

            // No run-loop pumping between starting the transfer and replacing the
            // private clipboard: this guarantees the new owner precedes completion.
            let owned = source.appendingPathComponent("owned.txt")
            try write("OWNED", to: owned)
            check("safety-new-owner-cut-delivered", cutFiles(source, names: ["owned.txt"]))
            pasteFiles(into: destination)
            check("safety-new-owner-transfer-started", transferInFlight)
            filePasteboard.clearContents()
            filePasteboard.setString("NEW CLIPBOARD", forType: .string)
            let newerChangeCount = filePasteboard.changeCount
            check("safety-new-owner-completed", settle { !transferInFlight })
            check(
                "safety-new-owner-retained",
                filePasteboard.changeCount == newerChangeCount
                    && filePasteboard.string(forType: .string) == "NEW CLIPBOARD"
                    && bytes(destination.appendingPathComponent("owned.txt")) == "OWNED")

            // A failed move must retain its cut URLs so transient failures can be retried.
            let failing = source.appendingPathComponent("failing.txt")
            try write("FAILURE FIXTURE", to: failing)
            check("safety-failed-cut-delivered", cutFiles(source, names: ["failing.txt"]))
            let held = root.appendingPathComponent("held-failing.txt")
            try fm.moveItem(at: failing, to: held)
            let failureChangeCount = filePasteboard.changeCount
            pasteFiles(into: destination)
            check("safety-failed-transfer-completed", settle { !transferInFlight })
            dismissOwnSheets()
            check(
                "safety-failed-retains-cut",
                filePasteboard.changeCount == failureChangeCount
                    && clipboardNames() == ["failing.txt"] && cutPaths == [failing.path])
            try fm.moveItem(at: held, to: failing)

            let olderCut = source.appendingPathComponent("older-cut.txt")
            let newerCut = source.appendingPathComponent("newer-cut.txt")
            try write("OLDER", to: olderCut)
            try write("NEWER", to: newerCut)
            check("safety-new-cut-delivered", cutFiles(source, names: ["older-cut.txt"]))
            check("safety-new-cut-listing", pane.debugHasEntry("newer-cut.txt"))
            pasteFiles(into: destination)
            pane.debugSelectNames(["newer-cut.txt"])
            cut(nil)
            let newerCutCount = filePasteboard.changeCount
            check(
                "safety-new-cut-precedes-completion",
                transferInFlight && cutPaths == [newerCut.path])
            check("safety-new-cut-completed", settle { !transferInFlight })
            check(
                "safety-new-cut-retained",
                filePasteboard.changeCount == newerCutCount
                    && clipboardNames() == ["newer-cut.txt"] && cutPaths == [newerCut.path]
                    && bytes(destination.appendingPathComponent("older-cut.txt")) == "OLDER")

            // Use the real engine's cancellation outcome with the same production
            // completion helper. This tests bookkeeping, not clicking the Cancel sheet.
            let cancelSource = try folder("cancel-source")
            let cancelDestination = try folder("cancel-dest")
            let one = cancelSource.appendingPathComponent("one.txt")
            let two = cancelSource.appendingPathComponent("two.txt")
            try write("ONE", to: one)
            try write("TWO", to: two)
            check(
                "safety-cancel-cut-delivered",
                cutFiles(cancelSource, names: ["one.txt", "two.txt"]))
            let cancelCount = filePasteboard.changeCount
            let cancelled = FileOperations.move(
                urls: [one, two], into: cancelDestination, shouldCancel: { true })
            finishCutPaste(
                urls: [one, two], pasteboard: filePasteboard, changeCount: cancelCount,
                performed: cancelled.performed)
            check(
                "safety-cancel-before-first-retains-all",
                cancelled.performed.isEmpty
                    && filePasteboard.changeCount == cancelCount
                    && clipboardNames() == ["one.txt", "two.txt"]
                    && cutPaths == [one.path, two.path])
            let partlyCancelled = FileOperations.move(
                urls: [one, two], into: cancelDestination,
                shouldCancel: {
                    fm.fileExists(atPath: cancelDestination.appendingPathComponent("one.txt").path)
                })
            finishCutPaste(
                urls: [one, two], pasteboard: filePasteboard, changeCount: cancelCount,
                performed: partlyCancelled.performed)
            check(
                "safety-cancel-after-first-retains-remainder",
                partlyCancelled.performed.count == 1
                    && partlyCancelled.failures.isEmpty && clipboardNames() == ["two.txt"]
                    && cutPaths == [two.path] && bytes(two) == "TWO"
                    && bytes(cancelDestination.appendingPathComponent("one.txt")) == "ONE")
            pasteFiles(into: cancelDestination)
            check("safety-cancel-retry-completed", settle { !transferInFlight })
            check(
                "safety-cancel-retry-moves-remainder",
                bytes(cancelDestination.appendingPathComponent("two.txt")) == "TWO"
                    && !fm.fileExists(atPath: two.path) && cutPaths.isEmpty
                    && (filePasteboard.types ?? []).isEmpty)

            let undoA = try folder("blocked-undo/a").appendingPathComponent("same.txt")
            let undoB = try folder("blocked-undo/b").appendingPathComponent("same.txt")
            let undoDestination = try folder("blocked-undo/dest")
            try write("A", to: undoA)
            try write("B", to: undoB)
            let batch = FileOperations.move(
                urls: [undoA, undoB], into: undoDestination, onConflict: .replace)
            registerUndo(batch.performed, actionName: "Blocked undo fixture")
            try write("UNRELATED", to: undoB)
            actionHistory.undo()
            dismissOwnSheets()
            check(
                "safety-failed-dependent-undo-no-redo",
                !actionHistory.canRedo
                    && !fm.fileExists(atPath: undoA.path) && bytes(undoB) == "UNRELATED"
                    && bytes(undoDestination.appendingPathComponent("same.txt")) == "B")
        } catch {
            check("safety-fixture-error-\(error.localizedDescription)", false)
        }
    }
}
#endif
