#if DEBUG
import AppKit
import PathemEngine

/// Semantic search as the third mode of the Cmd-F panel (Mission 53 task 13, S3). Each slow
/// step (enumerate, embed, rank) is handed out and answered on command, so no timer decides a
/// verdict and the real on-device model is never loaded.
extension BrowserViewController {
    func checkSemanticPanel(
        root: URL, check: (String, Bool) -> Void, settle: (() -> Bool) -> Bool
    ) {
        guard let window = view.window, let pane = leftTabs.activePane else {
            check("semanticpanel-window", false)
            return
        }
        let fm = FileManager.default
        let folder = root.appendingPathComponent("panel-folder")
        let other = root.appendingPathComponent("panel-other")
        try? fm.createDirectory(
            at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        for i in 0..<30 {
            let name = String(format: "a%02d.txt", i)
            try? "x".write(
                to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            try? "x".write(
                to: other.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for i in 0..<10 {
            try? "x".write(
                to: folder.appendingPathComponent(String(format: "sub/b%02d.txt", i)),
                atomically: true, encoding: .utf8)
        }
        func listed(_ dir: URL, recursive: Bool) -> [FileEntry] {
            recursive
                ? FlatEnumerator.entries(of: dir, includeFolders: true).entries
                : ((try? BulkEnumerator().entries(of: dir, includingHidden: false)) ?? [])
        }
        @Sendable func tag(_ dir: URL, _ recursive: Bool) -> String {
            "\(dir.lastPathComponent)|\(recursive ? "deep" : "flat")"
        }
        let entriesGate = Gate<[FileEntry]>()
        let indexGate = Gate<FolderSemanticIndex>()
        let rankGate = Gate<[Int]>()
        let saved = semanticSearch.backend
        semanticSearch.invalidate()
        semanticSearch.backend = SemanticSearchController.Backend(
            entries: { dir, recursive in try await entriesGate.request(tag(dir, recursive)) },
            index: { entries, _, cap, _ in
                (try? await indexGate.request("\(min(entries.count, cap))"))
                    ?? FolderSemanticIndex(ids: [], vectors: [])
            },
            rank: { query, _ in (try? await rankGate.request(query)) ?? [] })
        defer {
            semanticSearch.backend = saved
            semanticSearch.invalidate()
        }
        func fullIndex(_ n: Int) -> FolderSemanticIndex {
            FolderSemanticIndex(ids: Array(0..<n), vectors: Array(repeating: [1], count: n))
        }

        final class Log {
            var revealed: [URL] = []
            var opened: [URL] = []
        }
        let log = Log()
        let find = GlobalSearchController(semantic: semanticSearch)
        defer { find.debugPanel.cancelOperation(nil) }
        func present(
            _ dir: URL = folder, everywhere: Bool = false,
            mode: GlobalSearchController.Mode = .semantic,
            local: Bool = true
        ) {
            find.present(
                over: window, currentFolder: dir, everywhere: everywhere, mode: mode,
                folderIsLocal: local,
                onReveal: { log.revealed.append($0) }, onOpen: { log.opened.append($0) })
        }
        func status() -> String { find.debugStatus }
        let pump = { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
        /// Drive one search to its ranked answer; returns the results.
        func answerAll(_ dir: URL, recursive: Bool, ranking: [Int], cap: Int? = nil) {
            _ = settle { entriesGate.pending == 1 }
            entriesGate.answer(.success(listed(dir, recursive: recursive)))
            _ = settle { indexGate.pending == 1 }
            indexGate.answer(.success(fullIndex(cap ?? listed(dir, recursive: recursive).count)))
            _ = settle { rankGate.pending == 1 }
            rankGate.answer(.success(ranking))
        }

        // Mode: the popup has three entries, the default is still file name, and the existing
        // command opens the panel in semantic mode.
        present(mode: .filename)
        check(
            "semanticpanel-three-modes-default-filename",
            find.debugModeTitles.count == 3 && find.debugMode.indexOfSelectedItem == 0)
        find.debugPanel.cancelOperation(nil)
        activePane = pane
        pane.navigate(to: folder)
        _ = settle { pane.entries.count == 31 }
        let paneState = (pane.currentURL, pane.isShowingSearchResults, pane.entries.count)
        check(
            "semanticpanel-command-opens-semantic-mode",
            commands.perform("search.semantic")
                && globalSearchController.debugMode.indexOfSelectedItem == 2
                && globalSearchController.debugPanel.isVisible)
        globalSearchController.debugPanel.cancelOperation(nil)

        // States, for This Folder with subfolders (the default).
        present()
        find.debugSetKeyword("alpha")
        check(
            "semanticpanel-indexing-state",
            settle { entriesGate.labels == ["panel-folder|deep"] && status() == "Indexing…" })
        entriesGate.answer(.success(listed(folder, recursive: true)))
        _ = settle { indexGate.pending == 1 }
        check("semanticpanel-indexing-persists", status() == "Indexing…" && find.debugBusy)
        indexGate.answer(.success(fullIndex(40)))
        check(
            "semanticpanel-ranking-state",
            settle { rankGate.pending == 1 && status() == "Ranking…" }
                && !find.debugOpen.isEnabled)
        rankGate.answer(.success([3, 1, 2]))
        let deep = listed(folder, recursive: true)
        check(
            "semanticpanel-results-listed",
            settle { find.debugResults.count == 3 && !find.debugBusy }
                && status() == "3 matching items."
                && find.debugResults.map(\.lastPathComponent)
                    == [3, 1, 2].map { deep[$0].name }
                && find.debugOpen.isEnabled)
        check(
            "semanticpanel-recursive-result-url-uses-its-own-folder",
            find.debugResults.allSatisfy { fm.fileExists(atPath: $0.path) })

        // The index is cached: a second query goes straight to Ranking.
        find.debugSetKeyword("beta")
        check(
            "semanticpanel-cached-index-skips-indexing",
            settle { rankGate.pending == 1 && status() == "Ranking…" }
                && entriesGate.pending == 0 && indexGate.pending == 0)
        rankGate.answer(.success([]))
        check(
            "semanticpanel-no-matches-state",
            settle { !find.debugBusy && status() == "No matching files." })

        // Scope: subfolders off asks for a flat index; Other Folder indexes that folder.
        find.debugSetSubfolders(false)
        check(
            "semanticpanel-subfolders-off-flat-request",
            settle { entriesGate.labels == ["panel-folder|flat"] })
        answerAll(folder, recursive: false, ranking: [0, 1])
        check(
            "semanticpanel-flat-results",
            settle { find.debugResults.count == 2 && !find.debugBusy }
                && find.debugResults.allSatisfy {
                    $0.deletingLastPathComponent().path
                        == folder.resolvingSymlinksInPath().path
                        || $0.deletingLastPathComponent().path == folder.path
                })
        find.debugChooseFolder(other)
        check(
            "semanticpanel-other-folder-request",
            settle { entriesGate.labels == ["panel-other|flat"] })
        answerAll(other, recursive: false, ranking: [0])
        check(
            "semanticpanel-other-folder-results",
            settle { find.debugResults.count == 1 && !find.debugBusy }
                && find.debugResults[0].deletingLastPathComponent().lastPathComponent
                    == "panel-other"
        )

        // Scope: This Mac makes the mode unavailable and says why; no index is built.
        present()
        find.debugSetKeyword("alpha")
        _ = settle { entriesGate.pending == 1 }
        entriesGate.answer(.failure(FixtureError(message: "stop")))
        _ = settle { !find.debugBusy }
        present(everywhere: true)
        check(
            "semanticpanel-this-mac-says-why",
            status()
                == "Semantic search ranks one folder at a time. Choose This Folder or Other Folder…."
                && !find.debugSemanticItemEnabled)
        find.debugSetKeyword("alpha")
        pump()
        check(
            "semanticpanel-this-mac-starts-no-work",
            entriesGate.pending == 0 && indexGate.pending == 0 && rankGate.pending == 0
                && find.debugResults.isEmpty && !find.debugBusy)
        find.debugSetScope(index: 0)
        check(
            "semanticpanel-leaving-this-mac-reenables-mode",
            find.debugSemanticItemEnabled && find.debugMode.indexOfSelectedItem == 2)
        // The other modes stay available over This Mac.
        present(everywhere: true, mode: .filename)
        check("semanticpanel-mac-other-modes-unaffected", status() == "Type a keyword to search.")
        // A remote pane has no local folder to index.
        present(local: false)
        check(
            "semanticpanel-remote-pane-says-why",
            status() == "Semantic search works on local folders, not remote ones.")
        find.debugSetKeyword("x")
        pump()
        check("semanticpanel-remote-pane-starts-no-work", entriesGate.pending == 0)

        // Failure states.
        semanticSearch.invalidate()
        present()
        find.debugSetKeyword("gamma")
        _ = settle { entriesGate.pending == 1 }
        entriesGate.answer(.failure(FixtureError(message: "disk gone")))
        check(
            "semanticpanel-failure-shows-reason",
            settle {
                status() == "Semantic search could not index this folder: disk gone"
                    && !find.debugBusy && find.debugResults.isEmpty
            })
        semanticSearch.invalidate()
        find.debugSetKeyword("gamma2")
        _ = settle { entriesGate.pending == 1 }
        entriesGate.answer(.success(listed(folder, recursive: true)))
        _ = settle { indexGate.pending == 1 }
        indexGate.answer(.success(FolderSemanticIndex(ids: [], vectors: [])))
        check(
            "semanticpanel-empty-index-shows-reason",
            settle {
                status().hasPrefix("Semantic search could not index this folder: ")
                    && !find.debugBusy
            })

        // Cap, with a small injected cap.
        semanticSearch.invalidate()
        semanticSearch.maxItems = 10
        find.debugSetKeyword("delta")
        _ = settle { entriesGate.pending == 1 }
        entriesGate.answer(.success(listed(folder, recursive: true)))
        _ = settle { indexGate.pending == 1 }
        check("semanticpanel-index-receives-cap", indexGate.labels == ["10"])
        indexGate.answer(.success(fullIndex(10)))
        _ = settle { rankGate.pending == 1 }
        rankGate.answer(.success([0, 1]))
        check(
            "semanticpanel-cap-note-with-results",
            settle {
                status() == "2 matching items. Only the first 10 items were indexed."
                    && find.debugResults.count == 2
            })
        semanticSearch.maxItems = SemanticSearchController.defaultMaxItems

        // Keyboard: arrows move the selection, Return reveals, the Open button opens.
        semanticSearch.invalidate()
        present()
        find.debugSetKeyword("alpha")
        answerAll(folder, recursive: true, ranking: [5, 6, 7])
        _ = settle { find.debugResults.count == 3 && !find.debugBusy }
        guard let editor = find.debugField.currentEditor() as? NSTextView else {
            check("semanticpanel-field-editor", false)
            return
        }
        let down = find.control(
            find.debugField, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        check("semanticpanel-arrow-down-selects-second", down && find.debugTable.selectedRow == 1)
        let target = find.debugResults[1]
        _ = find.control(
            find.debugField, textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
        check(
            "semanticpanel-return-reveals-and-dismisses",
            log.revealed == [target] && log.opened.isEmpty && !find.debugPanel.isVisible)
        present()
        find.debugSetKeyword("alpha")  // cached index: ranking only
        _ = settle { rankGate.pending == 1 }
        rankGate.answer(.success([8, 9]))
        _ = settle { find.debugResults.count == 2 && !find.debugBusy }
        let openTarget = find.debugResults[0]
        find.debugOpenSelected()
        check(
            "semanticpanel-open-opens-and-dismisses",
            log.opened == [openTarget] && !find.debugPanel.isVisible)

        // Races. A reveal while still ranking is refused (actions are disabled while busy).
        present()
        find.debugSetKeyword("one")
        _ = settle { rankGate.pending == 1 }
        let revealedBefore = log.revealed.count
        find.debugRevealSelected()
        check(
            "semanticpanel-reveal-refused-while-ranking",
            log.revealed.count == revealedBefore && find.debugPanel.isVisible)
        // The query changes: the old query's answer must not land, the new one's does.
        find.debugSetKeyword("two")
        check(
            "semanticpanel-both-queries-reach-ranking",
            settle { Set(rankGate.labels) == ["one", "two"] })
        rankGate.answer(.success([1]), label: "one")
        pump()
        check(
            "semanticpanel-old-query-answer-ignored",
            find.debugResults.isEmpty && status() == "Ranking…")
        rankGate.answer(.success([2, 3]), label: "two")
        check(
            "semanticpanel-new-query-answer-lands",
            settle { find.debugResults.count == 2 && !find.debugBusy })
        // The query is cleared while ranking: nothing lands and no state lingers.
        find.debugSetKeyword("three")
        _ = settle { rankGate.pending == 1 }
        find.debugSetKeyword("")
        rankGate.answer(.success([4]))
        pump()
        check(
            "semanticpanel-answer-after-clear-ignored",
            find.debugResults.isEmpty && status() == "Type a keyword to search."
                && !find.debugBusy)
        // The mode changes while ranking: the semantic answer must not land in the name list.
        find.debugSetKeyword("four")
        _ = settle { rankGate.pending == 1 }
        find.debugSetMode(.filename)
        rankGate.answer(.success([4]))
        pump()
        check(
            "semanticpanel-answer-after-mode-change-ignored",
            !status().contains("Ranking…") && find.debugMode.indexOfSelectedItem == 0)
        find.debugSetMode(.semantic)
        // The scope changes while ranking: the old folder's answer must not land.
        find.debugSetKeyword("five")
        _ = settle { rankGate.pending == 1 }
        find.debugSetSubfolders(false)
        _ = settle { entriesGate.pending == 1 }
        rankGate.answer(.success([4]))
        pump()
        check(
            "semanticpanel-answer-after-scope-change-ignored",
            find.debugResults.isEmpty && status() == "Indexing…")
        answerAll(folder, recursive: false, ranking: [0])
        check(
            "semanticpanel-new-scope-answer-lands",
            settle { find.debugResults.count == 1 && !find.debugBusy })
        // The panel closes while indexing: the late answer must not land, and reopening shows
        // a clean panel, not a stuck state.
        semanticSearch.invalidate()
        find.debugSetKeyword("six")
        _ = settle { entriesGate.pending == 1 }
        find.debugPanel.cancelOperation(nil)
        entriesGate.answer(.success(listed(folder, recursive: false)))
        pump()
        indexGate.answer(.success(fullIndex(31)))
        rankGate.answer(.success([1]))
        pump()
        present()
        check(
            "semanticpanel-reopen-after-close-is-clean",
            find.debugResults.isEmpty && status() == "Type a keyword to search."
                && !find.debugBusy && find.debugField.stringValue.isEmpty)
        // Focus moving to the other pane while indexing changes nothing: the pane never takes
        // part in a semantic search.
        semanticSearch.invalidate()
        find.debugSetKeyword("seven")
        _ = settle { entriesGate.pending == 1 }
        if let right = rightTabs.activePane { setActiveSide(rightTabs, pane: right) }
        answerAll(folder, recursive: true, ranking: [1])
        check(
            "semanticpanel-answer-lands-after-focus-change",
            settle { find.debugResults.count == 1 && !find.debugBusy })
        find.debugPanel.cancelOperation(nil)

        // The pane was never re-ranked, whatever the panel did.
        setActiveSide(leftTabs, pane: pane)
        check(
            "semanticpanel-pane-untouched",
            pane.currentURL == paneState.0 && !pane.isShowingSearchResults
                && pane.entries.count == paneState.2 && pane.searchPhase == nil
                && pane.searchFailure == nil)
    }
}
#endif
