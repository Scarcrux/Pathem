// Debug/automation hooks for the smoke + E2E harness. Debug-only so they never ship in the
// notarized release binary (5.7); available in `swift run` / `swift test` (both debug).
#if DEBUG
import AppKit
import PathemEngine
import TorrentKit

// PATHEM_*_SHOT / PATHEM_SMOKE diagnostic hooks: headless render, state-poking, and
// self-check entry points used only by PathemApp.swift's screenshot/demo dispatch and by
// +SmokeTest.swift's self-check — never by shipping UI. Split out of BrowserViewController.
@MainActor
extension BrowserViewController {
    /// Structural UI smoke check (run via PATHEM_SMOKE=1). Asserts the window and
    /// panes laid out sanely: exactly the class of regression that the engine
    /// tests can't see (the window-sliver and dual-pane-collapse bugs). Returns
    /// a pass/fail plus human-readable lines.
    /// Idempotent geometry invariants, polled by the smoke harness until the
    /// window has actually laid out (layout can lag a beat right after launch or
    /// under load, so a single fixed delay is flaky).
    func layoutSettled() -> Bool {
        let size = view.window?.frame.size ?? .zero
        return size.width >= 700 && size.height >= 400
            && leftTabs.containerView.frame.width > 50
            && rightTabs.containerView.frame.width > 50
            && (100...360).contains(sidebar.containerView.frame.width)
            // The listing now loads off the main thread, so "settled" must also mean the
            // startup folder's rows have arrived (else the row/column smoke checks race the read).
            && leftTabs.activePane?.entries.isEmpty == false
    }

    /// Set the active pane's view mode (PATHEM_VIEW_SHOT diagnostics).
    func debugSetActiveViewMode(_ mode: ViewFormat.ViewMode) { activePane?.setViewMode(mode) }

    /// Navigate the active pane (PATHEM_VIEW_SHOT diagnostics, bypassing session restore).
    func debugNavigateActive(to url: URL) { activePane?.navigate(to: url) }

    /// Browser-level vertical breakdown, to find what squishes the panes (the "pane pushes up"
    /// report): the window content view vs the stacked browser elements.
    func debugBrowserHeights() -> String {
        "win=\(Int(view.window?.frame.height ?? 0)) rootView=\(Int(view.frame.height)) "
            + "mainStack=\(Int(mainStack.frame.height)) vSplit=\(Int(vSplit.frame.height)) "
            + "outerSplit=\(Int(outerSplit.frame.height)) panes=\(Int(panesContainer.frame.height)) "
            + "terminal=\(Int(terminal.view.frame.height)) termHidden=\(terminal.view.isHidden)"
    }

    /// Create a new folder in the active pane (PATHEM_E2E: drives the real create flow).
    func debugNewFolder() { newFolder() }

    /// Create a new file in the active pane (PATHEM_E2E).
    func debugNewFile() { newFile() }

    /// Rename the entry named `name` in the active pane to `newName`, via the real commit path
    /// (PATHEM_E2E). Ends any in-progress inline edit first so it doesn't fight the rename.
    func debugCommitRename(_ name: String, to newName: String) {
        view.window?.makeFirstResponder(nil)  // close any inline editor from a just-created item
        guard let pane = activePane, let entry = pane.entries.first(where: { $0.name == name })
        else { return }
        commitLocalRename(entry, to: newName, pane: pane)
    }

    /// Toggle the preview pane and report whether both panes kept a real width (the
    /// regression guard for the auto-preview layout collapse). Used by the smoke self-check.
    func debugPreviewToggleKeepsPanes() -> Bool {
        let before = split.frame.width
        togglePreviewPane()  // show
        view.layoutSubtreeIfNeeded()
        let shown = split.frame.width
        togglePreviewPane()  // hide
        view.layoutSubtreeIfNeeded()
        let hidden = split.frame.width
        // With the preview open the panes must keep most of their width (not collapse to
        // zero), and closing it must restore them.
        return shown > 200 && hidden > before - 20
    }

    /// Select row N of column M in the active column view (PATHEM_VIEW_SHOT staging).
    /// Selecting a file in the last column surfaces the preview column.
    func debugDrillActive(row: Int, column: Int = 0) {
        activePane?.debugColumnDrill(row: row, column: column)
    }

    /// Hide the floating quick-actions bar so staged captures aren't photobombed by it.
    func debugHideQuickBar() { quickBar.isHidden = true }

    /// Mark every view dirty so stale layer pixels (ghost dividers after programmatic
    /// split moves and view-mode swaps) are gone before a capture.
    func debugRepaintAll() {
        func walk(_ v: NSView) {
            v.needsDisplay = true
            v.subviews.forEach(walk)
        }
        walk(view)
        view.displayIfNeeded()
    }

    /// Expand named top-level folders in the active pane's tree outline (PATHEM_VIEW_SHOT).
    func debugTreeExpandActive(names: [String]) { activePane?.debugTreeExpand(names: names) }

    /// Move focus to the opposite pane (PATHEM_VIEW_SHOT hero staging).
    func debugFocusOtherPane() {
        let side = activeSide === leftTabs ? rightTabs : leftTabs
        if let pane = side.activePane { setActiveSide(side, pane: pane) }
    }

    /// Render the whole browser to a PNG (PATHEM_VIEW_SHOT diagnostics).
    func debugRender(to path: String) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 10, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return
        }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("VIEW SHOT: \(path) \(Int(bounds.width))x\(Int(bounds.height))")
        }
    }

    /// Apply every built-in theme in turn through the same path the toolbar menu uses and render
    /// the window chrome after each, with a selection in both panes so the accent shows
    /// (PATHEM_THEME_SHOTS=<dir>, with PATHEM_DEMO=1). Calls `done` after the last one.
    func debugRenderThemes(
        toDir dir: String, communityTheme: ThemePreset? = nil, done: @escaping () -> Void
    ) {
        let presets = ThemePreset.presets
        var shots = presets.map {
            (
                name: $0.name, theme: $0, mode: ViewFormat.ViewMode.list,
                appearance: Optional<NSAppearance.Name>.none
            )
        }
        for (themeName, standard, increased) in [
            ("Paper", NSAppearance.Name.aqua, NSAppearance.Name.accessibilityHighContrastAqua),
            (
                "Harbor", NSAppearance.Name.darkAqua,
                NSAppearance.Name.accessibilityHighContrastDarkAqua
            ),
        ] {
            guard let theme = presets.first(where: { $0.name == themeName }) else { continue }
            for mode in ViewFormat.ViewMode.allCases {
                shots.append(("\(themeName)-\(mode.rawValue)-standard", theme, mode, standard))
                shots.append(("\(themeName)-\(mode.rawValue)-contrast", theme, mode, increased))
            }
        }

        for (folderAndFiles, toolbar) in zip(
            zip(ThemeStyles.Folder.allCases, ThemeStyles.FileIcons.allCases),
            ThemeStyles.Toolbar.allCases
        ) {
            let (folder, files) = folderAndFiles
            var theme = ThemePreset.harbor
            theme.styles = ThemeStyles(folder, files, toolbar)
            shots.append(
                (
                    "Styles-\(folder.rawValue)-\(files.rawValue)-\(toolbar.rawValue)",
                    theme, .icon, nil
                ))
        }

        if let communityTheme {
            shots = [
                NSAppearance.Name.aqua, .darkAqua,
                .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ].flatMap { appearance in
                ViewFormat.ViewMode.allCases.map { mode in
                    ("\(mode.rawValue)-\(appearance.rawValue)", communityTheme, mode, appearance)
                }
            }
        }

        func step(_ index: Int) {
            guard index < shots.count else {
                renderThemePreview(nil)
                done()
                return
            }
            let shot = shots[index]
            renderThemePreview(shot.theme)
            if let appearance = shot.appearance {
                NSApp.appearance = NSAppearance(named: appearance)
            }
            for side in [leftTabs, rightTabs] {
                side.activePane?.setViewMode(shot.mode)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                for side in [self.leftTabs, self.rightTabs] {
                    if let pane = side.activePane,
                        let entry = pane.entries.dropFirst(2).first ?? pane.entries.first
                    {
                        pane.debugSelectNames([entry.name])
                        if shot.appearance != nil { pane.refreshIcons() }
                    }
                }
                let name = shot.name.replacingOccurrences(of: " ", with: "-")
                self.debugRenderWindowChrome(
                    to: "\(dir)/\(String(format: "%02d", index))-\(name).png")
                step(index + 1)
            }
        }
        if let photos = rightTabs.activePane {
            let lisbon = photos.currentURL.appendingPathComponent("2026-11 Lisbon")
            if FileManager.default.fileExists(atPath: lisbon.path) {
                photos.navigate(to: lisbon)
            }
        }
        step(0)
    }

    /// Scripted check of the folder tree against two real panes (PATHEM_LAYOUT_SHOTS): the
    /// selection follows the active pane's folder, follows a focus switch, and a click
    /// navigates the active pane. Prints one FOLDERTREE line per check.
    func debugFolderTreeFollowCheck(done: @escaping () -> Void) {
        func report(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("FOLDERTREE: \(ok ? "PASS" : "FAIL") \(name) \(detail)")
        }
        prefs.showFolderTree = true
        applyPreferences()
        guard let left = leftTabs.activePane, let right = rightTabs.activePane,
            let child = FolderTree.subfolders(of: left.currentURL, includingHidden: false)
                .folders.first
        else {
            report("setup", false)
            done()
            return
        }
        let leftHome = left.currentURL
        setActiveSide(leftTabs, pane: left)
        left.navigate(to: child.url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            report(
                "follows-navigation",
                self.folderTree.debugSelectedPath == child.url.standardizedFileURL.path,
                self.folderTree.debugSelectedPath ?? "nil")
            self.setActiveSide(self.rightTabs, pane: right)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                report(
                    "follows-pane-focus",
                    self.folderTree.debugSelectedPath == right.currentURL.standardizedFileURL.path,
                    self.folderTree.debugSelectedPath ?? "nil")
                self.folderTree.onSelectFolder?(leftHome)  // what a click on the folder does
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    report(
                        "click-navigates-active-pane",
                        right.currentURL.standardizedFileURL.path
                            == leftHome.standardizedFileURL.path,
                        right.currentURL.path)
                    self.setActiveSide(self.leftTabs, pane: left)
                    left.navigate(to: leftHome)
                    done()
                }
            }
        }
    }

    /// Scripted check of the folder tree's roots, pins, persistence, markers, reveal command,
    /// drop target and context menu against real panes (PATHEM_LAYOUT_SHOTS). Leaves one pin
    /// and the expansion in place so the renders that follow show them; `debugFolderTreeCleanup`
    /// removes the pin. Prints one FOLDERTREE line per check.
    func debugFolderTreeDepthCheck(done: @escaping () -> Void) {
        func report(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("FOLDERTREE: \(ok ? "PASS" : "FAIL") \(name) \(detail)")
        }
        let fm = FileManager.default
        guard let left = leftTabs.activePane, let right = rightTabs.activePane,
            let pinTarget = FolderTree.subfolders(of: left.currentURL, includingHidden: false)
                .folders.first
        else {
            report("depth-setup", false)
            done()
            return
        }
        prefs.showFolderTree = true
        applyPreferences()
        setActiveSide(leftTabs, pane: left)
        let roots = folderTree.debugRootNames
        report(
            "roots-home-then-volumes",
            roots.first == L("breadcrumb.home", "Home") && roots.contains("Macintosh HD"),
            roots.joined(separator: ","))

        // Pin through the command path, then see it as a root and in the saved preferences.
        left.navigate(to: pinTarget.url.deletingLastPathComponent())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let menuBefore = self.folderTree.debugMenuTitles(for: left.currentURL)
            report(
                "context-menu-offers-pin",
                menuBefore.contains(L("bvc.cmd.pinFolderTree", "Pin to Folder Tree")),
                menuBefore.joined(separator: "|"))
            self.folderTree.pin(pinTarget.url)
            report(
                "pin-adds-root-and-persists",
                self.folderTree.debugRootNames.last == pinTarget.name
                    && self.prefs.folderTreeState.isPinned(pinTarget.url)
                    && self.folderTree.isPinned(pinTarget.url),
                self.folderTree.debugRootNames.joined(separator: ","))
            let saved = Self.preferencesURL.flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) }
            report(
                "pin-written-to-config", saved?.folderTreeState.isPinned(pinTarget.url) == true)

            // Both panes' locations carry a marker (and they differ in the demo).
            left.navigate(to: pinTarget.url)
            self.setActiveSide(self.rightTabs, pane: right)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let marks = self.folderTree.debugMarks
                let slots = Set(marks.values.flatMap { $0 })
                report(
                    "both-panes-marked", slots == [0, 1],
                    "\(marks) \(self.folderTree.debugGeometry)")

                // Expansion persists: a fresh controller restored from the saved state reopens it.
                let expanded = self.prefs.folderTreeState.expanded
                report("expansion-recorded", !expanded.isEmpty, "\(expanded.count) folders")
                let reborn = FolderTreeController(
                    home: self.demoLayout?.root ?? fm.homeDirectoryForCurrentUser,
                    volumes: { [] })
                reborn.restore(self.prefs.folderTreeState)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let rows = reborn.debugVisibleRows().map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    report(
                        "expansion-restored-after-relaunch",
                        rows.contains(pinTarget.name) && rows.count > 3,
                        rows.prefix(8).joined(separator: ","))

                    // Reveal command: select a folder in the tree without navigating.
                    let before = self.rightTabs.activePane?.currentURL
                    self.folderTree.reveal(left.currentURL)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        report(
                            "reveal-selects-without-navigating",
                            self.folderTree.debugSelectedPath
                                == left.currentURL.standardizedFileURL.path
                                && self.rightTabs.activePane?.currentURL == before)

                        // Dropping files onto a tree folder reaches the drop hook, move or copy.
                        let board = NSPasteboard.withUniqueName()
                        let file = pinTarget.url.appendingPathComponent(".depth-check-source")
                        fm.createFile(atPath: file.path, contents: Data("x".utf8))
                        board.writeObjects([file as NSURL])
                        var delivered: [(Bool, String)] = []
                        let original = self.folderTree.onDropFiles
                        self.folderTree.onDropFiles = { _, folder, move in
                            delivered.append((move, folder.lastPathComponent))
                        }
                        if let window = self.view.window {
                            let info = TransferDraggingInfo(board, window: window)
                            self.folderTree.dragMovesByDefault = false
                            let copyOp = self.folderTree.debugDrop(
                                info, onto: pinTarget.url, accept: true)
                            self.folderTree.dragMovesByDefault = true
                            let moveOp = self.folderTree.debugDrop(
                                info, onto: pinTarget.url, accept: true)
                            info.draggingSourceOperationMask = []
                            let refused = self.folderTree.debugDrop(
                                info, onto: pinTarget.url, accept: true)
                            report(
                                "drop-on-tree-folder-uses-drop-policy",
                                copyOp == .copy && moveOp == .move && refused.isEmpty
                                    && delivered.map(\.0) == [false, true]
                                    && delivered.allSatisfy { $0.1 == pinTarget.name },
                                "\(copyOp.rawValue) \(moveOp.rawValue) \(delivered)")
                        } else {
                            report("drop-on-tree-folder-uses-drop-policy", false, "no window")
                        }
                        self.folderTree.onDropFiles = original
                        board.releaseGlobally()
                        try? fm.removeItem(at: file)

                        let menuAfter = self.folderTree.debugMenuTitles(for: pinTarget.url)
                        report(
                            "context-menu-offers-unpin-once-pinned",
                            menuAfter.contains(
                                L("bvc.cmd.unpinFolderTree", "Unpin from Folder Tree")),
                            menuAfter.joined(separator: "|"))
                        done()
                    }
                }
            }
        }
    }

    /// Undo what `debugFolderTreeDepthCheck` left behind (the pin and expansion).
    func debugFolderTreeCleanup() {
        for path in prefs.folderTreeState.pinned {
            folderTree.unpin(URL(fileURLWithPath: path))
        }
        prefs.folderTreeState = FolderTreeState()
        saveConfig(prefs, to: Self.preferencesURL)
    }

    /// Render the pane arrangements (side by side, stacked, stacked with the terminal drawer)
    /// in light and dark through the same preference path the menu uses
    /// (PATHEM_LAYOUT_SHOTS=<dir>, with PATHEM_DEMO=1). Calls `done` after the last one.
    func debugRenderLayoutShots(toDir dir: String, done: @escaping () -> Void) {
        let shots: [(name: String, stacked: Bool, terminal: Bool, tree: Bool)] = [
            ("side-by-side", false, false, false), ("stacked", true, false, false),
            ("stacked-terminal", true, true, false), ("side-by-side-tree", false, false, true),
            ("stacked-tree", true, false, true),
        ]
        let looks: [(String, Preferences.Appearance)] = [("light", .light), ("dark", .dark)]
        let plan = looks.flatMap { look in shots.map { (look, $0) } }
        func setTerminal(_ on: Bool) {
            guard terminal.view.isHidden == on else { return }
            if on { debugStageTerminal() } else { toggleTerminal() }
        }
        func step(_ index: Int) {
            guard index < plan.count else {
                setTerminal(false)
                prefs.appearance = .system
                prefs.stackPanesVertically = false
                prefs.showFolderTree = false
                applyPreferences()
                done()
                return
            }
            let (look, shot) = plan[index]
            prefs.appearance = look.1
            prefs.stackPanesVertically = shot.stacked
            prefs.showFolderTree = shot.tree
            applyPreferences()
            setTerminal(shot.terminal)
            for side in [leftTabs, rightTabs] {
                side.activePane?.refreshIcons()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (shot.terminal ? 2.0 : 1.0)) {
                self.view.layoutSubtreeIfNeeded()
                self.debugRenderWindowChrome(
                    to: "\(dir)/\(shot.name)-\(look.0).png")
                step(index + 1)
            }
        }
        step(0)
    }

    /// Render the whole window chrome (title bar + toolbar + content) to a PNG by caching the
    /// window's theme frame, the view that owns the toolbar -- `debugRender` covers only the content
    /// view. Needs no Screen Recording permission, unlike screencapture (PATHEM_CHROME_RENDER).
    func debugRenderWindowChrome(to path: String) {
        guard let window = view.window, let frame = window.contentView?.superview else { return }
        frame.layoutSubtreeIfNeeded()
        let bounds = frame.bounds
        guard bounds.width > 10, let rep = frame.bitmapImageRepForCachingDisplay(in: bounds) else {
            return
        }
        frame.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("CHROME RENDER: \(path) \(Int(bounds.width))x\(Int(bounds.height))")
        }
    }

    /// Apply a skin and select the first row so a render shows the accent (PATHEM_THEME_SHOT).
    func debugApplyTheme(accentHex: String, tintHex: String) {
        prefs.accentColorHex = accentHex
        prefs.windowTintHex = tintHex
        applyTheme()
        if let first = activePane?.entries.first { activePane?.select(name: first.name) }
        view.layoutSubtreeIfNeeded()
    }

    /// Toggle commander mode (PATHEM_COMMANDER_SHOT); returns whether it's now visible.
    @discardableResult
    func debugToggleCommander() -> Bool {
        toggleCommander()
        view.layoutSubtreeIfNeeded()
        return !commanderBar.isHidden
    }

    /// Set the active pane's arrange-by key (PATHEM_ICONGROUP_SHOT).
    func debugSetActiveGroupKey(_ key: ViewFormat.GroupKey) {
        activePane?.setGroupKey(key)
        view.layoutSubtreeIfNeeded()
    }

    /// Switch the active icon set and reload (PATHEM_ICONSET_SHOT).
    func debugSetIconSet(_ name: String) {
        prefs.iconSetName = name
        applyIconSet()
        view.layoutSubtreeIfNeeded()
    }

    /// Set a folder background on the active folder and apply it (PATHEM_FOLDERBG_SHOT).
    func debugSetFolderBackground(colorHex: String, imagePath: String) {
        guard let pane = activePane else { return }
        folderBackgrounds.set(
            FolderBackground(colorHex: colorHex, imagePath: imagePath), for: pane.currentURL.path)
        pane.applyFolderBackground()
        view.layoutSubtreeIfNeeded()
    }

    /// Round-trip a folder background through the store (PATHEM_SMOKE): set, read, clear.
    func debugFolderBackgroundRoundTrips() -> Bool {
        let path = "/tmp/pathem-bg-\(UUID().uuidString)"
        folderBackgrounds.set(FolderBackground(colorHex: "#112233"), for: path)
        let got = folderBackgrounds.background(for: path)?.colorHex == "#112233"
        folderBackgrounds.set(nil, for: path)
        let cleared = folderBackgrounds.background(for: path) == nil
        return got && cleared
    }

    /// Force compact (icons-only) sidebar for a render check (PATHEM_SIDEBAR_COMPACT).
    func debugSetCompactSidebar(_ on: Bool) {
        prefs.compactSidebar = on
        applyCompactSidebar()
        view.layoutSubtreeIfNeeded()
    }

    /// Force monochrome (template) sidebar icons for a render check (PATHEM_SIDEBAR_MONO).
    func debugSetMonochromeSidebar(_ on: Bool) {
        prefs.monochromeSidebarIcons = on
        applyCompactSidebar()
        view.layoutSubtreeIfNeeded()
    }

    /// Reorder sidebar sections for a render, without persisting (PATHEM_SIDEBAR_ORDER).
    func debugReorderSidebar(_ order: [String]) {
        sidebar.debugSetSectionOrder(order)
        view.layoutSubtreeIfNeeded()
    }

    /// Seed grouped connections for a render, without persisting (PATHEM_SITE_GROUPS).
    func debugSeedGroupedConnections() {
        let conns = [
            RemoteConnection(
                name: "Web 1", proto: .sftp, host: "web1.example.com", group: "Production"),
            RemoteConnection(
                name: "Web 2", proto: .sftp, host: "web2.example.com", group: "Production"),
            RemoteConnection(name: "Backups", proto: .s3, host: "s3.example.com", group: "Storage"),
            RemoteConnection(name: "Scratch", proto: .ftp, host: "ftp.example.com"),
        ]
        connectionsController.connections = conns  // reloads the manager table (no persistence)
        sidebar.setConnections(conns)  // group them in the sidebar
    }

    /// Seed sample color rules for a render, without persisting (PATHEM_COLOR_RULES).
    func debugSeedColorRules() {
        let rules = ColorRules(rules: [
            ColorRule(
                name: "Folders", field: .kind, op: .isAnyOf, value: "folder", colorHex: "#95D5B2",
                bold: true),
            ColorRule(
                name: "Images", field: .ext, op: .isAnyOf, value: "png, jpg, jpeg, gif, heic",
                colorHex: "#8ECAE6"),
            ColorRule(
                name: "Docs", field: .ext, op: .isAnyOf, value: "pdf, doc, docx, txt, md",
                colorHex: "#FFB4A2"),
            ColorRule(
                name: "Drafts", field: .name, op: .contains, value: "draft", colorHex: "#FFB703",
                italic: true),
            ColorRule(
                name: "Big files", field: .size, op: .greaterThan, value: "50", colorHex: "#E76F51",
                bold: true),
        ])
        leftTabs.activePane?.setColorRules(rules)
        rightTabs.activePane?.setColorRules(rules)
    }

    /// Apply binary sizes + relative dates for a render, without persisting (PATHEM_FORMATS).
    func debugSetBinaryRelativeFormats() {
        leftTabs.activePane?.setFormats(size: .binary, date: .relative)
        rightTabs.activePane?.setFormats(size: .binary, date: .relative)
    }

    /// Open the torrents drawer (and, if `openDetail`, the detail overlay for a fake torrent),
    /// then dump the frames of every view in the stack and render a PNG. Diagnoses the
    /// "full black single pane" report (PATHEM_TORRENT_LAYOUT_SHOT).
    func debugTorrentLayout(
        openDetail: Bool, seedDemo: Bool = false, magnetStates: Bool = false, pngPath: String
    ) {
        showTorrentsDrawer()
        if seedDemo || magnetStates {
            torrentDrawer.debugSeedDemoTorrents(magnetStates: magnetStates)
        }  // populate the list for a real shot
        view.layoutSubtreeIfNeeded()
        if openDetail {
            let fake = TorrentSession.Status(
                infoHash: "0000000000000000000000000000000000000000", name: "smoke.bin",
                totalLength: 1024, downloaded: 512, fractionComplete: 0.5, downloadRate: 1000,
                peersConnected: 3, state: .downloading, savePath: NSHomeDirectory())
            showTorrentDetail(fake)
        }
        view.layoutSubtreeIfNeeded()
        func f(_ label: String, _ v: NSView?) {
            guard let v else {
                print("  \(label): nil")
                return
            }
            let fr = v.frame
            print(
                "  \(label): x=\(Int(fr.minX)) y=\(Int(fr.minY)) w=\(Int(fr.width)) h=\(Int(fr.height)) hidden=\(v.isHidden)"
            )
        }
        print("=== TORRENT LAYOUT (detail=\(openDetail)) ===")
        f("vSplit", vSplit)
        f("  outerSplit", outerSplit)
        f("    sidebar", sidebar.containerView)
        f("    panesContainer", panesContainer)
        f("      split", split)
        f("      torrentDetail", torrentDetail)
        f("  terminal", terminal.view)
        f("  torrentDrawer", torrentDrawer.view)
        f("leftTabs", leftTabs.containerView)
        f("rightTabs", rightTabs.containerView)
        debugRender(to: pngPath)
    }

    /// Open the synthetic Network view (seeding a fake discovered host so both a real mount and a
    /// mountable host show) and render it (PATHEM_NETWORK_SHOT).
    func debugRenderNetworkView(to path: String) {
        debugStageNetworkView()
        let names = activePane?.entries.map(\.name) ?? []
        print("NETWORK VIEW entries: \(names)")
        debugRender(to: path)
    }

    /// Stage the PDF markup viewer over the active pane with the markup toolbar showing and a tool
    /// armed, for the marquee shot (PATHEM_MAIN_MODE=markup). Writes a legible demo document first so
    /// the annotation tools have real text to sit over.
    func debugStageMarkup() {
        let url = DebugDemoPDF.write()
        activePane?.debugPresentMarkup(url)
        view.layoutSubtreeIfNeeded()
    }

    /// Stage the Network view with demo hosts (no render) so an outer screencapture can grab it
    /// with real thumbnails + vibrancy (PATHEM_MAIN_MODE=network).
    func debugStageNetworkView() {
        discoveredHosts = ["Studio-Mac", "living-room-nas", "media-server"]
        // Generic saved servers in the sidebar so the shot shows remote connections too.
        // Display only: nothing connects.
        sidebar.demoConnections = [
            RemoteConnection(
                name: "assets-bucket", proto: .s3, host: "s3.amazonaws.com", region: "us-east-1",
                colorLabel: "orange"),
            RemoteConnection(name: "build-server", proto: .sftp, host: "build.example.com"),
            RemoteConnection(name: "team-share", proto: .webdavs, host: "dav.example.com"),
        ]
        showNetworkView()
        view.layoutSubtreeIfNeeded()
    }

    /// Stage the terminal for a screencapture (PATHEM_TERMINAL_SHOT). Shows it, then deterministically
    /// gives it a fixed bottom strip -- the shipping sizeTerminalDrawer no-ops when the split hasn't
    /// laid out yet, which is what let the terminal grab the whole window in a headless shot. The
    /// caller must let the shell spawn before calling debugRunTerminalDemo, then let it render.
    func debugStageTerminal() {
        view.layoutSubtreeIfNeeded()
        if terminal.view.isHidden { toggleTerminal() }  // reveals + starts the shell
        view.layoutSubtreeIfNeeded()
        let height = vSplit.bounds.height
        if height > 340 { vSplit.setPosition(height - 300, ofDividerAt: 0) }  // 300px terminal strip
        view.layoutSubtreeIfNeeded()
    }

    /// Run a safe, non-private command so the terminal capture shows real output instead of a bare
    /// prompt. Called after the shell has had a beat to spawn.
    func debugRunTerminalDemo() {
        terminal.runInline(
            "clear && sw_vers && echo && swift --version",
            in: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Render the sidebar to a PNG for headless layout inspection (PATHEM_SIDEBAR_SHOT). Set
    /// PATHEM_SIDEBAR_SELECT=<row> to highlight a row first, to inspect the selection style.
    func debugRenderSidebar(to path: String) {
        if let sel = ProcessInfo.processInfo.environment["PATHEM_SIDEBAR_SELECT"], let r = Int(sel)
        {
            sidebar.debugSelectRow(r)
        }
        let view = sidebar.containerView
        let bounds = view.bounds
        guard bounds.width > 10, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return
        }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SIDEBAR SHOT: \(Int(bounds.width))x\(Int(bounds.height))")
        }
    }
}

/// A one-page demo PDF (a fake project brief) written to a temp file, so the markup shot has real
/// text to annotate. Rendered from an NSTextView via `dataWithPDF`, which needs no external assets.
enum DebugDemoPDF {
    @MainActor
    static func write() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-demo-brief.pdf")
        let page = NSSize(width: 612, height: 792)  // US Letter
        let textView = NSTextView(frame: NSRect(origin: .zero, size: page))
        textView.textContainerInset = NSSize(width: 56, height: 64)
        textView.backgroundColor = .white
        textView.textStorage?.setAttributedString(body())
        // Off-window text views don't generate glyphs on their own; force layout so the PDF captures
        // real text instead of a blank page.
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
        }
        let data = textView.dataWithPDF(inside: NSRect(origin: .zero, size: page))
        do {
            try data.write(to: url)
        } catch {
            print("DebugDemoPDF: write failed: \(error)")
        }
        return url
    }

    private static func body() -> NSAttributedString {
        let text = NSMutableAttributedString()
        let heading: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.black,
        ]
        let sub: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.darkGray,
        ]
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        para.paragraphSpacing = 10
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black,
            .paragraphStyle: para,
        ]
        text.append(NSAttributedString(string: "Project Brief: Aurora\n", attributes: heading))
        text.append(
            NSAttributedString(string: "Prepared for review \u{2014} draft 3\n\n", attributes: sub))
        let paragraphs = [
            "Aurora is a cross-platform sync layer that keeps a team's working files consistent across machines without a central server. Edits propagate peer to peer, and conflicts resolve deterministically so two people can work offline and reconcile cleanly on reconnect.",
            "The first milestone covers the file-watching core, the change journal, and a reference client. The watcher coalesces rapid saves into a single logical change; the journal is append-only and content-addressed, so history is verifiable and cheap to prune.",
            "Open questions: how aggressively to compact the journal, whether to expose a merge UI for text conflicts, and what the right default is for large binary files. These are flagged for discussion in the sections below.",
            "Next steps are to lock the on-disk format, wire the reference client to the journal, and run a week-long soak test across three machines with intentionally poor connectivity.",
        ]
        for paragraph in paragraphs {
            text.append(NSAttributedString(string: paragraph + "\n", attributes: bodyAttrs))
        }
        return text
    }
}
#endif
