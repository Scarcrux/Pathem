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
    }

    /// Set the active pane's view mode (PATHEM_VIEW_SHOT diagnostics).
    func debugSetActiveViewMode(_ mode: ViewFormat.ViewMode) { activePane?.setViewMode(mode) }

    /// Navigate the active pane (PATHEM_VIEW_SHOT diagnostics, bypassing session restore).
    func debugNavigateActive(to url: URL) { activePane?.navigate(to: url) }

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

    /// Drill the first column's row N (PATHEM_VIEW_SHOT column-drill test).
    func debugDrillActive(row: Int) { activePane?.debugColumnDrill(row: row) }

    /// Render the whole browser to a PNG (PATHEM_VIEW_SHOT diagnostics).
    func debugRender(to path: String) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 10, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("VIEW SHOT: \(path) \(Int(bounds.width))x\(Int(bounds.height))")
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
        folderBackgrounds.set(FolderBackground(colorHex: colorHex, imagePath: imagePath), for: pane.currentURL.path)
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
            RemoteConnection(name: "Web 1", proto: .sftp, host: "web1.example.com", group: "Production"),
            RemoteConnection(name: "Web 2", proto: .sftp, host: "web2.example.com", group: "Production"),
            RemoteConnection(name: "Backups", proto: .s3, host: "s3.example.com", group: "Storage"),
            RemoteConnection(name: "Scratch", proto: .ftp, host: "ftp.example.com"),
        ]
        connectionsController.connections = conns  // reloads the manager table (no persistence)
        sidebar.setConnections(conns)  // group them in the sidebar
    }

    /// Seed sample color rules for a render, without persisting (PATHEM_COLOR_RULES).
    func debugSeedColorRules() {
        let rules = ColorRules(rules: [
            ColorRule(name: "Folders", field: .kind, op: .isAnyOf, value: "folder", colorHex: "#95D5B2", bold: true),
            ColorRule(name: "Images", field: .ext, op: .isAnyOf, value: "png, jpg, jpeg, gif, heic", colorHex: "#8ECAE6"),
            ColorRule(name: "Docs", field: .ext, op: .isAnyOf, value: "pdf, doc, docx, txt, md", colorHex: "#FFB4A2"),
            ColorRule(name: "Drafts", field: .name, op: .contains, value: "draft", colorHex: "#FFB703", italic: true),
            ColorRule(name: "Big files", field: .size, op: .greaterThan, value: "50", colorHex: "#E76F51", bold: true),
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
    func debugTorrentLayout(openDetail: Bool, pngPath: String) {
        showTorrentsDrawer()
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
            guard let v else { print("  \(label): nil"); return }
            let fr = v.frame
            print("  \(label): x=\(Int(fr.minX)) y=\(Int(fr.minY)) w=\(Int(fr.width)) h=\(Int(fr.height)) hidden=\(v.isHidden)")
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
        discoveredHosts = ["Studio-Mac", "living-room-nas"]
        showNetworkView()
        view.layoutSubtreeIfNeeded()
        let names = activePane?.entries.map(\.name) ?? []
        print("NETWORK VIEW entries: \(names)")
        debugRender(to: path)
    }

    /// Render the sidebar to a PNG for headless layout inspection (PATHEM_SIDEBAR_SHOT).
    func debugRenderSidebar(to path: String) {
        let view = sidebar.containerView
        let bounds = view.bounds
        guard bounds.width > 10, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SIDEBAR SHOT: \(Int(bounds.width))x\(Int(bounds.height))")
        }
    }
}
