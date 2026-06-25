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
    static func main() {
        // A broken pipe to a subprocess (curl/sftp exiting mid-write) must never
        // deliver a fatal signal; the remote runner handles the error instead.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let updater = UpdaterController()
        app.mainMenu = makeMainMenu(updater: updater)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pathem"
        window.center()

        if ProcessInfo.processInfo.environment["PATHEM_L10N_SMOKE"] != nil {
            // Deterministic: every shipped language must be bundled and actually
            // translated (sample keys resolve to a non-empty value that differs from
            // English). Independent of the system language.
            print("=== L10N SMOKE: localized resources ===")
            let available = Bundle.module.localizations
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
                    let path = Bundle.module.path(forResource: actual, ofType: "lproj"),
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

        // Normal mode: a dual-pane browser rooted at the home directory.
        let browser = BrowserViewController(start: FileManager.default.homeDirectoryForCurrentUser)
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
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        // Headless sidebar render for layout inspection (PATHEM_SIDEBAR_SHOT=1).
        if ProcessInfo.processInfo.environment["PATHEM_SIDEBAR_SHOT"] != nil {
            window.setContentSize(NSSize(width: 1100, height: 520))  // a realistic short window
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
                print("RESULT: \(report.ok ? "PASS" : "FAIL")")
                exit(report.ok ? 0 : 1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: tick)
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
        appMenu.addItem(
            withTitle: L("menu.quit", "Quit Pathem"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: L("menu.file", "File"))
        fileItem.submenu = fileMenu
        fileMenu.addItem(commandItem("New Tab", "tab.new"))
        fileMenu.addItem(commandItem("New Folder", "files.newFolder", "n", [.command, .shift]))
        fileMenu.addItem(commandItem("New File", "files.newFile"))  // chord owned by the keymap
        fileMenu.addItem(commandItem("Batch Create…", "files.batchCreate"))
        fileMenu.addItem(commandItem("Manage Templates…", "templates.manage"))
        fileMenu.addItem(commandItem("Open", "files.open", "o"))
        fileMenu.addItem(openInEditorMenuItem())
        fileMenu.addItem(commandItem("Get Info", "files.getInfo", "i"))
        fileMenu.addItem(applyLabelMenuItem())
        fileMenu.addItem(commandItem("Add to Collection…", "files.addToCollection"))
        fileMenu.addItem(commandItem("Rename…", "files.rename"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(commandItem("Move to Trash", "files.trash", "\u{8}"))
        fileMenu.addItem(commandItem("Uninstall App…", "files.deleteApp"))
        fileMenu.addItem(commandItem("Reveal in Finder", "files.reveal"))
        fileMenu.addItem(commandItem("Send via AirDrop", "files.airdrop"))
        fileMenu.addItem(commandItem("Add to Shelf", "shelf.add", "y"))
        fileMenu.addItem(commandItem("Copy SHA-256", "files.copySHA256"))
        fileMenu.addItem(commandItem("Verify Checksum…", "files.verifyChecksum"))
        fileMenu.addItem(commandItem("Compress", "files.compress"))
        fileMenu.addItem(commandItem("Extract", "files.extract"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(commandItem("Close Tab", "tab.close"))

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: L("menu.edit", "Edit"))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: L("menu.undo", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("menu.redo", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
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

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: L("menu.view", "View"))
        viewItem.submenu = viewMenu
        viewMenu.addItem(commandItem("as List", "view.asList", "1"))
        viewMenu.addItem(commandItem("as Icons", "view.asIcons", "2"))
        viewMenu.addItem(commandItem("as Gallery", "view.asGallery", "3"))
        viewMenu.addItem(commandItem("as Columns", "view.asColumn", "4"))
        viewMenu.addItem(commandItem("Flat View", "view.flatView", "f", [.command, .control]))
        viewMenu.addItem(commandItem("Filter…", "view.filter", "f"))
        viewMenu.addItem(commandItem("Find Duplicates", "files.findDuplicates"))
        viewMenu.addItem(commandItem("Compare Panes…", "files.comparePanes"))
        viewMenu.addItem(commandItem("Size Browser…", "view.sizeBrowser"))
        viewMenu.addItem(commandItem("Cleanup…", "view.cleanup"))
        viewMenu.addItem(commandItem("Use as Default View", "view.useAsDefault"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(commandItem("Show Hidden Files", "view.toggleHidden"))
        viewMenu.addItem(commandItem("Show Full Path in Title Bar", "view.fullPathTitle"))
        viewMenu.addItem(commandItem("Show Path Bar at Bottom", "view.pathBarBottom"))
        viewMenu.addItem(commandItem("Calculate All Sizes", "view.calculateSizes"))
        viewMenu.addItem(commandItem("Compact Sidebar", "view.compactSidebar"))
        viewMenu.addItem(commandItem("Show Shelf", "shelf.toggle", "y", [.command, .shift]))
        viewMenu.addItem(commandItem("Quick Look", "view.quickLook"))
        viewMenu.addItem(commandItem("Preview Pane", "view.previewPane", "p", [.command, .option]))
        viewMenu.addItem(.separator())
        viewMenu.addItem(commandItem("Toggle Terminal", "terminal.toggle", "`", [.control]))
        viewMenu.addItem(commandItem("Open Terminal Here", "terminal.here"))
        viewMenu.addItem(commandItem("Terminal Follows Folder", "terminal.toggleFollow"))
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
        viewMenu.addItem(themeItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(commandItem("Command Palette…", "palette.show"))
        viewMenu.addItem(commandItem("Ask Pathem…", "ai.run"))
        viewMenu.addItem(commandItem("Organize with AI…", "files.organizeAI"))
        viewMenu.addItem(commandItem("Batch Rename…", "files.batchRename"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(commandItem("Commit…", "git.commit"))
        viewMenu.addItem(commandItem("Push", "git.push"))
        viewMenu.addItem(commandItem("Pull", "git.pull"))

        let goItem = NSMenuItem()
        mainMenu.addItem(goItem)
        let goMenu = NSMenu(title: L("menu.go", "Go"))
        goItem.submenu = goMenu
        goMenu.addItem(commandItem("Back", "nav.back"))
        goMenu.addItem(commandItem("Forward", "nav.forward"))
        goMenu.addItem(commandItem("Enclosing Folder", "nav.up"))
        goMenu.addItem(commandItem("Go to Path…", "nav.editPath", "l"))
        goMenu.addItem(.separator())
        goMenu.addItem(commandItem("Connections…", "connections.manage", "k", [.command, .shift]))
        goMenu.addItem(commandItem("Open Connections in a New Tab", "connections.newTabToggle"))
        goMenu.addItem(commandItem("Download from Server…", "remote.download"))

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
        let item = NSMenuItem(
            title: L("menu.\(commandID)", title),  // localized by command id; English is the fallback
            action: #selector(BrowserViewController.performMenuCommand(_:)),
            keyEquivalent: key)
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
}

/// Warns before quitting while a copy/move is running, so Cmd-Q can't leave a
/// transfer half-finished without the user's say-so.
@MainActor
final class PathemAppDelegate: NSObject, NSApplicationDelegate {
    weak var browser: BrowserViewController?
    var updater: UpdaterController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        browser?.saveSessionNow()  // persist tabs/folders for next launch
        // Hang up the embedded shell so it (and any job it launched) is not orphaned.
        browser?.terminateTerminal()
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
