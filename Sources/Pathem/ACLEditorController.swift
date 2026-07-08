import AppKit
import PathemEngine

/// A small editor for a file's POSIX ACL: lists the current access-control entries and lets the
/// user add one (a user/group, allow or deny, a permission preset) or remove the selected one.
/// Reads via FileMetadata.aclEntries and writes via ACLEditor (chmod), off the main thread.
@MainActor
final class ACLEditorController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private let principalField = NSTextField()
    private let kindPopup = NSPopUpButton()
    private let presetPopup = NSPopUpButton()
    private let removeButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var url: URL?
    private var entries: [String] = []

    /// The permission presets offered, mapped to chmod keyword lists.
    private static let presets: [(name: String, permissions: [String])] = [
        ("Read only", ["read", "execute"]),
        ("Read & Write", ["read", "write", "execute", "delete"]),
        ("Full", ACLEditor.permissionKeywords),
    ]

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        build()
    }

    func present(url: URL, over parent: NSWindow?) {
        self.url = url
        panel.title = String(format: L("acl.title", "Permissions for “%@”"), url.lastPathComponent)
        principalField.stringValue = ""
        statusLabel.stringValue = ""
        reload()
        panel.centerOverMainWindow()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(principalField)
    }

    private func reload() {
        guard let url else { return }
        entries = FileMetadata.aclEntries(of: url) ?? []
        table.reloadData()
        removeButton.isEnabled = table.selectedRow >= 0
    }

    @objc private func add() {
        guard let url else { return }
        let principal = principalField.stringValue
        let allow = kindPopup.indexOfSelectedItem == 0
        let permissions = Self.presets[presetPopup.indexOfSelectedItem].permissions
        Task { @MainActor in
            let error = await Task.detached { ACLEditor.add(principal: principal, allow: allow, permissions: permissions, to: url) }.value
            if let error {
                self.statusLabel.stringValue = error
                self.statusLabel.textColor = .systemRed
            } else {
                self.principalField.stringValue = ""
                self.statusLabel.stringValue = L("acl.added", "Added.")
                self.statusLabel.textColor = .secondaryLabelColor
                self.reload()
            }
        }
    }

    @objc private func remove() {
        guard let url, table.selectedRow >= 0, table.selectedRow < entries.count else { return }
        let index = table.selectedRow
        Task { @MainActor in
            let error = await Task.detached { ACLEditor.removeEntry(at: index, from: url) }.value
            if let error {
                self.statusLabel.stringValue = error
                self.statusLabel.textColor = .systemRed
            } else {
                self.statusLabel.stringValue = L("acl.removed", "Removed.")
                self.statusLabel.textColor = .secondaryLabelColor
                self.reload()
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let field = NSTextField(labelWithString: "")
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
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
        cell.textField?.stringValue = row < entries.count ? entries[row] : ""
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = table.selectedRow >= 0
    }

    private func build() {
        let column = NSTableColumn(identifier: .init("ace"))
        column.title = L("acl.entries", "Access control entries")
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 18
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        principalField.placeholderString = L("acl.principal", "User or group name")
        principalField.translatesAutoresizingMaskIntoConstraints = false
        kindPopup.addItems(withTitles: [L("acl.allow", "Allow"), L("acl.deny", "Deny")])
        presetPopup.addItems(withTitles: Self.presets.map { L("acl.preset.\($0.name)", $0.name) })
        let addButton = NSButton(title: L("acl.add", "Add"), target: self, action: #selector(add))
        addButton.bezelStyle = .rounded
        let addRow = NSStackView(views: [principalField, kindPopup, presetPopup, addButton])
        addRow.orientation = .horizontal
        addRow.spacing = 8
        principalField.setContentHuggingPriority(.init(1), for: .horizontal)
        addRow.translatesAutoresizingMaskIntoConstraints = false

        removeButton.title = L("acl.remove", "Remove Selected")
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.isEnabled = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let close = NSButton(title: L("common.close", "Close"), target: panel, action: #selector(NSWindow.performClose(_:)))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        let bottom = NSStackView(views: [removeButton, statusLabel, NSView(), close])
        bottom.orientation = .horizontal
        bottom.spacing = 10
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        [scroll, addRow, bottom].forEach { content.addSubview($0) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            addRow.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            addRow.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            addRow.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: addRow.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }
}
