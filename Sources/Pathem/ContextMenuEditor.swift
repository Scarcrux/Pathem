import AppKit
import PathemEngine

/// The editor for the file right-click menu: a reorderable list of every entry with a
/// checkbox to show or hide it. Drag a row to change the menu's order; uncheck to hide it.
/// Lives in Settings > Menus. Reports changes back as (order, hidden) for persistence.
@MainActor
final class ContextMenuEditorController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView()
    private let table = NSTableView()
    private let rowType = NSPasteboard.PasteboardType("com.scarcrux.pathem.contextmenu-row")

    /// The entries in display order (command ids and submenu tokens).
    private var entries: [String]
    private var hidden: Set<String>
    /// Fired on every edit so Settings can persist and re-apply to open panes.
    var onChange: ((_ order: [String], _ hidden: [String]) -> Void)?

    init(order: [String], hidden: [String]) {
        entries = ContextMenuLayout.ordered(
            default: FileContextMenuController.defaultEntries, user: order)
        self.hidden = Set(hidden)
        super.init()
        build()
    }

    private func build() {
        let column = NSTableColumn(identifier: .init("entry"))
        column.title = L("prefs.contextMenuColumn", "Right-Click Menu")
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        table.usesAutomaticRowHeights = false
        table.registerForDraggedTypes([rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(
            wrappingLabelWithString: L(
                "prefs.contextMenuEditorHint",
                "Drag to reorder the file right-click menu. Uncheck an item to hide it. Dividers are added automatically."
            ))
        hint.font = .systemFont(ofSize: 11)
        hint.preferredMaxLayoutWidth = 390
        hint.setContentCompressionResistancePriority(.required, for: .vertical)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let reset = NSButton(
            title: L("prefs.contextMenuReset", "Reset to Default"), target: self,
            action: #selector(resetToDefault))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(hint)
        view.addSubview(scroll)
        view.addSubview(reset)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: view.topAnchor),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 360),
            reset.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            reset.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reset.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func resetToDefault() {
        entries = FileContextMenuController.defaultEntries
        hidden = []
        table.reloadData()
        onChange?([], [])  // empty order + no hidden = the default menu
    }

    private func commit() {
        onChange?(entries, Array(hidden).sorted())
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? EntryCell) ?? EntryCell(id: id)
        let token = entries[row]
        cell.checkbox.state = hidden.contains(token) ? .off : .on
        cell.checkbox.target = self
        cell.checkbox.action = #selector(toggleRow(_:))
        cell.checkbox.tag = row
        cell.iconView.image =
            token.hasPrefix("@")
            ? NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
            : MenuIcons.image(forCommand: token)
        cell.label.stringValue = FileContextMenuController.title(for: token)
        return cell
    }

    @objc private func toggleRow(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        let token = entries[sender.tag]
        if sender.state == .on { hidden.remove(token) } else { hidden.insert(token) }
        commit()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> NSPasteboardWriting?
    {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: rowType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
        proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        dropOperation == .above && info.draggingPasteboard.availableType(from: [rowType]) != nil
            ? .move : []
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let str = info.draggingPasteboard.string(forType: rowType), let from = Int(str),
            entries.indices.contains(from)
        else { return false }
        var target = row
        let moved = entries.remove(at: from)
        if from < target { target -= 1 }  // account for the removed row
        entries.insert(moved, at: min(max(target, 0), entries.count))
        table.reloadData()
        commit()
        return true
    }

    /// A row: a show/hide checkbox, the command icon, and its title.
    private final class EntryCell: NSTableCellView {
        let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        let iconView = NSImageView()
        let label = NSTextField(labelWithString: "")

        init(id: NSUserInterfaceItemIdentifier) {
            super.init(frame: .zero)
            identifier = id
            iconView.imageScaling = .scaleProportionallyDown
            let stack = NSStackView(views: [checkbox, iconView, label])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),
            ])
        }
        required init?(coder: NSCoder) { fatalError("not used") }
    }
}
