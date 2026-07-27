import AppKit

/// A recent-actions panel over the file-operation `ActionHistory`: the undo stack newest-first,
/// with Undo (the most recent), Redo, and "Undo This" -- a selective undo of the chosen action
/// when nothing newer depends on it (the footprint-overlap check). Refreshes live via onChange.
@MainActor
final class UndoHistoryController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private let undoThisButton = NSButton()
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private weak var history: ActionHistory?
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        build()
    }

    func present(over window: NSWindow, history: ActionHistory) {
        self.history = history
        history.onChange = { [weak self] in self?.refresh() }
        refresh()
        panel.growToFitContent()
        panel.centerOverMainWindow()
        panel.makeKeyAndOrderFront(nil)
    }

    /// undoStack is oldest-first; the panel lists newest at the top, so map row <-> stack index.
    private func stackIndex(forRow row: Int) -> Int? {
        guard let count = history?.undoStack.count, (0..<count).contains(row) else { return nil }
        return count - 1 - row
    }

    private func refresh() {
        table.reloadData()
        undoButton.isEnabled = history?.canUndo ?? false
        redoButton.isEnabled = history?.canRedo ?? false
        let row = table.selectedRow
        undoThisButton.isEnabled =
            stackIndex(forRow: row).map { history?.isIndependentlyUndoable(at: $0) ?? false } ?? false
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refresh() }

    @objc private func undoTapped() { history?.undo() }
    @objc private func redoTapped() { history?.redo() }
    @objc private func undoThisTapped() {
        guard let index = stackIndex(forRow: table.selectedRow) else { NSSound.beep(); return }
        if history?.undo(at: index) != true { NSSound.beep() }  // something newer depends on it
    }

    private func build() {
        panel.title = L("history.title", "Undo History")
        for (id, title, width) in [
            ("name", L("history.colAction", "Action"), CGFloat(280)),
            ("when", L("history.colWhen", "When"), 120),
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
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        func button(_ b: NSButton, _ title: String, _ selector: Selector) -> NSButton {
            b.title = title
            b.bezelStyle = .rounded
            b.target = self
            b.action = selector
            return b
        }
        let hint = NSTextField(labelWithString: L("history.hint", "“Undo This” selectively undoes an action nothing newer touched."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let bar = NSStackView(views: [
            button(undoThisButton, L("history.undoThis", "Undo This"), #selector(undoThisTapped)),
            NSView(),
            button(undoButton, L("history.undo", "Undo"), #selector(undoTapped)),
            button(redoButton, L("history.redo", "Redo"), #selector(redoTapped)),
        ])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(scroll)
        content.addSubview(hint)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            bar.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    // MARK: Table
    func numberOfRows(in tableView: NSTableView) -> Int { history?.undoStack.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let index = stackIndex(forRow: row), let action = history?.undoStack[index]
        else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let c = NSTableCellView()
                c.identifier = id
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(field)
                c.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                    field.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                    field.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
        if tableColumn.identifier.rawValue == "name" {
            cell.textField?.stringValue = action.name
            cell.textField?.textColor = .labelColor
        } else {
            cell.textField?.stringValue = Self.relative.localizedString(for: action.date, relativeTo: Date())
            cell.textField?.textColor = .secondaryLabelColor
        }
        return cell
    }
}
