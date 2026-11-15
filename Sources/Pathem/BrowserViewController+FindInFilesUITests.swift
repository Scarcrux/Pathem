#if DEBUG
import AppKit
import PathemEngine

/// Find in Files must only show and act on the answer to its current request (Mission 53
/// task 46). The backend here hands out each request and answers it when the test says so,
/// so "the old answer arrived after the panel moved on" is produced deliberately rather
/// than hoped for with a timer.
extension BrowserViewController {
    private final class FindBackend: @unchecked Sendable {
        private let lock = NSLock()
        private var searches: [(label: String, answer: ([ContentSearch.Match]) -> Void)] = []
        private var replaces: [(ContentSearch.ReplaceResult) -> Void] = []
        private var searchLabels: [String] = []

        func search(_ label: String) async -> [ContentSearch.Match] {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    searchLabels.append(label)
                    searches.append((label, { continuation.resume(returning: $0) }))
                }
            }
        }
        func replace() async -> ContentSearch.ReplaceResult {
            await withCheckedContinuation { continuation in
                lock.withLock { replaces.append({ continuation.resume(returning: $0) }) }
            }
        }
        var pendingSearches: Int { lock.withLock { searches.count } }
        var pendingReplaces: Int { lock.withLock { replaces.count } }
        var requested: [String] { lock.withLock { searchLabels } }
        func answerSearch(_ matches: [ContentSearch.Match]) {
            let next = lock.withLock { searches.isEmpty ? nil : searches.removeFirst() }
            next?.answer(matches)
        }
        func answerReplace() {
            let next = lock.withLock { replaces.isEmpty ? nil : replaces.removeFirst() }
            next?(ContentSearch.ReplaceResult(filesChanged: 1, replacements: 3))
        }
    }

    func checkFindInFiles(check: (String, Bool) -> Void, settle: (() -> Bool) -> Bool) {
        guard let window = view.window else {
            check("find-window", false)
            return
        }
        let backend = FindBackend()
        final class Opened { var items: [String] = [] }
        let opened = Opened()
        let find = findInFiles
        func present(_ folder: String) {
            find.present(
                over: window, folderName: folder,
                search: { query, _, _ in await backend.search("\(folder):\(query)") },
                open: { match in opened.items.append("\(folder)<-\(match.path)") },
                replace: { _, _, _, _ in await backend.replace() })
        }
        func match(_ path: String) -> ContentSearch.Match {
            ContentSearch.Match(path: path, line: 1, text: "needle")
        }
        /// Give an answer that must NOT land time to land, then prove delivery still works.
        func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }

        // Control: a request answered in its own session shows its rows.
        present("folder-A")
        find.debugSearch("needle")
        check("find-control-request-reaches-backend", settle { backend.pendingSearches == 1 })
        backend.answerSearch([match("/A/one.txt")])
        check(
            "find-control-same-session-rows-appear",
            settle { find.debugRowCount == 1 } && !find.debugBusy)

        // A request from folder A answered after the panel was re-presented for folder B.
        find.debugSearch("needle")
        _ = settle { backend.pendingSearches == 1 }
        present("folder-B")
        let resetOnPresent = find.debugRowCount == 0
        backend.answerSearch([match("/A/stale.txt")])
        pump()
        check(
            "find-old-folder-answer-ignored-after-represent",
            resetOnPresent && find.debugRowCount == 0 && find.debugTitle.contains("folder-B")
                && !find.debugBusy && find.debugStatus.isEmpty)
        // The pump above was long enough for a delivery: a fresh folder-B request lands.
        find.debugSearch("needle")
        _ = settle { backend.pendingSearches == 1 }
        backend.answerSearch([match("/B/fresh.txt")])
        let freshLanded = settle { find.debugRowCount == 1 }
        find.debugOpenRow(0)
        check(
            "find-new-session-opens-through-its-own-callback",
            freshLanded && opened.items == ["folder-B<-/B/fresh.txt"])

        // A request answered after the query was cleared.
        find.debugSearch("needle")
        _ = settle { backend.pendingSearches == 1 }
        find.debugSearch("")
        let resetOnClear = find.debugRowCount == 0
        backend.answerSearch([match("/B/after-clear.txt")])
        pump()
        check(
            "find-answer-ignored-after-query-cleared",
            resetOnClear && find.debugRowCount == 0 && find.debugStatus.isEmpty && !find.debugBusy)

        // A request answered after the panel was closed.
        find.debugSearch("needle")
        _ = settle { backend.pendingSearches == 1 }
        find.debugClose()
        backend.answerSearch([match("/B/after-close.txt")])
        pump()
        check("find-answer-ignored-after-close", find.debugRowCount == 0 && !find.debugBusy)

        // A Replace All from folder A that finishes after the panel moved to folder B must
        // not write its result into B, and must not start a search in B on B's behalf.
        present("folder-A")
        find.debugSearch("needle")
        _ = settle { backend.pendingSearches == 1 }
        backend.answerSearch([match("/A/one.txt")])
        _ = settle { find.debugRowCount == 1 }
        find.debugReplaceAllConfirmed(with: "thread")
        let replaceStarted = settle { backend.pendingReplaces == 1 }
        present("folder-B")
        let before = backend.requested.count
        backend.answerReplace()
        pump()
        check(
            "find-old-replace-does-not-touch-new-session",
            replaceStarted && find.debugStatus.isEmpty && !find.debugBusy
                && backend.requested.count == before && find.debugRowCount == 0)
        // Control: a replace that finishes in its own session reports and refreshes.
        find.debugSearch("needle")
        _ = settle { backend.pendingSearches == 1 }
        backend.answerSearch([match("/B/fresh.txt")])
        _ = settle { find.debugRowCount == 1 }
        find.debugReplaceAllConfirmed(with: "thread")
        _ = settle { backend.pendingReplaces == 1 }
        let requestsBefore = backend.requested.count
        backend.answerReplace()
        check(
            "find-control-own-replace-refreshes",
            settle { backend.requested.count == requestsBefore + 1 }
                && backend.requested.last == "folder-B:needle")
        backend.answerSearch([])
        _ = settle { !find.debugBusy }
        find.debugClose()
    }
}
#endif
