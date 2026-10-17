#if DEBUG
import AppKit
import PathemEngine

/// Explicitly deliver new then stale responses; cancellation must not make the
/// old response disappear from the test before the generation guard sees it.
@MainActor
private final class MatrixSearchGate {
    private(set) var requests: [FileSearch.Request] = []
    private var pending: [String: CheckedContinuation<FileSearch.Response, Never>] = [:]
    func response(_ request: FileSearch.Request) async -> FileSearch.Response {
        requests.append(request)
        return await withCheckedContinuation { pending[request.keyword] = $0 }
    }
    func deliver(_ keyword: String, urls: [URL]) -> Bool {
        guard let continuation = pending.removeValue(forKey: keyword) else { return false }
        continuation.resume(returning: .init(urls: urls))
        return true
    }
    func finish() {
        let remaining = Array(pending.values)
        pending.removeAll()
        for continuation in remaining { continuation.resume(returning: .init()) }
    }
}

@MainActor
extension BrowserViewController {
    /// Actual folder searches and table responders, with two distinguishable roots
    /// and real nonzero pane viewports. No external application or picker approval.
    func fileSearchInteractionMatrix(root: URL, sample: Bool, columnOnly: Bool = false)
        -> [(name: String, ok: Bool, detail: String)]
    {
        var checks: [(name: String, ok: Bool, detail: String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks.append(("matrix-" + name, ok, detail))
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
        else { return [("matrix-window-and-panes", false, "")] }
        let fm = FileManager.default
        let matrixRoot = root.appendingPathComponent("matrix")
        let leftRoot = matrixRoot.appendingPathComponent("left")
        let rightRoot = matrixRoot.appendingPathComponent("right")
        func name(_ row: Int) -> String { String(format: "match-%03d.txt", row) }
        do {
            for (folder, content) in [(leftRoot, "LEFT"), (rightRoot, "RIGHT")] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for row in 0..<160 {
                    try Data("\(content) \(row)".utf8).write(
                        to: folder.appendingPathComponent(name(row)))
                }
            }
        } catch { return [("matrix-fixture-created", false, error.localizedDescription)] }
        window.setContentSize(NSSize(width: 1200, height: 800))
        loadSavedSearches()
        let controller = globalSearchController
        defer { controller.debugPanel.cancelOperation(nil) }

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
                && abs(state.clip.bounds.origin.x - state.point.x) < 1
                && abs(state.clip.bounds.origin.y - state.point.y) < 1
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
            columnOnly
            ? [(.column, true), (.column, false)]
            : sample
                ? [(.list, true), (.gallery, false)]
                : ViewFormat.ViewMode.allCases.flatMap { [($0, true), ($0, false)] }
        for (mode, fromLeft) in cells {
            let cell = "\(mode.rawValue)-\(fromLeft ? "left" : "right")"
            controller.debugPanel.cancelOperation(nil)
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
                check(
                    "views-delivered-\(cell)", false,
                    "left=\(left.viewMode)/\(left.debugEntryCount) right=\(right.viewMode)/\(right.debugEntryCount)"
                )
                continue
            }
            check(
                "views-delivered-\(cell)", true,
                "acceptedListings=\(leftBefore)->\(left.debugListingCompletions),\(rightBefore)->\(right.debugListingCompletions)"
            )
            view.layoutSubtreeIfNeeded()
            left.select(name: name(159))
            right.select(name: name(159))
            let scrolled = settle {
                guard let a = snapshot(left), let b = snapshot(right) else { return false }
                return a.names == [name(159)] && b.names == [name(159)]
                    && (a.point.x > 1 || a.point.y > 1) && (b.point.x > 1 || b.point.y > 1)
                    && selectionVisible(left) && selectionVisible(right)
            }
            guard scrolled, let leftState = snapshot(left), let rightState = snapshot(right) else {
                check(
                    "nonzero-viewports-\(cell)", false,
                    "left=\(String(describing: snapshot(left)?.point)) right=\(String(describing: snapshot(right)?.point))"
                )
                continue
            }
            check(
                "nonzero-viewports-\(cell)", true,
                "left=\(leftState.point) right=\(rightState.point)")
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
            func present() -> Bool {
                setActiveSide(side, pane: origin)
                if fromLeft {
                    searchButton.performClick(nil)
                } else if !commands.perform("search.palette") {
                    return false
                }
                return controller.debugPanel.isVisible && controller.debugLocation == folder.path
                    && controller.debugMode.indexOfSelectedItem == 0
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
            func response(_ count: Int, after before: Int, keyword: String) -> Bool {
                settle {
                    guard controller.debugCompletedBackendRequests.count > before,
                        !controller.debugBusy, controller.debugResults.count == count,
                        let request = controller.debugCompletedBackendRequests.last,
                        request.keyword == keyword, case .folder(let actual, _) = request.scope
                    else { return false }
                    return actual.path == folder.path
                        && controller.debugResults.allSatisfy {
                            $0.deletingLastPathComponent().path == folder.path
                        }
                }
            }
            check("entry-point-\(cell)", present())
            check("open-preserves-both-\(cell)", bothPreserved())
            let firstResponse = controller.debugCompletedBackendRequests.count
            check("field-editor-query-\(cell)", type("match-"))
            check(
                "loading-disables-actions-\(cell)",
                controller.debugBusy && !controller.debugOpen.isEnabled
                    && !controller.debugReveal.isEnabled)
            let switched = focusOther()
            check(
                "pane-switch-before-response-\(cell)", switched && controller.debugBusy)
            check(
                "origin-root-response-\(cell)",
                response(160, after: firstResponse, keyword: "match-"))
            check("query-switch-preserves-both-\(cell)", bothPreserved())
            let negativeResponse = controller.debugCompletedBackendRequests.count
            check("negative-query-delivered-\(cell)", type("absent-fixture-keyword"))
            check(
                "negative-query-control-\(cell)",
                response(0, after: negativeResponse, keyword: "absent-fixture-keyword"))
            check("no-matches-preserves-both-\(cell)", bothPreserved())
            check("clear-delivered-\(cell)", type(""))
            check(
                "clear-idle-\(cell)",
                !controller.debugBusy && controller.debugResults.isEmpty
                    && !controller.debugOpen.isEnabled && !controller.debugReveal.isEnabled)
            controller.debugPanel.cancelOperation(nil)
            check(
                "dismiss-preserves-both-\(cell)",
                !controller.debugPanel.isVisible && bothPreserved())

            check(
                "reopen-origin-\(cell)",
                present() && controller.debugResults.isEmpty
                    && controller.debugField.stringValue.isEmpty)
            let secondResponse = controller.debugCompletedBackendRequests.count
            check("reopen-query-delivered-\(cell)", type("match-"))
            check("reopen-other-focus-\(cell)", focusOther())
            check(
                "reopen-origin-response-\(cell)",
                response(160, after: secondResponse, keyword: "match-"))
            check("reopen-preserves-both-\(cell)", bothPreserved())
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
            check("result-down-\(cell)", down && table.selectedRow == 91)
            let up = controller.control(
                controller.debugField, textView: editor,
                doCommandBy: #selector(NSResponder.moveUp(_:)))
            check("result-up-\(cell)", up && table.selectedRow == 90)
            let tableClip = table.enclosingScrollView?.contentView
            check(
                "nonfirst-result-visible-\(cell)",
                table.selectedRow == 90 && controller.debugResults.count == 160
                    && controller.debugResults[90].lastPathComponent == name(90)
                    && (tableClip?.bounds.origin.y ?? 0) > 0
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
                "key-recipient-\(cell)", focused && controller.debugPanel.firstResponder === table,
                "keyCode=\(event.keyCode) selectedRow=\(table.selectedRow)")
            check(
                "other-focus-before-reveal-\(cell)",
                activePane === other && window.firstResponder === other.keyView)
            table.keyDown(with: event)
            check(
                "key-reveal-dismisses-\(cell)", !controller.debugPanel.isVisible, "keyCode=\(code)")
            check(
                "key-reveals-origin-selection-\(cell)",
                settle {
                    origin.currentURL.path == folder.path
                        && origin.selectedEntries.map(\.name) == [name(90)]
                        && selectionVisible(origin)
                },
                "selected=\(origin.selectedEntries.map(\.name)) clip=\(String(describing: snapshot(origin)?.point)) "
                    + "visible=\(String(describing: origin.keyView.visibleRect)) "
                    + "selectionRect=\(String(describing: origin.selectionRectInWindow))")
            check(
                "key-keeps-other-pane-\(cell)",
                activePane === other && preserved(other, otherState),
                "activeIsOther=\(activePane === other) selected=\(other.selectedEntries.map(\.name))"
            )
            if mode == .column {
                check(
                    "column-explicit-focus-activates-\(cell)",
                    window.makeFirstResponder(origin.keyView) && activePane === origin)
            }
        }
        controller.debugPanel.cancelOperation(nil)
        checks += fileSearchMatrixRaceChecks(
            root: matrixRoot, leftRoot: leftRoot, rightRoot: rightRoot)
        return checks
    }

    private func fileSearchMatrixRaceChecks(root: URL, leftRoot: URL, rightRoot: URL)
        -> [(name: String, ok: Bool, detail: String)]
    {
        var checks: [(name: String, ok: Bool, detail: String)] = []
        func check(_ name: String, _ ok: Bool) { checks.append(("matrix-race-" + name, ok, "")) }
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
        else { return [("matrix-race-window", false, "")] }
        left.navigate(to: leftRoot)
        right.navigate(to: rightRoot)
        left.debugClickViewSwitcher(.list)
        right.debugClickViewSwitcher(.list)
        check(
            "listings-delivered",
            settle { left.debugEntryCount == 160 && right.debugEntryCount == 160 })
        let gate = MatrixSearchGate()
        let controller = GlobalSearchController { request in await gate.response(request) }
        defer {
            controller.debugPanel.cancelOperation(nil)
            gate.finish()
        }
        var oldOpen: URL?
        var newOpen: URL?
        var revealed: URL?
        func started(_ keyword: String, in folder: URL) -> Bool {
            gate.requests.contains { request in
                guard request.keyword == keyword, case .folder(let actual, _) = request.scope else {
                    return false
                }
                return actual.path == folder.path
            }
        }
        controller.present(
            over: window, currentFolder: leftRoot,
            onReveal: { revealed = $0 }, onOpen: { oldOpen = $0 })
        controller.debugSetKeyword("old")
        check("old-backend-started", settle { started("old", in: leftRoot) })
        left.navigate(to: rightRoot)
        check(
            "origin-navigation-delivered",
            settle { left.currentURL.path == rightRoot.path && left.debugEntryCount == 160 })
        setActiveSide(rightTabs, pane: right)
        controller.debugPanel.cancelOperation(nil)
        controller.present(
            over: window, currentFolder: rightRoot,
            onReveal: { revealed = $0 }, onOpen: { newOpen = $0 })
        controller.debugSetKeyword("new")
        check("new-backend-started", settle { started("new", in: rightRoot) })
        let newURLs = [
            rightRoot.appendingPathComponent("match-100.txt"),
            rightRoot.appendingPathComponent("match-101.txt"),
        ]
        check("new-response-released", gate.deliver("new", urls: newURLs))
        check(
            "new-response-received",
            settle {
                controller.debugCompletedBackendRequests.count == 1 && !controller.debugBusy
                    && controller.debugResults == newURLs
            })
        check(
            "stale-response-released",
            gate.deliver("old", urls: [leftRoot.appendingPathComponent("match-090.txt")]))
        check(
            "stale-response-received",
            settle {
                controller.debugCompletedBackendRequests.count == 2
                    && Set(controller.debugCompletedBackendRequests.map(\.keyword)) == [
                        "old", "new",
                    ]
            })
        check(
            "reopen-retains-new-scope-results",
            controller.debugLocation == rightRoot.path
                && controller.debugField.stringValue == "new" && controller.debugResults == newURLs
                && controller.debugOpen.isEnabled && controller.debugReveal.isEnabled)
        check(
            "responses-dont-navigate-or-open",
            left.currentURL.path == rightRoot.path
                && right.currentURL.path == rightRoot.path && oldOpen == nil && newOpen == nil
                && revealed == nil)
        controller.debugTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.debugOpen.performClick(nil)
        check(
            "open-uses-new-nonfirst-result",
            newOpen == newURLs[1] && oldOpen == nil
                && !controller.debugPanel.isVisible)

        // A same-named file is deliberately present at the destination, so a
        // stale post-listing Reveal would visibly select it if ownership is lost.
        let destination = root.appendingPathComponent("navigation-control")
        do {
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            try Data("DIFFERENT DIRECTORY".utf8).write(
                to: destination.appendingPathComponent("match-090.txt"))
        } catch {
            checks.append(("matrix-race-fixture", false, error.localizedDescription))
            return checks
        }
        left.reveal(leftRoot.appendingPathComponent("match-090.txt"))
        left.navigate(to: destination)
        check(
            "new-directory-listing-delivered",
            settle {
                left.currentURL.path == destination.path && left.debugEntryCount == 1
                    && (left.keyView as? NSTableView)?.numberOfRows == 1
            })
        check(
            "reveal-does-not-cross-directory",
            left.selectedEntries.isEmpty
                && left.currentURL.path == destination.path && left.debugHasEntry("match-090.txt"))
        return checks
    }
}
#endif
