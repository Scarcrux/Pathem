import AppKit
import PathemEngine

/// A small panel listing a file's extended attributes (name, size, text preview), with a
/// Remove for the selected one and a one-click "Remove Quarantine" for the common case of
/// clearing Gatekeeper's download flag. A reusable single panel, refreshed each present.
@MainActor
final class XattrController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private let quarantineButton = NSButton()
    private let removeButton = NSButton()
    private var url: URL?
    private var attrs: [ExtendedAttributes.Attribute] = []
    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 380),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        panel.isReleasedWhenClosed = false
        build()
    }

    func present(for url: URL, over window: NSWindow?) {
        self.url = url
        reload()
        if !panel.isVisible { panel.centerOverMainWindow() }
        panel.makeKeyAndOrderFront(nil)
    }

    private func build() {
        for (id, title, width) in [
            ("name", L("xattr.colName", "Attribute"), CGFloat(230)),
            ("size", L("xattr.colSize", "Size"), CGFloat(70)),
            ("value", L("xattr.colValue", "Value"), CGFloat(200)),
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
        table.target = self
        table.doubleAction = #selector(removeSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        quarantineButton.title = L("xattr.removeQuarantine", "Remove Quarantine")
        quarantineButton.bezelStyle = .rounded
        quarantineButton.target = self
        quarantineButton.action = #selector(removeQuarantine)
        removeButton.title = L("xattr.remove", "Remove Selected")
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        let actions = NSStackView(views: [quarantineButton, NSView(), removeButton])
        actions.orientation = .horizontal

        let root = NSStackView(views: [scroll, actions])
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(root)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            ])
        }
    }

    private func reload() {
        attrs = url.map { ExtendedAttributes.list($0) } ?? []
        quarantineButton.isEnabled = url.map { ExtendedAttributes.isQuarantined($0) } ?? false
        removeButton.isEnabled = !attrs.isEmpty
        panel.title =
            url.map { String(format: L("xattr.titleFor", "Extended Attributes — %@"), $0.lastPathComponent) }
            ?? L("xattr.title", "Extended Attributes")
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { attrs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < attrs.count else { return nil }
        let attribute = attrs[row]
        let text: String
        switch tableColumn.identifier.rawValue {
        case "name": text = attribute.name
        case "size": text = byteFormatter.string(fromByteCount: Int64(attribute.size))
        default: text = attribute.preview ?? L("xattr.binary", "(binary)")
        }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let view = NSTableCellView()
                view.identifier = id
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(field)
                view.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
                return view
            }()
        cell.textField?.stringValue = text
        cell.textField?.textColor = tableColumn.identifier.rawValue == "value" ? .secondaryLabelColor : .labelColor
        return cell
    }

    @objc private func removeSelected() {
        let row = table.selectedRow
        guard let url, attrs.indices.contains(row) else { NSSound.beep(); return }
        let name = attrs[row].name
        do {
            try ExtendedAttributes.remove(name, from: url)
            reload()
        } catch {
            let alert = NSAlert()
            alert.messageText = String(format: L("xattr.removeFailedTitle", "Couldn’t remove “%@”"), name)
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L("common.ok", "OK"))
            if let window = table.window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
        }
    }

    @objc private func removeQuarantine() {
        guard let url else { return }
        _ = ExtendedAttributes.removeQuarantine(from: url)
        reload()
    }

    /// Test hook: number of attribute rows currently shown.
    var debugRowCount: Int { attrs.count }
}
