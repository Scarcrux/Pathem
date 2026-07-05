import AppKit

/// A power tool that shows what's on the file clipboard -- the copied/cut items and whether a
/// paste will copy or move them -- with Paste-here and Clear. Makes the otherwise-invisible
/// pasteboard state inspectable. One reused panel, refreshed on each present.
@MainActor
final class ClipboardViewerController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private let header = NSTextField(labelWithString: "")
    private let pasteButton = NSButton()
    private let clearButton = NSButton()
    private var items: [URL] = []
    private var isCut = false
    private var onPaste: (() -> Void)?
    private var onClear: (() -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        panel.title = L("clipboard.title", "Clipboard")
        panel.isReleasedWhenClosed = false
        build()
    }

    func present(
        items: [URL], isCut: Bool, over window: NSWindow?, onPaste: (() -> Void)?, onClear: (() -> Void)?
    ) {
        self.items = items
        self.isCut = isCut
        self.onPaste = onPaste
        self.onClear = onClear
        reload()
        if !panel.isVisible { panel.centerOverMainWindow() }
        panel.makeKeyAndOrderFront(nil)
    }

    private func reload() {
        if items.isEmpty {
            header.stringValue = L("clipboard.empty", "The clipboard is empty.")
        } else {
            let verb = isCut ? L("clipboard.cut", "Cut (moves on paste)") : L("clipboard.copy", "Copy")
            header.stringValue = String(
                format: L("clipboard.summary", "%d item(s) · %@"), items.count, verb)
        }
        pasteButton.isEnabled = !items.isEmpty
        clearButton.isEnabled = !items.isEmpty
        table.reloadData()
    }

    private func build() {
        header.font = .systemFont(ofSize: 12, weight: .medium)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = L("clipboard.colItem", "Item")
        nameColumn.width = 220
        let pathColumn = NSTableColumn(identifier: .init("path"))
        pathColumn.title = L("clipboard.colLocation", "Location")
        pathColumn.width = 260
        table.addTableColumn(nameColumn)
        table.addTableColumn(pathColumn)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        pasteButton.title = L("clipboard.pasteHere", "Paste to Current Folder")
        pasteButton.bezelStyle = .rounded
        pasteButton.target = self
        pasteButton.action = #selector(pasteHere)
        clearButton.title = L("clipboard.clear", "Clear")
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clear)
        let buttons = NSStackView(views: [clearButton, NSView(), pasteButton])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        for view in [header, scroll, buttons] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count, let column = tableColumn else { return nil }
        let url = items[row]
        let id = NSUserInterfaceItemIdentifier(column.identifier.rawValue)
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? Self.makeCell(id, withIcon: column.identifier.rawValue == "name")
        if column.identifier.rawValue == "name" {
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
            cell.textField?.stringValue = url.lastPathComponent
        } else {
            cell.textField?.stringValue = url.deletingLastPathComponent().path
            cell.textField?.textColor = .secondaryLabelColor
        }
        return cell
    }

    private static func makeCell(_ id: NSUserInterfaceItemIdentifier, withIcon: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(field)
        cell.textField = field
        if withIcon {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    @objc private func pasteHere() {
        onPaste?()
        panel.close()
    }

    @objc private func clear() {
        onClear?()
        items = []
        reload()
    }
}
