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
    /// Open the chosen server (the browser prompts for a password and connects).
    var onConnect: ((RemoteConnection) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        build()
    }

    private func build() {
        panel.title = L("conn.panelTitle", "Connections")
        panel.isReleasedWhenClosed = false  // controller owns it; title-bar close just hides it
        let column = NSTableColumn(identifier: .init("c"))
        column.title = L("conn.serverColumn", "Server")
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(connectSelected)
        table.target = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let add = button(L("conn.addButton", "Add"), #selector(addNew))
        let edit = button(L("conn.editButton", "Edit"), #selector(editSelected))
        let remove = button(L("common.remove", "Remove"), #selector(removeSelected))
        let importFZ = button(L("conn.importButton", "Import from FileZilla…"), #selector(importFileZilla))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let connect = button(L("conn.connectButton", "Connect"), #selector(connectSelected))
        connect.keyEquivalent = "\r"
        let close = button(L("common.done", "Done"), #selector(closePanel))
        let bar = NSStackView(views: [add, edit, remove, importFZ, spacer, connect, close])
        bar.orientation = .horizontal
        bar.spacing = 12
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(scroll)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    func present(over window: NSWindow?) {
        if !panel.isVisible {
            if let window {  // center over the owning window
                let f = window.frame
                let s = panel.frame.size
                panel.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: f.midY - s.height / 2))
            } else {
                panel.center()
            }
        }
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

    /// Remove a connection by identity (from the sidebar right-click menu).
    func remove(_ connection: RemoteConnection) {
        connections.removeAll { $0.id == connection.id }
        commit()
    }

    /// Open the edit sheet for a specific connection (the panel must be visible).
    func beginEdit(_ connection: RemoteConnection) {
        guard let row = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        editConnection(row)
    }

    @objc private func connectSelected() {
        let row = table.selectedRow
        guard row >= 0, row < connections.count else { return }
        let conn = connections[row]
        panel.orderOut(nil)
        onConnect?(conn)
    }

    @objc private func closePanel() { panel.orderOut(nil) }

    @objc private func importFileZilla() {
        if let url = FileZillaImporter.defaultSiteManagerURL() {
            merge(FileZillaImporter.importSites(from: url))
        } else {
            // Let the user point at sitemanager.xml.
            let openPanel = NSOpenPanel()
            openPanel.message = L("conn.chooseSiteManager", "Choose FileZilla's sitemanager.xml")
            openPanel.allowedContentTypes = [.xml]
            openPanel.allowsMultipleSelection = false
            openPanel.beginSheetModal(for: panel) { [weak self] response in
                guard response == .OK, let url = openPanel.url else { return }
                self?.merge(FileZillaImporter.importSites(from: url))
            }
        }
    }

    /// Add imported sites that aren't already present (by proto+host+port+user).
    private func merge(_ imported: [RemoteConnection]) {
        guard !imported.isEmpty else {
            NSSound.beep()
            return
        }
        func key(_ c: RemoteConnection) -> String { "\(c.proto.rawValue)|\(c.host)|\(c.effectivePort)|\(c.user)" }
        var existing = Set(connections.map(key))
        let before = connections.count
        for site in imported where existing.insert(key(site)).inserted { connections.append(site) }
        if connections.count > before {
            commit()  // only write when something actually changed
        } else {
            NSSound.beep()  // everything was already present
        }
    }

    /// Add (row == nil) or edit a connection via a compact form sheet.
    private func editConnection(_ row: Int?) {
        let existing = row.map { connections[$0] }
        let alert = NSAlert()
        alert.messageText = row == nil ? L("conn.newConnectionTitle", "New Connection") : L("conn.editConnectionTitle", "Edit Connection")

        let proto = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        proto.addItems(withTitles: RemoteConnection.Proto.allCases.map(\.label))
        proto.selectItem(at: RemoteConnection.Proto.allCases.firstIndex(of: existing?.proto ?? .ftp) ?? 0)

        func field(_ placeholder: String, _ value: String) -> NSTextField {
            let f = NSTextField()
            f.placeholderString = placeholder
            f.stringValue = value
            return f
        }
        let name = field(L("conn.namePlaceholder", "Name"), existing?.name ?? "")
        let host = field(L("conn.hostPlaceholder", "Host"), existing?.host ?? "")
        let port = field(L("conn.portPlaceholder", "Port (blank = default)"), existing.map { $0.port == 0 ? "" : "\($0.port)" } ?? "")
        let user = field(L("conn.userPlaceholder", "User (S3: access key)"), existing?.user ?? "")
        let path = field(L("conn.pathPlaceholder", "Path (S3: /bucket)"), existing?.path ?? "/")
        let region = field(L("conn.regionPlaceholder", "Region (S3, e.g. us-east-1)"), existing?.region ?? "")

        let rows = NSStackView(views: [
            labeled(L("conn.protocolLabel", "Protocol"), proto), labeled(L("conn.nameLabel", "Name"), name), labeled(L("conn.hostLabel", "Host"), host),
            labeled(L("conn.portLabel", "Port"), port), labeled(L("conn.userLabel", "User"), user), labeled(L("conn.pathLabel", "Path"), path),
            labeled(L("conn.regionLabel", "Region"), region),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.frame = NSRect(x: 0, y: 0, width: 340, height: 232)
        alert.accessoryView = rows
        alert.addButton(withTitle: L("common.save", "Save"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))

        guard let window = panel.isVisible ? panel : nil else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let host = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let chosen = RemoteConnection.Proto.allCases[proto.indexOfSelectedItem]
            // S3 may leave the host blank (derived from the region: s3.<region>.amazonaws.com);
            // every other protocol needs a valid, non-smuggling host.
            if chosen == .s3 {
                if !host.isEmpty, !RemoteConnection.isValidHost(host) { NSSound.beep(); return }
            } else if host.isEmpty || !RemoteConnection.isValidHost(host) {
                NSSound.beep()
                return
            }
            let conn = RemoteConnection(
                id: existing?.id ?? UUID(),
                name: name.stringValue.isEmpty ? (host.isEmpty ? "Amazon S3" : host) : name.stringValue,
                proto: chosen, host: host, port: Int(port.stringValue) ?? 0,
                user: user.stringValue, path: path.stringValue.isEmpty ? "/" : path.stringValue,
                region: region.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            // Resolve the target by identity, not the captured row index, which can
            // go stale if the list changed while this modeless sheet was open.
            if let existing, let idx = self.connections.firstIndex(where: { $0.id == existing.id }) {
                self.connections[idx] = conn
            } else {
                self.connections.append(conn)
            }
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
