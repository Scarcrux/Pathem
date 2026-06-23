import AppKit
import PathemEngine

/// Manage saved remote servers: list, add, edit, remove, and import from
/// FileZilla. Connecting/browsing is handled elsewhere (out-of-process); this is
/// the management surface. Persists via `onChange`.
@MainActor
final class ConnectionsController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()

    var connections: [RemoteConnection] = [] { didSet { table.reloadData() } }
    /// Called whenever the list changes, so the browser can persist it.
    var onChange: (([RemoteConnection]) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        build()
    }

    private func build() {
        panel.title = "Connections"
        let column = NSTableColumn(identifier: .init("c"))
        column.title = "Server"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(editSelected)
        table.target = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let add = button("Add", #selector(addNew))
        let edit = button("Edit", #selector(editSelected))
        let remove = button("Remove", #selector(removeSelected))
        let importFZ = button("Import from FileZilla…", #selector(importFileZilla))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let close = button("Done", #selector(closePanel))
        let bar = NSStackView(views: [add, edit, remove, importFZ, spacer, close])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(scroll)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    func present(over window: NSWindow?) {
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
    }

    private func commit() { onChange?(connections) }

    // MARK: Actions

    @objc private func addNew() {
        editConnection(nil)
    }

    @objc private func editSelected() {
        let row = table.selectedRow
        guard row >= 0, row < connections.count else { return }
        editConnection(row)
    }

    @objc private func removeSelected() {
        let row = table.selectedRow
        guard row >= 0, row < connections.count else { return }
        connections.remove(at: row)
        commit()
    }

    @objc private func closePanel() { panel.orderOut(nil) }

    @objc private func importFileZilla() {
        if let url = FileZillaImporter.defaultSiteManagerURL() {
            merge(FileZillaImporter.importSites(from: url))
        } else {
            // Let the user point at sitemanager.xml.
            let openPanel = NSOpenPanel()
            openPanel.message = "Choose FileZilla's sitemanager.xml"
            openPanel.allowedContentTypes = [.xml]
            openPanel.allowsMultipleSelection = false
            openPanel.beginSheetModal(for: panel) { [weak self] response in
                guard response == .OK, let url = openPanel.url else { return }
                self?.merge(FileZillaImporter.importSites(from: url))
            }
        }
    }

    /// Add imported sites that aren't already present (by host+user+proto).
    private func merge(_ imported: [RemoteConnection]) {
        guard !imported.isEmpty else {
            NSSound.beep()
            return
        }
        var existing = Set(connections.map { "\($0.proto.rawValue)|\($0.host)|\($0.user)" })
        for site in imported {
            let key = "\(site.proto.rawValue)|\(site.host)|\(site.user)"
            if existing.insert(key).inserted { connections.append(site) }
        }
        commit()
    }

    /// Add (row == nil) or edit a connection via a compact form sheet.
    private func editConnection(_ row: Int?) {
        let existing = row.map { connections[$0] }
        let alert = NSAlert()
        alert.messageText = row == nil ? "New Connection" : "Edit Connection"

        let proto = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        proto.addItems(withTitles: RemoteConnection.Proto.allCases.map(\.label))
        proto.selectItem(at: RemoteConnection.Proto.allCases.firstIndex(of: existing?.proto ?? .ftp) ?? 0)

        func field(_ placeholder: String, _ value: String) -> NSTextField {
            let f = NSTextField()
            f.placeholderString = placeholder
            f.stringValue = value
            return f
        }
        let name = field("Name", existing?.name ?? "")
        let host = field("Host", existing?.host ?? "")
        let port = field("Port (blank = default)", existing.map { $0.port == 0 ? "" : "\($0.port)" } ?? "")
        let user = field("User", existing?.user ?? "")
        let path = field("Path", existing?.path ?? "/")

        let rows = NSStackView(views: [
            labeled("Protocol", proto), labeled("Name", name), labeled("Host", host),
            labeled("Port", port), labeled("User", user), labeled("Path", path),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        alert.accessoryView = rows
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        guard let window = panel.isVisible ? panel : nil else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let host = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else {
                NSSound.beep()
                return
            }
            let chosen = RemoteConnection.Proto.allCases[proto.indexOfSelectedItem]
            let conn = RemoteConnection(
                id: existing?.id ?? UUID(),
                name: name.stringValue.isEmpty ? host : name.stringValue,
                proto: chosen, host: host, port: Int(port.stringValue) ?? 0,
                user: user.stringValue, path: path.stringValue.isEmpty ? "/" : path.stringValue)
            if let row { self.connections[row] = conn } else { self.connections.append(conn) }
            self.commit()
        }
    }

    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 70).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        control.widthAnchor.constraint(equalToConstant: 230).isActive = true
        return row
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { connections.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? Self.makeCell(id)
        let conn = connections[row]
        cell.textField?.stringValue = "\(conn.name)\n\(conn.proto.label)  \(conn.displayURL)"
        return cell
    }

    private static func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byTruncatingTail
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
