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
            _ = waitUntil(3) {
                self.activePane?.currentURL == dir && self.activePane?.debugEntryCount == count
            }
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
                    try? fm.createDirectory(
                        at: d.appendingPathComponent("sub-\(i)"), withIntermediateDirectories: true)
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
                    at: dir.appendingPathComponent(String(format: "folder-%03d", i)),
                    withIntermediateDirectories: true)
            }
        }
        navigate(to: manyFolders, expecting: 40)
        let overflows =
            (activePane?.debugListContentHeight ?? 0) > (activePane?.debugListClipHeight ?? 0)
        check(
            "list-overflows-viewport", overflows,
            "content=\(Int(activePane?.debugListContentHeight ?? 0)) clip=\(Int(activePane?.debugListClipHeight ?? 0))"
        )

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
                    fm.createFile(
                        atPath: dir.appendingPathComponent(String(format: "file-%02d.txt", i)).path,
                        contents: Data("x".utf8))
                }
            }
            navigate(to: dir, expecting: 40)
            activePane?.select(name: "file-00.txt")  // top by name, in view
            pumpRunLoop(0.2)
            activePane?.debugFireSort(.name, ascending: false)  // name desc -> file-00 to the bottom
            let visible = waitUntil(3) { self.activePane?.debugRowVisible("file-00.txt") == true }
            check("sort-keeps-selection-visible", visible)
        }

        // Scenario 3b: an external app can update an opened file's metadata. The watcher-driven
        // refresh then re-sorts it without going through the explicit column-header callback above.
        // A file that was visible when opened must remain visible at its new row.
        do {
            let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
            let dir = makeDir("open-refresh") { dir in
                for i in 0..<40 {
                    let url = dir.appendingPathComponent(String(format: "opened-%02d.txt", i))
                    fm.createFile(atPath: url.path, contents: Data("x".utf8))
                    try? fm.setAttributes(
                        [.modificationDate: baseDate.addingTimeInterval(Double(i))],
                        ofItemAtPath: url.path)
                }
            }
            navigate(to: dir, expecting: 40)
            activePane?.debugFireSort(.date, ascending: true)
            _ = waitUntil(3) { self.activePane?.debugEntryCount == 40 }
            pumpRunLoop(0.3)
            activePane?.select(name: "opened-00.txt")  // oldest: visible at the top
            pumpRunLoop(0.2)
            try? fm.setAttributes(
                [.modificationDate: baseDate.addingTimeInterval(10_000)],
                ofItemAtPath: dir.appendingPathComponent("opened-00.txt").path)
            activePane?.reload()  // the same in-place path used by the folder watcher
            let moved = waitUntil(3) { self.activePane?.debugEntryPosition("opened-00.txt") == 39 }
            pumpRunLoop(0.2)
            let visible = activePane?.debugRowVisible("opened-00.txt") == true
            check("open-metadata-refresh-keeps-selection-visible", moved && visible)
        }

        // Scenario 4: cut+paste is a real move -- source cleared, dest populated, no duplicate. This
        // is the local path (the iCloud path can't run headlessly); it guards the move-not-copy family.
        do {
            let names = ["a.txt", "b.txt", "c.txt"]
            let src = makeDir("cutsrc") { d in
                for n in names {
                    fm.createFile(
                        atPath: d.appendingPathComponent(n).path, contents: Data("x".utf8))
                }
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
                names.allSatisfy {
                    self.activePane?.debugHasEntry($0) == false
                        && self.otherPane?.debugHasEntry($0) == true
                }
            }
            let sourceCleared = names.allSatisfy { activePane?.debugHasEntry($0) == false }
            let destPopulated = names.allSatisfy { otherPane?.debugHasEntry($0) == true }
            let srcEmptyOnDisk =
                ((try? fm.contentsOfDirectory(atPath: src.path))?.filter { !$0.hasPrefix(".") }
                    .isEmpty) ?? false
            check("cut-paste-move-clears-source", sourceCleared)
            check("cut-paste-move-populates-dest", destPopulated)
            check("cut-paste-no-duplicate-on-disk", srcEmptyOnDisk)
        }

        // Scenario 4b: cut+paste across every REAL iCloud boundary. A temp-only test cannot enter the
        // coordinated move path. In particular, the destination item does not exist before a
        // local-to-iCloud move, so only its containing folder can identify that crossing. Each case
        // verifies bytes as well as source removal; the delayed check catches a provider resurrecting
        // an iCloud source shortly after the operation. Online-only eviction cannot be forced here,
        // but these are genuine ubiquitous locations and exercise the same coordination boundary.
        let iCloudBase = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fm.fileExists(atPath: iCloudBase.path) {
            let stamp = "pathem-uitest-icloud-\(ProcessInfo.processInfo.processIdentifier)"
            let src = iCloudBase.appendingPathComponent("\(stamp)-src", isDirectory: true)
            let dst = iCloudBase.appendingPathComponent("\(stamp)-dst", isDirectory: true)
            let outbound = iCloudBase.appendingPathComponent("\(stamp)-outbound", isDirectory: true)
            let inbound = iCloudBase.appendingPathComponent("\(stamp)-inbound", isDirectory: true)
            defer {
                try? fm.removeItem(at: src)
                try? fm.removeItem(at: dst)
                try? fm.removeItem(at: outbound)
                try? fm.removeItem(at: inbound)
            }
            for dir in [src, dst, outbound, inbound] {
                try? fm.removeItem(at: dir)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            // iCloud -> iCloud.
            let names = ["ic-a.txt", "ic-b.txt", "ic-c.txt"]
            for n in names {
                fm.createFile(
                    atPath: src.appendingPathComponent(n).path,
                    contents: Data("cloud-to-cloud-\(n)".utf8))
            }
            // Sanity: assert the source really is ubiquitous, else this scenario is vacuous (it would
            // silently take the plain-move path and pretend to cover the iCloud branch).
            let ubiquitous =
                (try? src.appendingPathComponent(names[0])
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
                names.allSatisfy {
                    self.activePane?.debugHasEntry($0) == false
                        && self.otherPane?.debugHasEntry($0) == true
                }
            }
            let sourceCleared = names.allSatisfy { activePane?.debugHasEntry($0) == false }
            let destPopulated = names.allSatisfy { otherPane?.debugHasEntry($0) == true }
            let srcEmptyOnDisk =
                ((try? fm.contentsOfDirectory(atPath: src.path))?.filter { !$0.hasPrefix(".") }
                    .isEmpty) ?? false
            check("icloud-cut-paste-clears-source", sourceCleared)
            check("icloud-cut-paste-populates-dest", destPopulated)
            check("icloud-cut-paste-no-duplicate-on-disk", srcEmptyOnDisk)

            // iCloud -> local. The source must remain absent after the provider has had time to
            // reconcile the coordinated move.
            let outboundName = "cloud-to-local.txt"
            let outboundBytes = Data("cloud-to-local-payload".utf8)
            let outboundSource = outbound.appendingPathComponent(outboundName)
            fm.createFile(atPath: outboundSource.path, contents: outboundBytes)
            let localDestination = makeDir("icloud-outbound") { _ in }
            navigate(to: outbound, expecting: 1)
            otherPane?.navigate(to: localDestination)
            _ = waitUntil(3) { self.otherPane?.currentURL == localDestination }
            pumpRunLoop(0.3)
            activePane?.debugSelectNames([outboundName])
            cut(nil)
            pasteInto(otherPane)
            let outboundLanded = waitUntil(6) {
                !fm.fileExists(atPath: outboundSource.path)
                    && fm.fileExists(
                        atPath: localDestination.appendingPathComponent(outboundName).path)
            }
            check(
                "icloud-to-local-clears-source",
                outboundLanded && !fm.fileExists(atPath: outboundSource.path))
            check(
                "icloud-to-local-preserves-bytes",
                (try? Data(contentsOf: localDestination.appendingPathComponent(outboundName)))
                    == outboundBytes)
            pumpRunLoop(2)
            check("icloud-to-local-source-stays-gone", !fm.fileExists(atPath: outboundSource.path))

            // Local -> iCloud. The missing destination item itself reports no ubiquitous metadata;
            // the parent folder must route the operation through coordination.
            let inboundName = "local-to-cloud.txt"
            let inboundBytes = Data("local-to-cloud-payload".utf8)
            let localSource = makeDir("icloud-inbound") { dir in
                fm.createFile(
                    atPath: dir.appendingPathComponent(inboundName).path, contents: inboundBytes)
            }
            let inboundDestination = inbound.appendingPathComponent(inboundName)
            let folderUbiquitous =
                (try? inbound
                    .resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
            let missingItemUbiquitous =
                (try? inboundDestination
                    .resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
            check(
                "local-to-icloud-routes-by-destination-folder",
                folderUbiquitous && !missingItemUbiquitous,
                "folder=\(folderUbiquitous) missingItem=\(missingItemUbiquitous)")
            navigate(to: localSource, expecting: 1)
            otherPane?.navigate(to: inbound)
            _ = waitUntil(3) { self.otherPane?.currentURL == inbound }
            pumpRunLoop(0.3)
            activePane?.debugSelectNames([inboundName])
            cut(nil)
            pasteInto(otherPane)
            let inboundLanded = waitUntil(6) {
                !fm.fileExists(atPath: localSource.appendingPathComponent(inboundName).path)
                    && fm.fileExists(atPath: inboundDestination.path)
            }
            check(
                "local-to-icloud-clears-source",
                inboundLanded
                    && !fm.fileExists(atPath: localSource.appendingPathComponent(inboundName).path))
            check(
                "local-to-icloud-preserves-bytes",
                (try? Data(contentsOf: inboundDestination)) == inboundBytes)
            let inboundUbiquitous = waitUntil(6) {
                (try? inboundDestination.resourceValues(forKeys: [.isUbiquitousItemKey])
                    .isUbiquitousItem) == true
            }
            check("local-to-icloud-lands-ubiquitous", inboundUbiquitous)
        } else {
            FileHandle.standardError.write(
                Data("UITEST: SKIP  icloud-cut-paste  (no iCloud Drive)\n".utf8))
        }

        // Scenario 4c: generate the complete input-routing matrices from the registered data rather
        // than checking a hand-picked shortcut or view. Every effective shortcut must resolve to a
        // command, and every pane mode plus the fixed chrome destinations must retain its drop hook.
        let deadShortcuts = keymap.bindings.filter {
            !$0.value.isEmpty && commands.command($0.value) == nil
        }
        check(
            "shortcut-coverage-matrix", deadShortcuts.isEmpty,
            deadShortcuts.isEmpty
                ? "\(keymap.bindings.count) shortcuts resolve"
                : "dead=\(deadShortcuts.map { "\($0.key)=\($0.value)" }.sorted())")
        var dropMatrix: [String: Bool] = [:]
        for mode in ViewFormat.ViewMode.allCases {
            setActiveViewMode(mode)
            pumpRunLoop(0.1)
            let wiring = activePane?.debugDropDestinationWiring()
            dropMatrix["pane.\(mode.rawValue)"] = wiring?.content == true
            dropMatrix["breadcrumb"] = wiring?.breadcrumb == true
            dropMatrix["up"] = wiring?.up == true
        }
        dropMatrix["sidebar"] = sidebar.debugFileDropHandlerWired
        dropMatrix["drop-stack"] = shelf.debugFileDropHandlerWired
        setActiveViewMode(.list)
        let deadDrops = dropMatrix.filter { !$0.value }.map(\.key).sorted()
        check(
            "drop-destination-coverage-matrix", deadDrops.isEmpty,
            deadDrops.isEmpty
                ? dropMatrix.keys.sorted().joined(separator: ",") : "dead=\(deadDrops)")

        // Scenario 5: switching a pane to Gallery must NOT auto-open the separate (far-right) preview
        // pane. Gallery draws its own inline preview, so the extra pane just duplicated the selection
        // across the window over the OTHER pane (the reported bug). Even with the old pref on.
        do {
            prefs.previewInGalleryView = true
            let dir = makeDir("gallery") { d in
                for i in 0..<6 {
                    fm.createFile(
                        atPath: d.appendingPathComponent("img-\(i).txt").path,
                        contents: Data("x".utf8))
                }
            }
            navigate(to: dir, expecting: 6)
            setActiveViewMode(.gallery)
            pumpRunLoop(0.6)
            check(
                "gallery-no-auto-preview-pane", !previewPane.isVisible,
                "previewVisible=\(previewPane.isVisible)")
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
            let opened =
                previewPane.isVisible
                && outerSplit.arrangedSubviews.contains(previewPane.view)
            check(
                "preview-pane-opens-docked", opened,
                "visible=\(previewPane.isVisible) subviews=\(outerSplit.arrangedSubviews.count)")
            togglePreviewPane()  // close
            pumpRunLoop(0.3)
            let closed =
                !previewPane.isVisible
                && !outerSplit.arrangedSubviews.contains(previewPane.view)
                && outerSplit.arrangedSubviews.count == panesBefore
            check(
                "preview-pane-closes-clean", closed,
                "visible=\(previewPane.isVisible) subviews=\(outerSplit.arrangedSubviews.count) before=\(panesBefore)"
            )
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
                let tbv = findToolbarView(frame)
            {
                // Probe a few x positions across the strip; at least one must be background.
                let ys = tbv.bounds.midY
                var offered: [String] = []
                for fx in stride(from: 0.05, through: 0.95, by: 0.05) {
                    let pt = NSPoint(x: tbv.bounds.width * fx, y: ys)
                    guard
                        let ev = NSEvent.mouseEvent(
                            with: .rightMouseDown, location: tbv.convert(pt, to: nil),
                            modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                    else { continue }
                    let hit = tbv.hitTest(tbv.convert(pt, to: tbv.superview))
                    let menu = hit?.menu(for: ev) ?? tbv.menu(for: ev)
                    let titles = menu?.items.map(\.title) ?? []
                    if titles.contains(where: { $0.hasPrefix("Customize") }) {
                        ok = true
                        offered = titles
                        break
                    }
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
            check(
                "pane-header-hide-applies-to-both-panes", hiddenHere && hiddenOther,
                "here=\(hiddenHere) other=\(hiddenOther)")
            check(
                "pane-header-hide-persists-to-prefs", persisted,
                "prefs=\(prefs.hiddenPaneHeaderButtons)")
            check(
                "pane-header-hide-collapses-row", after < before,
                "width \(Int(before)) -> \(Int(after))")
            let menu = activePane?.debugHeaderMenuState() ?? []
            let sixItems = menu.count == 6
            let sortOff = menu.first { $0.0 == L("pane.sortTooltip", "Sort") }?.1 == false
            let othersOn = menu.filter { $0.0 != L("pane.sortTooltip", "Sort") }.allSatisfy(\.1)
            check(
                "pane-header-menu-lists-six-with-states", sixItems && sortOff && othersOn,
                "items=\(menu)")
            activePane?.debugToggleHeaderButton("sort")  // restore
            pumpRunLoop(0.2)
            check(
                "pane-header-show-restores-everywhere",
                activePane?.debugHeaderButtonHidden("sort") == false
                    && otherPane?.debugHeaderButtonHidden("sort") == false
                    && prefs.hiddenPaneHeaderButtons.isEmpty)
        }

        // Scenario 9: header reordering. A move driven through the Cmd-drag-ended path must change
        // the on-screen order in BOTH panes, persist as a full normalized order, and a partial /
        // garbage saved order must still yield every button exactly once.
        do {
            let original = activePane?.debugHeaderOrder() ?? []
            activePane?.debugReorderHeader(moving: "sort", to: 0)
            pumpRunLoop(0.2)
            let here = activePane?.debugHeaderOrder() ?? []
            let other = otherPane?.debugHeaderOrder() ?? []
            check(
                "pane-header-reorder-applies-to-both-panes", here.first == "sort" && other == here,
                "here=\(here) other=\(other)")
            check(
                "pane-header-reorder-persists-full-order",
                prefs.paneHeaderButtonOrder == here && here.count == 6,
                "prefs=\(prefs.paneHeaderButtonOrder)")
            let normalized = PaneController.normalizedHeaderOrder([
                "actions", "bogus", "actions", "up",
            ])
            check(
                "pane-header-order-normalizer-never-drops",
                normalized == ["actions", "up", "back", "forward", "viewSwitcher", "sort"],
                "\(normalized)")
            rememberHeaderButtonOrder(original)  // restore
            pumpRunLoop(0.2)
            check(
                "pane-header-reorder-restores",
                activePane?.debugHeaderOrder() == original
                    && otherPane?.debugHeaderOrder() == original)
        }

        // Scenario 9b: the Cmd-drag GESTURE itself. Synthesized Cmd mouseDown on "sort", a drag
        // leftward past the midpoints of "viewSwitcher" then "up", and mouseUp, sent to the real
        // header stack: the midpoint-crossing logic must move the button two places and end the
        // reorder (persisting it). Not just the programmatic path.
        do {
            guard let pane = activePane, let window = view.window,
                let sortFrame = pane.debugHeaderButtonFrameInWindow("sort"),
                let upFrame = pane.debugHeaderButtonFrameInWindow("up")
            else {
                check("pane-header-cmd-drag-gesture", false, "no frames")
                return exit(1)
            }
            let stack = pane.debugHeaderStack
            let y = sortFrame.midY
            func ev(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: x, y: y), modifierFlags: [.command],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let before = pane.debugHeaderOrder()
            stack.mouseDown(with: ev(.leftMouseDown, x: sortFrame.midX))
            // Step leftward in small increments so each neighbor's midpoint is crossed in turn.
            var x = sortFrame.midX
            while x > upFrame.minX - 4 {
                x -= 6
                stack.mouseDragged(with: ev(.leftMouseDragged, x: x))
            }
            stack.mouseUp(with: ev(.leftMouseUp, x: x))
            pumpRunLoop(0.2)
            let after = pane.debugHeaderOrder()
            let sortIdx = after.firstIndex(of: "sort") ?? -1
            let upIdx = after.firstIndex(of: "up") ?? -1
            let moved = sortIdx >= 0 && upIdx >= 0 && sortIdx < upIdx && after != before
            check("pane-header-cmd-drag-gesture", moved, "before=\(before) after=\(after)")
            check(
                "pane-header-cmd-drag-persists",
                prefs.paneHeaderButtonOrder == after && otherPane?.debugHeaderOrder() == after)
            rememberHeaderButtonOrder(before)  // restore
            pumpRunLoop(0.2)
        }

        // Scenario 11: in icon mode, Cmd+= (zoom in), Cmd+Shift+= (the + key) and Cmd+- (zoom out)
        // sent as real keyDown events to the icon view must change the zoom scale. Live report:
        // zoom in did nothing in icon mode while zoom out worked.
        do {
            let dir = makeDir("zoom") { d in
                for i in 0..<12 {
                    fm.createFile(
                        atPath: d.appendingPathComponent("z-\(i).txt").path,
                        contents: Data("x".utf8))
                }
            }
            navigate(to: dir, expecting: 12)
            setActiveViewMode(.icon)
            pumpRunLoop(0.4)
            if let window = view.window, let keyView = activePane?.debugIconKeyView {
                window.makeFirstResponder(keyView)
                func key(_ chars: String, _ ignoring: String, code: UInt16, shift: Bool = false)
                    -> NSEvent
                {
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero,
                        modifierFlags: shift ? [.command, .shift] : [.command],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        characters: chars, charactersIgnoringModifiers: ignoring, isARepeat: false,
                        keyCode: code)!
                }
                let s0 = activePane?.debugIconScale ?? -1
                keyView.keyDown(with: key("=", "=", code: 24))  // Cmd+=
                pumpRunLoop(0.2)
                let s1 = activePane?.debugIconScale ?? -1
                keyView.keyDown(with: key("+", "+", code: 24, shift: true))  // Cmd+Shift+= i.e. Cmd++
                pumpRunLoop(0.2)
                let s2 = activePane?.debugIconScale ?? -1
                keyView.keyDown(with: key("-", "-", code: 27))  // Cmd+-
                pumpRunLoop(0.2)
                let s3 = activePane?.debugIconScale ?? -1
                check("icon-zoom-in-cmd-equals", s1 > s0, "scale \(s0) -> \(s1)")
                check("icon-zoom-in-cmd-plus", s2 > s1, "scale \(s1) -> \(s2)")
                check("icon-zoom-out-cmd-minus", s3 < s2, "scale \(s2) -> \(s3)")
                // The REAL dispatch path (NSApp.sendEvent: menu key equivalents, then the first
                // responder). Flow A, the common one: list focused, then the user clicks the pane's
                // own view switcher to go to icons, then presses Cmd+=. Flow B: nothing focused
                // (fresh window / after clicking chrome) then the same switch and key.
                func send(_ e: NSEvent) {
                    NSApp.sendEvent(e)
                    pumpRunLoop(0.2)
                }
                func fr() -> String {
                    window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                }
                setActiveViewMode(.list)
                pumpRunLoop(0.3)
                if let listKey = activePane?.debugListKeyView { window.makeFirstResponder(listKey) }
                activePane?.debugClickViewSwitcher(.icon)
                pumpRunLoop(0.4)
                let frA = fr()
                let a0 = activePane?.debugIconScale ?? -1
                send(key("=", "=", code: 24))
                let a1 = activePane?.debugIconScale ?? -1
                send(key("-", "-", code: 27))
                let a2 = activePane?.debugIconScale ?? -1
                check(
                    "icon-zoom-real-dispatch-list-focused-then-switch", a1 > a0 && a2 < a1,
                    "firstResponder=\(frA) scale \(a0) -> \(a1) -> \(a2)")
                setActiveViewMode(.list)
                pumpRunLoop(0.3)
                window.makeFirstResponder(nil)
                activePane?.debugClickViewSwitcher(.icon)
                pumpRunLoop(0.4)
                let frB = fr()
                let b0 = activePane?.debugIconScale ?? -1
                send(key("=", "=", code: 24))
                let b1 = activePane?.debugIconScale ?? -1
                check(
                    "icon-zoom-real-dispatch-nothing-focused-then-switch", b1 > b0,
                    "firstResponder=\(frB) scale \(b0) -> \(b1)")
            } else {
                check("icon-zoom-in-cmd-equals", false, "no icon key view")
            }
            setActiveViewMode(.list)
            pumpRunLoop(0.3)
        }

        // Scenario 12: the status-row eye must show/hide dotfiles in BOTH directions, including
        // when "show hidden by default" is on (live report: the eye did nothing; effective
        // visibility was showHidden || default, so with the default on it could never hide).
        do {
            // A fresh folder per case: the eye's decision is remembered per folder (by design), so
            // reusing one would carry the first case's override into the second.
            for defaultOn in [true, false] {
                let tag = defaultOn ? "default-on" : "default-off"
                let dir = makeDir("eye-\(tag)") { d in
                    fm.createFile(
                        atPath: d.appendingPathComponent("visible.txt").path,
                        contents: Data("x".utf8))
                    fm.createFile(
                        atPath: d.appendingPathComponent(".dotfile").path, contents: Data("x".utf8))
                }
                activePane?.showHiddenByDefault = defaultOn
                navigate(to: dir, expecting: defaultOn ? 2 : 1)
                let c0 = activePane?.debugEntryCount ?? -1
                let flipped = defaultOn ? 1 : 2
                activePane?.debugClickHiddenEye()
                _ = waitUntil(3) { self.activePane?.debugEntryCount == flipped }
                let c1 = activePane?.debugEntryCount ?? -1
                let glyph1 = activePane?.debugHiddenShown == true ? "eye" : "eye.slash"
                activePane?.debugClickHiddenEye()
                _ = waitUntil(3) { self.activePane?.debugEntryCount == c0 }
                let c2 = activePane?.debugEntryCount ?? -1
                check(
                    "eye-toggles-hidden-\(tag)", c1 == flipped && c2 == c0,
                    "counts \(c0) -> \(c1) -> \(c2)")
                check(
                    "eye-glyph-tracks-state-\(tag)", glyph1 == (defaultOn ? "eye.slash" : "eye"),
                    "after first click glyph=\(glyph1)")
            }
            activePane?.showHiddenByDefault = false
        }

        // Scenario 10: the window toolbar default carries no navigation (each pane header has its
        // own) and centers the search field between two flexible spaces.
        do {
            let ids = view.window?.toolbar?.items.map(\.itemIdentifier) ?? []
            let hasNav = ids.contains { Self.toolbarCommandID($0)?.hasPrefix("nav.") == true }
            let s = ids.firstIndex(of: Self.searchItemID) ?? -1
            let centered =
                s > 0 && s + 1 < ids.count && ids[s - 1] == .flexibleSpace
                && ids[s + 1] == .flexibleSpace
            check("window-toolbar-default-no-nav", !hasNav, "\(ids.map(\.rawValue))")
            check("window-toolbar-default-search-centered", centered)
        }

        for r in results {
            FileHandle.standardError.write(
                Data("UITEST: \(r.ok ? "PASS" : "FAIL")  \(r.name)  \(r.detail)\n".utf8))
        }
        let passed = results.filter(\.ok).count
        let allPass = passed == results.count
        FileHandle.standardError.write(
            Data("RESULT: \(allPass ? "PASS" : "FAIL")  (\(passed)/\(results.count))\n".utf8))
        exit(allPass ? 0 : 1)
    }

    /// Run the main run loop for `seconds`, letting queued main-actor work (async listing reloads,
    /// layout) run -- the deterministic replacement for a fixed sleep.
    private func pumpRunLoop(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Pump the run loop until `cond` holds or `timeout` elapses; returns the final value of `cond`.
    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return cond()
    }
}
#endif
