import AppKit
import PathomEngine

// AppKit entry point. Normal launch shows a dual-pane browser rooted at the
// home directory. Launch with PATHOM_GATE_A=1 to run the Gate A virtualization
// proof (DESIGN.md §5): load 1,000,000 synthetic rows and confirm the table
// materializes only ~visible cells, not all 1M.
@main
@MainActor
enum PathomApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pathom"
        window.center()

        if ProcessInfo.processInfo.environment["PATHOM_GATE_A"] != nil {
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
