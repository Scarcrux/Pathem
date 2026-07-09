import AppKit
import PathemEngine

/// Manage saved remote servers: list, add, edit, remove, and import from
/// FileZilla. Connecting/browsing is handled elsewhere (out-of-process); this is
/// the management surface. Persists via `onChange`.
@MainActor
final class ConnectionsController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private let search = NSSearchField()
    /// The live filter text; the table shows only sites matching it (see `displayed`).
    private var filterText = ""
    /// The key-file field of the connection editor currently open, so "Choose…" can fill it.
    private weak var editingKeyFileField: NSTextField?
    private weak var editingLocalPathField: NSTextField?
    private weak var editingHostField: NSTextField?

    /// Common S3-compatible endpoints, so B2 / GCS / Wasabi / Spaces are discoverable. "" = Amazon
    /// (host derived from the region). Regions in the sample hosts are placeholders to edit.
    private static let s3Endpoints: [(name: String, host: String)] = [
        ("Amazon S3", ""),
        ("Backblaze B2", "s3.us-west-002.backblazeb2.com"),
        ("Google Cloud Storage", "storage.googleapis.com"),
        ("Wasabi", "s3.wasabisys.com"),
        ("DigitalOcean Spaces", "nyc3.digitaloceanspaces.com"),
        ("Cloudflare R2", "<accountid>.r2.cloudflarestorage.com"),
    ]
    @objc private func s3EndpointChanged(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem < Self.s3Endpoints.count else { return }
        editingHostField?.stringValue = Self.s3Endpoints[sender.indexOfSelectedItem].host
    }

    var connections: [RemoteConnection] = [] { didSet { table.reloadData() } }

    /// The sites currently shown in the table: all of them, or those matching the
    /// filter (by name, host, user, or protocol). Row actions map back to
    /// `connections` by identity, so a filter never touches the wrong site.
    private var displayed: [RemoteConnection] {
        let q = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return connections }
        return connections.filter {
            $0.name.lowercased().contains(q) || $0.host.lowercased().contains(q)
                || $0.user.lowercased().contains(q) || $0.proto.label.lowercased().contains(q)
        }
    }

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

        search.placeholderString = L("conn.filterPlaceholder", "Filter sites")
        search.translatesAutoresizingMaskIntoConstraints = false
        search.target = self
        search.action = #selector(filterChanged)
        search.sendsWholeSearchString = false  // filter live as the user types

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
        content.addSubview(search)
        content.addSubview(scroll)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
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
                panel.centerOverMainWindow()
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func commit() { onChange?(connections) }

    // MARK: Actions

    @objc private func filterChanged() {
        filterText = search.stringValue
        table.reloadData()
    }

    @objc private func addNew() {
        editConnection(nil)
    }

    @objc private func editSelected() {
        let row = table.selectedRow
        guard row >= 0, row < displayed.count else { return }
        editConnection(displayed[row])
    }

    @objc private func removeSelected() {
        let row = table.selectedRow
        guard row >= 0, row < displayed.count else { return }
        connections.removeAll { $0.id == displayed[row].id }
        commit()
    }

    /// Remove a connection by identity (from the sidebar right-click menu).
    func remove(_ connection: RemoteConnection) {
        connections.removeAll { $0.id == connection.id }
        commit()
    }

    /// Open the edit sheet for a specific connection (the panel must be visible).
    func beginEdit(_ connection: RemoteConnection) {
        // Clear any active filter so the site is visible and its row selectable.
        if !filterText.isEmpty {
            filterText = ""
            search.stringValue = ""
            table.reloadData()
        }
        if let row = displayed.firstIndex(where: { $0.id == connection.id }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        editConnection(connection)
    }

    @objc private func connectSelected() {
        let row = table.selectedRow
        guard row >= 0, row < displayed.count else { return }
        let conn = displayed[row]
        panel.orderOut(nil)
        onConnect?(conn)
    }

    @objc private func closePanel() { panel.orderOut(nil) }

    @objc private func importFileZilla() {
        if let url = FileZillaImporter.defaultSiteManagerURL() {
            merge(FileZillaImporter.importSites(from: url))
        } else {
            // Let the user point at sitemanager.xml. Start in FileZilla's config folder and
            // show hidden files -- it lives in ~/.config/filezilla, which the panel hides by
            // default, so otherwise the user lands in a random folder with no way to reach it.
            let openPanel = NSOpenPanel()
            openPanel.message = L(
                "conn.chooseSiteManager",
                "Choose FileZilla's sitemanager.xml (usually in ~/.config/filezilla). It imports your saved sites, not passwords.")
            openPanel.allowedContentTypes = [.xml]
            openPanel.allowsMultipleSelection = false
            openPanel.showsHiddenFiles = true
            openPanel.directoryURL =
                FileZillaImporter.defaultConfigDirectory()
                ?? FileManager.default.homeDirectoryForCurrentUser
            openPanel.beginSheetModal(for: panel) { [weak self] response in
                guard response == .OK, let url = openPanel.url else { return }
                self?.merge(FileZillaImporter.importSites(from: url))
            }
        }
    }

    /// Add imported sites that aren't already present (by proto+host+port+user).
    private func merge(_ imported: [RemoteConnection]) {
        guard !imported.isEmpty else {
            info(
                L("conn.importEmptyTitle", "No sites found"),
                L("conn.importEmptyBody", "That FileZilla file didn’t contain any sites Pathem could import."))
            return
        }
        func key(_ c: RemoteConnection) -> String { "\(c.proto.rawValue)|\(c.host)|\(c.effectivePort)|\(c.user)" }
        var existing = Set(connections.map(key))
        let before = connections.count
        for site in imported where existing.insert(key(site)).inserted { connections.append(site) }
        let added = connections.count - before
        if added > 0 {
            commit()  // only write when something actually changed
        } else {
            info(
                L("conn.importNoneNewTitle", "Already imported"),
                String(
                    format: L("conn.importNoneNewBody", "All %d site(s) in that file are already in your list."),
                    imported.count))
        }
    }

    /// Show a simple informational sheet over the connections panel.
    private func info(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: L("common.ok", "OK"))
        alert.beginSheetModal(for: panel) { _ in }
    }

    /// Add (row == nil) or edit a connection via a compact form sheet.
    /// Browse for a private key file and fill the editor's Key File field. Starts in ~/.ssh and
    /// shows hidden files (keys live in a dotfolder). Any file may be picked (keys have no
    /// standard extension: .pem, id_ed25519, no extension, ...).
    @objc private func chooseKeyFile() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.showsHiddenFiles = true
        openPanel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        openPanel.prompt = L("conn.chooseKeyPrompt", "Use Key")
        openPanel.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            self?.editingKeyFileField?.stringValue = url.path
        }
    }

    @objc private func chooseLocalPath() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.prompt = L("conn.chooseLocalPrompt", "Choose")
        openPanel.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            self?.editingLocalPathField?.stringValue = url.path
        }
    }

    private func editConnection(_ existing: RemoteConnection?) {
        let alert = NSAlert()
        alert.messageText = existing == nil ? L("conn.newConnectionTitle", "New Connection") : L("conn.editConnectionTitle", "Edit Connection")

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
        let host = field(L("conn.hostPlaceholder", "Host (S3/Azure endpoint; blank = default)"), existing?.host ?? "")
        editingHostField = host
        let s3Endpoint = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        s3Endpoint.addItems(withTitles: Self.s3Endpoints.map(\.name) + [L("conn.s3Other", "Other…")])
        s3Endpoint.target = self
        s3Endpoint.action = #selector(s3EndpointChanged(_:))
        let port = field(L("conn.portPlaceholder", "Port (blank = default)"), existing.map { $0.port == 0 ? "" : "\($0.port)" } ?? "")
        let user = field(L("conn.userPlaceholder", "User (S3 access key / Azure account)"), existing?.user ?? "")
        let path = field(L("conn.pathPlaceholder", "Path (S3 /bucket, Azure /container)"), existing?.path ?? "/")
        let region = field(L("conn.regionPlaceholder", "Region (S3, e.g. us-east-1)"), existing?.region ?? "")
        let keyFile = field(L("conn.keyFilePlaceholder", "SFTP private key (e.g. ~/.ssh/id_ed25519)"), existing?.keyFile ?? "")
        editingKeyFileField = keyFile
        keyFile.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let chooseKey = NSButton(title: L("conn.chooseKey", "Choose…"), target: self, action: #selector(chooseKeyFile))
        chooseKey.bezelStyle = .rounded
        let keyRow = NSStackView(views: [keyFile, chooseKey])
        keyRow.orientation = .horizontal
        keyRow.spacing = 6

        // Per-site color label (a sidebar dot) and default local directory.
        let colorPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        let colorNames = [""] + FileTag.Color.displayOrder.map(\.nameKey)
        colorPopup.addItems(withTitles: [L("conn.colorNone", "None")] + FileTag.Color.displayOrder.map(\.label))
        colorPopup.selectItem(at: max(0, colorNames.firstIndex(of: existing?.colorLabel ?? "") ?? 0))
        let group = field(L("conn.groupPlaceholder", "Group (organizes sites in the sidebar; optional)"), existing?.group ?? "")
        let localPath = field(L("conn.localPathPlaceholder", "Local folder to open on connect (optional)"), existing?.localPath ?? "")
        let chooseLocal = NSButton(title: L("conn.chooseLocal", "Choose…"), target: self, action: #selector(chooseLocalPath))
        chooseLocal.bezelStyle = .rounded
        editingLocalPathField = localPath
        localPath.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let localRow = NSStackView(views: [localPath, chooseLocal])
        localRow.orientation = .horizontal
        localRow.spacing = 6

        let rows = NSStackView(views: [
            labeled(L("conn.protocolLabel", "Protocol"), proto), labeled(L("conn.nameLabel", "Name"), name), labeled(L("conn.hostLabel", "Host"), host),
            labeled(L("conn.portLabel", "Port"), port), labeled(L("conn.userLabel", "User"), user), labeled(L("conn.pathLabel", "Path"), path),
            labeled(L("conn.regionLabel", "Region"), region), labeled(L("conn.s3EndpointLabel", "S3 endpoint"), s3Endpoint),
            labeled(L("conn.keyFileLabel", "Key File"), keyRow),
            labeled(L("conn.colorLabel2", "Color"), colorPopup), labeled(L("conn.groupLabel", "Group"), group),
            labeled(L("conn.localLabel", "Local dir"), localRow),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.frame = NSRect(x: 0, y: 0, width: 360, height: 356)
        alert.accessoryView = rows
        alert.addButton(withTitle: L("common.save", "Save"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))

        guard let window = panel.isVisible ? panel : nil else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let host = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let chosen = RemoteConnection.Proto.allCases[proto.indexOfSelectedItem]
            // S3 and Azure may leave the host blank (S3 derives it from the region,
            // Azure from the account: <account>.blob.core.windows.net); every other
            // protocol needs a valid, non-smuggling host.
            if chosen == .s3 || chosen == .azure {
                if !host.isEmpty, !RemoteConnection.isValidHost(host) { NSSound.beep(); return }
            } else if host.isEmpty || !RemoteConnection.isValidHost(host) {
                NSSound.beep()
                return
            }
            // SFTP interpolates the user into the "user@host" argv token, so it must be
            // a plain login name. Other protocols pass the user via curl's stdin config
            // (safely quoted), where email-style names with "@" are legitimate.
            if chosen == .sftp,
                !RemoteConnection.isValidUser(user.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                NSSound.beep()
                return
            }
            let conn = RemoteConnection(
                id: existing?.id ?? UUID(),
                name: name.stringValue.isEmpty ? (host.isEmpty ? chosen.label : host) : name.stringValue,
                proto: chosen, host: host, port: Int(port.stringValue) ?? 0,
                user: user.stringValue, path: path.stringValue.isEmpty ? "/" : path.stringValue,
                region: region.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                keyFile: keyFile.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                colorLabel: colorNames[colorPopup.indexOfSelectedItem],
                localPath: localPath.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                bookmarks: existing?.bookmarks ?? [],  // edits keep the site's saved bookmarks
                group: group.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
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

    func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? Self.makeCell(id)
        let conn = displayed[row]
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
