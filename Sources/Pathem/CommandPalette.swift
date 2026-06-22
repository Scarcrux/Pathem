import AppKit
import PathemEngine

/// A floating command palette (DESIGN.md section 10, Phase 3): type to fuzzy-find
/// any registered command and run it. Because every action is a Command in the
/// registry, the palette lists the whole surface for free, which doubles as the
/// app's discoverability mechanism. Driven entirely from the search field via
/// the field editor's command selectors, so up/down/return/escape work while you
/// keep typing.
@MainActor
final class CommandPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let panel: NSPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()

    private var all: [(id: String, title: String)] = []
    private var filtered: [(id: String, title: String)] = []
    private var onRun: ((String) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: true)
        super.init()
        configure()
    }

    private func configure() {
        panel.title = "Run Command"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        field.placeholderString = "Type a command…"
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

    /// Show the palette over `window`, listing `commands`; `onRun` is called with
    /// the chosen command id (the palette closes first).
    func present(
        commands: [(id: String, title: String)],
        onRun: @escaping (String) -> Void,
        over window: NSWindow
    ) {
        all = commands
        self.onRun = onRun
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
        filtered = FuzzyMatch.rank(all, query: field.stringValue, key: { $0.title })
        table.reloadData()
        if !filtered.isEmpty { select(0) }
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
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let id = filtered[row].id
        close()
        onRun?(id)
    }

    @objc private func runClicked() {
        // Use the clicked row, not the selection: a double-click on empty space
        // reports clickedRow == -1 and must do nothing (the keyboard path uses
        // runSelected). Mirrors FileListController.handleDoubleClick.
        let row = table.clickedRow
        guard row >= 0, row < filtered.count else { return }
        let id = filtered[row].id
        close()
        onRun?(id)
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
