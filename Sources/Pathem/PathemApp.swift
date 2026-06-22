import AppKit
import PathemEngine

// AppKit entry point. Normal launch shows a dual-pane browser rooted at the
// home directory. Launch with PATHEM_GATE_A=1 to run the Gate A virtualization
// proof (DESIGN.md §5): load 1,000,000 synthetic rows and confirm the table
// materializes only ~visible cells, not all 1M.
@main
@MainActor
enum PathemApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMainMenu()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pathem"
        window.center()

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
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    /// The main menu. App/Edit cover Quit, Undo/Redo, and text editing; File/View/
    /// Go are thin bindings to the command registry (each item carries its command
    /// id in representedObject and dispatches via BrowserViewController). Only
    /// chords the keymap does not own get key equivalents here, so the menu and
    /// the rebindable keymap never fight over the same keys.
    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About Pathem",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(commandItem("Settings…", "view.preferences", ","))
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Pathem", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(commandItem("New Tab", "tab.new"))
        fileMenu.addItem(commandItem("New Folder", "files.newFolder", "n", [.command, .shift]))
        fileMenu.addItem(commandItem("Open", "files.open", "o"))
        fileMenu.addItem(commandItem("Rename…", "files.rename"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(commandItem("Move to Trash", "files.trash", "\u{8}"))
        fileMenu.addItem(commandItem("Reveal in Finder", "files.reveal"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(commandItem("Close Tab", "tab.close"))

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(commandItem("Show Hidden Files", "view.toggleHidden"))
        viewMenu.addItem(commandItem("Quick Look", "view.quickLook"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(commandItem("Command Palette…", "palette.show"))
        viewMenu.addItem(commandItem("Ask Pathem…", "ai.run"))
        viewMenu.addItem(commandItem("Batch Rename…", "files.batchRename"))

        let goItem = NSMenuItem()
        mainMenu.addItem(goItem)
        let goMenu = NSMenu(title: "Go")
        goItem.submenu = goMenu
        goMenu.addItem(commandItem("Back", "nav.back"))
        goMenu.addItem(commandItem("Forward", "nav.forward"))
        goMenu.addItem(commandItem("Enclosing Folder", "nav.up"))

        return mainMenu
    }

    /// A menu item that runs a registry command via BrowserViewController. A key
    /// equivalent is set only when provided (chords the keymap owns are left
    /// without one so the two never collide).
    private static func commandItem(
        _ title: String, _ commandID: String, _ key: String = "",
        _ mods: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title, action: #selector(BrowserViewController.performMenuCommand(_:)),
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
