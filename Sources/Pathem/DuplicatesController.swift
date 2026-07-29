import AppKit
import PathemEngine

/// A grouped duplicate resolver: scans a folder for byte-identical files (via DuplicateFinder),
/// shows each duplicate SET with one copy kept and the rest queued for the Trash, and reports the
/// reclaimable space. This is the "keep one, trash the rest" flow people install Gemini / dupeGuru
/// for; the detection was already done, this is the results layer that makes it actionable. Trashing
/// routes back through the host so it lands in the Trash with Put Back + undo intact.
@MainActor
final class DuplicatesController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private weak var host: NSWindow?
    private var root = FileManager.default.homeDirectoryForCurrentUser
    private var scanID = 0

    private var groups: [DuplicateFinder.Group] = []
    /// Per group, per file: keep this copy (true) or queue it for the Trash (false).
    private var keep: [[Bool]] = []

    private let table = NSTableView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let trashButton = NSButton(title: "", target: nil, action: nil)

    /// Send the queued duplicate copies to the Trash (with undo). Set by the host.
    var onTrash: (([URL]) -> Void)?
    /// Reveal a file in a pane (double-click). Set by the host.
    var onReveal: ((URL) -> Void)?

    func present(root: URL, over host: NSWindow?) {
        self.root = root
        self.host = host
        buildWindowIfNeeded()
        window?.title = String(format: L("dupes.windowTitle", "Duplicates in “%@”"), root.lastPathComponent)
        rescan()
        if let window {
            if let host { host.beginSheet(window) { _ in } } else { window.makeKeyAndOrderFront(nil) }
        }
    }

    // MARK: Window

    private func buildWindowIfNeeded() {
        guard window == nil else { return }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let column = NSTableColumn(identifier: .init("item"))
        column.title = L("dupes.colItem", "Duplicate sets")
        column.width = 520
        table.addTableColumn(column)
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.borderType = .bezelBorder

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor

        trashButton.title = L("dupes.trash", "Move to Trash")
        trashButton.bezelStyle = .rounded
        trashButton.keyEquivalent = "\r"
        trashButton.target = self
        trashButton.action = #selector(trashClicked)

        let close = NSButton(title: L("common.close", "Close"), target: self, action: #selector(closeClicked))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"

        let footer = NSStackView(views: [spinner, summaryLabel, NSView(), close, trashButton])
        footer.orientation = .horizontal
        footer.spacing = 10

        let content = NSStackView(views: [scroll, footer])
        content.orientation = .vertical
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.contentView = content
        window.minSize = NSSize(width: 480, height: 320)
        window.center()
        self.window = window
    }

    // MARK: Scan

    private func rescan() {
        scanID += 1
        let id = scanID
        let root = self.root
        spinner.startAnimation(nil)
        summaryLabel.stringValue = L("dupes.scanning", "Scanning…")
        trashButton.isEnabled = false
        Task { @MainActor in
            let found = await Task.detached {
                DuplicateFinder.find(in: [root], minSize: 1)
            }.value
            guard self.scanID == id else { return }
            self.groups = found
            self.keep = found.map { group in group.files.indices.map { $0 == 0 } }  // keep the first copy
            self.spinner.stopAnimation(nil)
            self.table.reloadData()
            self.updateSummary()
        }
    }

    private func updateSummary() {
        let reclaimable = queuedURLsAndBytes().bytes
        if groups.isEmpty {
            summaryLabel.stringValue = L("dupes.none", "No duplicate files found")
        } else {
            summaryLabel.stringValue = String(
                format: L("dupes.summary", "%d duplicate set(s) · %@ reclaimable"),
                groups.count, ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file))
        }
        trashButton.isEnabled = !queuedURLsAndBytes().urls.isEmpty
    }

    // MARK: Row model (flatten groups into header + file rows)

    private enum Row {
        case header(group: Int)
        case file(group: Int, file: Int)
    }

    private var rows: [Row] {
        var out: [Row] = []
        for g in groups.indices {
            out.append(.header(group: g))
            for f in groups[g].files.indices { out.append(.file(group: g, file: f)) }
        }
        return out
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let g):
            let group = groups[g]
            let size = ByteCountFormatter.string(fromByteCount: group.files.first?.size ?? 0, countStyle: .file)
            let label = NSTextField(labelWithString: String(
                format: L("dupes.setLabel", "%d copies · %@ each · keep one"), group.files.count, size))
            label.font = .boldSystemFont(ofSize: 12)
            return label
        case .file(let g, let f):
            let entry = groups[g].files[f]
            let check = NSButton(
                checkboxWithTitle: L("dupes.keep", "Keep"), target: self, action: #selector(keepToggled(_:)))
            check.state = keep[g][f] ? .on : .off
            check.tag = g * 100_000 + f
            let folder = (entry.location ?? "") as NSString
            let fullPath = folder.appendingPathComponent(entry.name) as NSString
            let path = NSTextField(labelWithString: fullPath.abbreviatingWithTildeInPath)
            path.font = .systemFont(ofSize: 11)
            path.textColor = .secondaryLabelColor
            path.lineBreakMode = .byTruncatingHead
            let stack = NSStackView(views: [check, path])
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
            return stack
        }
    }

    // MARK: Actions

    @objc private func keepToggled(_ sender: NSButton) {
        let g = sender.tag / 100_000
        let f = sender.tag % 100_000
        guard g < keep.count, f < keep[g].count else { return }
        keep[g][f] = sender.state == .on
        updateSummary()
    }

    @objc private func rowDoubleClicked() {
        let clicked = table.clickedRow
        guard clicked >= 0, clicked < rows.count, case .file(let g, let f) = rows[clicked],
            let location = groups[g].files[f].location
        else { return }
        onReveal?(URL(fileURLWithPath: location).appendingPathComponent(groups[g].files[f].name))
    }

    @objc private func trashClicked() {
        let urls = queuedURLsAndBytes().urls
        guard !urls.isEmpty, let window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = String(format: L("dupes.confirmTitle", "Move %d duplicate copy(ies) to the Trash?"), urls.count)
        alert.informativeText = L("dupes.confirmBody", "One copy of each set is kept. You can Put Back from the Trash, or undo.")
        alert.addButton(withTitle: L("dupes.trash", "Move to Trash"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.onTrash?(urls)
            self.rescan()  // reflect the freed space
        }
    }

    @objc private func closeClicked() { close() }

    private func close() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil) }
        self.window = nil
    }

    /// Smoke: load `groups` with the default keep-first selection and report how many copies would
    /// be queued for the Trash. Proves keep-one-per-set (a set of N queues N-1).
    func debugQueuedCount(groups: [DuplicateFinder.Group]) -> Int {
        self.groups = groups
        self.keep = groups.map { group in group.files.indices.map { $0 == 0 } }
        return queuedURLsAndBytes().urls.count
    }

    // MARK: Helpers

    /// The copies queued for the Trash (every unkept file) plus their total bytes. Never queues the
    /// last surviving copy of a set: if the user unchecked all of a group, its first file is spared.
    private func queuedURLsAndBytes() -> (urls: [URL], bytes: Int64) {
        var urls: [URL] = []
        var bytes: Int64 = 0
        for g in groups.indices {
            let flags = keep[g]
            let anyKept = flags.contains(true)
            for f in groups[g].files.indices {
                if flags[f] { continue }
                if !anyKept && f == 0 { continue }  // spare one so the content survives
                let entry = groups[g].files[f]
                guard let location = entry.location else { continue }
                urls.append(URL(fileURLWithPath: location).appendingPathComponent(entry.name))
                bytes += entry.size
            }
        }
        return (urls, bytes)
    }
}
