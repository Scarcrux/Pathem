#if DEBUG
import AppKit
import PathemEngine

/// Semantic search must say what it is doing (Mission 53 task 13, S2). The backend here hands
/// out each slow step (enumerate, embed, rank) and completes it when the check says so, so
/// "the answer arrived after the query changed" is produced deliberately and no timer decides
/// a verdict. The real on-device model is never loaded.
extension BrowserViewController {
    struct FixtureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Requests waiting for an answer, matched by label.
    final class Gate<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [(label: String, answer: (Result<Value, Error>) -> Void)] = []
        func request(_ label: String) async throws -> Value {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    waiting.append((label, { continuation.resume(with: $0) }))
                }
            }
        }
        var pending: Int { lock.withLock { waiting.count } }
        var labels: [String] { lock.withLock { waiting.map(\.label) } }
        func answer(_ result: Result<Value, Error>, label: String? = nil) {
            let next = lock.withLock { () -> ((Result<Value, Error>) -> Void)? in
                guard
                    let i = waiting.firstIndex(where: { label == nil || $0.label == label })
                else { return nil }
                return waiting.remove(at: i).answer
            }
            next?(result)
        }
    }

    func checkSemanticSearch(
        root: URL, check: (String, Bool) -> Void, settle: (() -> Bool) -> Bool
    ) {
        guard let pane = leftTabs.activePane else {
            check("semantic-pane", false)
            return
        }
        let fm = FileManager.default
        let folder = root.appendingPathComponent("semantic-folder")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let count = 200
        for i in 0..<count {
            let name = String(format: "f%03d.txt", i)
            try? "x".write(
                to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        activePane = pane
        // Earlier checks in the full suite leave the pane in column view; start from a list.
        pane.setViewMode(.list)
        _ = settle { pane.viewMode == .list }
        pane.navigate(to: folder)
        check("semantic-fixture-listed", settle { pane.entries.count == count })
        let fixtureEntries =
            (try? BulkEnumerator().entries(of: folder, includingHidden: false)) ?? []
        let names = fixtureEntries.map(\.name)

        let entriesGate = Gate<[FileEntry]>()
        let indexGate = Gate<FolderSemanticIndex>()
        let rankGate = Gate<[Int]>()
        semanticSearch.invalidate()
        semanticSearch.backend = SemanticSearchController.Backend(
            entries: { directory, _ in try await entriesGate.request(directory.lastPathComponent) },
            index: { entries, _, cap, _ in
                (try? await indexGate.request("\(min(entries.count, cap))"))
                    ?? FolderSemanticIndex(ids: [], vectors: [])
            },
            rank: { query, _ in (try? await rankGate.request(query)) ?? [] })
        func fullIndex(_ n: Int) -> FolderSemanticIndex {
            FolderSemanticIndex(ids: Array(0..<n), vectors: Array(repeating: [1], count: n))
        }
        func status() -> String { pane.debugStatusText() }
        func clipY() -> CGFloat { pane.contentClipView.bounds.origin.y }
        func scrollTo(_ y: CGFloat) {
            pane.contentClipView.scroll(to: NSPoint(x: 0, y: y))
            pane.contentClipView.enclosingScrollView?.reflectScrolledClipView(pane.contentClipView)
        }
        // Other checks leave focus on either pane; search acts on the active one, so claim it.
        func search(_ query: String) {
            activePane = pane
            performSearch(query)
        }
        let pump = { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        func cleanUp() {
            search("")
            pump()
        }

        // The listing the user had before searching: a selection and a scrolled position.
        let selected: Set<String> = [names[120], names[121]]
        pane.debugSelectNames(Array(selected))
        scrollTo(1200)
        let scrollBefore = clipY()
        check(
            "semantic-fixture-scrolled",
            scrollBefore > 500 && Set(pane.selectedEntries.map(\.name)) == selected)

        // States: Indexing, then Ranking, then the results.
        search("alpha")
        check(
            "semantic-indexing-status-shown",
            settle { entriesGate.pending == 1 && status() == "Indexing…" })
        entriesGate.answer(.success(fixtureEntries))
        check(
            "semantic-indexing-persists-while-embedding",
            settle { indexGate.pending == 1 } && status() == "Indexing…")
        indexGate.answer(.success(fullIndex(count)))
        check(
            "semantic-ranking-status-shown",
            settle { rankGate.pending == 1 && status() == "Ranking…" })
        rankGate.answer(.success([2, 1, 0]))
        check(
            "semantic-results-replace-the-states",
            settle { pane.entries.map(\.name) == [names[2], names[1], names[0]] }
                && !status().contains("…") && !status().contains("Only the first"))

        // Clear: the same selection and scroll position come back.
        search("")
        check("semantic-clear-restores-listing", settle { pane.entries.count == count })
        check(
            "semantic-clear-restores-selection",
            settle { Set(pane.selectedEntries.map(\.name)) == selected })
        check(
            "semantic-clear-restores-scroll",
            settle { abs(clipY() - scrollBefore) < 1 })

        // A second search reuses the cached index: straight to Ranking, no indexing step.
        search("beta")
        check(
            "semantic-cached-index-skips-indexing",
            settle { rankGate.pending == 1 && status() == "Ranking…" }
                && entriesGate.pending == 0 && indexGate.pending == 0)
        rankGate.answer(.success([5]))
        _ = settle { pane.entries.count == 1 }
        cleanUp()
        _ = settle { pane.entries.count == count }

        // Failure: enumeration throws; the reason is shown, not an empty or unchanged list.
        semanticSearch.invalidate()
        search("gamma")
        _ = settle { entriesGate.pending == 1 }
        entriesGate.answer(.failure(FixtureError(message: "disk gone")))
        check(
            "semantic-enumeration-failure-shows-reason",
            settle {
                pane.searchFailure == "Semantic search could not index this folder: disk gone"
            } && pane.entries.isEmpty && !status().contains("…"))
        cleanUp()
        check("semantic-failure-clear-restores", settle { pane.entries.count == count })

        // Failure: nothing could be embedded (model not ready).
        semanticSearch.invalidate()
        search("gamma")
        _ = settle { entriesGate.pending == 1 }
        entriesGate.answer(.success(fixtureEntries))
        _ = settle { indexGate.pending == 1 }
        indexGate.answer(.success(FolderSemanticIndex(ids: [], vectors: [])))
        check(
            "semantic-empty-index-failure-shows-reason",
            settle {
                pane.searchFailure?.hasPrefix("Semantic search could not index this folder: ")
                    == true
            })
        cleanUp()
        _ = settle { pane.entries.count == count }

        // Cap: more items than the index covers, with a small injected cap.
        semanticSearch.invalidate()
        semanticSearch.maxItems = 10
        search("delta")
        _ = settle { entriesGate.pending == 1 }
        entriesGate.answer(.success(fixtureEntries))
        _ = settle { indexGate.pending == 1 }
        check("semantic-index-receives-the-cap", indexGate.labels == ["10"])
        indexGate.answer(.success(fullIndex(10)))
        _ = settle { rankGate.pending == 1 }
        rankGate.answer(.success([0, 1]))
        check(
            "semantic-cap-note-shown-with-results",
            settle {
                pane.entries.count == 2
                    && status().contains("Only the first 10 items were indexed.")
            })
        cleanUp()
        _ = settle { pane.entries.count == count }
        semanticSearch.maxItems = SemanticSearchController.defaultMaxItems

        // Stale: the query changed while the folder was being indexed. The old query's rank
        // answer must not land; the new one's does.
        semanticSearch.invalidate()
        search("one")
        _ = settle { entriesGate.pending == 1 }
        search("two")
        entriesGate.answer(.success(fixtureEntries))
        _ = settle { indexGate.pending == 1 }
        indexGate.answer(.success(fullIndex(count)))
        check(
            "semantic-both-queries-reach-ranking",
            settle { Set(rankGate.labels) == ["one", "two"] })
        rankGate.answer(.success([7]), label: "one")
        pump()
        check(
            "semantic-old-query-answer-ignored",
            pane.entries.count == count && status() == "Ranking…")
        rankGate.answer(.success([8, 9]), label: "two")
        check(
            "semantic-new-query-answer-lands",
            settle { pane.entries.map(\.name) == [names[8], names[9]] })
        cleanUp()
        _ = settle { pane.entries.count == count }

        // Stale: the query was cleared while ranking. The late answer must not replace the
        // restored listing, and the state must not linger.
        search("three")
        _ = settle { rankGate.pending == 1 }
        search("")
        rankGate.answer(.success([3]))
        pump()
        check(
            "semantic-answer-after-clear-ignored",
            pane.entries.count == count && !status().contains("…"))

        // Stale: focus moved to the other pane while ranking. The answer is dropped, and the
        // searched pane must not keep "Ranking…" in its status line for good.
        if let other = rightTabs.activePane {
            search("four")
            _ = settle { rankGate.pending == 1 && status() == "Ranking…" }
            activePane = other
            rankGate.answer(.success([4]))
            pump()
            check(
                "semantic-focus-change-clears-the-state",
                pane.entries.count == count && !status().contains("…"))
            cleanUp()
            _ = settle { pane.entries.count == count }
        } else {
            check("semantic-focus-change-clears-the-state", false)
        }

        // Refusals: each says why, in the status line, and starts no work.
        pane.setViewMode(.column)
        check("semantic-column-mode-entered", settle { pane.viewMode == .column })
        search("x")
        check(
            "semantic-refuses-column-view",
            status()
                == "Semantic search is not available in column view. Switch to list, icon or gallery view."
                && entriesGate.pending == 0 && rankGate.pending == 0)
        pane.setViewMode(.list)
        _ = settle { pane.viewMode == .list && pane.entries.count == count }

        pane.openRemote(
            RemoteConnection(name: "Fixture", proto: .sftp, host: "fixture.invalid"), password: "")
        check("semantic-remote-pane-entered", pane.isRemote)
        search("x")
        check(
            "semantic-refuses-remote-pane",
            status() == "Semantic search works on local folders, not remote ones."
                && entriesGate.pending == 0)
        pane.closeRemote()
        _ = settle { !pane.isRemote }
        pane.navigate(to: folder)
        _ = settle { pane.entries.count == count }

        pane.showSmartResults([], title: "Fixture smart list")
        check("semantic-smart-view-entered", pane.isShowingSmartResults)
        search("x")
        check(
            "semantic-refuses-smart-results",
            status()
                == "Semantic search is not available over search results or smart lists. Open a folder first."
                && entriesGate.pending == 0)
        pane.navigate(to: folder)
        _ = settle { !pane.isShowingSmartResults && pane.entries.count == count }
        // Control: with none of those conditions, the same call runs the search.
        search("x")
        check(
            "semantic-control-plain-folder-searches",
            settle { entriesGate.pending == 1 || indexGate.pending == 1 || rankGate.pending == 1 })
        search("")
        semanticSearch.backend = .live
        semanticSearch.invalidate()
    }
}
#endif
