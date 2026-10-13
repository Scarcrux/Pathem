#if DEBUG
import AppKit
import PathemEngine

@MainActor
private final class SearchBackendReceipts {
    private(set) var oldRequestsStarted = 0
    func received(_ request: FileSearch.Request) {
        if request.keyword == "old" { oldRequestsStarted += 1 }
    }
}

@MainActor
extension BrowserViewController {
    /// Real controls + real folder search. Only the environmental whole-Mac index is stubbed.
    func fileSearchUIChecks() -> [(name: String, ok: Bool, detail: String)] {
        var checks: [(name: String, ok: Bool, detail: String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks.append((name, ok, detail))
        }
        func settle(_ seconds: Double = 3, until condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            repeat {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < end
            return condition()
        }
        guard let window = view.window, let pane = activePane else {
            return [("search-has-window", false, "")]
        }
        window.makeKeyAndOrderFront(nil)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-search-ui-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(
                at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try "unrelated".write(
                to: root.appendingPathComponent("plants-name.txt"), atomically: true,
                encoding: .utf8)
            try "plants in contents".write(
                to: root.appendingPathComponent("neutral.txt"), atomically: true, encoding: .utf8)
            try "plants".write(
                to: root.appendingPathComponent("nested/plants-child.txt"), atomically: true,
                encoding: .utf8)
            pane.navigate(to: root)
            check(
                "search-fixture-listed",
                settle {
                    pane.currentURL.path == root.path && pane.debugHasEntry("plants-name.txt")
                        && pane.debugEntryCount == 3
                })
        } catch { return [("search-fixture-created", false, error.localizedDescription)] }

        if ProcessInfo.processInfo.environment["PATHEM_SEARCH_SESSION_SAMPLE"] == "1" {
            return checks + fileSearchSessionChecks(over: window, root: root)
        }

        // Check production entry points, not only the standalone controller.
        loadSavedSearches()
        check(
            "saved-search-reload-retains-built-in-commands",
            commands.command("search.palette") != nil && commands.command("search.semantic") != nil)
        let ranSearch = commands.perform("search.palette")
        check(
            "cmd-f-opens-literal-search",
            settle { globalSearchController.debugPanel.isVisible }
                && globalSearchController.debugMode.indexOfSelectedItem == 0,
            "registered=\(commands.command("search.palette") != nil) ran=\(ranSearch) visible=\(globalSearchController.debugPanel.isVisible)"
        )
        globalSearchController.debugPanel.cancelOperation(nil)
        searchButton.performClick(nil)
        check("toolbar-opens-same-search", globalSearchController.debugPanel.isVisible)
        globalSearchController.debugPanel.cancelOperation(nil)

        var opened: URL?
        let controller = GlobalSearchController()
        func present() {
            controller.present(
                over: window, currentFolder: root,
                onReveal: { pane.reveal($0) }, onOpen: { opened = $0 })
        }
        func type(_ value: String) {
            controller.debugPanel.makeFirstResponder(controller.debugField)
            if let editor = controller.debugField.currentEditor() as? NSTextView {
                editor.insertText(
                    value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count)
                )
                check(
                    "search-text-editor-delivered", controller.debugField.stringValue == value,
                    value)
            } else {
                check("search-text-editor-delivered", false, "no editor")
            }
        }
        func choose(_ popup: NSPopUpButton, _ index: Int) {
            popup.selectItem(at: index)
            _ = popup.sendAction(popup.action, to: popup.target)
        }
        func finished() -> Bool { settle { !controller.debugBusy } }
        present()
        type("plants")
        check(
            "search-loading-disables-actions",
            controller.debugBusy && !controller.debugOpen.isEnabled
                && !controller.debugReveal.isEnabled)
        check(
            "search-filename-positive-and-content-negative",
            finished()
                && Set(controller.debugResults.map(\.lastPathComponent)) == [
                    "plants-name.txt", "plants-child.txt",
                ])
        check(
            "search-does-not-replace-pane-listing",
            pane.debugEntryCount == 3 && !pane.isShowingSearchResults)
        controller.debugSubfolders.performClick(nil)
        check(
            "search-subfolders-toggle",
            finished() && controller.debugResults.map(\.lastPathComponent) == ["plants-name.txt"])
        choose(controller.debugMode, 1)
        check(
            "search-content-positive-and-name-negative",
            finished() && controller.debugResults.map(\.lastPathComponent) == ["neutral.txt"])
        controller.debugChooseFolder(root.appendingPathComponent("nested"))
        check(
            "search-other-folder-confined",
            finished() && controller.debugResults.map(\.lastPathComponent) == ["plants-child.txt"])
        type("does-not-exist")
        check(
            "search-no-matches",
            finished() && controller.debugResults.isEmpty
                && controller.debugStatus == L("filesearch.noMatches", "No matching files."))
        type("")
        check(
            "search-clear-is-idle",
            !controller.debugBusy && controller.debugResults.isEmpty
                && !controller.debugReveal.isEnabled)
        choose(controller.debugScope, 0)
        choose(controller.debugMode, 0)
        controller.debugSubfolders.performClick(nil)
        type("plants")
        check("search-keyboard-results-ready", finished() && controller.debugResults.count == 2)
        // Arrow/Return selectors are the ones AppKit delivers to the field editor delegate.
        let editor = controller.debugField.currentEditor() as? NSTextView ?? NSTextView()
        _ = controller.control(
            controller.debugField, textView: editor,
            doCommandBy: #selector(NSResponder.moveDown(_:)))
        _ = controller.control(
            controller.debugField, textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
        check(
            "search-keyboard-reveal-selected-visible",
            settle {
                pane.selectedEntries.first?.name == "plants-name.txt"
                    && pane.debugRowVisible("plants-name.txt")
            })
        check("search-reveal-dismisses", !controller.debugPanel.isVisible)
        present()
        type("neutral")
        check("search-open-result-ready", finished() && controller.debugResults.count == 1)
        controller.debugOpen.performClick(nil)
        check(
            "search-open-routes-exact-file",
            opened == root.appendingPathComponent("neutral.txt") && !controller.debugPanel.isVisible
        )

        // A delayed backend deliberately ignores cancellation: generations must still reject it.
        let receipts = SearchBackendReceipts()
        let delayed = GlobalSearchController { request in
            await receipts.received(request)
            if request.keyword == "old" {
                await Task.detached { try? await Task.sleep(for: .milliseconds(650)) }.value
            }
            if request.keyword == "error" { return .init(error: "fixture backend failure") }
            if request.keyword == "limited" {
                return .init(
                    urls: [root.appendingPathComponent("neutral.txt")], truncated: true, skipped: 2)
            }
            if case .mac = request.scope {
                return .init(urls: [
                    root.appendingPathComponent(
                        request.mode == .filename ? "mac-name" : "mac-content")
                ])
            }
            return .init(urls: [root.appendingPathComponent(request.keyword)])
        }
        func presentDelayed() {
            delayed.present(over: window, currentFolder: root, onReveal: { _ in }, onOpen: { _ in })
        }
        presentDelayed()
        let queryResponses = delayed.debugCompletedBackendRequests.count
        delayed.debugSetKeyword("old")
        check("search-old-query-backend-delivered", settle { receipts.oldRequestsStarted == 1 })
        delayed.debugSetKeyword("new")
        check(
            "search-both-query-responses-delivered",
            settle {
                delayed.debugCompletedBackendRequests.count == queryResponses + 2
                    && !delayed.debugBusy
            })
        check(
            "search-stale-query-rejected", delayed.debugResults.map(\.lastPathComponent) == ["new"])
        choose(delayed.debugScope, 1)
        check(
            "search-this-mac-name-routing",
            settle { !delayed.debugBusy }
                && delayed.debugResults.map(\.lastPathComponent) == ["mac-name"])
        choose(delayed.debugMode, 1)
        check(
            "search-this-mac-content-routing",
            settle { !delayed.debugBusy }
                && delayed.debugResults.map(\.lastPathComponent) == ["mac-content"])
        delayed.debugSetKeyword("error")
        check(
            "search-error-not-no-matches",
            settle { !delayed.debugBusy } && delayed.debugStatus.contains("fixture backend failure")
        )
        delayed.debugSetKeyword("limited")
        check(
            "search-limits-and-skips-visible",
            settle { !delayed.debugBusy }
                && delayed.debugStatus.contains(
                    L("filesearch.limited", "Results limited; narrow your search."))
                && delayed.debugStatus.contains("2"))
        let reopenStarts = receipts.oldRequestsStarted
        let reopenResponses = delayed.debugCompletedBackendRequests.count
        delayed.debugSetKeyword("old")
        check(
            "search-old-reopen-backend-delivered",
            settle {
                receipts.oldRequestsStarted == reopenStarts + 1
            })
        delayed.debugPanel.performClose(nil)
        presentDelayed()
        check(
            "search-old-reopen-response-delivered",
            settle {
                delayed.debugCompletedBackendRequests.count == reopenResponses + 1
            })
        check(
            "search-close-reopen-drops-stale-results",
            delayed.debugResults.isEmpty && !delayed.debugBusy)
        delayed.debugPanel.cancelOperation(nil)

        checks += fileSearchSessionChecks(over: window, root: root)

        for mode in ViewFormat.ViewMode.allCases {
            pane.setViewMode(mode)
            check(
                "search-actual-mode-\(mode.rawValue)",
                settle { pane.viewMode == mode && pane.debugEntryCount == 3 })
            searchButton.performClick(nil)
            globalSearchController.debugSetKeyword("plants")
            check(
                "search-view-\(mode.rawValue)-supported",
                settle { !globalSearchController.debugBusy }
                    && globalSearchController.debugResults.count == 2)
            globalSearchController.debugReveal.performClick(nil)
            check(
                "search-reveal-\(mode.rawValue)-selected-visible",
                settle {
                    pane.selectedEntries.first?.name == "plants-child.txt"
                        && pane.selectionRectInWindow.map {
                            $0.intersects(
                                pane.contentClipView.convert(pane.contentClipView.bounds, to: nil))
                        } == true
                })
            check(
                "search-reveal-\(mode.rawValue)-dismisses",
                !globalSearchController.debugPanel.isVisible)
            pane.navigate(to: root)
            check(
                "search-return-root-\(mode.rawValue)",
                settle { pane.currentURL.path == root.path && pane.debugEntryCount == 3 })
        }
        pane.setViewMode(.list)
        _ = settle { pane.debugEntryCount == 3 }
        pane.debugSelectNames(["neutral.txt"])
        searchButton.performClick(nil)
        globalSearchController.debugSetKeyword("plants")
        _ = settle { !globalSearchController.debugBusy }
        check(
            "search-retains-underlying-selection-and-viewport",
            pane.selectedEntries.first?.name == "neutral.txt" && pane.debugRowVisible("neutral.txt")
        )
        debugFocusOtherPane()
        let otherURL = activePane?.currentURL
        globalSearchController.debugReveal.performClick(nil)
        check(
            "search-reveal-stays-with-originating-pane",
            settle {
                pane.selectedEntries.first?.name == "plants-child.txt"
            } && activePane !== pane && activePane?.currentURL == otherURL)
        debugFocusOtherPane()
        pane.navigate(to: root)
        _ = settle { pane.debugEntryCount == 3 }
        showPalette(prefill: ">")
        palette.debugSetQuery("compress")  // deleting the prefix must not silently enable semantic search
        check(
            "search-commands-stay-separate",
            !palette.debugIsSemantic && !pane.isShowingSearchResults)
        palette.debugDismiss()

        present()
        type("plants")
        _ = finished()
        controller.debugPanel.setContentSize(NSSize(width: 680, height: 360))
        controller.debugPanel.contentView?.layoutSubtreeIfNeeded()
        let controls =
            [
                controller.debugField, controller.debugMode, controller.debugScope,
                controller.debugSubfolders, controller.debugOpen, controller.debugReveal,
            ] as [NSView]
        check(
            "search-minimum-layout-no-clipping",
            controls.allSatisfy { v in
                guard let content = controller.debugPanel.contentView else { return false }
                let rect = v.convert(v.bounds, to: content)
                return rect.width > 30 && rect.height > 10
                    && content.bounds.insetBy(dx: -1, dy: -1).contains(rect)
                    && !v.hasAmbiguousLayout
            })
        if ProcessInfo.processInfo.environment["PATHEM_SEARCH_CAPTURE"] != nil {
            // Window-server capture: cacheDisplay renders AppKit controls/materials incorrectly.
            _ = settle(0.3) { false }
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = [
                "-x", "-l", String(controller.debugPanel.windowNumber),
                "/tmp/pathem-file-search-live.png",
            ]
            do {
                try capture.run()
                capture.waitUntilExit()
                check(
                    "search-live-capture", capture.terminationStatus == 0,
                    "exit=\(capture.terminationStatus)")
            } catch { check("search-live-capture", false, error.localizedDescription) }
        }
        controller.debugPanel.cancelOperation(nil)
        check("search-escape-dismisses", !controller.debugPanel.isVisible)
        return checks
    }

    func runFileSearchUIAutomation() -> Never {
        let checks = fileSearchUIChecks()
        for c in checks { print("SEARCHUI: \(c.ok ? "PASS" : "FAIL") \(c.name) \(c.detail)") }
        let passed = checks.filter(\.ok).count
        print("RESULT: \(passed == checks.count ? "PASS" : "FAIL") (\(passed)/\(checks.count))")
        exit(passed == checks.count ? 0 : 1)
    }

    /// Native picker cancellation, with an injected index backend to distinguish scopes.
    private func fileSearchSessionChecks(over window: NSWindow, root: URL)
        -> [(name: String, ok: Bool, detail: String)]
    {
        var checks: [(name: String, ok: Bool, detail: String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks.append(("search-session-" + name, ok, detail))
        }
        func settle(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(3)
            repeat {
                if condition() { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < end
            return condition()
        }
        let controller = GlobalSearchController { request in
            let prefix: String
            switch request.scope {
            case .mac: prefix = "mac-"
            case .folder: prefix = "folder-"
            }
            return .init(urls: [root.appendingPathComponent(prefix + request.keyword)])
        }
        defer { controller.debugPanel.cancelOperation(nil) }
        var oldOpened: URL?
        var replacementOpened: URL?
        controller.present(
            over: window, currentFolder: root, onReveal: { _ in }, onOpen: { oldOpened = $0 })
        check("no-picker-before-action-control", controller.debugPanel.attachedSheet == nil)
        func showPicker(rechoose: Bool = false) -> NSOpenPanel? {
            let control: NSControl
            if rechoose {
                control = controller.debugChooseButton
                check("choose-button-visible", !controller.debugChooseButton.isHidden)
            } else {
                controller.debugScope.selectItem(at: 2)
                control = controller.debugScope
            }
            check(
                rechoose ? "choose-action-delivered" : "scope-action-delivered",
                control.sendAction(control.action, to: control.target))
            guard settle({ controller.debugPanel.attachedSheet?.isVisible == true }),
                let picker = controller.debugPanel.attachedSheet as? NSOpenPanel
            else {
                check("native-picker-mounted", false)
                return nil
            }
            check(
                "native-picker-mounted",
                picker.sheetParent === controller.debugPanel
                    && picker.canChooseDirectories && !picker.canChooseFiles
                    && !picker.allowsMultipleSelection)
            return picker
        }
        guard let controlPicker = showPicker() else { return checks }
        let controlReceipt = controller.debugFolderPickerCompletions
        check(
            "duplicate-scope-action-delivered",
            controller.debugScope.sendAction(
                controller.debugScope.action, to: controller.debugScope.target))
        check(
            "duplicate-picker-retains-original",
            controller.debugPanel.attachedSheet === controlPicker
                && controller.debugFolderPickerCompletions == controlReceipt)
        controlPicker.cancel(nil)
        check(
            "same-session-cancel-receipt",
            settle {
                controller.debugFolderPickerCompletions == controlReceipt + 1
                    && controller.debugPanel.attachedSheet == nil
            })
        check(
            "same-session-cancel-control",
            controller.debugScope.indexOfSelectedItem == 0
                && !controller.debugBusy && controller.debugResults.isEmpty)

        guard let stalePicker = showPicker() else { return checks }
        let staleReceipt = controller.debugFolderPickerCompletions
        let replacementRoot = root.appendingPathComponent("nested")
        controller.present(
            over: window, currentFolder: replacementRoot,
            onReveal: { _ in }, onOpen: { replacementOpened = $0 })
        check(
            "replacement-root-delivered",
            controller.debugLocation == replacementRoot.path
                && controller.debugScope.indexOfSelectedItem == 0)
        controller.debugScope.selectItem(at: 1)
        check(
            "replacement-scope-action-delivered",
            controller.debugScope.sendAction(
                controller.debugScope.action, to: controller.debugScope.target))
        check(
            "replacement-scope-delivered",
            controller.debugScope.indexOfSelectedItem == 1
                && controller.debugMode.indexOfSelectedItem == 0)
        controller.debugSetKeyword("current")
        let expected = root.appendingPathComponent("mac-current")
        check(
            "replacement-backend-delivered",
            settle {
                !controller.debugBusy && controller.debugResults == [expected]
            })
        stalePicker.cancel(nil)
        check(
            "stale-picker-completion-received",
            settle {
                controller.debugFolderPickerCompletions == staleReceipt + 1
                    && controller.debugPanel.attachedSheet == nil
            })
        check(
            "stale-cancel-preserves-new-scope", controller.debugScope.indexOfSelectedItem == 1,
            "scope=\(controller.debugScope.indexOfSelectedItem) receipts=\(controller.debugFolderPickerCompletions)"
        )
        check(
            "stale-cancel-preserves-new-results",
            settle {
                !controller.debugBusy && controller.debugResults == [expected]
            }, "results=\(controller.debugResults.map(\.lastPathComponent))")
        controller.debugOpen.performClick(nil)
        check(
            "replacement-callback-only", replacementOpened == expected && oldOpened == nil,
            "replacement=\(replacementOpened?.lastPathComponent ?? "nil") old=\(oldOpened?.lastPathComponent ?? "nil")"
        )

        for closeWindow in [true, false] {
            let boundary = closeWindow ? "window-close" : "panel-cancel"
            controller.present(
                over: window, currentFolder: root, onReveal: { _ in }, onOpen: { _ in })
            guard showPicker() != nil else { return checks }
            let receipt = controller.debugFolderPickerCompletions
            if closeWindow {
                controller.debugPanel.close()
            } else {
                controller.debugPanel.cancelOperation(nil)
            }
            check(boundary + "-delivered", !controller.debugPanel.isVisible)
            controller.present(
                over: window, currentFolder: replacementRoot, everywhere: true,
                onReveal: { _ in }, onOpen: { _ in })
            controller.debugSetKeyword(boundary)
            let reopened = root.appendingPathComponent("mac-" + boundary)
            check(
                boundary + "-picker-completion-received",
                settle {
                    controller.debugFolderPickerCompletions == receipt + 1
                        && controller.debugPanel.attachedSheet == nil
                })
            check(
                boundary + "-reopen-preserves-new-search",
                settle { !controller.debugBusy && controller.debugResults == [reopened] }
                    && controller.debugScope.indexOfSelectedItem == 1)
            controller.debugPanel.cancelOperation(nil)
        }

        controller.present(
            over: window, currentFolder: root, onReveal: { _ in }, onOpen: { _ in })
        let fixtureFolder = replacementRoot.resolvingSymlinksInPath()
        // macOS's remote picker raises NSGenericException for ok(nil). Seed the
        // selected-folder precondition explicitly; do not claim native acceptance.
        controller.debugChooseFolder(fixtureFolder)
        check(
            "selected-folder-precondition-delivered",
            controller.debugScope.indexOfSelectedItem == 2
                && URL(fileURLWithPath: controller.debugLocation).resolvingSymlinksInPath()
                    == fixtureFolder,
            "scope=\(controller.debugScope.indexOfSelectedItem)")
        guard controller.debugScope.indexOfSelectedItem == 2 else { return checks }
        controller.debugMode.selectItem(at: 1)
        check(
            "contents-action-delivered",
            controller.debugMode.sendAction(
                controller.debugMode.action, to: controller.debugMode.target))
        controller.debugSubfolders.state = .off
        check(
            "subfolders-action-delivered",
            controller.debugSubfolders.sendAction(
                controller.debugSubfolders.action, to: controller.debugSubfolders.target))
        controller.debugSetKeyword("chosen")
        check("selected-folder-query-delivered", settle { !controller.debugBusy })
        guard let rechoosePicker = showPicker(rechoose: true) else { return checks }
        let rechooseReceipt = controller.debugFolderPickerCompletions
        let rechooseResponses = controller.debugCompletedBackendRequests.count
        rechoosePicker.cancel(nil)
        check(
            "selected-folder-cancel-completion-received",
            settle {
                controller.debugFolderPickerCompletions == rechooseReceipt + 1
                    && controller.debugPanel.attachedSheet == nil
            })
        check(
            "selected-folder-cancel-requeries-current-options",
            settle {
                controller.debugCompletedBackendRequests.count == rechooseResponses + 1
                    && !controller.debugBusy
            }
                && controller.debugCompletedBackendRequests.last?.keyword == "chosen"
                && controller.debugCompletedBackendRequests.last?.mode == .contents
                && controller.debugCompletedBackendRequests.last?.scope
                    == .folder(fixtureFolder, recursive: false)
                && controller.debugScope.indexOfSelectedItem == 2,
            "scope=\(controller.debugScope.indexOfSelectedItem) receipts=\(controller.debugFolderPickerCompletions)"
        )
        return checks
    }
}
#endif
