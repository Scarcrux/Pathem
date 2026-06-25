import AppKit
import PathemEngine

/// A Storage-style Cleanup panel: scans a folder for reclaimable space (junk,
/// duplicates, large, old), lets the user check items and move them to the Trash
/// (reversible), and — on macOS 26 with Apple Intelligence — asks the on-device model
/// to recommend which are safe. Junk + duplicates are pre-checked; large/old are
/// review-only.
@MainActor
final class CleanupController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private struct Row {
        let item: StorageScan.Item
        var checked: Bool
    }

    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: L("cleanup.title", "Cleanup"))
    private let summaryLabel = NSTextField(labelWithString: "")
    private let diskBar = NSProgressIndicator()
    private let diskLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let spinner = NSProgressIndicator()
    private let aiButton = NSButton()
    private let trashButton = NSButton()
    private let gen = GenerationBox()
    private var rows: [Row] = []
    private var root = URL(fileURLWithPath: NSHomeDirectory())
    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        super.init()
        panel.title = L("cleanup.panelTitle", "Cleanup")
        build()
    }

    func present(for url: URL, over window: NSWindow?) {
        root = url
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        updateDiskStats()  // instant: overall capacity/used/free, before the scan runs
        scan()
    }

    /// Volume capacity, used, and free for the scanned folder's disk (like the macOS
    /// Storage summary). Instant via the file system, so it shows immediately.
    private func updateDiskStats() {
        let values = try? root.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let total = values?.volumeTotalCapacity, total > 0 else {
            diskLabel.stringValue = ""
            diskBar.isHidden = true
            return
        }
        let free = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        let used = max(0, Int64(total) - free)
        diskBar.isHidden = false
        diskBar.doubleValue = Double(used) / Double(total)
        diskLabel.stringValue = String(
            format: L("cleanup.diskUsage", "%@ used of %@ · %@ free"),
            byteFormatter.string(fromByteCount: used),
            byteFormatter.string(fromByteCount: Int64(total)),
            byteFormatter.string(fromByteCount: free))
    }

    // MARK: Build

    private func build() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        diskBar.style = .bar
        diskBar.isIndeterminate = false
        diskBar.minValue = 0
        diskBar.maxValue = 1
        diskBar.controlSize = .small
        diskLabel.font = .systemFont(ofSize: 11)
        diskLabel.textColor = .secondaryLabelColor

        for (id, title, width) in [
            ("check", "", CGFloat(24)), ("name", L("cleanup.colItem", "Item"), 280),
            ("size", L("cleanup.colSize", "Size"), 90),
            ("category", L("cleanup.colWhy", "Why"), 130),
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        aiButton.title = L("cleanup.recommendWithAI", "Recommend with AI")
        aiButton.bezelStyle = .rounded
        aiButton.target = self
        aiButton.action = #selector(recommendWithAI)
        trashButton.title = L("cleanup.moveCheckedToTrash", "Move Checked to Trash")
        trashButton.bezelStyle = .rounded
        trashButton.keyEquivalent = "\r"
        trashButton.target = self
        trashButton.action = #selector(trashChecked)
        let reveal = NSButton(
            title: L("cleanup.reveal", "Reveal"), target: self, action: #selector(revealSelected))
        reveal.bezelStyle = .rounded

        let header = NSStackView(views: [titleLabel, spinner, NSView(), summaryLabel])
        header.orientation = .horizontal
        header.spacing = 8
        summaryLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        let diskStats = NSStackView(views: [diskBar, diskLabel])
        diskStats.orientation = .vertical
        diskStats.alignment = .leading
        diskStats.spacing = 3
        let actions = NSStackView(views: [aiButton, NSView(), reveal, trashButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        let root = NSStackView(views: [header, diskStats, scroll, actions])
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(root)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
                diskStats.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
                diskBar.widthAnchor.constraint(equalTo: diskStats.widthAnchor),
            ])
        }
    }

    // MARK: Scan

    private var quickReport: StorageScan.Report?

    /// Two-phase so results appear fast: the quick walk (junk/large/old) shows almost
    /// immediately, then the slower duplicate analysis fills in, with a live status.
    private func scan() {
        titleLabel.stringValue = String(
            format: L("cleanup.scanning", "Scanning %@…"), root.lastPathComponent)
        summaryLabel.stringValue = L("cleanup.phaseScanning", "Scanning files…")
        rows = []
        quickReport = nil
        table.reloadData()
        trashButton.isEnabled = false
        spinner.startAnimation(nil)
        let generation = gen.bump()
        let url = root
        Task.detached(priority: .utility) { [weak self] in
            let quick = StorageScan.scanQuick(url)
            await MainActor.run {
                guard let self, self.gen.isCurrent(generation) else { return }
                self.applyQuick(quick)
            }
            let dups = StorageScan.duplicates(url)
            await MainActor.run {
                guard let self, self.gen.isCurrent(generation) else { return }
                self.applyDuplicates(dups)
            }
        }
    }

    private func applyQuick(_ report: StorageScan.Report) {
        quickReport = report
        titleLabel.stringValue = String(
            format: L("cleanup.titleFor", "Cleanup: %@"), root.lastPathComponent)
        rebuildRows()
        updateSummary(extra: " · " + L("cleanup.phaseDuplicates", "analyzing duplicates…"))
    }

    private func applyDuplicates(_ items: [StorageScan.Item]) {
        spinner.stopAnimation(nil)
        quickReport?.duplicates = items
        rebuildRows()
        updateSummary(extra: (quickReport?.truncated ?? false) ? L("cleanup.partialScan", " (partial scan)") : "")
    }

    /// Rebuild the row list from the latest report, preserving any check toggles the
    /// user made while the scan was still running.
    private func rebuildRows() {
        guard let report = quickReport else {
            rows = []
            table.reloadData()
            return
        }
        let priorChecked = Dictionary(rows.map { ($0.item.path, $0.checked) }, uniquingKeysWith: { a, _ in a })
        func row(_ item: StorageScan.Item, _ defaultChecked: Bool) -> Row {
            Row(item: item, checked: priorChecked[item.path] ?? defaultChecked)
        }
        rows =
            report.junk.map { row($0, true) }
            + report.duplicates.map { row($0, true) }
            + report.large.map { row($0, false) }
            + report.old.map { row($0, false) }
        table.reloadData()
    }

    private func updateSummary(extra: String = "") {
        let checked = rows.filter(\.checked).reduce(Int64(0)) { $0 + $1.item.size }
        let safe = rows.filter { $0.item.category == .junk || $0.item.category == .duplicate }
            .reduce(Int64(0)) { $0 + $1.item.size }
        summaryLabel.stringValue =
            String(
                format: L("cleanup.summary", "%@ checked · %@ safe to remove"),
                byteFormatter.string(fromByteCount: checked),
                byteFormatter.string(fromByteCount: safe)) + extra
        trashButton.isEnabled = checked > 0
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < rows.count else { return nil }
        let item = rows[row].item
        switch tableColumn.identifier.rawValue {
        case "check":
            let id = NSUserInterfaceItemIdentifier("check")
            let button = (tableView.makeView(withIdentifier: id, owner: self) as? NSButton) ?? {
                let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRow(_:)))
                b.identifier = id
                return b
            }()
            button.tag = row
            button.state = rows[row].checked ? .on : .off
            return button
        case "name":
            let cell = Self.textCell(tableView, owner: self, icon: true)
            cell.textField?.stringValue = (item.path as NSString).lastPathComponent
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.path)
            cell.textField?.toolTip = item.path
            return cell
        case "size":
            let cell = Self.textCell(tableView, owner: self, icon: false)
            cell.textField?.stringValue = byteFormatter.string(fromByteCount: item.size)
            return cell
        default:
            let cell = Self.textCell(tableView, owner: self, icon: false)
            cell.textField?.stringValue = "\(item.category.rawValue) · \(item.reason)"
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        }
    }

    @objc private func toggleRow(_ sender: NSButton) {
        guard sender.tag < rows.count else { return }
        rows[sender.tag].checked = (sender.state == .on)
        updateSummary()
    }

    // MARK: Actions

    @objc private func trashChecked() {
        let urls = rows.filter(\.checked).map { URL(fileURLWithPath: $0.item.path) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        let result = FileOperations.trash(urls: urls)
        let trashed = Set(result.trashed.map(\.original.path))
        rows.removeAll { trashed.contains($0.item.path) }
        table.reloadData()
        updateSummary()
        if !result.failures.isEmpty { NSSound.beep() }
    }

    @objc private func revealSelected() {
        let urls = table.selectedRowIndexes.compactMap {
            $0 < rows.count ? URL(fileURLWithPath: rows[$0].item.path) : nil
        }
        guard !urls.isEmpty else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func recommendWithAI() {
        if let reason = AIAvailability.unavailableReason() {
            AIAvailability.presentUnavailable(
                L("ai.cleanup.unavail", "AI recommendations are unavailable"), reason: reason,
                over: panel)
            return
        }
        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                let items = rows.map { (path: ($0.item.path as NSString).lastPathComponent, size: $0.item.size, reason: "\($0.item.category.rawValue), \($0.item.reason)") }
                guard !items.isEmpty else { NSSound.beep(); return }
                aiButton.isEnabled = false
                summaryLabel.stringValue = L("ai.cleanup.thinking", "Asking the model…")
                Task { @MainActor in
                    defer { self.aiButton.isEnabled = true }
                    guard let advice = await recommendCleanup(items: items) else {
                        self.summaryLabel.stringValue = L(
                            "ai.cleanup.noRec", "The model had no recommendation.")
                        return
                    }
                    for index in advice.safeToDelete where index >= 0 && index < self.rows.count {
                        self.rows[index].checked = true
                    }
                    self.table.reloadData()
                    self.updateSummary(extra: advice.summary.isEmpty ? "" : ": \(advice.summary)")
                }
            }
        #endif
    }

    private static func textCell(_ table: NSTableView, owner: Any?, icon: Bool) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(icon ? "nameCell" : "plainCell")
        if let reused = table.makeView(withIdentifier: id, owner: owner) as? NSTableCellView { return reused }
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        if icon {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }
}
