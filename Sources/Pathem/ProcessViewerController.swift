import AppKit
import PathemEngine

/// A lightweight process viewer: a filterable, sortable list of running processes with
/// Quit / Force Quit. Refreshes on a timer while visible. Data comes from the engine's
/// out-of-process `ps`; killing uses `kill`.
@MainActor
final class ProcessViewerController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate, NSSearchFieldDelegate
{
    private let window: NSWindow
    private let table = NSTableView()
    private let searchField = NSSearchField()
    private let quitButton = NSButton(title: "", target: nil, action: nil)
    private let forceButton = NSButton(title: "", target: nil, action: nil)
    private var all: [RunningProcess] = []
    private var shown: [RunningProcess] = []
    private var sort = NSSortDescriptor(key: "cpu", ascending: false)
    private var timer: Timer?
    private var loading = false

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
            defer: true)
        super.init()
        window.title = L("proc.title", "Process Viewer")
        window.delegate = self
        window.isReleasedWhenClosed = false
        build()
    }

    func present() {
        if !window.isVisible { window.centerOverMainWindow() }
        window.makeKeyAndOrderFront(nil)
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func build() {
        searchField.placeholderString = L("proc.filter", "Filter by name or PID")
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let refresh = NSButton(
            title: L("proc.refresh", "Refresh"), target: self, action: #selector(reloadTapped))
        refresh.bezelStyle = .rounded
        quitButton.title = L("proc.quit", "Quit")
        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quitSelected)
        forceButton.title = L("proc.forceQuit", "Force Quit")
        forceButton.bezelStyle = .rounded
        forceButton.target = self
        forceButton.action = #selector(forceQuitSelected)

        let controls = NSStackView(views: [searchField, NSView(), refresh, quitButton, forceButton])
        controls.orientation = .horizontal
        controls.spacing = 8

        let columns: [(String, String, CGFloat)] = [
            ("pid", L("proc.pid", "PID"), 64), ("name", L("proc.name", "Name"), 240),
            ("user", L("proc.user", "User"), 90), ("cpu", L("proc.cpu", "CPU %"), 64),
            ("mem", L("proc.mem", "Mem %"), 64), ("rss", L("proc.rss", "Memory"), 90),
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: id, ascending: id == "name" || id == "pid")
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.sortDescriptors = [sort]
        table.target = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let stack = NSStackView(views: [controls, scroll])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                controls.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            ])
        }
        updateButtons()
    }

    @objc private func reloadTapped() { reload() }

    private func reload() {
        guard !loading else { return }
        loading = true
        let keepPID = selectedProcess()?.pid
        Task { @MainActor in
            let snapshot = await ProcessList.snapshot()
            self.loading = false
            self.all = snapshot
            self.applyFilterAndSort()
            if let keepPID, let row = self.shown.firstIndex(where: { $0.pid == keepPID }) {
                self.table.selectRowIndexes([row], byExtendingSelection: false)
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) { applyFilterAndSort() }

    func tableView(
        _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        if let first = tableView.sortDescriptors.first { sort = first }
        applyFilterAndSort()
    }

    private func applyFilterAndSort() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var list = all
        if !query.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(query) || "\($0.pid)".contains(query)
            }
        }
        let ascending = sort.ascending
        list.sort { a, b in
            let result: Bool
            switch sort.key {
            case "pid": result = a.pid < b.pid
            case "name":
                result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case "user": result = a.user < b.user
            case "mem": result = a.mem < b.mem
            case "rss": result = a.rss < b.rss
            default: result = a.cpu < b.cpu
            }
            return ascending ? result : !result
        }
        shown = list
        table.reloadData()
        updateButtons()
    }

    private func selectedProcess() -> RunningProcess? {
        let row = table.selectedRow
        return (row >= 0 && row < shown.count) ? shown[row] : nil
    }

    private func updateButtons() {
        let hasSelection = selectedProcess() != nil
        quitButton.isEnabled = hasSelection
        forceButton.isEnabled = hasSelection
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    @objc private func quitSelected() { terminate(force: false) }
    @objc private func forceQuitSelected() { terminate(force: true) }

    private func terminate(force: Bool) {
        guard let process = selectedProcess() else { return }
        let alert = Self.makeTerminateConfirmation(
            name: process.name, pid: Int(process.pid), force: force)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            let ok = await ProcessList.terminate(process.pid, force: force)
            if !ok { NSSound.beep() }
            self.reload()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let tableColumn, row < shown.count else { return nil }
        let process = shown[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let c = NSTableCellView()
                c.identifier = id
                let f = NSTextField(labelWithString: "")
                f.lineBreakMode = .byTruncatingMiddle
                f.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(f)
                c.textField = f
                NSLayoutConstraint.activate([
                    f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                    f.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                    f.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
        let value: String
        switch tableColumn.identifier.rawValue {
        case "pid": value = "\(process.pid)"
        case "name": value = process.name
        case "user": value = process.user
        case "cpu": value = String(format: "%.1f", process.cpu)
        case "mem": value = String(format: "%.1f", process.mem)
        default: value = String(format: "%.1f MB", Double(process.rss) / 1024)
        }
        cell.textField?.stringValue = value
        cell.textField?.font =
            tableColumn.identifier.rawValue == "name"
            ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        return cell
    }
}

@MainActor
extension ProcessViewerController {
    /// Production construction shared with isolated geometry/lifecycle checks.
    static func makeTerminateConfirmation(name: String, pid: Int, force: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(
            format: force
                ? L("proc.confirmForce", "Force quit %@ (%d)?")
                : L("proc.confirmQuit", "Quit %@ (%d)?"), name, pid)
        alert.informativeText =
            force
            ? L("proc.forceWarning", "Force quitting may lose unsaved work.")
            : L("proc.quitInfo", "Sends a terminate signal to the process.")
        alert.addButton(
            withTitle: force ? L("proc.forceQuit", "Force Quit") : L("proc.quit", "Quit"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        return alert
    }
}
