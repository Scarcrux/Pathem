import AppKit
import PathemEngine

/// A floating multi-mode command bar (DESIGN.md section 10, Phase 3). One widget, four
/// modes chosen by the first character:
///   - bare text (or a leading ">") fuzzy-finds and runs any registered command,
///   - "/" or "~/" jumps to a filesystem path (with directory completion),
///   - "?" runs the on-device semantic search in the active folder.
/// Because every action is a Command in the registry, the command mode lists the whole
/// surface for free. Driven entirely from the field editor's command selectors, so
/// up/down/return/escape work while typing.
@MainActor
final class CommandPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let panel: NSPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()

    private var all: [(id: String, title: String)] = []
    private var filtered: [(id: String, title: String)] = []
    private var onRun: ((String) -> Void)?
    private var onNavigate: ((URL) -> Void)?
    private var onSemantic: ((String) -> Void)?

    private enum Mode { case command, path, semantic }
    private var mode: Mode {
        let s = field.stringValue
        if s.hasPrefix("/") || s.hasPrefix("~/") { return .path }
        if s.hasPrefix("?") { return .semantic }
        return .command
    }

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: true)
        super.init()
        configure()
    }

    private func configure() {
        panel.title = L("palette.runCommandTitle", "Command Bar")
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        field.placeholderString = L("palette.multiPlaceholder", "Command, /path, or ?search")
        field.delegate = self
        field.font = .systemFont(ofSize: 15)
        field.translatesAutoresizingMaskIntoConstraints = false

        table.headerView = nil
        table.rowHeight = 24
        table.style = .inset
        let column = NSTableColumn(identifier: .init("title"))
        column.width = 520
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runClicked)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(field)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    /// Show the bar over `window`. The three callbacks route the three non-command modes;
    /// command mode uses `onRun` with the chosen command id.
    func present(
        commands: [(id: String, title: String)],
        onRun: @escaping (String) -> Void,
        onNavigate: @escaping (URL) -> Void,
        onSemantic: @escaping (String) -> Void,
        over window: NSWindow
    ) {
        all = commands
        self.onRun = onRun
        self.onNavigate = onNavigate
        self.onSemantic = onSemantic
        field.stringValue = ""
        refilter()

        let windowFrame = window.frame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: windowFrame.midX - size.width / 2, y: windowFrame.maxY - size.height - 80))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func refilter() {
        switch mode {
        case .command:
            let query = field.stringValue.hasPrefix(">")
                ? String(field.stringValue.dropFirst()) : field.stringValue
            filtered = FuzzyMatch.rank(all, query: query, key: { $0.title })
        case .path:
            filtered = pathCompletions(field.stringValue)
        case .semantic:
            let query = String(field.stringValue.dropFirst()).trimmingCharacters(in: .whitespaces)
            filtered =
                query.isEmpty
                ? []
                : [(id: query, title: String(format: L("palette.searchFor", "Search for “%@”"), query))]
        }
        table.reloadData()
        if !filtered.isEmpty { select(0) }
    }

    /// Child directories of the path's parent that match its trailing component.
    private func pathCompletions(_ input: String) -> [(id: String, title: String)] {
        let expanded = (input as NSString).expandingTildeInPath
        let endsWithSlash = expanded.hasSuffix("/")
        let dir = endsWithSlash ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = endsWithSlash ? "" : (expanded as NSString).lastPathComponent
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    && (prefix.isEmpty || url.lastPathComponent.lowercased().hasPrefix(prefix.lowercased()))
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(60)
            .map { (id: $0.path, title: $0.path) }
    }

    private func select(_ row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        select(min(max(table.selectedRow + delta, 0), filtered.count - 1))
    }

    private func runSelected() {
        switch mode {
        case .command:
            let row = table.selectedRow
            guard row >= 0, row < filtered.count else { return }
            let id = filtered[row].id
            close()
            onRun?(id)
        case .path:
            // A fully-typed existing directory wins; otherwise the selected completion.
            let typed = (field.stringValue as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: typed, isDirectory: &isDir), isDir.boolValue {
                close()
                onNavigate?(URL(fileURLWithPath: typed))
                return
            }
            let row = table.selectedRow
            guard row >= 0, row < filtered.count else { return }
            close()
            onNavigate?(URL(fileURLWithPath: filtered[row].id))
        case .semantic:
            let query = String(field.stringValue.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return }
            close()
            onSemantic?(query)
        }
    }

    @objc private func runClicked() {
        let row = table.clickedRow
        guard row >= 0, row < filtered.count else { return }
        select(row)
        runSelected()
    }

    private func close() { panel.orderOut(nil) }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    // MARK: NSTableView data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? Self.makeCell(id)
        cell.textField?.stringValue = filtered[row].title
        return cell
    }

    private static func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 14)
        field.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
