import AVFoundation
import AppKit
import AppRelaunch
import PDFKit
import PathemEngine
import PathemTerminal

@MainActor
private final class GateADemoCapture {
    let framesDirectory: URL?
    private(set) var tickCount = 0
    private(set) var frameCount = 0
    private(set) var frameWriteFailed = false

    init(framesDirectory: URL?) {
        self.framesDirectory = framesDirectory
    }

    func advanceTick() {
        tickCount += 1
    }

    func capture(window: NSWindow) {
        guard let framesDirectory, let content = window.contentView,
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            frameWriteFailed = true
            return
        }
        let output = framesDirectory.appendingPathComponent(
            String(format: "frame-%05d.png", frameCount))
        do {
            try png.write(to: output, options: .atomic)
            frameCount += 1
        } catch {
            frameWriteFailed = true
        }
    }

    var result: (message: String?, exitCode: Int32) {
        let tooFewFrames = framesDirectory != nil && frameCount < 2
        let failed = frameWriteFailed || tooFewFrames
        let message = framesDirectory.map { _ in
            "GATE_A_DEMO: \(failed ? "FAIL" : "PASS") frames=\(frameCount)"
        }
        return (message, failed ? 1 : 0)
    }
}

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
        let launchEnvironment = ProcessInfo.processInfo.environment
        #if DEBUG
        if launchEnvironment["PATHEM_TREE_STAT_TEST"] == "1" {
            do { exit(try TreeMetadataProbe.run() ? 0 : 1) } catch {
                print("TREE STAT: \(error.localizedDescription)")
                exit(1)
            }
        }
        #endif
        #if DEBUG
        let configurationTest =
            launchEnvironment["PATHEM_CONTENT_PREFS_UI_TEST"] != nil
            || launchEnvironment["PATHEM_SETTINGS_DEFAULTS_UI_TEST"] != nil
            || launchEnvironment["PATHEM_OPENER_UI_TEST"] != nil
            || launchEnvironment["PATHEM_SIDEBAR_TRANSFER_UI_TEST"] != nil
            || launchEnvironment["PATHEM_FILE_SEARCH_TEST"] != nil
            || launchEnvironment["PATHEM_LAYOUT_MATRIX_TEST"] != nil
            || launchEnvironment["PATHEM_TRANSIENT_SURFACES_TEST"] != nil
            || launchEnvironment["PATHEM_COMMUNITY_GALLERY_TEST"] != nil
        #else
        let configurationTest = false
        #endif
        if configurationTest || launchEnvironment["PATHEM_RELEASE_TEST"] != nil {
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            guard let path = launchEnvironment["PATHEM_CONFIG_DIR"], !path.isEmpty else {
                print("RESULT: FAIL configuration test requires an isolated temporary config root")
                exit(64)
            }
            let configured = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard configured.pathComponents.count > temporary.pathComponents.count,
                configured.pathComponents.starts(with: temporary.pathComponents)
            else {
                print("RESULT: FAIL configuration test refuses a non-temporary config root")
                exit(64)
            }
        }
        // Automation owns a new, private demo tree. Never delete an existing directory
        // supplied through the environment, including a symlink to another launch's tree.
        var automationDemoRoot: URL?
        if isAutomationLaunch && launchEnvironment["PATHEM_DEMO"] != nil {
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            let root =
                launchEnvironment["PATHEM_DEMO_ROOT"].map { URL(fileURLWithPath: $0) }
                ?? temporary.appendingPathComponent("pathem-demo-\(UUID().uuidString)")
            let resolved = root.resolvingSymlinksInPath()
            guard resolved.pathComponents.count > temporary.pathComponents.count,
                resolved.pathComponents.starts(with: temporary.pathComponents),
                !FileManager.default.fileExists(atPath: root.path)
            else {
                print(
                    "RESULT: FAIL automation demo root must be a new directory inside system temp")
                exit(64)
            }
            automationDemoRoot = resolved
            atexit_b {
                do {
                    try FileManager.default.removeItem(at: resolved)
                    print("DEMOISOLATION: removed \(resolved.path)")
                } catch {
                    fputs("DEMOISOLATION: FAIL cleanup\n", stderr)
                }
            }
        }
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
        let shotRun =
            ProcessInfo.processInfo.environment["PATHEM_VIEW_SHOT"] != nil
            || ProcessInfo.processInfo.environment["PATHEM_MAIN_SHOT"] != nil
            || ProcessInfo.processInfo.environment["PATHEM_SITE_SHOT"] != nil
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

        #if DEBUG  // automation / self-check / screenshot entrypoints; stripped from the release binary (5.7)
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
            for lang in [
                "en", "es", "fr", "de", "zh-Hans", "ja", "it", "pt-BR", "ko", "zh-Hant", "ru", "nl",
            ] where code(for: lang) == nil {
                print("  MISSING lproj: \(lang)")
                ok = false
            }
            // Keys whose translation differs from English in every shipped language ("File" is also
            // the Italian menu title, so menu.file cannot be a sample).
            let sample = ["menu.edit": "Edit", "common.cancel": "Cancel"]
            for lang in [
                "es", "fr", "de", "zh-Hans", "ja", "it", "pt-BR", "ko", "zh-Hant", "ru", "nl",
            ] {
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
            SettingsWindowController().debugRenderPanes(toDir: captureDirectory)
            BatchCreateController().debugRender(to: capturePath("batch.png"))
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

        if ProcessInfo.processInfo.environment["PATHEM_GATE_A_DEMO"] != nil {
            // The same 1M-row dataset, but smoothly auto-scrolled for a screen recording (the
            // above-the-fold demo). Runs the app loop so the scroll timer fires, then exits.
            let controller = FileListController()
            window.contentView = controller.scrollView
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            startGateADemoScroll(controller, window)
            app.run()
            return
        }

        if let suite = DeterministicE2E.requestedSuite {
            DeterministicE2E.start(suite)
            app.run()
            return
        }
        #endif

        // Normal mode: a dual-pane browser rooted at the home directory (or a sample
        // folder when rendering view-mode screenshots).
        let viewShot = ProcessInfo.processInfo.environment["PATHEM_VIEW_SHOT"] != nil
        // Privacy-safe demo mode (PATHEM_DEMO=1): a fake workspace + sidebar for screenshots.
        let demoLayout =
            ProcessInfo.processInfo.environment["PATHEM_DEMO"] != nil
            ? DemoWorkspace.build(root: automationDemoRoot) : nil
        if let automationDemoRoot { print("DEMOISOLATION: used \(automationDemoRoot.path)") }
        let start =
            viewShot ? Self.makeSampleFolder() : FileManager.default.homeDirectoryForCurrentUser
        // An automation launch (smoke test, screenshot, or a render/test harness) navigates panes to
        // scratch paths; it must NOT persist over the user's real saved session, or their next normal
        // launch reopens with /tmp-style tabs. Only a plain interactive launch owns session.json.
        let browser = BrowserViewController(
            start: start, demo: demoLayout, persistsSession: !Self.isAutomationLaunch)
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
        if isAutomationLaunch || !window.setFrameUsingName(frameName) {
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.center()
        }
        if !isAutomationLaunch { window.setFrameAutosaveName(frameName) }
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
        #if DEBUG
        if let phase = launchEnvironment["PATHEM_COMMUNITY_GALLERY_TEST"] {
            guard let fixture = launchEnvironment["PATHEM_COMMUNITY_FIXTURE"],
                let store = CommunityThemeGalleryWindow.storeURL
            else {
                print("COMMUNITY GALLERY: fixture and local gallery configuration required")
                exit(64)
            }
            browser.installToolbarIfNeeded()
            do {
                try browser.smokeCommunityGallery(
                    phase: phase, fixture: URL(fileURLWithPath: fixture), store: store)
                print("community-gallery-\(phase): PASS")
                exit(0)
            } catch {
                print("community-gallery-\(phase): FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
        if ProcessInfo.processInfo.environment["PATHEM_SMOKE"] == "themes" {
            browser.installToolbarIfNeeded()
            let passed = browser.smokeThemePreservesCustomToolbar()
            print("theme-preserves-custom-toolbar: \(passed ? "PASS" : "FAIL")")
            exit(passed ? 0 : 1)
        }
        if let check = launchEnvironment["PATHEM_THEME_AUTOSAVE_TEST"],
            ["write", "read"].contains(check),
            let runID = launchEnvironment["PATHEM_THEME_AUTOSAVE_ID"].flatMap(
                UUID.init(uuidString:))
        {
            let identifier = NSToolbar.Identifier("com.scarcrux.pathem.toolbar.test.\(runID)")
            let key = "NSToolbar Configuration \(identifier)"
            let stored = UserDefaults.standard.dictionary(forKey: key)?["TB Item Identifiers"]
            print("theme-toolbar-before-install: \(stored != nil)")
            browser.installToolbarIfNeeded(identifier: identifier)
            let passed = browser.smokeThemeToolbarAutosave(write: check == "write")
            print("theme-toolbar-autosave-\(check): \(passed ? "PASS" : "FAIL")")
            exit(passed ? 0 : 1)
        }
        if let dir = ProcessInfo.processInfo.environment["PATHEM_THEME_SHOTS"] {
            let communityTheme: ThemePreset?
            if let package = launchEnvironment["PATHEM_COMMUNITY_RENDER_PACKAGE"] {
                do {
                    communityTheme = try ThemePackage.decode(
                        Data(contentsOf: URL(fileURLWithPath: package)))
                } catch {
                    print("COMMUNITY RENDER: \(error.localizedDescription)")
                    exit(1)
                }
            } else {
                communityTheme = nil
            }
            browser.installToolbarIfNeeded()
            window.setContentSize(NSSize(width: 1200, height: 760))
            browser.view.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                browser.debugRenderThemes(toDir: dir, communityTheme: communityTheme) { exit(0) }
            }
            // The in-process render does not need desktop activation or Screen Recording.
            RunLoop.main.run(until: Date().addingTimeInterval(60))
            exit(1)
        }
        #endif
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        delegate.vpnStatusItem = VPNStatusItem()  // shows only while VPN binding is enabled
        // Offer a relaunch if a newer build gets installed under us (a `make install` under a
        // running process). Silent under automation launches (smoke / screenshot / test), which
        // start and exit in seconds. The watcher is the shared AppRelaunch package; see its notes
        // for why it reads the bundle by path, keeps a grace margin, and never force-quits.
        if !Self.isAutomationLaunch {
            AppRelaunch.watch(.init(appName: "pathem")) { stale in
                StaleBuildState.record(stale)
            }
        }

        #if DEBUG  // all remaining automation / screenshot / E2E dispatch; stripped from release (5.7)
        // PATHEM_E2E: drive a real create -> rename -> new-file flow on a temp workspace and assert
        // the on-disk outcomes end to end (feature-level, not just UI invariants), then capture an
        // offscreen render. The seed of a feature E2E harness; run via `make e2e`.
        if ProcessInfo.processInfo.environment["PATHEM_E2E"] != nil {
            runE2E(browser: browser)
            app.run()
            return
        }

        // PATHEM_UI_TEST: the in-process UI-automation harness -- drives real UI flows in a real
        // window and asserts on real geometry (interaction/scroll bugs). It pumps the run loop itself
        // and exits, so no app.run() here.
        if ProcessInfo.processInfo.environment["PATHEM_UI_TEST"] != nil {
            browser.runUIAutomation()
        }
        if ProcessInfo.processInfo.environment["PATHEM_FILE_SEARCH_TEST"] != nil {
            browser.runFileSearchUIAutomation()
        }
        if ProcessInfo.processInfo.environment["PATHEM_FINDER_UI_TEST"] != nil {
            browser.runFinderUIAutomation()
        }
        if ProcessInfo.processInfo.environment["PATHEM_BACKGROUND_UI_TEST"] != nil {
            browser.runBackgroundMenuUIAutomation()
        }
        if ProcessInfo.processInfo.environment["PATHEM_SIDEBAR_TRANSFER_UI_TEST"] != nil {
            browser.runSidebarTransferUIAutomation()
        }
        if ProcessInfo.processInfo.environment["PATHEM_CONTENT_PREFS_UI_TEST"] != nil {
            browser.runContentConfigurationUIAutomation()
        }
        if ProcessInfo.processInfo.environment["PATHEM_SETTINGS_DEFAULTS_UI_TEST"] != nil {
            browser.runSettingsDefaultsUIAutomation()
        }
        if ProcessInfo.processInfo.environment["PATHEM_OPENER_UI_TEST"] != nil {
            browser.runOpenerUIAutomation()
        }
        if ProcessInfo.processInfo.environment["PATHEM_LAYOUT_UI_TEST"] != nil {
            browser.runLayoutUIAutomation()
        }
        if ProcessInfo.processInfo.environment["PATHEM_LAYOUT_MATRIX_TEST"] != nil {
            guard let demoLayout else {
                print("RESULT: FAIL layout matrix requires PATHEM_DEMO=1")
                exit(64)
            }
            browser.runLayoutMatrixAutomation(demo: demoLayout)
        }
        if ProcessInfo.processInfo.environment["PATHEM_TRANSIENT_UI_TEST"] != nil {
            browser.runTransientUIAutomation()
        }
        if ProcessInfo.processInfo.environment["PATHEM_TRANSIENT_SURFACES_TEST"] != nil {
            guard let demoLayout else {
                print("RESULT: FAIL transient surfaces require isolated demo")
                exit(64)
            }
            browser.runTransientSurfaceSample(demo: demoLayout)
        }
        if ProcessInfo.processInfo.environment["PATHEM_COMPILER_UI_TEST"] != nil {
            browser.runCompilerUIAutomation()
        }

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
            bar.update(selectionCount: 3, isViewable: false)
            host.center()
            host.makeKeyAndOrderFront(nil)
            let number = host.windowNumber
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l\(number)", "/tmp/quickbar_live.png"]
                try? capture.run()
                capture.waitUntilExit()
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
                    try? capture.run()
                    capture.waitUntilExit()
                    exit(0)
                }
            }
        }

        // Live screenshot of the transfer queue with an in-progress download (PATHEM_QUEUE_SHOT=1).
        if ProcessInfo.processInfo.environment["PATHEM_QUEUE_SHOT"] != nil {
            let queue = TransferQueueController()
            Self.liveDialog = queue
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
                "pathem-queue-demo.bin")
            try? Data(repeating: 0, count: 46_000).write(to: tmp)  // 46% of 100k
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let running = TransferQueueController.Item(
                    name: "vacation-4k.mov", totalBytes: 100_000, progressFile: tmp
                ) {
                    try? await Task.sleep(for: .seconds(4))
                }
                let queued = TransferQueueController.Item(
                    name: "photos.zip", totalBytes: 5_000_000, progressFile: tmp
                ) {}
                queue.run([running, queued], title: "Downloading from example.com", over: window) {
                    _, _ in
                }
                let number = queue.debugWindowNumber
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l\(number)", "/tmp/queue_live.png"]
                    try? capture.run()
                    capture.waitUntilExit()
                    exit(0)
                }
            }
        }

        #if DEBUG
        // Open a list view's context menu on a selected demo file, so a screenshot taken from
        // outside shows what AppKit adds, Services included (PATHEM_SERVICES_SHOT=<file name>,
        // with PATHEM_DEMO=1).
        if let name = ProcessInfo.processInfo.environment["PATHEM_SERVICES_SHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let pane = browser.activePane else { return }
                pane.setViewMode(.list)
                pane.debugSelectNames([name])
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    pane.debugRightClickSelection()
                }
            }
        }
        #endif

        #if DEBUG
        // Pop up the toolbar's Theme submenu so a capture from outside shows it as drawn
        // (PATHEM_THEME_MENU_SHOT=1). Blocks in menu tracking until the process is ended.
        if ProcessInfo.processInfo.environment["PATHEM_THEME_MENU_SHOT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let menu = NSMenu()
                browser.populateOverflowMenu(menu)
                let theme = menu.items.first {
                    $0.submenu?.items.contains { $0.title == "Nord" } ?? false
                }
                if let sub = theme?.submenu, let content = window.contentView {
                    sub.popUp(
                        positioning: nil, at: NSPoint(x: 300, y: content.bounds.maxY - 40),
                        in: content)
                }
            }
        }
        // Show the views in pairs (left, right) for an outside capture, one pair every five
        // seconds: PATHEM_PANE_MODES="tree:icon,gallery:column".
        if let spec = ProcessInfo.processInfo.environment["PATHEM_PANE_MODES"] {
            let pairs = spec.split(separator: ",").map { $0.split(separator: ":").map(String.init) }
            for (step, pair) in pairs.enumerated() where pair.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(step) * 5) {
                    for (side, name) in zip([browser.leftTabs, browser.rightTabs], pair) {
                        if let mode = ViewFormat.ViewMode(rawValue: name) {
                            side.activePane?.setViewMode(mode)
                        }
                    }
                }
            }
        }
        #endif

        // Open Reclaim Space against the real home folder, wait for every known place to be
        // measured, print how long that took, and save a picture of the window
        // (PATHEM_RECLAIM_SHOT=<png path>). Read-only: nothing is checked or deleted.
        if let shot = ProcessInfo.processInfo.environment["PATHEM_RECLAIM_SHOT"] {
            let started = Date()
            browser.cleanup.present(
                for: FileManager.default.homeDirectoryForCurrentUser, over: window)
            // What the window shows before anything is measured: sizes remembered from last time.
            FileHandle.standardOutput.write(
                Data(
                    "RECLAIM OPEN: rows=\(browser.cleanup.debugPlaceRows.count) summary=\(browser.cleanup.debugSummary)\n"
                        .utf8))
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let elapsed = Date().timeIntervalSince(started)
                    // PATHEM_RECLAIM_SHOT_AFTER=<seconds> renders early, for layout checks.
                    let limit =
                        ProcessInfo.processInfo.environment["PATHEM_RECLAIM_SHOT_AFTER"]
                        .flatMap(Double.init) ?? 900
                    guard browser.cleanup.debugPlacesDone || elapsed > limit else { return }
                    print(
                        "RECLAIM SHOT: measured=\(browser.cleanup.debugPlacesDone) seconds=\(Int(elapsed)) rows=\(browser.cleanup.debugPlaceRows.count)"
                    )
                    for row in browser.cleanup.debugPlaceRows.prefix(12) {
                        print("RECLAIM ROW: \(row.title) | \(row.what) | \(row.size)")
                    }
                    print("RECLAIM SUMMARY: \(browser.cleanup.debugSummary)")
                    browser.cleanup.debugRender(to: shot)
                    exit(0)
                }
            }
        }

        // Headless render of the move/copy conflict popover content (PATHEM_CONFLICT_SHOT=1), to
        // inspect the button padding.
        if ProcessInfo.processInfo.environment["PATHEM_CONFLICT_SHOT"] != nil {
            let requestedAppearance = ProcessInfo.processInfo.environment[
                "PATHEM_CAPTURE_APPEARANCE"]
            let appearance: NSAppearance?
            switch requestedAppearance ?? "dark" {
            case "light": appearance = NSAppearance(named: .aqua)
            case "dark": appearance = NSAppearance(named: .darkAqua)
            default:
                print("CAPTURE ERROR: unsupported appearance; use light or dark")
                exit(64)
            }
            let longLabels =
                ProcessInfo.processInfo.environment["PATHEM_CAPTURE_LONG_LABELS"] == "1"
            CursorConfirm().debugRender(
                to: capturePath("conflict.png"),
                message: L("bvc.conflictOne", "1 item already exists at the destination"),
                info: BrowserViewController.conflictActionHint(move: false),
                buttons: longLabels
                    ? [
                        "Vorhandene Datei vollständig ersetzen", "Beide Dateien dauerhaft behalten",
                        "Diesen Eintrag überspringen", "Übertragung vollständig abbrechen",
                    ]
                    : [
                        L("bvc.replace", "Replace"), L("bvc.keepBoth", "Keep Both"),
                        L("bvc.skip", "Skip"), L("common.cancel", "Cancel"),
                    ],
                defaultIndex: 1, cancelIndex: 3, appearance: appearance)
            exit(0)
        }

        // Interactive preview of the real NSPopover, including its material, arrow, focus and
        // cursor-relative placement. Used during visual polish; it stays open until the user picks
        // an action or clicks away, while keeping the underlying demo window available for context.
        if ProcessInfo.processInfo.environment["PATHEM_CONFLICT_PREVIEW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                Task { @MainActor in
                    _ = await browser.cursorConfirm.ask(
                        message: "1 item already exists at the destination",
                        info: "Choose how to handle the copy.",
                        buttons: ["Replace", "Keep Both", "Skip", "Cancel"],
                        defaultIndex: 1,
                        cancelIndex: 3,
                        over: browser.view)
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
                    entries: [
                        "IMG_0001.jpg", "IMG_0002.jpg", "notes/todo.txt", "notes/ideas.md",
                        "cover.png",
                    ],
                    onExtractAll: {})
                let number = dialog.debugWindowNumber
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l\(number)", "/tmp/dialog_archive.png"]
                    try? capture.run()
                    capture.waitUntilExit()
                    exit(0)
                }
            }
        }

        // Live screenshot of the Get Info inspector for a sample app (PATHEM_INFO_SHOT=1).
        if ProcessInfo.processInfo.environment["PATHEM_INFO_SHOT"] != nil {
            let inspector = InfoInspectorController()
            Self.liveInspector = inspector
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                inspector.present(
                    urls: [URL(fileURLWithPath: "/System/Applications/Calculator.app")], over: nil)
                let number = inspector.debugWindowNumber
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l\(number)", "/tmp/info_live.png"]
                    try? capture.run()
                    capture.waitUntilExit()
                    exit(0)
                }
            }
        }

        // Bake an ink stroke of known shape into a PDF and exit (PATHEM_INK_TEST=<out.pdf>), so a
        // Quick Look render can confirm freehand ink lands where the input points are (page
        // coordinates, bottom-up). The stroke traces an "L": top-left, down, then right.
        if let inkOut = ProcessInfo.processInfo.environment["PATHEM_INK_TEST"] {
            let url = URL(fileURLWithPath: inkOut)
            let doc = PDFDocument()
            doc.insert(PDFPage(), at: 0)
            doc.write(to: url)
            let preview = DocumentPreviewView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
            preview.show(url)
            let ok = preview.debugInkAndSave(points: [
                CGPoint(x: 120, y: 680), CGPoint(x: 120, y: 400), CGPoint(x: 420, y: 400),
            ])
            print("INK TEST saved=\(ok) -> \(url.path)")
            exit(ok ? 0 : 1)
        }

        // Bake one of each shape / line / arrow into a PDF and exit (PATHEM_MARKUP_TEST=<out.pdf>),
        // so a Quick Look render confirms every modal tool lands where its drag would.
        if let shapesOut = ProcessInfo.processInfo.environment["PATHEM_MARKUP_TEST"] {
            let url = URL(fileURLWithPath: shapesOut)
            let doc = PDFDocument()
            doc.insert(PDFPage(), at: 0)
            doc.write(to: url)
            let preview = DocumentPreviewView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
            preview.show(url)
            let ok = preview.debugDrawShapesAndSave()
            print("MARKUP TEST saved=\(ok) -> \(url.path)")
            exit(ok ? 0 : 1)
        }

        // Bake a tastefully annotated demo PDF and exit (PATHEM_MARKUP_RENDER=<out.pdf>), for a
        // marketing figure of PDF markup. Quick Look (qlmanage) renders the result to a PNG; no
        // Screen Recording needed.
        if let renderOut = ProcessInfo.processInfo.environment["PATHEM_MARKUP_RENDER"] {
            let url = URL(fileURLWithPath: renderOut)
            let doc = DebugDemoPDF.write()
            if let data = try? Data(contentsOf: doc) { try? data.write(to: url) }
            let preview = DocumentPreviewView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
            preview.show(url)
            let ok = preview.debugAddSampleMarkupAndSave()
            print("MARKUP RENDER saved=\(ok) -> \(url.path)")
            exit(ok ? 0 : 1)
        }

        // Bake a free-text box and a sticky note into a PDF and exit (PATHEM_TEXT_TEST=<out.pdf>), so
        // a Quick Look render confirms the two prompt-driven tools place text where they should.
        if let textOut = ProcessInfo.processInfo.environment["PATHEM_TEXT_TEST"] {
            let url = URL(fileURLWithPath: textOut)
            let doc = PDFDocument()
            doc.insert(PDFPage(), at: 0)
            doc.write(to: url)
            let preview = DocumentPreviewView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
            preview.show(url)
            let ok = preview.debugDrawTextAndSave()
            print("TEXT TEST saved=\(ok) -> \(url.path)")
            exit(ok ? 0 : 1)
        }

        // Offscreen render of the window chrome incl. the toolbar (PATHEM_CHROME_RENDER=<out.png>),
        // for toolbar/title-bar checks that must measure what is actually drawn. Exits after.
        if let chromeOut = ProcessInfo.processInfo.environment["PATHEM_CHROME_RENDER"] {
            window.setContentSize(NSSize(width: 1100, height: 700))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                browser.debugRenderWindowChrome(to: chromeOut)
                exit(0)
            }
            app.run()
            return
        }

        // A staged marketing composition over the demo workspace (PATHEM_SITE_SHOT=<name>, with
        // PATHEM_DEMO=1). PATHEM_SITE_OUT is the PNG path; PATHEM_SITE_SIZE=<w>x<h> in points;
        // PATHEM_SITE_CAPTURE=screen takes a composited screencapture of this window (needs a
        // capture-entitled parent such as Terminal), otherwise the window is rendered in-process
        // at 2x. PATHEM_SITE_SETTLE=<seconds> is how long thumbnails get before the capture.
        if let shot = ProcessInfo.processInfo.environment["PATHEM_SITE_SHOT"], let demoLayout {
            let env = ProcessInfo.processInfo.environment
            let out = env["PATHEM_SITE_OUT"] ?? capturePath("site-\(shot).png")
            let parts = (env["PATHEM_SITE_SIZE"] ?? "1280x852").split(separator: "x").compactMap {
                Double($0)
            }
            let size =
                parts.count == 2
                ? NSSize(width: parts[0], height: parts[1]) : NSSize(width: 1280, height: 852)
            window.setFrame(NSRect(origin: NSPoint(x: 80, y: 80), size: size), display: true)
            let settle = env["PATHEM_SITE_SETTLE"].flatMap(Double.init) ?? 6
            let number = window.windowNumber
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                browser.debugStageSiteShot(shot, demo: demoLayout) {
                    // An inactive window is captured with grey traffic lights and dimmed text.
                    DispatchQueue.main.asyncAfter(deadline: .now() + settle - 0.6) {
                        NSApp.activate(ignoringOtherApps: true)
                        window.makeKeyAndOrderFront(nil)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                        print("SITE SHOT layout: \(browser.debugBrowserHeights())")
                        // The floating quick-actions bar follows the selection and would sit
                        // on top of the content a composition is meant to show. The icons
                        // shot keeps it: there it floats in empty space below the grid.
                        if shot != "icons" { browser.debugHideQuickBar() }
                        if env["PATHEM_SITE_CAPTURE"] == "screen" {
                            let capture = Process()
                            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                            capture.arguments = ["-x", "-o", "-l\(number)", out]
                            try? capture.run()
                            capture.waitUntilExit()
                            print("SITE SHOT (screen): \(out) exit=\(capture.terminationStatus)")
                        } else {
                            browser.debugRenderWindowAt2x(to: out)
                        }
                        exit(0)
                    }
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
                if let sectionOrder {
                    browser.debugReorderSidebar(sectionOrder.split(separator: ",").map(String.init))
                }
                if let navPath { browser.debugNavigateActive(to: URL(fileURLWithPath: navPath)) }
                if ProcessInfo.processInfo.environment["PATHEM_COLOR_RULES"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        browser.debugSeedColorRules()
                    }
                }
                if ProcessInfo.processInfo.environment["PATHEM_SITE_GROUPS"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        browser.debugSeedGroupedConnections()
                    }
                }
                if ProcessInfo.processInfo.environment["PATHEM_FORMATS"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        browser.debugSetBinaryRelativeFormats()
                    }
                }
                if let mode {
                    // Marquee-feature modes stage a whole subsystem for a screencapture; the file
                    // view modes just switch how the active folder is shown.
                    switch mode {
                    case "torrent": browser.showTorrentsDrawer()  // seeds via PATHEM_DEMO_TORRENTS
                    case "terminal": browser.debugStageTerminal()  // full shell timing: PATHEM_TERMINAL_SHOT
                    case "network": browser.debugStageNetworkView()
                    case "markup": browser.debugStageMarkup()  // PDF viewer + markup toolbar
                    default:
                        // PATHEM_MAIN_PATH picks the folder; otherwise the fake Photos folder in demo
                        // mode (privacy-safe) or the real ~/Pictures.
                        if navPath == nil {
                            let target =
                                demoLayout?.rightStart
                                ?? FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent("Pictures")
                            browser.debugNavigateActive(to: target)
                        }
                        let viewMode: ViewFormat.ViewMode =
                            mode == "gallery"
                            ? .gallery
                            : (mode == "column" ? .column : (mode == "list" ? .list : .icon))
                        browser.debugSetActiveViewMode(viewMode)
                    }
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

        // Live screenshot of the embedded terminal (PATHEM_TERMINAL_SHOT=1). Staged in steps with
        // generous delays: the shell has to spawn, then run a command, then the emulator has to draw
        // before the capture -- a single fixed delay (as PATHEM_MAIN_SHOT uses) races all three.
        if ProcessInfo.processInfo.environment["PATHEM_TERMINAL_SHOT"] != nil {
            window.setContentSize(NSSize(width: 1280, height: 820))
            let number = window.windowNumber
            var attempts = 0
            func tick() {
                attempts += 1
                guard browser.layoutSettled() || attempts >= 30 else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: tick)
                    return
                }
                browser.debugStageTerminal()  // show + fixed strip; shell starts
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    browser.debugRunTerminalDemo()  // shell has spawned; run the demo command
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                        let capture = Process()  // command has printed and drawn; capture
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-o", "-l\(number)", "/tmp/terminal-shot.png"]
                        try? capture.run()
                        capture.waitUntilExit()
                        exit(0)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: tick)
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
                browser.debugRenderSidebar(to: Self.capturePath("sidebar.png"))
                exit(0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: tick)
        }

        // Diagnose the "torrents = full black single pane" report: open the drawer (and detail),
        // dump the view frames, render a PNG (PATHEM_TORRENT_LAYOUT_SHOT=1; add DETAIL=1 for the overlay).
        if ProcessInfo.processInfo.environment["PATHEM_TORRENT_LAYOUT_SHOT"] != nil {
            window.setContentSize(NSSize(width: 1100, height: 700))
            let detail = ProcessInfo.processInfo.environment["DETAIL"] != nil
            let seedDemo = ProcessInfo.processInfo.environment["DEMO"] != nil
            var attempts = 0
            func tick() {
                attempts += 1
                guard browser.layoutSettled() || attempts >= 30 else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: tick)
                    return
                }
                browser.debugTorrentLayout(
                    openDetail: detail, seedDemo: seedDemo,
                    magnetStates: ProcessInfo.processInfo.environment["META"] != nil,
                    pngPath: "/tmp/torrent-layout.png")
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
                    print(
                        sheetOK
                            ? "ok   async-sheet-returns"
                            : "FAIL async-sheet-returns (\(response.rawValue))")
                    print("RESULT: \(report.ok && sheetOK ? "PASS" : "FAIL")")
                    exit(report.ok && sheetOK ? 0 : 1)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: tick)
        }

        // Headless torrents smoke: spawn the real pathem-torrentd via TorrentDaemonClient, add a
        // trackerless fixture .torrent AND a magnet, and confirm both come back in a status
        // broadcast. Exercises the app-side spawn + JSON round-trip that engine tests cannot reach.
        if ProcessInfo.processInfo.environment["PATHEM_TORRENTS_SMOKE"] != nil {
            print("=== TORRENTS SMOKE: daemon spawn + add ===")
            func bencodeLen(_ v: String) -> String { "\(v.utf8.count):\(v)" }
            let pieces = String(repeating: "a", count: 20)
            let info =
                "d" + bencodeLen("length") + "i1024e" + bencodeLen("name") + bencodeLen("smoke.bin")
                + bencodeLen("piece length") + "i16384e" + bencodeLen("pieces") + "20:\(pieces)e"
            let fixture = "d" + bencodeLen("info") + info + "e"
            let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "pathem-torrent-smoke-\(UUID().uuidString)", isDirectory: true)
            let fixtureURL = fixtureRoot.appendingPathComponent("fixture.torrent")
            let client = TorrentDaemonClient.shared
            do {
                try FileManager.default.createDirectory(
                    at: fixtureRoot, withIntermediateDirectories: true)
                try Data(fixture.utf8).write(to: fixtureURL)
                let spawned = client.startIfNeeded()
                print(spawned ? "ok   daemon-spawned" : "FAIL daemon-spawned (helper not found)")
                guard spawned else {
                    print("RESULT: FAIL")
                    exit(1)
                }
                client.addTorrent(
                    fileAt: fixtureURL.path, savePath: fixtureRoot.path)
                let magnetID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    .lowercased()
                let magnetHash = magnetID + String(repeating: "0", count: 8)
                let magnetName = "smoke-magnet-\(magnetID.prefix(8))"
                client.addMagnet(
                    "magnet:?xt=urn:btih:\(magnetHash)&dn=\(magnetName)",
                    savePath: fixtureRoot.path)
                var attempts = 0
                var smokeHash = ""
                var invalidMagnetRejected = false
                var filesListed = false
                var fileSelectionUpdated = false
                var detailsListed = false
                client.onError = { message in
                    if message.contains("valid magnet link") { invalidMagnetRejected = true }
                }
                client.addMagnet("not-a-magnet", savePath: fixtureRoot.path)
                func fail(_ step: String) -> Never {
                    print("FAIL \(step) (timed out, last count=\(client.torrents.count))")
                    print("RESULT: FAIL")
                    client.onUpdate = nil
                    client.onError = nil
                    client.onFiles = nil
                    client.onDetails = nil
                    client.shutdown()
                    try? FileManager.default.removeItem(at: fixtureRoot)
                    exit(1)
                }
                func pollRemoved() {
                    attempts += 1
                    if client.torrents.isEmpty {
                        print("ok   torrent-remove-updates-status")
                        print("RESULT: PASS")
                        client.onUpdate = nil
                        client.onError = nil
                        client.onFiles = nil
                        client.onDetails = nil
                        client.shutdown()
                        try? FileManager.default.removeItem(at: fixtureRoot)
                        exit(0)
                    }
                    if attempts >= 40 { fail("torrent-remove-updates-status") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: pollRemoved)
                }
                func pollResumed() {
                    attempts += 1
                    if let smoke = client.torrents.first(where: { $0.infoHash == smokeHash }),
                        smoke.state != .paused
                    {
                        print("ok   torrent-resumes-after-restart (state=\(smoke.state))")
                        client.remove(smokeHash, deleteData: true)
                        attempts = 0
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: pollRemoved)
                        return
                    }
                    if attempts >= 40 { fail("torrent-resumes-after-restart") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: pollResumed)
                }
                func pollRestored(_ receivedAfterRestart: @escaping () -> Bool) {
                    attempts += 1
                    if receivedAfterRestart(),
                        let smoke = client.torrents.first(where: { $0.infoHash == smokeHash }),
                        smoke.state == .paused,
                        client.downLimit == 4096, client.upLimit == 2048, client.superSeed
                    {
                        print("ok   daemon-restart-restores-paused-torrent")
                        print("ok   daemon-restart-restores-limits")
                        client.resume(smokeHash)
                        attempts = 0
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: pollResumed)
                        return
                    }
                    if attempts >= 40 {
                        let state = client.torrents.first(where: { $0.infoHash == smokeHash })?
                            .state
                        print(
                            "info restart-state received=\(receivedAfterRestart()) state=\(String(describing: state)) "
                                + "limits=\(client.downLimit)/\(client.upLimit) superSeed=\(client.superSeed)"
                        )
                        fail("daemon-restart-restores-state")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        pollRestored(receivedAfterRestart)
                    }
                }
                func restartDaemon() {
                    var receivedAfterRestart = false
                    client.onUpdate = { _ in receivedAfterRestart = true }
                    guard client.startIfNeeded() else { fail("daemon-restarts") }
                    print("ok   daemon-restarts")
                    client.requestList()
                    attempts = 0
                    pollRestored { receivedAfterRestart }
                }
                func pollPaused() {
                    attempts += 1
                    let onlyFixtureRemains =
                        client.torrents.count == 1
                        && client.torrents.first?.infoHash == smokeHash
                    if let smoke = client.torrents.first(where: { $0.infoHash == smokeHash }),
                        smoke.state == .paused, onlyFixtureRemains,
                        client.downLimit == 4096, client.upLimit == 2048, client.superSeed
                    {
                        print("ok   torrent-pause-updates-status")
                        print("ok   torrent-remove-pending-magnet")
                        print("ok   torrent-limits-roundtrip")
                        client.shutdown()
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + 1.0, execute: restartDaemon)
                        return
                    }
                    if attempts >= 40 { fail("torrent-pause-and-limits") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: pollPaused)
                }
                func beginLifecycleChecks() {
                    client.onFiles = nil
                    client.onDetails = nil
                    client.setFiles(smokeHash, wanted: [0])
                    client.pause(smokeHash)
                    client.remove(magnetHash, deleteData: true)
                    client.setLimits(
                        down: 4096, up: 2048, superSeed: true, encryptOutgoing: true,
                        preferUTP: true, bindToVPN: false)
                    attempts = 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: pollPaused)
                }
                func pollInspection() {
                    attempts += 1
                    if filesListed, fileSelectionUpdated, detailsListed {
                        print("ok   torrent-files-roundtrip")
                        print("ok   torrent-file-selection-roundtrip")
                        print("ok   torrent-details-roundtrip")
                        beginLifecycleChecks()
                        return
                    }
                    if attempts >= 40 { fail("torrent-files-and-details") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: pollInspection)
                }
                func pollInitial() {
                    attempts += 1
                    if invalidMagnetRejected,
                        let smoke = client.torrents.first(where: { $0.name == "smoke.bin" }),
                        let magnet = client.torrents.first(where: { $0.name == magnetName })
                    {
                        print("ok   torrent-appears-in-status")
                        print("ok   invalid-magnet-surfaces-error")
                        print(
                            magnet.state == .checking
                                ? "ok   magnet-appears-in-status"
                                : "FAIL magnet-appears-in-status (state=\(magnet.state))")
                        guard magnet.state == .checking else { fail("magnet-appears-in-status") }
                        smokeHash = smoke.infoHash
                        client.onFiles = { hash, files in
                            guard hash == smokeHash, files.count == 1,
                                files[0].path == "smoke.bin", files[0].length == 1024
                            else { return }
                            if files[0].wanted, !filesListed {
                                filesListed = true
                                client.setFiles(hash, wanted: [])
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    client.requestFiles(hash)
                                }
                            } else if !files[0].wanted {
                                fileSelectionUpdated = true
                            }
                        }
                        client.onDetails = { hash, peers, trackers in
                            guard hash == smokeHash else { return }
                            detailsListed =
                                peers.isEmpty && trackers.contains("DHT")
                                && trackers.contains("Peer Exchange")
                        }
                        client.requestFiles(smokeHash)
                        client.requestDetails(smokeHash)
                        attempts = 0
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + 0.25, execute: pollInspection)
                        return
                    }
                    if attempts >= 40 { fail("torrent-appears-in-status") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: pollInitial)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: pollInitial)
            } catch {
                print("FAIL fixture-write (\(error))")
                print("RESULT: FAIL")
                try? FileManager.default.removeItem(at: fixtureRoot)
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
                        instruction:
                            "Move images into a Pictures folder and PDFs into a Docs folder",
                        files: files)
                    guard let plan, !plan.steps.isEmpty else {
                        print("RESULT: FAIL (no plan; model unavailable or empty)")
                        exit(1)
                    }
                    for line in plan.summary(in: URL(fileURLWithPath: "/tmp")) {
                        print("  \(line)")
                    }
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
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "pathem-trim-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let src = dir.appendingPathComponent("tone.m4a")
                var ok = false
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                ]
                print("=== TRIM SMOKE ===")
                do {
                    // Write (and finalize, by scoping the file so it deallocs) 3s of silent AAC.
                    do {
                        let format = AVAudioFormat(
                            standardFormatWithSampleRate: 44100, channels: 1)!
                        let file = try AVAudioFile(forWriting: src, settings: settings)
                        let buffer = AVAudioPCMBuffer(
                            pcmFormat: format, frameCapacity: AVAudioFrameCount(44100 * 3))!
                        buffer.frameLength = AVAudioFrameCount(44100 * 3)
                        try file.write(from: buffer)
                    }
                    let srcDur = CMTimeGetSeconds(try await AVURLAsset(url: src).load(.duration))
                    print("wrote src dur=\(String(format: "%.2f", srcDur))s")
                    let out = await TrimController.debugExport(
                        from: src, startSeconds: 0, endSeconds: 1)
                    if let out {
                        let dur = CMTimeGetSeconds(try await AVURLAsset(url: out).load(.duration))
                        ok =
                            FileManager.default.fileExists(atPath: out.path) && dur < srcDur
                            && dur > 0.4
                        print("exported out dur=\(String(format: "%.2f", dur))s")
                    } else {
                        print("export returned nil")
                    }
                    let missing = await TrimController.debugExport(
                        from: dir.appendingPathComponent("missing.m4a"), startSeconds: 0,
                        endSeconds: 1)
                    print(
                        "TRIMCONTROL: \(missing == nil ? "PASS" : "FAIL") missing-source-rejected")
                    ok = ok && missing == nil
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
                let gradient = NSGradient(
                    starting: NSColor.systemTeal, ending: NSColor.systemIndigo)
                gradient?.draw(in: NSRect(x: 0, y: 0, width: 400, height: 400), angle: 45)
                img.unlockFocus()
                let path = "/tmp/pathem-folderbg.png"
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                    let png = rep.representation(using: .png, properties: [:])
                {
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
                // Automation's primary also leaves the owner's session alone.
                // PATHEM_SMOKE separately tests explicit interactive ownership.
                let independent = !browser.persistsSession && !second.persistsSession
                print("=== MULTIWINDOW SMOKE ===")
                print(
                    "windows=\(count) bothLaidOut=\(bothLaidOut) independentSession=\(independent)")
                let pass = count == 2 && bothLaidOut && independent
                print("RESULT: \(pass ? "PASS" : "FAIL")")
                WindowManager.shared.terminateAllTerminals()
                exit(pass ? 0 : 1)
            }
        }
        // End-to-end slideshow check: build two real images, present the full-screen slideshow,
        // then close it, asserting it went active and back inactive without leaving a window up.
        if ProcessInfo.processInfo.environment["PATHEM_SLIDESHOW_SMOKE"] != nil {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "pathem-slideshow-smoke")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var urls: [URL] = []
            for (i, color) in [NSColor.systemRed, NSColor.systemBlue].enumerated() {
                let image = NSImage(size: NSSize(width: 200, height: 200))
                image.lockFocus()
                color.setFill()
                NSRect(x: 0, y: 0, width: 200, height: 200).fill()
                image.unlockFocus()
                if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                    let png = rep.representation(using: .png, properties: [:])
                {
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
        #endif
        app.run()
    }

    /// The main menu. App/Edit cover Quit, Undo/Redo, and text editing; File/View/
    /// Go are thin bindings to the command registry (each item carries its command
    /// id in representedObject and dispatches via BrowserViewController). Only
    /// chords the keymap does not own get key equivalents here, so the menu and
    /// the rebindable keymap never fight over the same keys.
    /// Drive a real create -> rename -> new-file -> rename flow on a throwaway workspace and assert
    /// the on-disk results at each step (the actual feature working, end to end), then capture an
    /// offscreen render. Disk checks read the real filesystem, so they don't depend on UI reload
    /// timing; the delays only let the async listing/inline-edit settle between user actions.
    #if DEBUG
    private static func runE2E(browser: BrowserViewController) {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent(
            "pathem-e2e-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        let folderName = "E2E-Folder"
        let fileName = "E2E-File.txt"
        var results: [(name: String, ok: Bool, detail: String)] = []
        func others(_ excluding: Set<String>) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: workspace.path)) ?? [])
                .filter { !$0.hasPrefix(".") && !excluding.contains($0) }
        }
        func step(_ delay: Double, _ body: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
        }

        step(0.5) { browser.debugNavigateActive(to: workspace) }
        step(1.3) { browser.debugNewFolder() }  // creates the default-named folder + inline edit
        step(2.3) {
            let created = others([]).first
            results.append(("new-folder-created", created != nil, created ?? "none"))
            if let created { browser.debugCommitRename(created, to: folderName) }
        }
        step(3.3) {
            let ok = fm.fileExists(atPath: workspace.appendingPathComponent(folderName).path)
            results.append(("folder-renamed-on-disk", ok, folderName))
            browser.debugNewFile()  // creates the default-named file + inline edit
        }
        step(4.3) {
            let created = others([folderName]).first
            results.append(("new-file-created", created != nil, created ?? "none"))
            if let created { browser.debugCommitRename(created, to: fileName) }
        }
        step(5.3) {
            let ok = fm.fileExists(atPath: workspace.appendingPathComponent(fileName).path)
            results.append(("file-renamed-on-disk", ok, fileName))
            browser.debugRender(to: Self.capturePath("pathem-e2e.png"))  // cached capture; not native visual approval
        }
        step(6.0) {
            print("=== PATHEM_E2E: create -> rename flow ===")
            let ok = results.allSatisfy(\.ok)
            for r in results { print("\(r.ok ? "ok  " : "FAIL") \(r.name) (\(r.detail))") }
            print("RESULT: \(ok ? "PASS" : "FAIL")   render: \(Self.capturePath("pathem-e2e.png"))")
            try? fm.removeItem(at: workspace)
            exit(ok ? 0 : 1)
        }
    }
    #endif

    private static func makeMainMenu(updater: UpdaterController) -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: L("menu.about", "About Pathem"),
            action: #selector(PathemAppDelegate.showAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let checkUpdates = NSMenuItem(
            title: L("menu.checkUpdates", "Check for Updates…"),
            action: #selector(UpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        checkUpdates.target = updater
        appMenu.addItem(checkUpdates)
        appMenu.addItem(.separator())
        appMenu.addItem(commandItem("Settings…", "view.preferences", ","))
        appMenu.addItem(commandItem("Match Finder Settings", "settings.matchFinder"))
        appMenu.addItem(.separator())
        appMenu.addItem(commandItem("Reset Pathem Data…", "app.resetData"))
        appMenu.addItem(.separator())
        // The system fills this in with the Services that accept the current selection; the same
        // registration is what makes AppKit offer Services in the file views' context menus.
        let servicesItem = NSMenuItem(
            title: L("menu.services", "Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: L("menu.services", "Services"))
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        FileServices.register(servicesMenu: servicesMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L("menu.quit", "Quit Pathem"),
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

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
        // No ⌃⌘N here: that chord is the keymap default for New File. The command stays available
        // from the palette and the context menu; it just doesn't claim a colliding menu shortcut.
        fileMenu.addItem(commandItem("New Folder with Selection", "files.newFolderWithSelection"))
        fileMenu.addItem(commandItem("New File", "files.newFile"))  // chord owned by the keymap
        fileMenu.addItem(commandItem("Batch Create…", "files.batchCreate"))
        fileMenu.addItem(commandItem("Manage Templates…", "templates.manage"))
        // Open & inspect
        fileMenu.addItem(.separator())
        fileMenu.addItem(commandItem("Open", "files.open", "o"))
        fileMenu.addItem(commandItem("Show Package Contents", "files.showPackageContents"))
        fileMenu.addItem(commandItem("Open in New Tab", "files.openInNewTab"))
        fileMenu.addItem(commandItem("Open in This Pane", "files.openInThisPane"))
        fileMenu.addItem(commandItem("Open in Other Pane", "files.openInOtherPane"))
        fileMenu.addItem(openInEditorMenuItem())
        fileMenu.addItem(commandItem("Get Info", "files.getInfo", "i"))
        fileMenu.addItem(commandItem("Set Custom Icon…", "files.setCustomIcon"))
        fileMenu.addItem(commandItem("Remove Custom Icon", "files.removeCustomIcon"))
        fileMenu.addItem(commandItem("Reveal in Finder", "files.reveal"))
        fileMenu.addItem(commandItem("Reveal in Pathem", "files.revealInPathem"))
        fileMenu.addItem(commandItem("Download Now", "files.download"))
        fileMenu.addItem(commandItem("Remove Download", "files.offload"))
        // Organize
        fileMenu.addItem(.separator())
        fileMenu.addItem(commandItem("Rename…", "files.rename"))
        fileMenu.addItem(commandItem("AI Rename…", "ai.renameSelection"))
        fileMenu.addItem(commandItem("Duplicate", "files.duplicate"))  // chord owned by the keymap
        fileMenu.addItem(commandItem("Copy To…", "files.copyTo"))
        fileMenu.addItem(commandItem("Move To…", "files.moveTo"))
        fileMenu.addItem(applyLabelMenuItem())
        fileMenu.addItem(commandItem("Add to Collection…", "files.addToCollection"))
        fileMenu.addItem(commandItem("Add to Drop Stack", "shelf.add", "y"))
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
                    commandItem("Crop…", "image.crop"),
                    commandItem("Rotate Left", "image.rotateLeft"),
                    commandItem("Rotate Right", "image.rotateRight"),
                    commandItem("Remove Background", "image.removeBackground"),
                    commandItem("Auto-Tag by Content", "image.autoTag"),
                    commandItem("Remove Location", "image.removeLocation"),
                    commandItem("Create PDF", "image.createPDF"),
                    commandItem("Markup…", "image.markup"),
                    commandItem("Trim Media…", "files.trimMedia"),
                    commandItem("Extract Audio (M4A)", "media.extractAudio"),
                    commandItem("Convert to MP4", "media.convertToMP4"),
                    commandItem("Set Attributes…", "files.setAttributes"),
                    commandItem("Set Finder Comment…", "files.setFinderComment"),
                    commandItem("Edit Metadata…", "files.editMetadata"),
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
                    commandItem("Back Up To…", "files.backupTo")
                ]))
        // Delete
        fileMenu.addItem(.separator())
        fileMenu.addItem(commandItem("Move to Trash", "files.trash", "\u{8}"))
        fileMenu.addItem(
            commandItem(
                "Delete Immediately…", "files.deleteImmediately", "\u{8}", [.command, .option]))
        fileMenu.addItem(commandItem("Put Back", "files.putBack"))
        fileMenu.addItem(
            commandItem("Empty Trash…", "files.emptyTrash", "\u{8}", [.command, .shift]))
        fileMenu.addItem(commandItem("Secure Delete…", "files.secureDelete"))
        fileMenu.addItem(commandItem("Uninstall App…", "files.deleteApp"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(commandItem("Close Tab", "tab.close"))

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: L("menu.edit", "Edit"))
        editItem.submenu = editMenu
        editMenu.addItem(
            withTitle: L("menu.undo", "Undo"), action: #selector(BrowserViewController.undo(_:)),
            keyEquivalent: "z")
        let redo = editMenu.addItem(
            withTitle: L("menu.redo", "Redo"), action: #selector(BrowserViewController.redo(_:)),
            keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(commandItem("Undo History…", "edit.showHistory"))
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: L("menu.cut", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(
            withTitle: L("menu.copy", "Copy"), action: #selector(NSText.copy(_:)),
            keyEquivalent: "c")
        editMenu.addItem(
            withTitle: L("menu.paste", "Paste"), action: #selector(NSText.paste(_:)),
            keyEquivalent: "v")
        editMenu.addItem(
            withTitle: L("menu.selectAll", "Select All"), action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a")
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
        viewMenu.addItem(
            commandItem(L("viewopts.title", "View Options") + "…", "view.options", "j"))
        // View modes + arrangement stay at the top level (the most-used controls).
        viewMenu.addItem(commandItem("as List", "view.asList", "1"))
        viewMenu.addItem(commandItem("as Icons", "view.asIcons", "2"))
        viewMenu.addItem(commandItem("as Gallery", "view.asGallery", "3"))
        viewMenu.addItem(commandItem("as Columns", "view.asColumn", "4"))
        viewMenu.addItem(commandItem("as Tree", "view.asTree", "5"))
        viewMenu.addItem(
            submenu(
                L("viewchoice.groupBy", "Group By"),
                ViewFormat.GroupKey.allCases.map { commandItem($0.localizedTitle, $0.commandID) }))
        viewMenu.addItem(
            submenu(
                L("viewchoice.sortBy", "Sort By"),
                ViewFormat.SortKey.allCases.map { commandItem($0.localizedTitle, $0.commandID) }))
        viewMenu.addItem(.separator())
        viewMenu.addItem(commandItem("Zoom In", "view.zoomIn"))
        viewMenu.addItem(commandItem("Zoom Out", "view.zoomOut"))
        viewMenu.addItem(.separator())

        // Everything else is grouped into submenus so the top level stays scannable
        // instead of a 40-item wall. Shortcuts still work from inside a submenu.
        viewMenu.addItem(
            submenu(
                L("menu.group.find", "Find"),
                [
                    // Cmd-F opens literal file search; Cmd-K is the separate command palette.
                    commandItem("Search This Folder…", "search.palette", "f"),
                    commandItem("Semantic Search This Folder…", "search.semantic"),
                    commandItem("Filter…", "view.filter", "f", [.command, .shift]),
                    commandItem("Advanced Find…", "view.advancedFind", "f", [.command, .option]),
                    commandItem("Find in Files…", "files.findInFiles"),
                    commandItem("Find Duplicates", "files.findDuplicates"),
                    commandItem("Find Similar Names", "files.findSimilarNames"),
                    commandItem("Find Near-Duplicate Photos", "image.findNearDuplicates"),
                    .separator(),
                    // ⌥⌘L, not ⌃⌘F: ⌃⌘F is the system Enter Full Screen shortcut, which this shadowed.
                    commandItem("Flat View", "view.flatView", "l", [.command, .option]),
                    commandItem("Flatten Folder (Show All Items)", "view.flattenFolder"),
                ]))
        viewMenu.addItem(
            submenu(
                L("menu.group.folderTools", "Folder Tools"),
                [
                    commandItem("Compare Panes…", "files.comparePanes"),
                    commandItem("Size Browser…", "view.sizeBrowser"),
                    commandItem("Calculate All Sizes", "view.calculateSizes"),
                    .separator(),
                    commandItem("Cleanup…", "view.cleanup"),
                    commandItem("Reclaim in Repo…", "files.repoReclaim"),
                ]))
        viewMenu.addItem(
            submenu(
                L("menu.group.show", "Show"),
                [
                    commandItem("Show Hidden Files", "view.toggleHidden"),
                    commandItem("Show Full Path in Title Bar", "view.fullPathTitle"),
                    commandItem("Show Path Bar at Bottom", "view.pathBarBottom"),
                    commandItem("Compact Sidebar", "view.compactSidebar"),
                    commandItem("Sync Browsing", "view.syncBrowsing"),
                    commandItem("Vim Navigation", "nav.vimMode"),
                ]))
        viewMenu.addItem(
            submenu(
                L("menu.group.preview", "Preview"),
                [
                    commandItem("Quick Look", "view.quickLook"),
                    commandItem("Slideshow", "view.slideshow"),
                    commandItem("Preview Pane", "view.previewPane", "p", [.command, .option]),
                    commandItem("Show Drop Stack", "shelf.toggle", "y", [.command, .shift]),
                ]))
        viewMenu.addItem(
            submenu(
                L("menu.group.layoutStyle", "Layout & Style"),
                [
                    commandItem("Save Workspace…", "workspace.save"),
                    commandItem("Open Workspace…", "workspace.open"),
                    .separator(),
                    commandItem("Save Style…", "view.saveStyle"),
                    commandItem("Apply Style…", "view.applyStyle"),
                    commandItem("Use as Default View", "view.useAsDefault"),
                    .separator(),
                    submenu(
                        L("menu.group.folderBackground", "Folder Background"),
                        [
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
        viewMenu.addItem(
            submenu(
                L("menu.group.terminal", "Terminal"),
                [
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
        viewMenu.addItem(
            submenu(
                L("menu.group.organize", "Organize"),
                [
                    commandItem("Organize Folder…", "files.organize"),
                    commandItem("Organize with AI…", "files.organizeAI"),
                    commandItem("Summarize Folder", "ai.summarizeFolder"),
                    commandItem("Batch Rename…", "files.batchRename"),
                ]))
        viewMenu.addItem(
            submenu(
                L("menu.group.git", "Git"),
                [
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
        goMenu.addItem(
            commandItem("Find Files Everywhere…", "nav.findFiles", "o", [.command, .shift]))
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
            withTitle: L("menu.zoom", "Zoom"), action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: L("menu.bringAllToFront", "Bring All to Front"),
            action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApplication.shared.windowsMenu = windowMenu

        // Help: onboarding, demo workspace, and the in-app changelog.
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: L("menu.help", "Help"))
        helpItem.submenu = helpMenu
        helpMenu.addItem(commandItem("Load Demo Workspace", "help.demoWorkspace"))
        helpMenu.addItem(commandItem("Release Notes", "help.releaseNotes"))
        helpMenu.addItem(commandItem("Full Disk Access Guide…", "help.fullDiskAccess"))
        NSApplication.shared.helpMenu = helpMenu

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
            let none = NSMenuItem(
                title: L("menu.noEditors", "No editors found"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        } else {
            for editor in editors {
                let entry = NSMenuItem(
                    title: editor.name,
                    action: #selector(BrowserViewController.openInExternalEditor(_:)),
                    keyEquivalent: "")
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
            title: ViewFormat.SortKey.allCases.first(where: { $0.commandID == commandID })?
                .localizedTitle
                ?? ViewFormat.GroupKey.allCases.first(where: { $0.commandID == commandID })?
                .localizedTitle
                ?? L("menu.\(commandID)", title),
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
    /// Build the same 1,000,000-row dataset as Gate A and smoothly auto-scroll it top to bottom
    /// (ease-in-out) over PATHEM_GATE_A_SECONDS (default 10), then exit. When
    /// PATHEM_GATE_A_FRAMES_DIR is set, render the window content to PNG frames in-process. AppKit
    /// owns those pixels, so this produces the launch asset without Screen Recording permission.
    private static func startGateADemoScroll(_ controller: FileListController, _ window: NSWindow) {
        let n = 1_000_000
        let base = Date(timeIntervalSince1970: 1_700_000_000)
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
        controller.setEntries(rows)
        window.layoutIfNeeded()
        controller.tableView.layoutSubtreeIfNeeded()

        let duration =
            Double(ProcessInfo.processInfo.environment["PATHEM_GATE_A_SECONDS"] ?? "") ?? 10
        let framesDirectory = ProcessInfo.processInfo.environment["PATHEM_GATE_A_FRAMES_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let capture = GateADemoCapture(framesDirectory: framesDirectory)
        capture.capture(window: window)
        let clip = controller.scrollView.contentView
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            // Keep the non-Sendable `timer` out of the main-actor closure (act on it outside); the
            // timer fires on the main run loop, so assumeIsolated is safe for the UI touches.
            let done = MainActor.assumeIsolated { () -> Bool in
                let maxY = max(0, controller.tableView.frame.height - clip.bounds.height)
                let t = min(1, Date().timeIntervalSince(start) / max(0.1, duration))
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2  // ease-in-out
                clip.scroll(to: NSPoint(x: 0, y: maxY * CGFloat(eased)))
                controller.scrollView.reflectScrolledClipView(clip)
                capture.advanceTick()
                if capture.tickCount.isMultiple(of: 4) || t >= 1 {
                    capture.capture(window: window)  // 15 fps from the 60 Hz timer
                }
                return t >= 1
            }
            if done {
                timer.invalidate()
                let result = MainActor.assumeIsolated { capture.result }
                if let message = result.message { print(message) }
                exit(result.exitCode)
            }
        }
    }

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
        print(
            "RESULT: \(pass ? "PASS" : "FAIL"): table materializes bounded cells regardless of 1M-row dataset"
        )

        exit(pass ? 0 : 1)
    }

    /// Build a sample folder (subfolders, files, and gradient landscape PNGs that read like
    /// real photos in thumbnails) for PATHEM_VIEW_SHOT.
    /// Whether this process is a headless automation launch (the smoke test, a screenshot, or a
    /// render/test harness) rather than a normal interactive run. Such launches drive panes to
    /// scratch paths and must never persist over the user's real session. Match automation
    /// families and the two Gate A entry points, leaving configuration options and demo-only
    /// interactive launches alone.
    static var isAutomationLaunch: Bool {
        isAutomationLaunch(environment: ProcessInfo.processInfo.environment)
    }

    static func isAutomationLaunch(environment: [String: String]) -> Bool {
        environment.keys.contains { key in
            key.hasPrefix("PATHEM_")
                && (key.hasSuffix("_SMOKE") || key.hasSuffix("_E2E")
                    || key == "PATHEM_GATE_A" || key == "PATHEM_GATE_A_DEMO"
                    || key.hasSuffix("_SHOT") || key.hasSuffix("_TEST")
                    || key.hasSuffix("_RENDER") || key.hasSuffix("_PREVIEW")
                    || key == "PATHEM_THEME_SHOTS")
        }
    }

    private static func makeSampleFolder() -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-viewshot")
        try? fm.removeItem(at: dir)
        for sub in ["Subfolder A", "Subfolder B"] {
            try? fm.createDirectory(
                at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        for name in ["nested1.txt", "nested2.txt", "nested3.txt"] {
            try? "x".write(
                to: dir.appendingPathComponent("Subfolder A").appendingPathComponent(name),
                atomically: true, encoding: .utf8)
        }
        try? "notes".write(
            to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try? "code".write(
            to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        for name in [
            "Sunset.png", "Coastline.png", "Forest.png", "Mountains.png", "City.png", "Desert.png",
        ] {
            if let data = DemoArt.landscapePNG(named: name, side: 256) {
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
    /// The standard About panel, with the source commit next to the build number when the
    /// packaged app records one (scripts/package.sh), since local builds share a build number.
    @objc func showAboutPanel(_ sender: Any?) {
        let info = Bundle.main.infoDictionary ?? [:]
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let build = info["CFBundleVersion"] as? String,
            let commit = info["PathemSourceCommit"] as? String
        {
            options[.applicationVersion] = "\(build), \(commit)"
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    weak var browser: BrowserViewController?
    var updater: UpdaterController?
    var vpnStatusItem: VPNStatusItem?  // menu-bar VPN kill-switch indicator (self-hides when off)

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Finder's "Open With ▸ Pathem" (and `open -a Pathem <folder>`) delivers folders here.
    func application(_ application: NSApplication, open urls: [URL]) {
        openInPrimaryBrowser(urls)
    }

    /// The "Open in Pathem" Services item: open the sent files/folders.
    @objc func openInPathem(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        openInPrimaryBrowser(urls)
    }

    /// The "Preview in Pathem" Services item uses the same typed preview behavior as the URL/CLI
    /// handoff and never executes notebook rich output.
    @objc func previewInPathem(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        previewInPrimaryBrowser(urls)
    }

    /// The "Reveal in Pathem" Services item: select the sent item in its parent folder (the reveal
    /// verb of the handoff contract), rather than navigating into it.
    @objc func revealInPathem(
        _ pboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        revealInPrimaryBrowser(urls)
    }

    /// The most retries an inbound open/reveal will wait for the primary window during a launch race:
    /// ~4s at 100ms each, then give up rather than respin the main thread forever.
    private static let primaryBrowserMaxRetries = 40

    /// Reveal the first sent item in the primary window, waiting briefly for it during a launch race.
    private func revealInPrimaryBrowser(_ urls: [URL], attempt: Int = 0) {
        guard let url = urls.first else { return }
        guard let browser = WindowManager.shared.primaryBrowser else {
            guard attempt < Self.primaryBrowserMaxRetries else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.revealInPrimaryBrowser(urls, attempt: attempt + 1)
            }
            return
        }
        browser.revealExternalItem(url)
    }

    private func previewInPrimaryBrowser(_ urls: [URL], attempt: Int = 0) {
        guard let url = urls.first else { return }
        guard let browser = WindowManager.shared.primaryBrowser else {
            guard attempt < Self.primaryBrowserMaxRetries else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.previewInPrimaryBrowser(urls, attempt: attempt + 1)
            }
            return
        }
        browser.previewExternalItem(url)
    }

    /// Route opened URLs to the primary window, waiting briefly for it if it isn't up yet (open
    /// events can arrive during launch). Bounded, and spaced out (not a tight respin).
    private func openInPrimaryBrowser(_ urls: [URL], attempt: Int = 0) {
        guard !urls.isEmpty else { return }
        guard let browser = WindowManager.shared.primaryBrowser else {
            guard attempt < Self.primaryBrowserMaxRetries else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.openInPrimaryBrowser(urls, attempt: attempt + 1)
            }
            return
        }
        for url in urls {
            if url.scheme == "magnet" {
                browser.addMagnetToPanel(url.absoluteString)  // magnet: link -> Torrents panel
            } else if let action = PathemURLContract.parse(url) {
                // The `pathem` CLI seam: open navigates into a folder, reveal selects the item.
                let target = URL(fileURLWithPath: action.path)
                switch action.verb {
                case .open: browser.openExternalFolder(target)
                case .reveal: browser.revealExternalItem(target)
                case .preview: browser.previewExternalItem(target)
                }
            } else {
                browser.openExternalFolder(url)  // routes .torrent files to the panel itself
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowManager.shared.primaryBrowser?.saveSessionNow()  // persist tabs/folders for next launch
        FolderSizeStore.shared.flush()  // persist the folder-size cache so a restart doesn't re-walk
        // Hang up every window's embedded shell so none (and the jobs they launched) is orphaned.
        WindowManager.shared.terminateAllTerminals()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting used to drop unsaved PDF markup without asking. Settle it in every window
        // first; Cancel, or a save that fails, calls the quit off.
        for open in WindowManager.shared.browsers {
            guard open.prepareDocumentsToClose() else { return .terminateCancel }
        }
        guard browser?.isTransferring == true else { return .terminateNow }
        let alert = PathemApp.makeTransferQuitConfirmation()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

@MainActor
extension PathemApp {
    /// Production construction shared with isolated geometry/lifecycle checks.
    static func makeTransferQuitConfirmation() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("quit.transferTitle", "A file transfer is still in progress")
        alert.informativeText = L(
            "quit.transferBody", "Quitting now may leave it incomplete. Quit anyway?")
        alert.addButton(withTitle: L("quit.quitAnyway", "Quit Anyway"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        return alert
    }
}
