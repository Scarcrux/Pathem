// In-process UI-automation harness (PATHEM_UI_TEST). Unlike the headless smoke checks, this drives
// real UI flows in a real, sized, on-screen key window and asserts on real geometry -- so it can
// catch the interaction/scroll bugs (rename/sort scrolling the selection out of view) that headless
// probes miss. It pumps the run loop to settle the async listing reloads deterministically instead
// of guessing with fixed sleeps. Debug-only: stripped from the release binary (5.7). Run via
// `make ui-test`.
#if DEBUG
import AppKit
import PathemEngine

@MainActor
extension BrowserViewController {
    func runUIAutomation() -> Never {
        var results: [(name: String, ok: Bool, detail: String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            results.append((name, ok, detail))
        }

        // A tall, key, on-screen window so scroll/visibility assertions are meaningful. PATHEM_UI_TEST
        // ends in _TEST, so isAutomationLaunch is true and the terminal drawer won't restore and
        // squish the list (the trap that made the ad-hoc probes give a 100px-tall pane).
        if let window = view.window {
            window.setContentSize(NSSize(width: 1200, height: 820))
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        pumpRunLoop(0.4)

        let fm = FileManager.default
        func makeDir(_ tag: String, build: (URL) -> Void) -> URL {
            let dir = fm.temporaryDirectory.appendingPathComponent(
                "pathem-uitest-\(tag)-\(ProcessInfo.processInfo.processIdentifier)")
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            build(dir)
            return dir
        }
        func navigate(to dir: URL, expecting count: Int) {
            activePane?.navigate(to: dir)
            _ = waitUntil(3) { self.activePane?.currentURL == dir && self.activePane?.debugEntryCount == count }
            pumpRunLoop(0.3)
        }

        // Scenario 1: New Folder opens an inline rename right away (the "New Folder created but no
        // rename" bug).
        do {
            let dir = makeDir("newfolder") { _ in }
            navigate(to: dir, expecting: 0)
            newFolder()
            let editing = waitUntil(3) { self.activePane?.debugInlineEditing == true }
            check("new-folder-opens-inline-rename", editing, "isInlineEditing=\(editing)")
            view.window?.makeFirstResponder(nil)  // end the edit before the next scenario
            pumpRunLoop(0.3)
        }

        // Scenario 1b: New File also drops straight into an inline rename.
        do {
            let dir = makeDir("newfile") { _ in }
            navigate(to: dir, expecting: 0)
            newFile()
            let editing = waitUntil(3) { self.activePane?.debugInlineEditing == true }
            check("new-file-opens-inline-rename", editing, "isInlineEditing=\(editing)")
            view.window?.makeFirstResponder(nil)
            pumpRunLoop(0.3)
        }

        // Scenario 1c: New Folder in a POPULATED folder keeps the inline rename open after the async
        // cosmetic refreshes (folder sizes/tags/git) + the FSEvents tick land -- the "created a folder
        // but it never let me name it" bug. The empty-folder case above doesn't exercise those reloads.
        do {
            let dir = makeDir("newfolder-populated") { d in
                for i in 0..<10 {
                    try? fm.createDirectory(at: d.appendingPathComponent("sub-\(i)"), withIntermediateDirectories: true)
                }
            }
            navigate(to: dir, expecting: 10)
            newFolder()
            _ = waitUntil(3) { self.activePane?.debugInlineEditing == true }
            pumpRunLoop(1.2)  // let the async size/tag/git refreshes + watcher tick land; they must not cancel it
            check("new-folder-rename-survives-refresh", activePane?.debugInlineEditing == true)
            view.window?.makeFirstResponder(nil)
            pumpRunLoop(0.3)
        }

        // Precondition + Scenario 2 + 3 use a list taller than the viewport so scrolling matters.
        let manyFolders = makeDir("rename") { dir in
            for i in 0..<40 {
                try? fm.createDirectory(
                    at: dir.appendingPathComponent(String(format: "folder-%03d", i)), withIntermediateDirectories: true)
            }
        }
        navigate(to: manyFolders, expecting: 40)
        let overflows = (activePane?.debugListContentHeight ?? 0) > (activePane?.debugListClipHeight ?? 0)
        check(
            "list-overflows-viewport", overflows,
            "content=\(Int(activePane?.debugListContentHeight ?? 0)) clip=\(Int(activePane?.debugListClipHeight ?? 0))")

        // Scenario 2: renaming a folder that re-sorts to the bottom keeps it in view.
        do {
            debugCommitRename("folder-000", to: "folder-zzz")  // sorts to the bottom
            let visible = waitUntil(3) { self.activePane?.debugRowVisible("folder-zzz") == true }
            check("rename-resort-keeps-visible", visible)
        }

        // Scenario 3: sorting by a column header keeps the selected item in view.
        do {
            let dir = makeDir("sort") { dir in
                for i in 0..<40 {
                    fm.createFile(atPath: dir.appendingPathComponent(String(format: "file-%02d.txt", i)).path, contents: Data("x".utf8))
                }
            }
            navigate(to: dir, expecting: 40)
            activePane?.select(name: "file-00.txt")  // top by name, in view
            pumpRunLoop(0.2)
            activePane?.debugFireSort(.name, ascending: false)  // name desc -> file-00 to the bottom
            let visible = waitUntil(3) { self.activePane?.debugRowVisible("file-00.txt") == true }
            check("sort-keeps-selection-visible", visible)
        }

        // Scenario 4: cut+paste is a real move -- source cleared, dest populated, no duplicate. This
        // is the local path (the iCloud path can't run headlessly); it guards the move-not-copy family.
        do {
            let names = ["a.txt", "b.txt", "c.txt"]
            let src = makeDir("cutsrc") { d in
                for n in names { fm.createFile(atPath: d.appendingPathComponent(n).path, contents: Data("x".utf8)) }
            }
            let dst = makeDir("cutdst") { _ in }
            navigate(to: src, expecting: names.count)  // active (left) pane = source
            otherPane?.navigate(to: dst)
            _ = waitUntil(3) { self.otherPane?.currentURL == dst }
            pumpRunLoop(0.3)
            activePane?.debugSelectNames(names)
            pumpRunLoop(0.1)
            cut(nil)
            pasteInto(otherPane)
            _ = waitUntil(4) {
                names.allSatisfy { self.activePane?.debugHasEntry($0) == false && self.otherPane?.debugHasEntry($0) == true }
            }
            let sourceCleared = names.allSatisfy { activePane?.debugHasEntry($0) == false }
            let destPopulated = names.allSatisfy { otherPane?.debugHasEntry($0) == true }
            let srcEmptyOnDisk = ((try? fm.contentsOfDirectory(atPath: src.path))?.filter { !$0.hasPrefix(".") }.isEmpty) ?? false
            check("cut-paste-move-clears-source", sourceCleared)
            check("cut-paste-move-populates-dest", destPopulated)
            check("cut-paste-no-duplicate-on-disk", srcEmptyOnDisk)
        }

        for r in results {
            FileHandle.standardError.write(Data("UITEST: \(r.ok ? "PASS" : "FAIL")  \(r.name)  \(r.detail)\n".utf8))
        }
        let passed = results.filter(\.ok).count
        let allPass = passed == results.count
        FileHandle.standardError.write(Data("RESULT: \(allPass ? "PASS" : "FAIL")  (\(passed)/\(results.count))\n".utf8))
        exit(allPass ? 0 : 1)
    }

    /// Run the main run loop for `seconds`, letting queued main-actor work (async listing reloads,
    /// layout) run -- the deterministic replacement for a fixed sleep.
    private func pumpRunLoop(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    /// Pump the run loop until `cond` holds or `timeout` elapses; returns the final value of `cond`.
    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return cond()
    }
}
#endif
