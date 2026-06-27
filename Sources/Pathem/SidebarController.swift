import AppKit
import PathemEngine

/// A smart (Spotlight-backed) sidebar location that isn't a folder path.
enum SmartQuery: Equatable {
    case recents
    case tag(FileTag.Color)
}

/// A fully customizable Finder-style source list. The user's own groups and
/// shortcuts come from an editable `Sidebar` model (persisted as sidebar.json):
/// drag to reorder within and across groups, rename inline, change a shortcut's
/// SF Symbol icon, and create / rename / delete groups. Below the user groups,
/// CLOUD and VOLUMES are auto-detected (they reflect what's mounted) and are not
/// editable. Selecting a row hands its URL to `onSelect`.
@MainActor
final class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuDelegate, NSTextFieldDelegate
{
    let containerView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let outline = NSOutlineView()

    /// The editable part of the sidebar. Set by the browser after loading, then
    /// kept in sync; every edit calls `onModelChange` so it can be persisted.
    var model = Sidebar(groups: []) {
        didSet { reload() }
    }
    var onModelChange: ((Sidebar) -> Void)?
    var onSelect: ((URL) -> Void)?
    /// Open Settings (the gear shortcut at the bottom of the sidebar).
    var onOpenSettings: (() -> Void)?
    private let settingsButton = NSButton()
    /// When false, sidebar rows show icons only (compact mode); labels are the tooltip.
    private var showsLabels = true
    /// A smart location (Recents / a tag filter) was selected.
    var onSelectSmart: ((SmartQuery) -> Void)?
    /// A discovered shared computer (by display name) was selected.
    var onSelectShared: ((String) -> Void)?
    private var sharedHosts: [String] = []
    /// A saved FTP/SFTP connection was selected (connect to it).
    var onSelectConnection: ((RemoteConnection) -> Void)?
    /// Connect to a saved server in a new tab (from the right-click menu).
    var onConnectConnectionInNewTab: ((RemoteConnection) -> Void)?
    /// Edit a saved server (right-click menu).
    var onEditConnection: ((RemoteConnection) -> Void)?
    /// Forget a saved server's stored Keychain password (right-click menu).
    var onForgetConnection: ((RemoteConnection) -> Void)?
    /// Remove a saved server (right-click menu).
    var onRemoveConnection: ((RemoteConnection) -> Void)?
    /// Eject a mounted volume (right-click menu on a Volumes item).
    var onEjectVolume: ((URL) -> Void)?
    /// Files were dropped onto a folder item (Favorite/Volume/Cloud): move/copy them in.
    var onDropFilesIntoFolder: ((_ urls: [URL], _ folder: URL, _ move: Bool) -> Void)?
    /// Files were dropped onto a Tag: apply that color tag to them.
    var onApplyTag: ((_ urls: [URL], _ color: FileTag.Color) -> Void)?
    /// The AirDrop row was clicked: AirDrop the active pane's current selection.
    var onAirDrop: (() -> Void)?
    /// Files were dropped onto AirDrop: send them with the AirDrop sheet.
    var onAirDropFiles: ((_ urls: [URL]) -> Void)?
    /// Files were dropped onto the Trash: move them to the Trash.
    var onTrashFiles: ((_ urls: [URL]) -> Void)?
    /// The "Manage…" row in the Connections section was selected.
    var onManageConnections: (() -> Void)?
    private var connections: [RemoteConnection] = []
    /// Header keys the user has collapsed, so reload() doesn't re-expand them.
    private var collapsedHeaderKeys: Set<String> = []
    /// True while reload() restores the highlight, to suppress the action callback.
    private var restoringSelection = false

    /// Update the Connections section with the saved servers.
    func setConnections(_ list: [RemoteConnection]) {
        guard list != connections else { return }
        connections = list
        reload()
    }

    /// Update the Shared section with discovered SMB hosts.
    func setSharedHosts(_ hosts: [String]) {
        guard hosts != sharedHosts else { return }
        sharedHosts = hosts
        reload()
    }

    private var devices: [RemoteConnection] = []
    /// Update the Devices section with discovered USB phones (adb / iOS).
    func setDevices(_ found: [RemoteConnection]) {
        let identity: (RemoteConnection) -> String = { "\($0.proto.rawValue):\($0.host):\($0.name)" }
        guard devices.map(identity) != found.map(identity) else { return }
        devices = found
        reload()
    }
    /// Supplies the active pane's folder for "Add Current Folder".
    var currentFolder: (() -> URL?)?

    private static let itemType = NSPasteboard.PasteboardType("com.scarcrux.pathem.sidebar-item")
    private static let groupType = NSPasteboard.PasteboardType("com.scarcrux.pathem.sidebar-group")

    private static let iconChoices = [
        "house", "folder", "doc", "doc.text", "star", "heart", "flag", "tag",
        "bookmark", "tray.full", "archivebox", "music.note", "photo", "film",
        "hammer", "terminal", "gearshape", "cloud", "externaldrive",
        "square.grid.2x2", "briefcase", "book", "paintbrush", "cube", "network",
        "desktopcomputer", "laptopcomputer", "arrow.down.circle",
    ]

    private enum Kind {
        case userGroup(UUID)
        case userItem(UUID)
        case systemHeader
        case systemItem
        case folderChild  // a lazily-loaded subfolder of an expandable location
        case smart(SmartQuery)  // Recents / a tag filter (Spotlight-backed)
        case airdrop  // AirDrop send sheet (no filesystem path)
        case trash  // the user's Trash (navigable; drops trash the items)
        case shared(String)  // a discovered SMB host (by display name)
        case connection(RemoteConnection)  // a saved FTP/SFTP server
        case device(RemoteConnection)  // a discovered USB phone (adb / iOS)
        case manageConnections  // the "Manage…" row
    }

    private final class Node {
        let kind: Kind
        let title: String
        let url: URL?
        let icon: String?  // SF Symbol for user items
        /// A folder location can be expanded to reveal its subfolders.
        let isFolder: Bool
        /// A colored dot icon for a tag-filter row.
        let tagColor: FileTag.Color?
        var children: [Node]
        /// Subfolders are loaded lazily the first time the node is expanded.
        var childrenLoaded = false
        init(
            kind: Kind, title: String, url: URL?, icon: String?, isFolder: Bool = false,
            tagColor: FileTag.Color? = nil, children: [Node] = []
        ) {
            self.kind = kind
            self.title = title
            self.url = url
            self.icon = icon
            self.isFolder = isFolder
            self.tagColor = tagColor
            self.children = children
        }
        var isHeader: Bool {
            switch kind {
            case .userGroup, .systemHeader: return true
            default: return false
            }
        }
        var isEditable: Bool {
            switch kind {
            case .userGroup, .userItem: return true
            default: return false
            }
        }
    }
    private var roots: [Node] = []

    /// The node a context-menu action targets (set when the menu opens).
    private weak var menuTargetNode: Node?
    /// The node currently being renamed inline.
    private weak var editing: Node?

    override init() {
        super.init()
        build()
        reload()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
        }
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func volumesChanged() { reload() }

    private func build() {
        containerView.material = .sidebar
        containerView.blendingMode = .behindWindow

        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([Self.itemType, Self.groupType, .fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scrollView.documentView = outline
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true  // no scroller when the content fits
        scrollView.scrollerStyle = .overlay  // overlay scrollers don't steal width (no clipping)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        settingsButton.bezelStyle = .texturedRounded
        settingsButton.isBordered = false
        settingsButton.font = .systemFont(ofSize: 12)
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.toolTip = L("sidebar.settingsTooltip", "Settings")
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        configureSettingsButton()

        containerView.addSubview(scrollView)
        containerView.addSubview(settingsButton)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: containerView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -2),
            settingsButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
            settingsButton.trailingAnchor.constraint(
                lessThanOrEqualTo: containerView.trailingAnchor, constant: -8),
            settingsButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -6),
            settingsButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    /// The Settings button shows a "Settings" label like every other sidebar row,
    /// or just the gear when labels are hidden (compact mode).
    private func configureSettingsButton() {
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L("sidebar.settingsAccessibility", "Settings"))
        if showsLabels {
            settingsButton.title = L("sidebar.settingsTitle", "Settings")
            settingsButton.imagePosition = .imageLeading
        } else {
            settingsButton.title = ""
            settingsButton.imagePosition = .imageOnly
        }
    }

    /// Hide row labels (icons only) for a compact sidebar, or show them.
    func setShowsLabels(_ on: Bool) {
        guard on != showsLabels else { return }
        showsLabels = on
        configureSettingsButton()
        outline.reloadData()
    }

    @objc private func openSettings() { onOpenSettings?() }

    // MARK: Build the tree

    func reload() {
        // Nodes are rebuilt every reload, so remember the selection and per-header
        // collapse state by a stable key and restore them afterwards. Otherwise a
        // volume/connection change would clear the highlight and re-open sections
        // the user had collapsed.
        let selectedKey = (outline.item(atRow: outline.selectedRow) as? Node).map(Self.key)

        roots = model.groups.map { group in
            Node(
                kind: .userGroup(group.id), title: group.title, url: nil, icon: nil,
                children: group.items.map {
                    let url = URL(fileURLWithPath: $0.path)
                    // Favorites are not expandable (like Finder): a disclosure triangle
                    // and drag-hover spring-loading would fight dropping a new favorite
                    // between existing ones. Drilling stays on the Cloud/Volumes sections.
                    return Node(kind: .userItem($0.id), title: $0.name, url: url, icon: $0.icon)
                })
        }
        roots.append(locationsNode())
        if let cloud = cloudNode() { roots.append(cloud) }
        roots.append(volumesNode())
        if let devicesSection = devicesNode() { roots.append(devicesSection) }
        if let shared = sharedNode() { roots.append(shared) }
        roots.append(connectionsNode())
        roots.append(smartNode())
        roots.append(tagsNode())
        outline.reloadData()
        for root in roots where !collapsedHeaderKeys.contains(Self.key(root)) { outline.expandItem(root) }

        if let selectedKey, let row = rowForKey(selectedKey) {
            restoringSelection = true  // restore the highlight without re-firing the action
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            restoringSelection = false
        }
    }

    /// A stable identity for a node across rebuilds (used to restore selection and
    /// collapse state in reload()).
    private static func key(_ node: Node) -> String {
        switch node.kind {
        case .userGroup(let id): return "group:\(id)"
        case .userItem(let id): return "item:\(id)"
        case .systemHeader: return "header:\(node.title)"
        case .systemItem: return "system:\(node.title):\(node.url?.path ?? "")"
        case .folderChild: return "folder:\(node.url?.path ?? "")"
        case .smart(let query): return "smart:\(query)"
        case .airdrop: return "airdrop"
        case .trash: return "trash"
        case .shared(let host): return "shared:\(host)"
        case .connection(let connection): return "conn:\(connection.id)"
        case .device(let device): return "device:\(device.proto.rawValue):\(device.host)"
        case .manageConnections: return "manage"
        }
    }

    private func rowForKey(_ wanted: String) -> Int? {
        for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? Node).map(Self.key) == wanted {
            return row
        }
        return nil
    }

    /// Saved FTP/SFTP servers, always shown (with a Manage… row) so connections
    /// are discoverable; click a server to connect.
    private func connectionsNode() -> Node {
        var children = connections.map { connection in
            Node(kind: .connection(connection), title: connection.name, url: nil, icon: "network")
        }
        children.append(
            Node(
                kind: .manageConnections, title: connections.isEmpty ? L("sidebar.addConnection", "Add Connection…") : L("sidebar.manage", "Manage…"),
                url: nil, icon: "plus.circle"))
        return Node(kind: .systemHeader, title: L("sidebar.connectionsHeader", "Connections"), url: nil, icon: nil, children: children)
    }

    /// Discovered SMB computers on the local network (nil when none seen yet).
    private func devicesNode() -> Node? {
        guard !devices.isEmpty else { return nil }
        let children = devices.map { device in
            Node(
                kind: .device(device), title: device.name, url: nil,
                icon: device.proto == .adb ? "smartphone" : "iphone")
        }
        return Node(
            kind: .systemHeader, title: L("sidebar.devicesHeader", "Devices"), url: nil, icon: nil,
            children: children)
    }

    private func sharedNode() -> Node? {
        guard !sharedHosts.isEmpty else { return nil }
        let children = sharedHosts.map { host in
            Node(kind: .shared(host), title: host, url: nil, icon: "desktopcomputer")
        }
        return Node(kind: .systemHeader, title: L("sidebar.sharedHeader", "Shared"), url: nil, icon: nil, children: children)
    }

    /// AirDrop (a send sheet) and the Trash. AirDrop has no path; the Trash is a
    /// real folder you can browse, but dropping onto it trashes the items.
    private func locationsNode() -> Node {
        let airdrop = Node(
            kind: .airdrop, title: L("sidebar.airdrop", "AirDrop"), url: nil,
            icon: "dot.radiowaves.left.and.right")
        let trashURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let trash = Node(kind: .trash, title: L("sidebar.trash", "Trash"), url: trashURL, icon: nil)
        return Node(
            kind: .systemHeader, title: L("sidebar.locationsHeader", "Locations"), url: nil, icon: nil,
            children: [airdrop, trash])
    }

    /// Spotlight-backed smart locations (currently Recents).
    private func smartNode() -> Node {
        let recents = Node(kind: .smart(.recents), title: L("sidebar.recents", "Recents"), url: nil, icon: "clock")
        return Node(kind: .systemHeader, title: L("sidebar.smartHeader", "Smart"), url: nil, icon: nil, children: [recents])
    }

    /// The seven Finder tag colors; selecting one filters to files with that tag.
    private func tagsNode() -> Node {
        let children = FileTag.Color.displayOrder.map { color in
            Node(kind: .smart(.tag(color)), title: color.label, url: nil, icon: nil, tagColor: color)
        }
        return Node(kind: .systemHeader, title: L("sidebar.tagsHeader", "Tags"), url: nil, icon: nil, children: children)
    }

    /// Cloud storage the OS already mounts. nil when none are present.
    private func cloudNode() -> Node? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var children: [Node] = []

        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) {
            children.append(Node(kind: .systemItem, title: L("sidebar.iCloudDrive", "iCloud Drive"), url: iCloud, icon: nil, isFolder: true))
        }
        // Modern Dropbox/Google Drive/OneDrive/Box etc. mount here via the File Provider.
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        if let urls = try? fm.contentsOfDirectory(
            at: cloudStorage, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        {
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }
                // iCloud is already listed from Mobile Documents above; don't list it twice.
                if url.lastPathComponent.hasPrefix("iCloudDrive") { continue }
                children.append(Node(kind: .systemItem, title: Self.cloudLabel(url.lastPathComponent), url: url, icon: nil, isFolder: true))
            }
        }
        // Legacy/home-level cloud folders not under CloudStorage (older Dropbox, OneDrive,
        // Google Drive). Skip any whose provider is already listed above.
        let alreadyHasProvider: (String) -> Bool = { keyword in
            children.contains { $0.title.range(of: keyword, options: .caseInsensitive) != nil }
        }
        var legacy: [(name: String, folder: String, keyword: String)] = [
            ("Dropbox", "Dropbox", "Dropbox"), ("Google Drive", "Google Drive", "Google Drive"),
        ]
        // OneDrive home folders are "OneDrive", "OneDrive - Personal", "OneDrive - <Org>".
        if let homeChildren = try? fm.contentsOfDirectory(atPath: home.path) {
            for name in homeChildren.sorted() where name == "OneDrive" || name.hasPrefix("OneDrive -") {
                legacy.append((name, name, "OneDrive"))
            }
        }
        for entry in legacy {
            let url = home.appendingPathComponent(entry.folder)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                !alreadyHasProvider(entry.keyword)
            else { continue }
            children.append(Node(kind: .systemItem, title: entry.name, url: url, icon: nil, isFolder: true))
        }
        guard !children.isEmpty else { return nil }
        return Node(kind: .systemHeader, title: L("sidebar.cloudHeader", "Cloud"), url: nil, icon: nil, children: children)
    }

    private static let knownProviders = [
        "GoogleDrive": "Google Drive", "iCloudDrive": "iCloud Drive", "OneDrive": "OneDrive",
        "Dropbox": "Dropbox", "Box": "Box", "pCloud": "pCloud", "ProtonDrive": "Proton Drive",
    ]

    /// "GoogleDrive-me@x.com" -> "Google Drive (me@x.com)". CloudStorage folders
    /// are "Provider-Account"; the account (after the first "-") is shown in
    /// parentheses so multiple accounts of the same provider are distinguishable.
    static func cloudLabel(_ directoryName: String) -> String {
        let parts = directoryName.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let providerRaw = String(parts.first ?? "")
        let account = parts.count > 1 ? String(parts[1]) : ""
        let provider = knownProviders[providerRaw] ?? spacedCamelCase(providerRaw)
        let base = provider.isEmpty ? directoryName : provider
        // Drop an account that just repeats the provider (e.g. "iCloudDrive (date)").
        if account.isEmpty || account.hasPrefix(providerRaw) { return base }
        return "\(base) (\(account))"
    }

    /// "GoogleDrive" -> "Google Drive".
    private static func spacedCamelCase(_ text: String) -> String {
        var spaced = ""
        for character in text {
            if character.isUppercase, !spaced.isEmpty { spaced.append(" ") }
            spaced.append(character)
        }
        return spaced
    }

    private func volumesNode() -> Node {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
        let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var volumes: [Node] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.volumeIsBrowsable == false { continue }
            volumes.append(Node(kind: .systemItem, title: values?.volumeName ?? url.lastPathComponent, url: url, icon: nil, isFolder: true))
        }
        return Node(kind: .systemHeader, title: L("sidebar.volumesHeader", "Volumes"), url: nil, icon: nil, children: volumes)
    }

    // MARK: Mutation

    private func mutate(_ change: (inout Sidebar) -> Void) {
        var copy = model
        change(&copy)
        model = copy  // didSet calls reload()
        onModelChange?(model)
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return roots.count }
        if node.isFolder { loadChildrenIfNeeded(node) }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return roots[index] }
        if node.isFolder { loadChildrenIfNeeded(node) }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return node.isHeader || node.isFolder  // folders expand to their subfolders
    }

    /// Lazily list a folder node's subfolders (directories only, sorted) the first
    /// time it's expanded. The directory read runs off the main thread so a large
    /// or slow (cloud/network) folder never freezes the UI; children appear when
    /// it finishes.
    private func loadChildrenIfNeeded(_ node: Node) {
        guard node.isFolder, !node.childrenLoaded, let url = node.url else { return }
        node.childrenLoaded = true
        Task { [weak self, weak node] in
            let dirs = await Self.subfolders(of: url)  // runs off the main actor
            guard let self, let node else { return }
            node.children = dirs.map {
                Node(kind: .folderChild, title: $0.lastPathComponent, url: $0, icon: nil, isFolder: true)
            }
            self.outline.reloadItem(node, reloadChildren: true)
            if !node.children.isEmpty { self.outline.expandItem(node) }
        }
    }

    /// Reset a folder's lazy state when it collapses, so re-expanding re-reads it
    /// (otherwise its subfolders would be frozen for the node's lifetime).
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? Node else { return }
        if node.isHeader {
            collapsedHeaderKeys.insert(Self.key(node))  // remember it stays closed across reloads
            return
        }
        if node.isFolder {
            node.childrenLoaded = false
            node.children = []
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? Node, node.isHeader else { return }
        collapsedHeaderKeys.remove(Self.key(node))
    }

    /// Subfolders of a directory, off the main actor. nonisolated + async means an
    /// `await` from the main actor runs this on the cooperative pool.
    nonisolated private static func subfolders(of url: URL) async -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return
            contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }


    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Node)?.isHeader ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? Node)?.isHeader ?? false)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        if node.isHeader {
            let id = NSUserInterfaceItemIdentifier("header")
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? Self.makeHeaderCell(id)
            cell.textField?.stringValue = showsLabels ? node.title : ""
            cell.textField?.isEditable = node.isEditable
            cell.textField?.delegate = self
            cell.toolTip = node.title
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("place")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? Self.makePlaceCell(id)
        cell.textField?.stringValue = showsLabels ? node.title : ""  // compact: icons only
        cell.textField?.isEditable = node.isEditable
        cell.textField?.delegate = self
        cell.toolTip = node.title  // name on hover when compact
        if let tagColor = node.tagColor {
            cell.imageView?.image = TagColors.dot(tagColor, diameter: 12)
            cell.imageView?.contentTintColor = nil
        } else if let icon = node.icon {
            cell.imageView?.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            cell.imageView?.contentTintColor = nil
        } else if let url = node.url {
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !restoringSelection else { return }  // reload() is just restoring the highlight
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        if case .smart(let query) = node.kind {
            onSelectSmart?(query)
            return
        }
        if case .shared(let host) = node.kind {
            outline.deselectRow(row)  // a mount action; re-clicking should retry, not no-op
            onSelectShared?(host)
            return
        }
        if case .connection(let connection) = node.kind {
            outline.deselectRow(row)  // a connect action, not a persistent selection
            onSelectConnection?(connection)
            return
        }
        if case .device(let device) = node.kind {
            outline.deselectRow(row)  // a connect action, not a persistent selection
            onSelectConnection?(device)  // devices browse through the same provider seam
            return
        }
        if case .manageConnections = node.kind {
            outline.deselectRow(row)
            onManageConnections?()
            return
        }
        if case .airdrop = node.kind {
            outline.deselectRow(row)  // an action (share the selection), not a persistent location
            onAirDrop?()
            return
        }
        guard let url = node.url else { return }
        onSelect?(url)
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? Node else { return nil }
        let pb = NSPasteboardItem()
        switch node.kind {
        case .userItem(let id): pb.setString(id.uuidString, forType: Self.itemType)
        case .userGroup(let id): pb.setString(id.uuidString, forType: Self.groupType)
        default: return nil
        }
        return pb
    }

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
        proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        let pb = info.draggingPasteboard
        // Reordering a user shortcut: destination must be a user group.
        if pb.availableType(from: [Self.itemType]) != nil {
            if let group = item as? Node, case .userGroup = group.kind { return .move }
            return []
        }
        // Reordering a user group: only at the root, among the user groups.
        if pb.availableType(from: [Self.groupType]) != nil {
            if item == nil, index >= 0, index <= model.groups.count { return .move }
            return []
        }
        // Dropping files from a pane onto a folder item moves/copies them in; onto a Tag
        // applies that tag. Both require dropping ON the item, not between rows.
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
            let node = item as? Node, index == NSOutlineViewDropOnItemIndex
        {
            if case .smart(.tag) = node.kind { return .copy }  // apply tag
            if case .airdrop = node.kind { return .copy }  // send via AirDrop
            if case .trash = node.kind { return .move }  // always trashes, regardless of Command
            if let url = node.url, Self.isDirectory(url) { return Self.dropOperationForEvent() }
        }
        // Dropping folders from a pane: add them to a user group as shortcuts,
        // either into the group or between/onto existing favorites.
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            if let group = item as? Node, case .userGroup = group.kind { return .copy }
            // Dropped onto/near a favorite: retarget into its group at that slot so
            // the new favorite lands between favorites instead of being rejected.
            if let node = item as? Node, case let .userItem(id) = node.kind, let at = model.locate(id) {
                let slot = index == NSOutlineViewDropOnItemIndex ? at.item + 1 : at.item
                outlineView.setDropItem(roots[at.group], dropChildIndex: slot)
                return .copy
            }
            return []
        }
        return []
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
    static func dropOperationForEvent() -> NSDragOperation {
        NSApp.currentEvent?.modifierFlags.contains(.command) == true ? .move : .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int
    ) -> Bool {
        let pb = info.draggingPasteboard
        // Files onto a folder item (move/copy in) or a Tag (apply), when dropped ON it.
        if index == NSOutlineViewDropOnItemIndex, let node = item as? Node,
            let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty
        {
            if case .smart(.tag(let color)) = node.kind {
                onApplyTag?(urls, color)
                return true
            }
            if case .airdrop = node.kind {
                onAirDropFiles?(urls)
                return true
            }
            if case .trash = node.kind {
                onTrashFiles?(urls)
                return true
            }
            if let url = node.url, Self.isDirectory(url) {
                onDropFilesIntoFolder?(urls, url, Self.dropOperationForEvent() == .move)
                return true
            }
        }
        if let str = pb.string(forType: Self.itemType), let id = UUID(uuidString: str),
            let group = item as? Node, case let .userGroup(gid) = group.kind
        {
            let count = model.groups.first { $0.id == gid }?.items.count ?? 0
            let target = index < 0 ? count : index
            mutate { $0.moveItem(id, toGroup: gid, at: target) }
            return true
        }
        if let str = pb.string(forType: Self.groupType), let id = UUID(uuidString: str), item == nil {
            let target = min(max(index, 0), model.groups.count)
            mutate { $0.moveGroup(id, to: target) }
            return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            let group = item as? Node, case let .userGroup(gid) = group.kind
        {
            let count = model.groups.first { $0.id == gid }?.items.count ?? 0
            let start = index < 0 ? count : min(index, count)
            mutate { s in
                for (offset, url) in urls.enumerated() {
                    s.insertItem(
                        Sidebar.Item(name: url.lastPathComponent, icon: "folder", path: url.path),
                        toGroup: gid, at: start + offset)  // land where dropped, not appended
                }
            }
            return true
        }
        return false
    }

    // MARK: Inline rename

    private func beginRename(_ node: Node?) {
        guard let node, node.isEditable else { return }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        editing = node
        outline.editColumn(0, row: row, with: nil, select: true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let node = editing, let field = obj.object as? NSTextField else { return }
        editing = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { reload(); return }
        // Defer so the field editor finishes tearing down before we reload.
        DispatchQueue.main.async { [weak self] in
            switch node.kind {
            case .userItem(let id): self?.mutate { $0.renameItem(id, to: name) }
            case .userGroup(let id): self?.mutate { $0.renameGroup(id, to: name) }
            default: break
            }
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let node = outline.item(atRow: outline.clickedRow) as? Node
        menuTargetNode = node

        func add(_ title: String, _ selector: Selector) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        if let node {
            switch node.kind {
            case .userItem:
                add(L("sidebar.rename", "Rename"), #selector(renameTarget))
                menu.addItem(iconSubmenuItem())
                add(L("sidebar.removeFromSidebar", "Remove from Sidebar"), #selector(removeTarget))
                menu.addItem(.separator())
            case .userGroup:
                add(L("sidebar.renameGroup", "Rename Group"), #selector(renameTarget))
                add(L("sidebar.removeGroup", "Remove Group"), #selector(removeTarget))
                menu.addItem(.separator())
            case .connection:
                add(L("sidebar.connect", "Connect"), #selector(connectTarget))
                add(L("sidebar.connectInNewTab", "Connect in New Tab"), #selector(connectInNewTabTarget))
                menu.addItem(.separator())
                add(L("common.edit", "Edit…"), #selector(editConnectionTarget))
                add(L("sidebar.forgetPassword", "Forget Password"), #selector(forgetConnectionTarget))
                add(L("common.remove", "Remove"), #selector(removeConnectionTarget))
                return  // connection-only menu (no New Group / Add Current Folder)
            case .manageConnections:
                add(connections.isEmpty ? L("sidebar.addConnection", "Add Connection…") : L("sidebar.manage", "Manage…"), #selector(manageConnectionsTarget))
                return
            case .systemItem:
                if let url = node.url, url.path.hasPrefix("/Volumes/") {
                    add(L("sidebar.eject", "Eject"), #selector(ejectTarget))
                    menu.addItem(.separator())
                }
            default:
                break
            }
        }
        add(L("sidebar.newGroup", "New Group"), #selector(newGroup))
        if currentFolder?() != nil {
            add(L("sidebar.addCurrentFolder", "Add Current Folder"), #selector(addCurrentFolder))
        }
    }

    private func targetConnection() -> RemoteConnection? {
        guard let node = menuTargetNode, case let .connection(connection) = node.kind else { return nil }
        return connection
    }

    @objc private func connectTarget() { targetConnection().map { onSelectConnection?($0) } }
    @objc private func connectInNewTabTarget() { targetConnection().map { onConnectConnectionInNewTab?($0) } }
    @objc private func editConnectionTarget() { targetConnection().map { onEditConnection?($0) } }
    @objc private func forgetConnectionTarget() { targetConnection().map { onForgetConnection?($0) } }
    @objc private func removeConnectionTarget() { targetConnection().map { onRemoveConnection?($0) } }
    @objc private func manageConnectionsTarget() { onManageConnections?() }
    @objc private func ejectTarget() {
        if let url = menuTargetNode?.url { onEjectVolume?(url) }
    }

    private func iconSubmenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: L("sidebar.changeIcon", "Change Icon"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for symbol in Self.iconChoices {
            let item = NSMenuItem(title: symbol, action: #selector(pickIcon(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = symbol
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let custom = NSMenuItem(title: L("sidebar.otherIcon", "Other…"), action: #selector(customIcon), keyEquivalent: "")
        custom.target = self
        submenu.addItem(custom)
        parent.submenu = submenu
        return parent
    }

    @objc private func renameTarget() { beginRename(menuTargetNode) }

    @objc private func removeTarget() {
        guard let node = menuTargetNode else { return }
        switch node.kind {
        case .userItem(let id): mutate { $0.removeItem(id) }
        case .userGroup(let id): mutate { $0.removeGroup(id) }
        default: break
        }
    }

    @objc private func pickIcon(_ sender: NSMenuItem) {
        guard let symbol = sender.representedObject as? String,
            let node = menuTargetNode, case let .userItem(id) = node.kind
        else { return }
        mutate { $0.setIcon(id, to: symbol) }
    }

    @objc private func customIcon() {
        guard let node = menuTargetNode, case let .userItem(id) = node.kind else { return }
        let alert = NSAlert()
        alert.messageText = L("sidebar.sfSymbolNameTitle", "SF Symbol name")
        alert.informativeText = L("sidebar.sfSymbolNameBody", "Enter any SF Symbol name (for example, \"flame\" or \"folder.badge.gearshape\").")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L("sidebar.setButton", "Set"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        if let window = containerView.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                let symbol = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil else {
                    NSSound.beep()  // not a valid SF Symbol name
                    return
                }
                self?.mutate { $0.setIcon(id, to: symbol) }
            }
        }
    }

    @objc private func newGroup() {
        var newID: UUID?
        mutate { newID = $0.addGroup(title: L("sidebar.newGroupDefaultName", "New Group")) }
        guard let newID,
            let node = roots.first(where: { if case let .userGroup(g) = $0.kind { return g == newID }; return false })
        else { return }
        beginRename(node)
    }

    @objc private func addCurrentFolder() {
        guard let url = currentFolder?() else { return }
        let targetGroup = resolveGroupID(for: menuTargetNode)
        mutate { s in
            let gid: UUID
            if let targetGroup, s.groupIndex(targetGroup) != nil { gid = targetGroup }
            else if let first = s.groups.first { gid = first.id }
            else { gid = s.addGroup(title: L("sidebar.favoritesDefaultName", "Favorites")) }
            s.addItem(Sidebar.Item(name: url.lastPathComponent, icon: "folder", path: url.path), toGroup: gid)
        }
    }

    private func resolveGroupID(for node: Node?) -> UUID? {
        guard let node else { return nil }
        switch node.kind {
        case .userGroup(let id): return id
        case .userItem(let id): return model.locate(id).map { model.groups[$0.group].id }
        default: return nil
        }
    }

    // MARK: Cells

    private static func makeHeaderCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = .secondaryLabelColor
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private static func makePlaceCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: 13)
        cell.addSubview(icon)
        cell.addSubview(field)
        cell.imageView = icon
        cell.textField = field
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
