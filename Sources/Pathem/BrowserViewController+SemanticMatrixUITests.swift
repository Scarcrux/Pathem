#if DEBUG
import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    /// The semantic mode of the Cmd-F panel in every view mode, opened from either pane, with a
    /// real scrolled viewport and selection in both panes. Semantic search never touches a
    /// pane, so both must be exactly as they were at every step, including after Reveal. The
    /// slow steps are answered on command; the on-device model is never loaded.
    func semanticPanelMatrix(root: URL, sample: Bool)
        -> [(name: String, ok: Bool, detail: String)]
    {
        var checks: [(name: String, ok: Bool, detail: String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks.append(("semanticmatrix-" + name, ok, detail))
        }
        func settle(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(5)
            repeat {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < end
            return condition()
        }
        guard let window = view.window, let left = leftTabs.activePane,
            let right = rightTabs.activePane
        else { return [("semanticmatrix-window-and-panes", false, "")] }
        let fm = FileManager.default
        let base = root.appendingPathComponent("semantic-matrix")
        let leftRoot = base.appendingPathComponent("left")
        let rightRoot = base.appendingPathComponent("right")
        func name(_ row: Int) -> String { String(format: "match-%03d.txt", row) }
        do {
            for folder in [leftRoot, rightRoot] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for row in 0..<160 {
                    try Data("x \(row)".utf8).write(to: folder.appendingPathComponent(name(row)))
                }
            }
        } catch { return [("semanticmatrix-fixture-created", false, error.localizedDescription)] }
        window.setContentSize(NSSize(width: 1200, height: 800))

        let entriesGate = Gate<[FileEntry]>()
        let indexGate = Gate<FolderSemanticIndex>()
        let rankGate = Gate<[Int]>()
        let savedBackend = semanticSearch.backend
        semanticSearch.backend = SemanticSearchController.Backend(
            entries: { dir, recursive in
                try await entriesGate.request(dir.lastPathComponent + (recursive ? "|deep" : ""))
            },
            index: { entries, _, cap, _ in
                (try? await indexGate.request("\(min(entries.count, cap))"))
                    ?? FolderSemanticIndex(ids: [], vectors: [])
            },
            rank: { query, _ in (try? await rankGate.request(query)) ?? [] })
        let controller = globalSearchController
        defer {
            controller.debugPanel.cancelOperation(nil)
            semanticSearch.backend = savedBackend
            semanticSearch.invalidate()
        }

        typealias Snapshot = (
            key: NSView, clip: NSClipView, point: NSPoint, path: String, names: [String]
        )
        func snapshot(_ pane: PaneController) -> Snapshot? {
            guard let clip = pane.keyView.enclosingScrollView?.contentView else { return nil }
            return (
                pane.keyView, clip, clip.bounds.origin, pane.currentURL.path,
                pane.selectedEntries.map(\.name)
            )
        }
        func preserved(_ pane: PaneController, _ state: Snapshot) -> Bool {
            pane.keyView === state.key && pane.currentURL.path == state.path
                && pane.selectedEntries.map(\.name) == state.names && !pane.isShowingSearchResults
                && pane.searchPhase == nil && pane.searchFailure == nil
                && abs(state.clip.bounds.origin.x - state.point.x) < 1
                && abs(state.clip.bounds.origin.y - state.point.y) < 1
        }
        func why(_ pane: PaneController, _ state: Snapshot) -> String {
            "key=\(pane.keyView === state.key) path=\(pane.currentURL.path == state.path) "
                + "sel=\(pane.selectedEntries.map(\.name)) want=\(state.names) "
                + "results=\(pane.isShowingSearchResults) phase=\(String(describing: pane.searchPhase)) "
                + "fail=\(String(describing: pane.searchFailure)) "
                + "clip=\(state.clip.bounds.origin) was=\(state.point)"
        }
        func selectionVisible(_ pane: PaneController) -> Bool {
            guard let clip = pane.keyView.enclosingScrollView?.contentView else { return false }
            return pane.selectionRectInWindow?.intersects(clip.convert(clip.bounds, to: nil))
                == true
        }
        func delivered(_ pane: PaneController, mode: ViewFormat.ViewMode) -> Bool {
            guard pane.viewMode == mode, pane.debugEntryCount == 160 else { return false }
            if let table = pane.keyView as? NSTableView { return table.numberOfRows == 160 }
            if let grid = pane.keyView as? NSCollectionView {
                return grid.numberOfSections > 0 && grid.numberOfItems(inSection: 0) == 160
            }
            return false
        }
        let cells: [(ViewFormat.ViewMode, Bool)] =
            sample
            ? [(.list, true), (.gallery, false)]
            : ViewFormat.ViewMode.allCases.flatMap { [($0, true), ($0, false)] }
        for (mode, fromLeft) in cells {
            let cell = "\(mode.rawValue)-\(fromLeft ? "left" : "right")"
            controller.debugPanel.cancelOperation(nil)
            semanticSearch.invalidate()
            // Wait for the NEW listings: navigating to the folder a pane is already showing
            // still reloads it off-main, and that late completion would reset the selection
            // and scroll this cell is about to set up.
            let leftBefore = left.debugListingCompletions
            let rightBefore = right.debugListingCompletions
            left.navigate(to: leftRoot)
            right.navigate(to: rightRoot)
            left.debugClickViewSwitcher(mode)
            right.debugClickViewSwitcher(mode)
            guard
                settle({
                    delivered(left, mode: mode) && delivered(right, mode: mode)
                        && left.debugListingCompletions > leftBefore
                        && right.debugListingCompletions > rightBefore
                })
            else {
                check("views-delivered-\(cell)", false)
                continue
            }
            view.layoutSubtreeIfNeeded()
            left.select(name: name(159))
            right.select(name: name(159))
            guard
                settle({
                    guard let a = snapshot(left), let b = snapshot(right) else { return false }
                    return a.names == [name(159)] && b.names == [name(159)]
                        && (a.point.x > 1 || a.point.y > 1) && (b.point.x > 1 || b.point.y > 1)
                        && selectionVisible(left) && selectionVisible(right)
                }), let leftState = snapshot(left), let rightState = snapshot(right)
            else {
                check("nonzero-viewports-\(cell)", false)
                continue
            }
            check("nonzero-viewports-\(cell)", true)
            let origin = fromLeft ? left : right
            let other = fromLeft ? right : left
            let side = fromLeft ? leftTabs : rightTabs
            let otherSide = fromLeft ? rightTabs : leftTabs
            let folder = fromLeft ? leftRoot : rightRoot
            let otherState = fromLeft ? rightState : leftState
            func bothPreserved() -> Bool {
                preserved(left, leftState) && preserved(right, rightState)
            }
            func focusOther() -> Bool {
                let focused = window.makeFirstResponder(other.keyView)
                setActiveSide(otherSide, pane: other)
                return focused && window.firstResponder === other.keyView && activePane === other
            }
            func type(_ text: String) -> Bool {
                controller.debugPanel.makeFirstResponder(controller.debugField)
                guard let editor = controller.debugField.currentEditor() as? NSTextView else {
                    return false
                }
                editor.insertText(
                    text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                return controller.debugField.stringValue == text
            }
            setActiveSide(side, pane: origin)
            check(
                "command-opens-semantic-\(cell)",
                commands.perform("search.semantic") && controller.debugPanel.isVisible
                    && controller.debugMode.indexOfSelectedItem == 2
                    && controller.debugLocation == folder.path)
            check("open-preserves-both-\(cell)", bothPreserved())
            check("typed-\(cell)", type("match-"))
            check(
                "indexing-shown-\(cell)",
                settle { entriesGate.pending == 1 && controller.debugStatus == "Indexing…" })
            check(
                "indexing-preserves-both-\(cell)", bothPreserved(),
                "left: \(why(left, leftState)) right: \(why(right, rightState))")
            let switched = focusOther()
            check("pane-switch-while-indexing-\(cell)", switched && controller.debugBusy)
            let listing = FlatEnumerator.entries(of: folder, includeFolders: true).entries
            entriesGate.answer(.success(listing))
            _ = settle { indexGate.pending == 1 }
            indexGate.answer(
                .success(
                    FolderSemanticIndex(
                        ids: Array(0..<160), vectors: Array(repeating: [1], count: 160))))
            check(
                "ranking-shown-\(cell)",
                settle { rankGate.pending == 1 && controller.debugStatus == "Ranking…" }
                    && !controller.debugOpen.isEnabled)
            rankGate.answer(.success(Array((0..<160).reversed())))
            check(
                "results-in-origin-folder-\(cell)",
                settle { controller.debugResults.count == 160 && !controller.debugBusy }
                    && controller.debugResults.allSatisfy {
                        $0.deletingLastPathComponent().path == folder.path
                    } && controller.debugResults.first?.lastPathComponent == listing.last?.name,
                "first=\(String(describing: controller.debugResults.first)) folder=\(folder.path) listing.last=\(String(describing: listing.last?.name)) count=\(controller.debugResults.count)"
            )
            check("results-preserve-both-\(cell)", bothPreserved())
            // Clear, then query again from the cached index: Ranking only.
            check("clear-typed-\(cell)", type(""))
            check(
                "clear-idle-\(cell)",
                !controller.debugBusy && controller.debugResults.isEmpty
                    && !controller.debugOpen.isEnabled)
            check("clear-preserves-both-\(cell)", bothPreserved())
            check("requery-typed-\(cell)", type("match-"))
            check(
                "requery-ranks-from-cache-\(cell)",
                settle { rankGate.pending == 1 && controller.debugStatus == "Ranking…" }
                    && entriesGate.pending == 0)
            rankGate.answer(.success(Array((0..<160).reversed())))
            _ = settle { controller.debugResults.count == 160 && !controller.debugBusy }
            // Keyboard: select a non-first row, arrows, Return reveals it in the origin pane.
            let table = controller.debugTable
            table.selectRowIndexes(IndexSet(integer: 90), byExtendingSelection: false)
            table.scrollRowToVisible(90)
            guard let editor = controller.debugField.currentEditor() as? NSTextView else {
                check("result-editor-\(cell)", false)
                continue
            }
            let down = controller.control(
                controller.debugField, textView: editor,
                doCommandBy: #selector(NSResponder.moveDown(_:)))
            let up = controller.control(
                controller.debugField, textView: editor,
                doCommandBy: #selector(NSResponder.moveUp(_:)))
            check(
                "arrows-\(cell)",
                down && up && table.selectedRow == 90
                    && table.rect(ofRow: 90).intersects(table.visibleRect))
            let focused = controller.debugPanel.makeFirstResponder(table)
            let code: UInt16 = fromLeft ? 36 : 76
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: fromLeft ? [] : .numericPad,
                    timestamp: 0, windowNumber: controller.debugPanel.windowNumber, context: nil,
                    characters: fromLeft ? "\r" : "\u{3}",
                    charactersIgnoringModifiers: fromLeft ? "\r" : "\u{3}",
                    isARepeat: false, keyCode: code)
            else {
                check("key-event-created-\(cell)", false)
                continue
            }
            check(
                "key-recipient-\(cell)",
                focused && controller.debugPanel.firstResponder === table
                    && activePane === other)
            table.keyDown(with: event)
            check("key-reveal-dismisses-\(cell)", !controller.debugPanel.isVisible)
            check(
                "key-reveals-origin-selection-\(cell)",
                settle {
                    origin.currentURL.path == folder.path
                        && origin.selectedEntries.map(\.name) == [listing[69].name]
                        && selectionVisible(origin)
                })
            check(
                "key-keeps-other-pane-\(cell)",
                activePane === other && preserved(other, otherState))
        }
        return checks
    }
}
#endif
