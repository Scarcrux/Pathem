import AVFoundation
import AppKit
import PathemEngine
import PathemTerminal

// AppKit entry point. Normal launch shows a dual-pane browser rooted at the
// home directory. Launch with PATHEM_GATE_A=1 to run the Gate A virtualization
// proof (DESIGN.md §5): load 1,000,000 synthetic rows and confirm the table
// materializes only ~visible cells, not all 1M.
@main
@MainActor
enum PathemApp {
    static var liveSettings: SettingsWindowController?  // holds the PATHEM_SETTINGS_SHOT window
    static var liveInspector: InfoInspectorController?  // holds the PATHEM_INFO_SHOT panel
    static var liveDialog: AnyObject?  // holds the PATHEM_DIALOG_SHOT window

    static func main() {
        // A broken pipe to a subprocess (curl/sftp exiting mid-write) must never
        // deliver a fatal signal; the remote runner handles the error instead.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let updater = UpdaterController()
        app.mainMenu = makeMainMenu(updater: updater)

        // Screenshot runs use a window that always draws key chrome (colored traffic lights),
        // since macOS denies programmatic activation while the user is typing elsewhere and a
        // capture with gray lights reads as an inactive app.
        let shotRun = ProcessInfo.processInfo.environment["PATHEM_VIEW_SHOT"] != nil
            || ProcessInfo.processInfo.environment["PATHEM_MAIN_SHOT"] != nil
        let windowType: NSWindow.Type = shotRun ? AlwaysKeyWindow.self : NSWindow.self
        let window = windowType.init(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pathem"
        window.isReleasedWhenClosed = false  // WindowManager.Host owns the lifetime (see adoptPrimary)
        window.center()

        if ProcessInfo.processInfo.environment["PATHEM_L10N_SMOKE"] != nil {
            // Deterministic: every shipped language must be bundled and actually
            // translated (sample keys resolve to a non-empty value that differs from
            // English). Independent of the system language.
            print("=== L10N SMOKE: localized resources ===")
            let available = pathemResourceBundle.localizations
            print("available:", available)
            var ok = true
            // SwiftPM may canonicalize a region tag's case (e.g. zh-Hans -> zh-hans),
            // so match the shipped languages against `available` case-insensitively.
            func code(for wanted: String) -> String? {
                available.first { $0.caseInsensitiveCompare(wanted) == .orderedSame }
            }
            for lang in ["en", "es", "fr", "de", "zh-Hans", "ja"] where code(for: lang) == nil {
                print("  MISSING lproj: \(lang)")
                ok = false
            }
            let sample = ["menu.file": "File", "common.cancel": "Cancel"]
            for lang in ["es", "fr", "de", "zh-Hans", "ja"] {
                guard let actual = code(for: lang),
                    let path = pathemResourceBundle.path(forResource: actual, ofType: "lproj"),
                    let bundle = Bundle(path: path)
                else {
                    print("  \(lang): catalog not loadable")
                    ok = false
                    continue
                }
                for (key, english) in sample.sorted(by: { $0.key < $1.key }) {
                    let got = bundle.localizedString(forKey: key, value: "?", table: nil)
                    let good = !got.isEmpty && got != "?" && got != english
                    if !good { ok = false }
                    print("  \(lang)/\(key): \(got)\(good ? "" : "  <-- BAD")")
                }
            }
            print("RESULT: \(ok ? "PASS" : "FAIL")")
            exit(ok ? 0 : 1)
        }

        if ProcessInfo.processInfo.environment["PATHEM_PREFS_SHOT"] != nil {
            SettingsWindowController().debugRenderPanes(toDir: "/tmp")
            BatchCreateController().debugRender(to: "/tmp/batch.png")
            exit(0)
        }

        if ProcessInfo.processInfo.environment["PATHEM_GATE_A"] != nil {
            // Gate A drives a single FileListController directly.
            let controller = FileListController()
            window.contentView = controller.scrollView
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            runGateA(controller, window)  // measures synchronously, then exits
        }

        // Normal mode: a dual-pane browser rooted at the home directory (or a sample
        // folder when rendering view-mode screenshots).
        let viewShot = ProcessInfo.processInfo.environment["PATHEM_VIEW_SHOT"] != nil
        // Privacy-safe demo mode (PATHEM_DEMO=1): a fake workspace + sidebar for screenshots.
        let demoLayout = ProcessInfo.processInfo.environment["PATHEM_DEMO"] != nil ? DemoWorkspace.build() : nil
        let start = viewShot ? Self.makeSampleFolder() : FileManager.default.homeDirectoryForCurrentUser
        let browser = BrowserViewController(start: start, demo: demoLayout)
        window.contentViewController = browser
        // Assigning a contentViewController makes the window adopt the content's
        // Auto Layout fitting size, which collapses to a sliver here (the panes
        // impose no intrinsic size). Pin a real size and a sane minimum so the
        // window opens at 1100x700 instead of vanishing.
        window.contentMinSize = NSSize(width: 720, height: 420)
        // Remember the window's position and size across launches. setFrameUsingName
        // restores the saved frame; only on a genuine first launch (no saved frame)
        // do we pin the default size (otherwise the content view's fitting size
        // collapses the window to a sliver) and center. setFrameAutosaveName then
        // persists future moves/resizes.
        let frameName = NSWindow.FrameAutosaveName("com.scarcrux.pathem.mainWindow")
        if !window.setFrameUsingName(frameName) {
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.center()
        }
        window.setFrameAutosaveName(frameName)
        let delegate = PathemAppDelegate()
        delegate.browser = browser
        delegate.updater = updater  // keep the updater alive for the app's lifetime
        browser.updater = updater  // surfaced in Settings > Updates
        app.delegate = delegate  // kept alive by this frame for the lifetime of app.run()
        app.servicesProvider = delegate  // the "Open in Pathem" Services item routes here
        // Register this as the primary window so File ▸ New Window can spawn siblings and quit
        // tears every window down cleanly. Only the primary restores/saves the session.
        WindowManager.shared.updater = updater
        WindowManager.shared.adoptPrimary(window: window, browser: browser)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        delegate.vpnStatusItem = VPNStatusItem()  // shows only while VPN binding is enabled


        // Live capture of every view mode (list, gallery, column, tree, icon) plus a
        // dual-pane hero shot: one PNG per mode via screencapture (real window chrome and
        // thumbnails, unlike the offscreen cacheDisplay render). Runs over the sample
        // folder, or over the demo workspace when PATHEM_DEMO=1 is also set (Downloads for
        // the list, Photos for the grids, Projects for column drilling). Steps are
        // scheduled at flat absolute offsets to stay readable.
        if viewShot {
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.center()
            NSApp.activate(ignoringOtherApps: true)  // key window = colored traffic lights in captures
            let files = demoLayout.map { $0.root.appendingPathComponent("Downloads") } ?? start
            let photos = demoLayout.map { $0.root.appendingPathComponent("Photos") } ?? start
            let code = demoLayout.map { $0.root.appendingPathComponent("Projects") } ?? start
            let home = demoLayout.map { $0.root } ?? start
            if demoLayout == nil {
                browser.debugNavigateActive(to: start)  // bypass session restore; show the sample folder
            }
            let number = window.windowNumber
            func shoot(_ name: String) {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l\(number)", "/tmp/view-\(name).png"]
                try? capture.run()
                capture.waitUntilExit()
                print("VIEW SHOT: /tmp/view-\(name).png")
            }
            // Always navigate first and set the mode afterward: navigation applies the
            // destination folder's saved view format, which would stomp a mode set earlier.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                browser.debugNavigateActive(to: files)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                browser.debugSetActiveViewMode(.list)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
                shoot("list")
                browser.debugNavigateActive(to: photos)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
                browser.debugSetActiveViewMode(.gallery)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                shoot("gallery")
                // Column view is staged on Photos with the left pane widened: one column of
                // files plus the preview column (a real thumbnail + metadata), nothing clipped.
                // Park the right pane on Projects as a plain list first, so a saved gallery
                // format (per-folder views persist) can't photobomb the capture.
                browser.setRightPaneFraction(0.35)
                browser.debugFocusOtherPane()
                browser.debugNavigateActive(to: code)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.6) {
                browser.debugSetActiveViewMode(.list)
                browser.debugFocusOtherPane()
                browser.debugNavigateActive(to: photos)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 11.4) {
                browser.debugSetActiveViewMode(.column)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.2) {
                browser.debugDrillActive(row: 0)  // select a file: the preview column appears
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 13.2) {
                browser.debugHideQuickBar()  // selection pops the quick-actions bar; keep the shot clean
                browser.debugRepaintAll()  // clear ghost pixels from the split move
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 13.5) {
                shoot("column")
                browser.setRightPaneFraction(0.5)  // restore halves for the remaining shots
                browser.debugNavigateActive(to: home)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 14.5) {
                browser.debugSetActiveViewMode(.tree)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.5) {
                browser.debugTreeExpandActive(names: ["Projects", "Photos", "Music"])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 17.0) {
                shoot("tree")
                browser.debugNavigateActive(to: photos)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 18.0) {
                browser.debugSetActiveViewMode(.icon)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20.5) {
                shoot("icon")
            }
            // Stage the dual-pane hero: right pane showing Photos as a gallery, left pane
            // back on Projects as a list, focus on the left. Navigate the right pane back to
            // Photos explicitly: the column staging parked it on Projects.
            DispatchQueue.main.asyncAfter(deadline: .now() + 21.5) {
                browser.debugFocusOtherPane()
                browser.debugNavigateActive(to: photos)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 22.5) {
                browser.debugSetActiveViewMode(.gallery)  // right pane is at Photos
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 23.5) {
                browser.debugFocusOtherPane()
                browser.debugNavigateActive(to: code)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 25.0) {
                browser.debugSetActiveViewMode(.list)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 26.5) {
                NSApp.activate(ignoringOtherApps: true)  // colored traffic lights, when macOS allows it
                browser.debugRepaintAll()  // clear ghost pixels from the split move and mode swaps
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 27.0) {
                shoot("hero")
                exit(0)
            }
        }

        // Live screenshot of the quick-actions bar (PATHEM_QUICKBAR_SHOT=1).
        if ProcessInfo.processInfo.environment["PATHEM_QUICKBAR_SHOT"] != nil {
            let host = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 90),
                styleMask: [.borderless], backing: .buffered, defer: true)
            host.isOpaque = false
            host.backgroundColor = .clear
            let bar = QuickActionsBar()
            let content = NSView(frame: host.contentRect(forFrameRect: host.frame))
            content.addSubview(bar)
            host.contentView = content
            NSLayoutConstraint.activate([
                bar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                bar.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
            bar.update(selectionCount: 3)
            host.center()
            host.makeKeyAndOrderFront(nil)
            let number = host.windowNumber
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l\(number)", "/tmp/quickbar_live.png"]
                try? capture.run(); capture.waitUntilExit()
                exit(0)
            }
        }

        // Live screenshot of the AI command bar (PATHEM_AI_SHOT=1).
        if ProcessInfo.processInfo.environment["PATHEM_AI_SHOT"] != nil {
            let bar = AICommandBar()
            Self.liveDialog = bar
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                bar.present(over: window, resolve: { _ in nil }, run: { _ in })
                let number = bar.debugWindowNumber
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l\(number)", "/tmp/ai_live.png"]
                    try? capture.run(); capture.waitUntilExit()
                    exit(0)
                }
            }
        }

        // Live screenshot of the transfer queue with an in-progress download (PATHEM_QUEUE_SHOT=1).
        if ProcessInfo.processInfo.environment["PATHEM_QUEUE_SHOT"] != nil {
            let queue = TransferQueueController()
            Self.liveDialog = queue
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-queue-demo.bin")
            try? Data(repeating: 0, count: 46_000).write(to: tmp)  // 46% of 100k
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let running = TransferQueueController.Item(name: "vacation-4k.mov", totalBytes: 100_000, progressFile: tmp) {
                    try? await Task.sleep(for: .seconds(4))
                }
                let queued = TransferQueueController.Item(name: "photos.zip", totalBytes: 5_000_000, progressFile: tmp) {}
                queue.run([running, queued], title: "Downloading from example.com", over: window) { _, _ in }
                let number = queue.debugWindowNumber
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l\(number)", "/tmp/queue_live.png"]
                    try? capture.run(); capture.waitUntilExit()
                    exit(0)
                }
            }
        }

        // Live screenshot of the archive-contents dialog (PATHEM_DIALOG_SHOT=1).
        if ProcessInfo.processInfo.environment["PATHEM_DIALOG_SHOT"] != nil {
            let dialog = ArchiveContentsController()
            Self.liveDialog = dialog
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                dialog.present(
                    over: window, archiveName: "photos.zip",
                    entries: ["IMG_0001.jpg", "IMG_0002.jpg", "notes/todo.txt", "notes/ideas.md", "cover.png"],
                    onExtractAll: {})
                let number = dialog.debugWindowNumber
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l\(number)", "/tmp/dialog_archive.png"]
                    try? capture.run(); capture.waitUntilExit()
                    exit(0)
                }
            }
        }

        // Live screenshot of the Get Info inspector for a sample app (PATHEM_INFO_SHOT=1).
        if ProcessInfo.processInfo.environment["PATHEM_INFO_SHOT"] != nil {
            let inspector = InfoInspectorController()
            Self.liveInspector = inspector
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                inspector.present(urls: [URL(fileURLWithPath: "/System/Applications/Calculator.app")], over: nil)
                let number = inspector.debugWindowNumber
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l\(number)", "/tmp/info_live.png"]
                    try? capture.run(); capture.waitUntilExit()
                    exit(0)
                }
            }
        }

        // Live screenshot of the real main window (PATHEM_MAIN_SHOT=1). Navigation runs on
        // the run loop (asyncAfter), not synchronously here, or Launch Services deadlocks.
        if ProcessInfo.processInfo.environment["PATHEM_MAIN_SHOT"] != nil {
            let number = window.windowNumber
            let mode = ProcessInfo.processInfo.environment["PATHEM_MAIN_MODE"]
            let navPath = ProcessInfo.processInfo.environment["PATHEM_MAIN_PATH"]
            let sectionOrder = ProcessInfo.processInfo.environment["PATHEM_SIDEBAR_ORDER"]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let sectionOrder { browser.debugReorderSidebar(sectionOrder.split(separator: ",").map(String.init)) }
                if let navPath { browser.debugNavigateActive(to: URL(fileURLWithPath: navPath)) }
                if ProcessInfo.processInfo.environment["PATHEM_COLOR_RULES"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { browser.debugSeedColorRules() }
                }
                if ProcessInfo.processInfo.environment["PATHEM_SITE_GROUPS"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { browser.debugSeedGroupedConnections() }
                }
                if ProcessInfo.processInfo.environment["PATHEM_FORMATS"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { browser.debugSetBinaryRelativeFormats() }
                }
                if let mode {
                    // PATHEM_MAIN_PATH picks the folder; otherwise use the fake Photos folder
                    // in demo mode (privacy-safe for README shots) or the real ~/Pictures.
                    if navPath == nil {
                        let target =
                            demoLayout?.rightStart
                            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
                        browser.debugNavigateActive(to: target)
                    }
                    let viewMode: ViewFormat.ViewMode =
                        mode == "gallery"
                        ? .gallery : (mode == "column" ? .column : (mode == "list" ? .list : .icon))
                    browser.debugSetActiveViewMode(viewMode)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l\(number)", "/tmp/main_live.png"]
                    try? capture.run()
                    capture.waitUntilExit()
                    exit(0)
                }
            }
        }

        // Live screenshot of the real Settings window (PATHEM_SETTINGS_SHOT=1).
        if ProcessInfo.processInfo.environment["PATHEM_SETTINGS_SHOT"] != nil {
            let settings = SettingsWindowController()
            Self.liveSettings = settings  // keep it alive
            let number = settings.debugPresentLive()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l\(number)", "/tmp/settings_live.png"]
                try? capture.run()
                capture.waitUntilExit()
                exit(0)
            }
        }

        // Headless Network-view render (PATHEM_NETWORK_SHOT=1).
        if ProcessInfo.processInfo.environment["PATHEM_NETWORK_SHOT"] != nil {
            window.setContentSize(NSSize(width: 1100, height: 640))
            var attempts = 0
            func tick() {
                attempts += 1
                guard browser.layoutSettled() || attempts >= 30 else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: tick)
                    return
                }
                browser.debugRenderNetworkView(to: "/tmp/network-view.png")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: tick)
        }

        // Headless sidebar render for layout inspection (PATHEM_SIDEBAR_SHOT=1).
        if ProcessInfo.processInfo.environment["PATHEM_SIDEBAR_SHOT"] != nil {
            // Height override so checks can reach sections below the fold (Volumes, Shared).
            let h = Int(ProcessInfo.processInfo.environment["PATHEM_SIDEBAR_HEIGHT"] ?? "") ?? 520
            window.setContentSize(NSSize(width: 1100, height: CGFloat(h)))  // a realistic short window
            if ProcessInfo.processInfo.environment["PATHEM_SIDEBAR_COMPACT"] != nil {
                browser.debugSetCompactSidebar(true)
            }
            if ProcessInfo.processInfo.environment["PATHEM_SIDEBAR_MONO"] != nil {
                browser.debugSetMonochromeSidebar(true)
            }
            var attempts = 0
            func tick() {
                attempts += 1
                guard browser.layoutSettled() || attempts >= 30 else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: tick)
                    return
                }
                browser.debugRenderSidebar(to: "/tmp/sidebar.png")
                exit(0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: tick)
        }

        // Diagnose the "torrents = full black single pane" report: open the drawer (and detail),
        // dump the view frames, render a PNG (PATHEM_TORRENT_LAYOUT_SHOT=1; add DETAIL=1 for the overlay).
        if ProcessInfo.processInfo.environment["PATHEM_TORRENT_LAYOUT_SHOT"] != nil {
            window.setContentSize(NSSize(width: 1100, height: 700))
            let detail = ProcessInfo.processInfo.environment["DETAIL"] != nil
            var attempts = 0
            func tick() {
                attempts += 1
                guard browser.layoutSettled() || attempts >= 30 else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: tick)
                    return
                }
                browser.debugTorrentLayout(openDetail: detail, pngPath: "/tmp/torrent-layout.png")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: tick)
        }

        // Headless UI smoke test: once the window has laid out, assert the
        // structural invariants (window not collapsed, both panes visible) and
        // exit. Catches the layout regressions the engine tests can't see.
        if ProcessInfo.processInfo.environment["PATHEM_SMOKE"] != nil {
            // Poll until the window has laid out (up to ~6s), then assert once.
            // Layout lags a beat after launch, so a fixed delay flakes under load.
            var attempts = 0
            func tick() {
                attempts += 1
                guard browser.layoutSettled() || attempts >= 30 else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: tick)
                    return
                }
                let report = browser.smokeReport()
                print("=== SMOKE: Pathem UI invariants ===")
                report.lines.forEach { print($0) }
                // Verify the async sheet primitive (rename, New Folder, ...) presents on the
                // window and resolves. Async sheets don't run a nested modal loop, so a plain
                // dispatch dismissal fires normally -- dismiss it, then check presentSheet's
                // continuation returned the response.
                let sheetAlert = NSAlert()
                sheetAlert.messageText = "smoke"
                sheetAlert.addButton(withTitle: "OK")
                Task { @MainActor in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if let sheet = window.attachedSheet {
                            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                        }
                    }
                    let response = await browser.presentSheet(sheetAlert)
                    let sheetOK = response == .alertFirstButtonReturn
                    print(sheetOK ? "ok   async-sheet-returns" : "FAIL async-sheet-returns (\(response.rawValue))")
                    print("RESULT: \(report.ok && sheetOK ? "PASS" : "FAIL")")
                    exit(report.ok && sheetOK ? 0 : 1)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: tick)
        }

        // Headless torrents smoke: spawn the real pathem-torrentd via TorrentDaemonClient, add a
        // trackerless fixture .torrent, and confirm it comes back in a status broadcast. Exercises
        // the app-side spawn + JSON round-trip that the engine tests can't reach. Exits itself.
        if ProcessInfo.processInfo.environment["PATHEM_TORRENTS_SMOKE"] != nil {
            print("=== TORRENTS SMOKE: daemon spawn + add ===")
            func bencodeLen(_ v: String) -> String { "\(v.utf8.count):\(v)" }
            let pieces = String(repeating: "a", count: 20)
            let info = "d" + bencodeLen("length") + "i1024e" + bencodeLen("name") + bencodeLen("smoke.bin")
                + bencodeLen("piece length") + "i16384e" + bencodeLen("pieces") + "20:\(pieces)e"
            let fixture = "d" + bencodeLen("info") + info + "e"
            let fixtureURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("pathem-smoke-\(UUID().uuidString).torrent")
            let client = TorrentDaemonClient.shared
            do {
                try Data(fixture.utf8).write(to: fixtureURL)
                let spawned = client.startIfNeeded()
                print(spawned ? "ok   daemon-spawned" : "FAIL daemon-spawned (helper not found)")
                guard spawned else { print("RESULT: FAIL"); exit(1) }
                client.addTorrent(fileAt: fixtureURL.path, savePath: fixtureURL.deletingLastPathComponent().path)
                var attempts = 0
                func poll() {
                    attempts += 1
                    if let smoke = client.torrents.first(where: { $0.name == "smoke.bin" }) {
                        print("ok   torrent-appears-in-status")
                        print("RESULT: PASS")
                        // Remove the fixture so the smoke doesn't leave a torrent in real state.
                        client.remove(smoke.infoHash, deleteData: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            client.shutdown()
                            try? FileManager.default.removeItem(at: fixtureURL)
                            exit(0)
                        }
                        return
                    }
                    if attempts >= 40 {
                        print("FAIL torrent-appears-in-status (timed out, last count=\(client.torrents.count))")
                        print("RESULT: FAIL")
                        client.shutdown()
                        exit(1)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
            } catch {
                print("FAIL fixture-write (\(error))")
                print("RESULT: FAIL")
                exit(1)
            }
        }

        // Headless AI smoke: run the on-device model through our real proposal path
        // and print the plan it proposes. Needs macOS 26 + Apple Intelligence.
        #if canImport(FoundationModels)
            // Env var for direct runs; --ai-smoke arg so it also works via `open`
            // (LaunchServices doesn't pass the terminal environment through).
            if ProcessInfo.processInfo.environment["PATHEM_AI_SMOKE"] != nil
                || CommandLine.arguments.contains("--ai-smoke")
            {
                DispatchQueue.main.async {
                    Task.detached {
                        print("=== AI SMOKE: Organize with AI ===")
                        guard #available(macOS 26, *) else {
                            print("RESULT: SKIP (macOS < 26)")
                            exit(0)
                        }
                        // Skip (not fail) when Apple Intelligence isn't available, so the
                        // e2e suite is green on machines without it.
                        if let reason = AIAvailability.unavailableReason() {
                            print("RESULT: SKIP (\(reason))")
                            exit(0)
                        }
                        let files = [
                            "IMG_1024.jpg", "budget.pdf", "notes.txt", "screenshot.png", "invoice.pdf",
                            "cat.heic",
                        ]  // a filename-heavy case that used to trip the language classifier
                        let plan = await proposeOrganizePlan(
                            instruction: "Move images into a Pictures folder and PDFs into a Docs folder",
                            files: files)
                        guard let plan, !plan.steps.isEmpty else {
                            print("RESULT: FAIL (no plan; model unavailable or empty)")
                            exit(1)
                        }
                        for line in plan.summary(in: URL(fileURLWithPath: "/tmp")) { print("  \(line)") }
                        print("RESULT: PASS (\(plan.steps.count) steps proposed)")
                        exit(0)
                    }
                }
            }
        #endif

        // Render the main window with a distinctive skin (purple accent + dark tint) so the
        // themed selection/border/tab can be inspected headlessly.
        if ProcessInfo.processInfo.environment["PATHEM_THEME_SHOT"] != nil {
            window.setContentSize(NSSize(width: 1100, height: 700))
            browser.debugNavigateActive(to: FileManager.default.homeDirectoryForCurrentUser)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                browser.debugApplyTheme(accentHex: "#BD93F9", tintHex: "#282A36")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    browser.debugRender(to: "/tmp/theme.png")
                    exit(0)
                }
            }
        }

        // End-to-end trim export: generate a 3-second silent m4a, export the first second, and
        // assert the output exists and is shorter (the trim UI itself is interactive, not headless).
        if ProcessInfo.processInfo.environment["PATHEM_TRIM_SMOKE"] != nil {
            Task { @MainActor in
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-trim-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let src = dir.appendingPathComponent("tone.m4a")
                var ok = false
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 1,
                ]
                print("=== TRIM SMOKE ===")
                do {
                    // Write (and finalize, by scoping the file so it deallocs) 3s of silent AAC.
                    do {
                        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
                        let file = try AVAudioFile(forWriting: src, settings: settings)
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(44100 * 3))!
                        buffer.frameLength = AVAudioFrameCount(44100 * 3)
                        try file.write(from: buffer)
                    }
                    let srcDur = CMTimeGetSeconds(AVURLAsset(url: src).duration)
                    print("wrote src dur=\(String(format: "%.2f", srcDur))s")
                    let out = await TrimController.debugExport(from: src, startSeconds: 0, endSeconds: 1)
                    if let out {
                        let dur = CMTimeGetSeconds(AVURLAsset(url: out).duration)
                        ok = FileManager.default.fileExists(atPath: out.path) && dur < srcDur && dur > 0.4
                        print("exported out dur=\(String(format: "%.2f", dur))s")
                    } else {
                        print("export returned nil")
                    }
                } catch {
                    print("generate failed: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: dir)
                print("RESULT: \(ok ? "PASS" : "FAIL")")
                exit(ok ? 0 : 1)
            }
        }

        // Render commander mode (the F-key bar + command line docked at the bottom).
        if ProcessInfo.processInfo.environment["PATHEM_COMMANDER_SHOT"] != nil {
            window.setContentSize(NSSize(width: 1100, height: 700))
            browser.debugNavigateActive(to: FileManager.default.homeDirectoryForCurrentUser)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                browser.debugToggleCommander()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    browser.debugRender(to: "/tmp/commander.png")
                    exit(0)
                }
            }
        }

        // Render the tree/outline view over the home folder.
        if ProcessInfo.processInfo.environment["PATHEM_TREE_SHOT"] != nil {
            window.setContentSize(NSSize(width: 1100, height: 700))
            browser.debugNavigateActive(to: FileManager.default.homeDirectoryForCurrentUser)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                browser.debugSetActiveViewMode(.tree)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    browser.debugRender(to: "/tmp/tree.png")
                    exit(0)
                }
            }
        }

        // Render the icon grid grouped by kind so the section headers can be inspected.
        if ProcessInfo.processInfo.environment["PATHEM_ICONGROUP_SHOT"] != nil {
            window.setContentSize(NSSize(width: 1100, height: 700))
            browser.debugNavigateActive(to: FileManager.default.homeDirectoryForCurrentUser)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                browser.debugSetActiveViewMode(.icon)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    browser.debugSetActiveGroupKey(.kind)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        browser.debugRender(to: "/tmp/icongroup.png")
                        exit(0)
                    }
                }
            }
        }

        // Render the icon grid with the "Vivid" icon set so the themed file icons can be inspected.
        if ProcessInfo.processInfo.environment["PATHEM_ICONSET_SHOT"] != nil {
            window.setContentSize(NSSize(width: 1100, height: 700))
            browser.debugNavigateActive(to: FileManager.default.homeDirectoryForCurrentUser)
            browser.debugSetActiveViewMode(.list)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                browser.debugSetActiveViewMode(.list)
                browser.debugSetIconSet("Vivid")  // themed icons show in the list (and every view)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    browser.debugRender(to: "/tmp/iconset.png")
                    exit(0)
                }
            }
        }

        // Render a folder background (a tinted picture behind the list) for headless inspection.
        if ProcessInfo.processInfo.environment["PATHEM_FOLDERBG_SHOT"] != nil {
            window.setContentSize(NSSize(width: 1100, height: 700))
            browser.debugNavigateActive(to: FileManager.default.homeDirectoryForCurrentUser)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                // A soft gradient picture behind the pane proves the image path end to end.
                let img = NSImage(size: NSSize(width: 400, height: 400))
                img.lockFocus()
                let gradient = NSGradient(starting: NSColor.systemTeal, ending: NSColor.systemIndigo)
                gradient?.draw(in: NSRect(x: 0, y: 0, width: 400, height: 400), angle: 45)
                img.unlockFocus()
                let path = "/tmp/pathem-folderbg.png"
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                    let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                browser.debugSetFolderBackground(colorHex: "", imagePath: path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    browser.debugRender(to: "/tmp/folderbg.png")
                    exit(0)
                }
            }
        }

        // End-to-end multi-window check: actually open a second window through the same path the
        // New Window command uses, then assert both windows laid out with independent sessions.
        // Tears the second window's shell down so the run leaves nothing orphaned.
        if ProcessInfo.processInfo.environment["PATHEM_MULTIWINDOW_SMOKE"] != nil {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let second = WindowManager.shared.openWindow(start: home)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let count = WindowManager.shared.windowCount
                let bothLaidOut = browser.layoutSettled() && second.layoutSettled()
                let independent = browser.persistsSession && !second.persistsSession
                print("=== MULTIWINDOW SMOKE ===")
                print("windows=\(count) bothLaidOut=\(bothLaidOut) independentSession=\(independent)")
                let pass = count == 2 && bothLaidOut && independent
                print("RESULT: \(pass ? "PASS" : "FAIL")")
                WindowManager.shared.terminateAllTerminals()
                exit(pass ? 0 : 1)
            }
        }
        // End-to-end slideshow check: build two real images, present the full-screen slideshow,
        // then close it, asserting it went active and back inactive without leaving a window up.
        if ProcessInfo.processInfo.environment["PATHEM_SLIDESHOW_SMOKE"] != nil {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-slideshow-smoke")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var urls: [URL] = []
            for (i, color) in [NSColor.systemRed, NSColor.systemBlue].enumerated() {
                let image = NSImage(size: NSSize(width: 200, height: 200))
                image.lockFocus()
                color.setFill()
                NSRect(x: 0, y: 0, width: 200, height: 200).fill()
                image.unlockFocus()
                if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                    let png = rep.representation(using: .png, properties: [:]) {
                    let url = dir.appendingPathComponent("img\(i).png")
                    try? png.write(to: url)
                    urls.append(url)
                }
            }
            let show = SlideshowController()
            show.start(urls: urls)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let activeAfterStart = show.isActive
                show.close()
                let closed = !show.isActive
                print("=== SLIDESHOW SMOKE ===")
                print("images=\(urls.count) activeAfterStart=\(activeAfterStart) closed=\(closed)")
                try? FileManager.default.removeItem(at: dir)
                let pass = urls.count == 2 && activeAfterStart && closed
                print("RESULT: \(pass ? "PASS" : "FAIL")")
                exit(pass ? 0 : 1)
            }
        }
        app.run()
    }

    /// The main menu. App/Edit cover Quit, Undo/Redo, and text editing; File/View/
    /// Go are thin bindings to the command registry (each item carries its command
    /// id in representedObject and dispatches via BrowserViewController). Only
    /// chords the keymap does not own get key equivalents here, so the menu and
    /// the rebindable keymap never fight over the same keys.
    private static func makeMainMenu(updater: UpdaterController) -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: L("menu.about", "About Pathem"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let checkUpdates = NSMenuItem(
            title: L("menu.checkUpdates", "Check for Updates…"),
            action: #selector(UpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        checkUpdates.target = updater
        appMenu.addItem(checkUpdates)
        appMenu.addItem(.separator())
        appMenu.addItem(commandItem("Settings…", "view.preferences", ","))
        appMenu.addItem(.separator())
        appMenu.addItem(commandItem("Reset Pathem Data…", "app.resetData"))
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L("menu.quit", "Quit Pathem"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: L("menu.file", "File"))
        fileItem.submenu = fileMenu
        // A submenu grouping several command items under one title, to keep the File menu
        // scannable instead of a flat wall of items.
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu()
            items.forEach { menu.addItem($0) }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            return item
        }

        // New
        fileMenu.addItem(commandItem("New Window", "window.new", "n"))
        fileMenu.addItem(commandItem("New Tab", "tab.new"))
        fileMenu.addItem(commandItem("Move Tab to New Window", "window.moveTabToNew"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(commandItem("New Folder", "files.newFolder", "n", [.command, .shift]))
        fileMenu.addItem(commandItem("New Folder with Selection", "files.newFolderWithSelection", "n", [.command, .control]))
        fileMenu.addItem(commandItem("New File", "files.newFile"))  // chord owned by the keymap
        fileMenu.addItem(commandItem("Batch Create…", "files.batchCreate"))
        fileMenu.addItem(commandItem("Manage Templates…", "templates.manage"))
        // Open & inspect
        fileMenu.addItem(.separator())
        fileMenu.addItem(commandItem("Open", "files.open", "o"))
        fileMenu.addItem(commandItem("Open in New Tab", "files.openInNewTab"))
        fileMenu.addItem(openInEditorMenuItem())
        fileMenu.addItem(commandItem("Get Info", "files.getInfo", "i"))
        fileMenu.addItem(commandItem("Set Custom Icon…", "files.setCustomIcon"))
        fileMenu.addItem(commandItem("Remove Custom Icon", "files.removeCustomIcon"))
        fileMenu.addItem(commandItem("Reveal in Finder", "files.reveal"))
        fileMenu.addItem(commandItem("Reveal in Pathem", "files.revealInPathem"))
        // Organize
        fileMenu.addItem(.separator())
        fileMenu.addItem(commandItem("Rename…", "files.rename"))
        fileMenu.addItem(commandItem("AI Rename…", "ai.renameSelection"))
        fileMenu.addItem(commandItem("Duplicate", "files.duplicate"))  // chord owned by the keymap
        fileMenu.addItem(commandItem("Copy To…", "files.copyTo"))
        fileMenu.addItem(commandItem("Move To…", "files.moveTo"))
        fileMenu.addItem(applyLabelMenuItem())
        fileMenu.addItem(commandItem("Add to Collection…", "files.addToCollection"))
        fileMenu.addItem(commandItem("Add to Shelf", "shelf.add", "y"))
        fileMenu.addItem(commandItem("Send via AirDrop", "files.airdrop"))
        // Power operations, grouped into submenus
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            submenu(
                L("menu.makeLink", "Make Link"),
                [
                    commandItem("Symlink", "files.makeSymlink"),
                    commandItem("Alias", "files.makeAlias"),
                    commandItem("Hard Link", "files.makeHardlink"),
                    .separator(),
                    commandItem("Show Original", "files.showOriginal"),
                ]))
        fileMenu.addItem(
            submenu(
                L("menu.transform", "Transform"),
                [
                    commandItem("Split File…", "files.split"),
                    commandItem("Merge Parts", "files.merge"),
                    commandItem("Convert Images…", "files.convertImages"),
                    commandItem("Rotate Left", "image.rotateLeft"),
                    commandItem("Rotate Right", "image.rotateRight"),
                    commandItem("Create PDF", "image.createPDF"),
                    commandItem("Markup…", "image.markup"),
                    commandItem("Trim Media…", "files.trimMedia"),
                    commandItem("Set Attributes…", "files.setAttributes"),
                    commandItem("Set Finder Comment…", "files.setFinderComment"),
                    commandItem("Permissions…", "files.editACL"),
                    commandItem("Change Owner (Admin)…", "files.changeOwner"),
                    .separator(),
                    commandItem("Compress", "files.compress"),
                    commandItem("Compress to 7-Zip", "files.compress7z"),
                    commandItem("Extract", "files.extract"),
                    commandItem("Extract Here", "files.extractHere"),
                    commandItem("Extract to Folder…", "files.extractTo"),
                    commandItem("Show Archive Contents", "files.peekArchive"),
                ]))
        fileMenu.addItem(
            submenu(
                L("menu.checksumEncrypt", "Checksums & Encryption"),
                [
                    commandItem("Copy SHA-256", "files.copySHA256"),
                    commandItem("Verify Checksum…", "files.verifyChecksum"),
                    commandItem("New Encrypted Disk Image…", "files.encryptDMG"),
                ]))
        fileMenu.addItem(
            submenu(
                L("menu.storage", "Storage"),
                [
                    commandItem("Offload to iCloud", "files.offload"),
                    commandItem("Back Up To…", "files.backupTo"),
                ]))
        // Delete
        fileMenu.addItem(.separator())
        fileMenu.addItem(commandItem("Move to Trash", "files.trash", "\u{8}"))
        fileMenu.addItem(commandItem("Delete Immediately…", "files.deleteImmediately", "\u{8}", [.command, .option]))
        fileMenu.addItem(commandItem("Put Back", "files.putBack"))
        fileMenu.addItem(commandItem("Empty Trash…", "files.emptyTrash", "\u{8}", [.command, .shift]))
        fileMenu.addItem(commandItem("Secure Delete…", "files.secureDelete"))
        fileMenu.addItem(commandItem("Uninstall App…", "files.deleteApp"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(commandItem("Close Tab", "tab.close"))

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: L("menu.edit", "Edit"))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: L("menu.undo", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("menu.redo", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(commandItem("Undo History…", "edit.showHistory"))
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("menu.cut", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("menu.copy", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("menu.paste", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: L("menu.selectAll", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(commandItem("Copy Path", "files.copyPath", "c", [.command, .option]))
        editMenu.addItem(commandItem("Copy as File URL", "files.copyURL"))
        editMenu.addItem(commandItem("Copy Name", "files.copyName"))
        editMenu.addItem(.separator())
        editMenu.addItem(commandItem("Show Clipboard…", "view.clipboard"))
        editMenu.addItem(commandItem("Select by Pattern…", "files.selectByPattern"))

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: L("menu.view", "View"))
        viewItem.submenu = viewMenu
        // View modes + arrangement stay at the top level (the most-used controls).
        viewMenu.addItem(commandItem("as List", "view.asList", "1"))
        viewMenu.addItem(commandItem("as Icons", "view.asIcons", "2"))
        viewMenu.addItem(commandItem("as Gallery", "view.asGallery", "3"))
        viewMenu.addItem(commandItem("as Columns", "view.asColumn", "4"))
        viewMenu.addItem(commandItem("as Tree", "view.asTree", "5"))
        viewMenu.addItem(submenu("Arrange By", [
            commandItem("None", "view.arrangeNone"),
            commandItem("Kind", "view.arrangeKind"),
            commandItem("Size", "view.arrangeSize"),
            commandItem("Date Modified", "view.arrangeDate"),
            commandItem("Tag", "view.arrangeTag"),
        ]))
        viewMenu.addItem(.separator())
        viewMenu.addItem(commandItem("Zoom In", "view.zoomIn"))
        viewMenu.addItem(commandItem("Zoom Out", "view.zoomOut"))
        viewMenu.addItem(.separator())

        // Everything else is grouped into submenus so the top level stays scannable
        // instead of a 40-item wall. Shortcuts still work from inside a submenu.
        viewMenu.addItem(submenu("Find", [
            // Cmd-F opens the search-and-command overlay in search mode (Cmd-K opens the same
            // overlay in command mode); the old Cmd-F live filter moves to Shift-Cmd-F.
            commandItem("Search This Folder…", "search.palette", "f"),
            commandItem("Filter…", "view.filter", "f", [.command, .shift]),
            commandItem("Advanced Find…", "view.advancedFind", "f", [.command, .option]),
            commandItem("Find in Files…", "files.findInFiles"),
            commandItem("Find Duplicates", "files.findDuplicates"),
            commandItem("Find Similar Names", "files.findSimilarNames"),
            .separator(),
            commandItem("Flat View", "view.flatView", "f", [.command, .control]),
            commandItem("Flatten Folder (Show All Items)", "view.flattenFolder"),
        ]))
        viewMenu.addItem(submenu("Folder Tools", [
            commandItem("Compare Panes…", "files.comparePanes"),
            commandItem("Size Browser…", "view.sizeBrowser"),
            commandItem("Calculate All Sizes", "view.calculateSizes"),
            .separator(),
            commandItem("Cleanup…", "view.cleanup"),
            commandItem("Reclaim in Repo…", "files.repoReclaim"),
        ]))
        viewMenu.addItem(submenu("Show", [
            commandItem("Show Hidden Files", "view.toggleHidden"),
            commandItem("Show Full Path in Title Bar", "view.fullPathTitle"),
            commandItem("Show Path Bar at Bottom", "view.pathBarBottom"),
            commandItem("Compact Sidebar", "view.compactSidebar"),
            commandItem("Sync Browsing", "view.syncBrowsing"),
            commandItem("Vim Navigation", "nav.vimMode"),
        ]))
        viewMenu.addItem(submenu("Preview", [
            commandItem("Quick Look", "view.quickLook"),
            commandItem("Slideshow", "view.slideshow"),
            commandItem("Preview Pane", "view.previewPane", "p", [.command, .option]),
            commandItem("Show Shelf", "shelf.toggle", "y", [.command, .shift]),
        ]))
        viewMenu.addItem(submenu("Layout & Style", [
            commandItem("Save Workspace…", "workspace.save"),
            commandItem("Open Workspace…", "workspace.open"),
            .separator(),
            commandItem("Save Style…", "view.saveStyle"),
            commandItem("Apply Style…", "view.applyStyle"),
            commandItem("Use as Default View", "view.useAsDefault"),
            .separator(),
            submenu("Folder Background", [
                commandItem("Background Color…", "files.setFolderBgColor"),
                commandItem("Background Picture…", "files.setFolderBgPicture"),
                .separator(),
                commandItem("Remove Background", "files.clearFolderBg"),
            ]),
            commandItem("Customize Toolbar…", "view.customizeToolbar"),
        ]))

        // Terminal group, with the theme presets nested under it.
        let themeItem = NSMenuItem(
            title: L("menu.terminalTheme", "Terminal Theme"), action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for theme in TerminalTheme.presets {
            let item = NSMenuItem(
                title: theme.name, action: #selector(BrowserViewController.selectTerminalTheme(_:)),
                keyEquivalent: "")
            item.representedObject = theme.name
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        viewMenu.addItem(submenu("Terminal", [
            commandItem("Toggle Terminal", "terminal.toggle", "`", [.control]),
            commandItem("Commander Mode", "commander.toggle"),
            commandItem("Terminal Follows Folder", "terminal.toggleFollow"),
            commandItem("Open Terminal Here", "terminal.here"),
            .separator(),
            themeItem,
        ]))
        viewMenu.addItem(.separator())

        // The AI bar stays top-level; the folder-organizing and git actions group up.
        viewMenu.addItem(commandItem("Command Palette…", "palette.show", "k"))
        viewMenu.addItem(commandItem("Ask Pathem…", "ai.run"))
        viewMenu.addItem(submenu("Organize", [
            commandItem("Organize Folder…", "files.organize"),
            commandItem("Organize with AI…", "files.organizeAI"),
            commandItem("Summarize Folder", "ai.summarizeFolder"),
            commandItem("Batch Rename…", "files.batchRename"),
        ]))
        viewMenu.addItem(submenu("Git", [
            commandItem("Commit…", "git.commit"),
            commandItem("Push", "git.push"),
            commandItem("Pull", "git.pull"),
        ]))
        viewMenu.addItem(.separator())
        viewMenu.addItem(commandItem("Demo Mode (fake data for screenshots)", "view.demoMode"))

        let goItem = NSMenuItem()
        mainMenu.addItem(goItem)
        let goMenu = NSMenu(title: L("menu.go", "Go"))
        goItem.submenu = goMenu
        goMenu.addItem(commandItem("Back", "nav.back"))
        goMenu.addItem(commandItem("Forward", "nav.forward"))
        goMenu.addItem(commandItem("Enclosing Folder", "nav.up"))
        goMenu.addItem(commandItem("Go to Path…", "nav.editPath", "l"))
        goMenu.addItem(commandItem("Find Files Everywhere…", "nav.findFiles", "o", [.command, .shift]))
        goMenu.addItem(.separator())
        goMenu.addItem(commandItem("Connect to Server…", "files.connectToServer"))
        goMenu.addItem(commandItem("Connections…", "connections.manage", "k", [.command, .shift]))
        goMenu.addItem(commandItem("Open Connections in a New Tab", "connections.newTabToggle"))
        goMenu.addItem(commandItem("Download from Server…", "remote.download"))

        let toolsItem = NSMenuItem()
        mainMenu.addItem(toolsItem)
        let toolsMenu = NSMenu(title: L("menu.tools", "Tools"))
        toolsItem.submenu = toolsMenu
        toolsMenu.addItem(commandItem("Process Viewer", "tools.processViewer"))
        toolsMenu.addItem(commandItem("Torrents", "tools.torrents"))
        toolsMenu.addItem(commandItem("Transfers", "tools.transfers"))
        toolsMenu.addItem(commandItem("Eject Volume", "files.ejectVolume"))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(commandItem("Run Shortcut on Selection…", "tools.runShortcut"))
        toolsMenu.addItem(commandItem("Automation Rules…", "tools.automation"))
        toolsMenu.addItem(commandItem("Compare Files", "files.diff"))
        toolsMenu.addItem(commandItem("Extended Attributes…", "files.xattrs"))
        toolsMenu.addItem(commandItem("Remove Quarantine", "files.removeQuarantine"))

        // Window: standard AppKit window management. Assigning it as the app's windowsMenu makes
        // AppKit keep the open-window list current and add the native tabbing items ("Merge All
        // Windows", "Move Tab to New Window", "Show Next/Previous Tab") when windows are tabbed.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: L("menu.window", "Window"))
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: L("menu.minimize", "Minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: L("menu.zoom", "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: L("menu.bringAllToFront", "Bring All to Front"),
            action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApplication.shared.windowsMenu = windowMenu

        return mainMenu
    }

    /// A menu item that runs a registry command via BrowserViewController. A key
    /// equivalent is set only when provided (chords the keymap owns are left
    /// without one so the two never collide).
    /// An "Open in…" submenu listing the developer editors installed at launch; each
    /// opens the current/selected folder via BrowserViewController.openInExternalEditor.
    private static func openInEditorMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("menu.openIn", "Open in…"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Open in…")
        let editors = ExternalEditors.installed()
        if editors.isEmpty {
            let none = NSMenuItem(title: L("menu.noEditors", "No editors found"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        } else {
            for editor in editors {
                let entry = NSMenuItem(
                    title: editor.name,
                    action: #selector(BrowserViewController.openInExternalEditor(_:)), keyEquivalent: "")
                entry.representedObject = editor.url
                submenu.addItem(entry)
            }
        }
        item.submenu = submenu
        return item
    }

    /// A "Label" submenu of named labels (each a colored tag) plus Clear Tags.
    private static func applyLabelMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("menu.label", "Label"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Label")
        for label in LabelSet.default.labels {
            let entry = NSMenuItem(
                title: label.name,
                action: #selector(BrowserViewController.applyLabelFromMenu(_:)), keyEquivalent: "")
            entry.representedObject = label
            entry.image = TagColors.dot(label.color, diameter: 12)
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(commandItem("Clear Tags", "tags.clear"))
        item.submenu = submenu
        return item
    }

    private static func commandItem(
        _ title: String, _ commandID: String, _ key: String = "",
        _ mods: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        // AppKit rule: a Shift-modified letter equivalent must use the UPPERCASE letter. With a
        // lowercase key plus .shift in the mask the item can also match the *unshifted* key -- which
        // is why Cmd+K was firing the Cmd+Shift+K "Connections…" item. Uppercase whenever shift is set.
        let effectiveKey = mods.contains(.shift) ? key.uppercased() : key
        let item = NSMenuItem(
            title: L("menu.\(commandID)", title),  // localized by command id; English is the fallback
            action: #selector(BrowserViewController.performMenuCommand(_:)),
            keyEquivalent: effectiveKey)
        item.representedObject = commandID
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        return item
    }

    /// Gate A: prove the view-based table virtualizes a 1M-row dataset. Builds
    /// the rows, forces layout at several scroll positions, and reports how many
    /// cell views the table actually requested. A virtualized table requests a
    /// number proportional to the visible window (tens), not to the dataset.
    private static func runGateA(_ controller: FileListController, _ window: NSWindow) {
        let n = 1_000_000
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let t0 = Date()
        var rows = [FileEntry]()
        rows.reserveCapacity(n)
        for i in 0..<n {
            rows.append(
                FileEntry(
                    name: "file-\(String(format: "%07d", i)).dat",
                    isDirectory: i % 50 == 0,
                    size: Int64((i % 100_000) * 13),
                    modificationDate: base.addingTimeInterval(Double(i))))
        }
        let buildMs = Date().timeIntervalSince(t0) * 1000

        let t1 = Date()
        controller.setEntries(rows)
        window.layoutIfNeeded()
        controller.tableView.layoutSubtreeIfNeeded()
        controller.tableView.displayIfNeeded()
        let reloadMs = Date().timeIntervalSince(t1) * 1000
        let initial = controller.cellRequests

        func jump(_ row: Int) -> Int {
            let before = controller.cellRequests
            controller.tableView.scrollRowToVisible(row)
            controller.tableView.layoutSubtreeIfNeeded()
            controller.tableView.displayIfNeeded()
            return controller.cellRequests - before
        }
        let lastDelta = jump(n - 1)
        let midDelta = jump(n / 2)
        let topDelta = jump(0)

        let pass = initial < 5_000 && lastDelta < 5_000 && controller.tableView.numberOfRows == n

        print("=== GATE A: view-based NSTableView virtualization ===")
        print(String(format: "built %d FileEntry in %.0f ms", n, buildMs))
        print(String(format: "reloadData + first layout: %.0f ms", reloadMs))
        print("numberOfRows = \(controller.tableView.numberOfRows)")
        print("cell views requested for initial display = \(initial)")
        print("cells materialized per jump: lastRow=\(lastDelta) mid=\(midDelta) top=\(topDelta)")
        print("RESULT: \(pass ? "PASS" : "FAIL") — table materializes bounded cells regardless of 1M-row dataset")

        exit(pass ? 0 : 1)
    }

    /// Build a sample folder (subfolders, files, and gradient landscape PNGs that read like
    /// real photos in thumbnails) for PATHEM_VIEW_SHOT.
    private static func makeSampleFolder() -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-viewshot")
        try? fm.removeItem(at: dir)
        for sub in ["Subfolder A", "Subfolder B"] {
            try? fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        for name in ["nested1.txt", "nested2.txt", "nested3.txt"] {
            try? "x".write(to: dir.appendingPathComponent("Subfolder A").appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try? "notes".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try? "code".write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        for name in ["Sunset.png", "Coastline.png", "Forest.png", "Mountains.png", "City.png", "Desert.png"] {
            if let data = DemoWorkspace.landscapePNG(named: name, side: 256) {
                try? data.write(to: dir.appendingPathComponent(name))
            }
        }
        return dir
    }
}

/// A window that always reports key status, so screenshot runs draw colored traffic
/// lights even when macOS won't let a background launch actually become active.
/// Used only by the PATHEM_*_SHOT capture modes, never in a normal launch.
final class AlwaysKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }  // traffic lights consult main status as well
}

/// Warns before quitting while a copy/move is running, so Cmd-Q can't leave a
/// transfer half-finished without the user's say-so.
@MainActor
final class PathemAppDelegate: NSObject, NSApplicationDelegate {
    weak var browser: BrowserViewController?
    var updater: UpdaterController?
    var vpnStatusItem: VPNStatusItem?  // menu-bar VPN kill-switch indicator (self-hides when off)

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Finder's "Open With ▸ Pathem" (and `open -a Pathem <folder>`) delivers folders here.
    func application(_ application: NSApplication, open urls: [URL]) {
        openInPrimaryBrowser(urls)
    }

    /// The "Open in Pathem" Services item: open the sent files/folders.
    @objc func openInPathem(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        openInPrimaryBrowser(urls)
    }

    /// Route opened URLs to the primary window, retrying once if it isn't up yet (open events can
    /// arrive during launch).
    private func openInPrimaryBrowser(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let browser = WindowManager.shared.primaryBrowser {
            for url in urls {
                if url.scheme == "magnet" {
                    browser.addMagnetToPanel(url.absoluteString)  // magnet: link -> Torrents panel
                } else {
                    browser.openExternalFolder(url)  // routes .torrent files to the panel itself
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.openInPrimaryBrowser(urls) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowManager.shared.primaryBrowser?.saveSessionNow()  // persist tabs/folders for next launch
        // Hang up every window's embedded shell so none (and the jobs they launched) is orphaned.
        WindowManager.shared.terminateAllTerminals()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard browser?.isTransferring == true else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("quit.transferTitle", "A file transfer is still in progress")
        alert.informativeText = L(
            "quit.transferBody", "Quitting now may leave it incomplete. Quit anyway?")
        alert.addButton(withTitle: L("quit.quitAnyway", "Quit Anyway"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
