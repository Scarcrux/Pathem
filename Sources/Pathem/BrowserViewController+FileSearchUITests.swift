#if DEBUG
import AppKit
import PathemEngine

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
        let delayed = GlobalSearchController { request in
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
        delayed.debugSetKeyword("old")
        _ = settle(0.25) { false }  // deliver old request to the actual backend, past debounce
        delayed.debugSetKeyword("new")
        _ = settle(1.2) { false }
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
        delayed.debugSetKeyword("old")
        _ = settle(0.25) { false }
        delayed.debugPanel.performClose(nil)
        presentDelayed()
        _ = settle(0.8) { false }
        check(
            "search-close-reopen-drops-stale-results",
            delayed.debugResults.isEmpty && !delayed.debugBusy)
        delayed.debugPanel.cancelOperation(nil)

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
}
#endif
