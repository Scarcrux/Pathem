import AppKit
import PathemEngine

/// The bottom "Activity" drawer: a tab strip (just Log for now) over a searchable table of the
/// local operation log, with Reveal, Undo (while the undo entry still exists) and Clear Log.
@MainActor
final class ActivityDrawerController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate
{
    let view = NSView()
    private let tabs = NSSegmentedControl(
        labels: [L("activity.tabLog", "Log")], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let revealButton = NSButton(title: "", target: nil, action: nil)
    private let undoButton = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "")
    private let timeFormatter = DateFormatter()
    private var all: [OperationRecord] = []
    private(set) var shown: [OperationRecord] = []
    private var loadGeneration = 0

    /// Whether the undo entry with this token still exists in the app's action history.
    var canUndo: (String) -> Bool = { _ in false }
    var onUndo: ((String) -> Void)?
    var onReveal: ((OperationRecord) -> Void)?

    private enum Col: String, CaseIterable {
        case time, operation, items, location, result
        var title: String {
            switch self {
            case .time: return L("activity.colTime", "Time")
            case .operation: return L("activity.colOperation", "Operation")
            case .items: return L("activity.colItems", "Items")
            case .location: return L("activity.colLocation", "Path")
            case .result: return L("activity.colResult", "Result")
            }
        }
        var width: CGFloat {
            switch self {
            case .time: return 130
            case .operation: return 110
            case .items: return 50
            case .location: return 380
            case .result: return 160
            }
        }
    }

    override init() {
        super.init()
        timeFormatter.dateStyle = .short
        timeFormatter.timeStyle = .medium
        build()
        NotificationCenter.default.addObserver(
            self, selector: #selector(reloadIfVisible), name: .pathemActivityLogChanged, object: nil
        )
        ThemeManager.shared.onChange(owner: self) { [weak self] in self?.applyTheme() }
    }

    private func build() {
        view.wantsLayer = true
        view.setAccessibilityLabel(L("activity.title", "Activity"))
        let title = NSTextField(labelWithString: L("activity.title", "Activity"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        tabs.selectedSegment = 0
        tabs.controlSize = .small
        tabs.segmentStyle = .rounded
        search.placeholderString = L("activity.search", "Filter activity")
        search.controlSize = .small
        search.delegate = self
        search.setAccessibilityLabel(L("activity.search", "Filter activity"))
        for (button, text, action) in [
            (revealButton, L("activity.reveal", "Reveal"), #selector(revealSelected)),
            (undoButton, L("activity.undo", "Undo"), #selector(undoSelected)),
            (clearButton, L("activity.clear", "Clear Log"), #selector(clearLog)),
        ] {
            button.title = text
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
        }

        for col in Col.allCases {
            let c = NSTableColumn(identifier: .init(col.rawValue))
            c.title = col.title
            c.width = col.width
            c.minWidth = 40
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.style = .plain
        table.target = self
        table.doubleAction = #selector(revealSelected)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        emptyLabel.stringValue = L(
            "activity.empty", "No activity yet. File operations you run will be listed here.")
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        let header = NSStackView(views: [
            title, tabs, NSView(), search, revealButton, undoButton, clearButton,
        ])
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        let searchWidth = search.widthAnchor.constraint(equalToConstant: 180)
        searchWidth.priority = .defaultHigh
        searchWidth.isActive = true
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for sub in [header, scroll, emptyLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: scroll.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: scroll.trailingAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        applyTheme()
        updateButtons()
    }

    private func applyTheme() {
        view.layer?.backgroundColor = ThemeManager.shared.contentBackground.cgColor
    }

    // MARK: Data

    @objc private func reloadIfVisible() {
        guard !view.isHidden else { return }
        reload()
    }

    func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        Task { @MainActor in
            let entries = await OperationLogger.shared.entries()
            guard generation == loadGeneration else { return }
            all = entries
            applyFilter()
        }
    }

    /// Install records directly (screenshots and tests), bypassing the log file.
    func show(records: [OperationRecord]) {
        loadGeneration += 1
        all = records
        applyFilter()
    }

    private func applyFilter() {
        let query = search.stringValue
        shown = query.isEmpty ? all : all.filter { $0.matches(query) }
        table.reloadData()
        emptyLabel.isHidden = !shown.isEmpty
        emptyLabel.stringValue =
            all.isEmpty
            ? L("activity.empty", "No activity yet. File operations you run will be listed here.")
            : L("activity.noMatches", "Nothing matches the filter.")
        updateButtons()
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    static func operationTitle(_ key: String) -> String {
        switch key {
        case "copy": return L("activity.op.copy", "Copy")
        case "move": return L("activity.op.move", "Move")
        case "trash": return L("activity.op.trash", "Move to Trash")
        case "rename": return L("activity.op.rename", "Rename")
        case "batchRename": return L("activity.op.batchRename", "Batch Rename")
        case "archive": return L("activity.op.archive", "Archive")
        case "secureDelete": return L("activity.op.secureDelete", "Secure Delete")
        case "create": return L("activity.op.create", "Create")
        case "link": return L("activity.op.link", "Link")
        case "undo": return L("activity.op.undo", "Undo")
        case "redo": return L("activity.op.redo", "Redo")
        default: return key
        }
    }

    static func resultText(_ record: OperationRecord) -> String {
        switch record.outcome {
        case .ok: return L("activity.result.ok", "Done")
        case .failed:
            return record.error.map { "\(L("activity.result.failed", "Failed")): \($0)" }
                ?? L("activity.result.failed", "Failed")
        case .partial: return L("activity.result.partial", "Partly done")
        case .canceled: return L("activity.result.canceled", "Canceled")
        }
    }

    /// The path shown for a record: "source → destination" when both exist.
    static func locationText(_ record: OperationRecord) -> String {
        let source = record.sources.first ?? ""
        let more = record.sources.count > 1 ? " +\(record.sources.count - 1)" : ""
        if let destination = record.destination, !destination.isEmpty {
            return "\(source)\(more) → \(destination)"
        }
        return source + more
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard row < shown.count, let id = tableColumn?.identifier,
            let col = Col(rawValue: id.rawValue)
        else { return nil }
        let record = shown[row]
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingMiddle
            field.font = .systemFont(ofSize: 11)
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let text: String
        switch col {
        case .time: text = timeFormatter.string(from: record.time)
        case .operation: text = Self.operationTitle(record.operation)
        case .items: text = String(record.itemCount)
        case .location: text = Self.locationText(record)
        case .result: text = Self.resultText(record)
        }
        cell.textField?.stringValue = text
        cell.textField?.textColor = record.outcome == .failed ? .systemRed : .labelColor
        cell.toolTip =
            col == .location
            ? ([record.sources.joined(separator: "\n")]
                + (record.destination.map { ["→ " + $0] } ?? [])).joined(separator: "\n") : nil
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: Actions

    private var selected: OperationRecord? {
        let row = table.selectedRow
        return row >= 0 && row < shown.count ? shown[row] : nil
    }

    /// Undo is offered only while the action history still holds the matching entry.
    func undoAvailable(for record: OperationRecord?) -> Bool {
        guard let token = record?.undoToken else { return false }
        return canUndo(token)
    }

    private func updateButtons() {
        revealButton.isEnabled = selected != nil
        undoButton.isEnabled = undoAvailable(for: selected)
        clearButton.isEnabled = !all.isEmpty
    }

    @objc private func revealSelected() {
        if let record = selected { onReveal?(record) }
    }

    @objc private func undoSelected() {
        guard let token = selected?.undoToken, undoAvailable(for: selected) else { return }
        onUndo?(token)
        updateButtons()
    }

    @objc private func clearLog() {
        OperationLogger.shared.clear()
        all = []
        applyFilter()
    }

    func refreshUndoState() { updateButtons() }
}

#if DEBUG
extension ActivityDrawerController {
    /// Exercise the mounted views without displaying a window or touching real paths.
    static func runFixture() -> Bool {
        let drawer = ActivityDrawerController()
        let undo = UUID().uuidString
        let first = OperationRecord(operation: "copy", sources: ["/fixture/Alpha"], undoToken: undo)
        let second = OperationRecord(
            operation: "rename", sources: ["/fixture/Beta"], outcome: .failed)
        drawer.view.frame = NSRect(x: 0, y: 0, width: 630, height: 180)
        drawer.canUndo = { $0 == undo }
        var performedUndo: String?
        drawer.onUndo = { performedUndo = $0 }
        drawer.show(records: [first, second])
        drawer.view.layoutSubtreeIfNeeded()
        let mounted = drawer.scroll.frame.height > 100 && drawer.table.numberOfRows == 2
        drawer.search.stringValue = "beta failed"
        drawer.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        drawer.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let failedMatch = drawer.shown == [second] && !drawer.undoButton.isEnabled
        drawer.search.stringValue = "alpha"
        drawer.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        drawer.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let canUndo = drawer.undoButton.isEnabled
        drawer.undoSelected()
        drawer.canUndo = { _ in false }
        drawer.refreshUndoState()
        let matchingUndo = canUndo && performedUndo == undo && !drawer.undoButton.isEnabled
        let statuses = [
            ("mounted rows", mounted), ("path and outcome filter", failedMatch),
            ("undo token and invalidation", matchingUndo),
        ]
        for (name, passed) in statuses {
            print("ACTIVITY: \(passed ? "PASS" : "FAIL") \(name)")
        }
        let passed = statuses.filter { $0.1 }.count
        print("RESULT: \(passed == statuses.count ? "PASS" : "FAIL") (\(passed)/\(statuses.count))")
        return passed == statuses.count
    }
}
#endif
