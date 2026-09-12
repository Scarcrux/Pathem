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

        // Scenario 4b: cut+paste of REAL iCloud (ubiquitous) files. This is the branch scenario 4
        // can't reach -- a temp dir isn't ubiquitous, so the move above never enters coordinatedMove
        // (the NSFileCoordinator path that the "iCloud paste duplicated the files" fix lives in).
        // Files created under com~apple~CloudDocs are ubiquitous immediately (before upload), so this
        // exercises the coordinated move for real. It skips cleanly when there is no iCloud Drive, and
        // it removes its temp subfolders (they sync to the cloud briefly, then go). The original
        // symptom involved dataless/online-only files, which can't be synthesized on demand; what it
        // proves is the correctness the fix guarantees -- moved not copied, no leftover on the source.
        let iCloudBase = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fm.fileExists(atPath: iCloudBase.path) {
            let stamp = "pathem-uitest-icloud-\(ProcessInfo.processInfo.processIdentifier)"
            let src = iCloudBase.appendingPathComponent("\(stamp)-src", isDirectory: true)
            let dst = iCloudBase.appendingPathComponent("\(stamp)-dst", isDirectory: true)
            defer { try? fm.removeItem(at: src); try? fm.removeItem(at: dst) }
            try? fm.removeItem(at: src)
            try? fm.removeItem(at: dst)
            try? fm.createDirectory(at: src, withIntermediateDirectories: true)
            try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let names = ["ic-a.txt", "ic-b.txt", "ic-c.txt"]
            for n in names { fm.createFile(atPath: src.appendingPathComponent(n).path, contents: Data("x".utf8)) }
            // Sanity: assert the source really is ubiquitous, else this scenario is vacuous (it would
            // silently take the plain-move path and pretend to cover the iCloud branch).
            let ubiquitous = (try? src.appendingPathComponent(names[0])
                .resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
            check("icloud-cut-paste-is-ubiquitous", ubiquitous, "isUbiquitousItem=\(ubiquitous)")
            navigate(to: src, expecting: names.count)
            otherPane?.navigate(to: dst)
            _ = waitUntil(3) { self.otherPane?.currentURL == dst }
            pumpRunLoop(0.3)
            activePane?.debugSelectNames(names)
            pumpRunLoop(0.1)
            cut(nil)
            pasteInto(otherPane)
            _ = waitUntil(6) {
                names.allSatisfy { self.activePane?.debugHasEntry($0) == false && self.otherPane?.debugHasEntry($0) == true }
            }
            let sourceCleared = names.allSatisfy { activePane?.debugHasEntry($0) == false }
            let destPopulated = names.allSatisfy { otherPane?.debugHasEntry($0) == true }
            let srcEmptyOnDisk = ((try? fm.contentsOfDirectory(atPath: src.path))?.filter { !$0.hasPrefix(".") }.isEmpty) ?? false
            check("icloud-cut-paste-clears-source", sourceCleared)
            check("icloud-cut-paste-populates-dest", destPopulated)
            check("icloud-cut-paste-no-duplicate-on-disk", srcEmptyOnDisk)
        } else {
            FileHandle.standardError.write(Data("UITEST: SKIP  icloud-cut-paste  (no iCloud Drive)\n".utf8))
        }

        // Scenario 5: switching a pane to Gallery must NOT auto-open the separate (far-right) preview
        // pane. Gallery draws its own inline preview, so the extra pane just duplicated the selection
        // across the window over the OTHER pane (the reported bug). Even with the old pref on.
        do {
            prefs.previewInGalleryView = true
            let dir = makeDir("gallery") { d in
                for i in 0..<6 { fm.createFile(atPath: d.appendingPathComponent("img-\(i).txt").path, contents: Data("x".utf8)) }
            }
            navigate(to: dir, expecting: 6)
            setActiveViewMode(.gallery)
            pumpRunLoop(0.6)
            check("gallery-no-auto-preview-pane", !previewPane.isVisible, "previewVisible=\(previewPane.isVisible)")
            setActiveViewMode(.list)  // restore
            pumpRunLoop(0.3)
        }

        // Scenario 6: the preview pane the user opens by hand shows then hides -- guards the toggle
        // path after PreviewPaneController extraction (5.6). Asserts the pane docks into outerSplit
        // (a third arranged subview) and that closing it removes it without collapsing the panes.
        do {
            let panesBefore = outerSplit.arrangedSubviews.count
            togglePreviewPane()  // open
            pumpRunLoop(0.3)
            let opened = previewPane.isVisible
                && outerSplit.arrangedSubviews.contains(previewPane.view)
            check("preview-pane-opens-docked", opened, "visible=\(previewPane.isVisible) subviews=\(outerSplit.arrangedSubviews.count)")
            togglePreviewPane()  // close
            pumpRunLoop(0.3)
            let closed = !previewPane.isVisible
                && !outerSplit.arrangedSubviews.contains(previewPane.view)
                && outerSplit.arrangedSubviews.count == panesBefore
            check("preview-pane-closes-clean", closed, "visible=\(previewPane.isVisible) subviews=\(outerSplit.arrangedSubviews.count) before=\(panesBefore)")
        }

        // Scenario 7: right-clicking the toolbar BACKGROUND must offer "Customize Toolbar..." (the
        // native NSToolbar contextual menu; allowsUserCustomization is on). Asks the toolbar view
        // directly for the menu it would show at a background point, so no real event injection.
        do {
            func findToolbarView(_ v: NSView) -> NSView? {
                if String(describing: type(of: v)).contains("ToolbarView") { return v }
                for sub in v.subviews { if let f = findToolbarView(sub) { return f } }
                return nil
            }
            var detail = "no toolbar view"
            var ok = false
            if let window = view.window, let frame = window.contentView?.superview,
                let tbv = findToolbarView(frame) {
                // Probe a few x positions across the strip; at least one must be background.
                let ys = tbv.bounds.midY
                var offered: [String] = []
                for fx in stride(from: 0.05, through: 0.95, by: 0.05) {
                    let pt = NSPoint(x: tbv.bounds.width * fx, y: ys)
                    guard let ev = NSEvent.mouseEvent(
                        with: .rightMouseDown, location: tbv.convert(pt, to: nil), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                    let hit = tbv.hitTest(tbv.convert(pt, to: tbv.superview))
                    let menu = hit?.menu(for: ev) ?? tbv.menu(for: ev)
                    let titles = menu?.items.map(\.title) ?? []
                    if titles.contains(where: { $0.hasPrefix("Customize") }) { ok = true; offered = titles; break }
                    if offered.isEmpty, !titles.isEmpty { offered = titles }
                }
                detail = "toolbarView=\(type(of: tbv)) menuItems=\(offered)"
            }
            check("toolbar-right-click-offers-customize", ok, detail)
        }

        // Scenario 8: the pane header row is customizable. Toggling a button through the menu path
        // must hide it in BOTH panes (global pref), persist, actually collapse the row, and the
        // header's right-click menu must list all six buttons with the right check states.
        do {
            let before = activePane?.debugHeaderRowWidth ?? 0
            activePane?.debugToggleHeaderButton("sort")
            pumpRunLoop(0.2)
            let hiddenHere = activePane?.debugHeaderButtonHidden("sort") == true
            let hiddenOther = otherPane?.debugHeaderButtonHidden("sort") == true
            let persisted = prefs.hiddenPaneHeaderButtons == ["sort"]
            let after = activePane?.debugHeaderRowWidth ?? 0
            check("pane-header-hide-applies-to-both-panes", hiddenHere && hiddenOther, "here=\(hiddenHere) other=\(hiddenOther)")
            check("pane-header-hide-persists-to-prefs", persisted, "prefs=\(prefs.hiddenPaneHeaderButtons)")
            check("pane-header-hide-collapses-row", after < before, "width \(Int(before)) -> \(Int(after))")
            let menu = activePane?.debugHeaderMenuState() ?? []
            let sixItems = menu.count == 6
            let sortOff = menu.first { $0.0 == L("pane.sortTooltip", "Sort") }?.1 == false
            let othersOn = menu.filter { $0.0 != L("pane.sortTooltip", "Sort") }.allSatisfy(\.1)
            check("pane-header-menu-lists-six-with-states", sixItems && sortOff && othersOn, "items=\(menu)")
            activePane?.debugToggleHeaderButton("sort")  // restore
            pumpRunLoop(0.2)
            check(
                "pane-header-show-restores-everywhere",
                activePane?.debugHeaderButtonHidden("sort") == false && otherPane?.debugHeaderButtonHidden("sort") == false
                    && prefs.hiddenPaneHeaderButtons.isEmpty)
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
