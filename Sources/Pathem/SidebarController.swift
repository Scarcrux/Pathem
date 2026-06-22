import AppKit

/// A Finder-style source list: PLACES (Home, Desktop, Documents, Downloads,
/// Applications) and VOLUMES (mounted, browsable drives). Selecting a row hands
/// its URL to `onSelect`, which the browser routes to the active pane. The view
/// is a translucent sidebar (NSVisualEffectView + source-list NSOutlineView) for
/// the native look, and it refreshes its volumes on mount and unmount.
@MainActor
final class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let containerView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let outline = NSOutlineView()

    var onSelect: ((URL) -> Void)?

    private final class Node {
        let title: String
        let url: URL?
        let isHeader: Bool
        var children: [Node]
        init(title: String, url: URL?, isHeader: Bool, children: [Node] = []) {
            self.title = title
            self.url = url
            self.isHeader = isHeader
            self.children = children
        }
    }
    private var roots: [Node] = []

    override init() {
        super.init()
        build()
        reload()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(
            self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        center.addObserver(
            self, selector: #selector(volumesChanged), name: NSWorkspace.didRenameVolumeNotification, object: nil)
    }

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

        scrollView.documentView = outline
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: containerView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
    }

    func reload() {
        roots = [placesNode(), cloudNode(), volumesNode()].compactMap { $0 }
        outline.reloadData()
        for root in roots { outline.expandItem(root) }
    }

    private func placesNode() -> Node {
        let fm = FileManager.default
        var places: [Node] = []
        func add(_ title: String, _ url: URL?) {
            if let url { places.append(Node(title: title, url: url, isHeader: false)) }
        }
        add("Home", fm.homeDirectoryForCurrentUser)
        add("Desktop", try? fm.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
        add("Documents", try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
        add("Downloads", try? fm.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
        add("Applications", URL(fileURLWithPath: "/Applications"))
        return Node(title: "Places", url: nil, isHeader: true, children: places)
    }

    /// Cloud storage the OS already mounts: iCloud Drive plus third-party File
    /// Providers under ~/Library/CloudStorage. nil when none are present.
    private func cloudNode() -> Node? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var children: [Node] = []

        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) {
            children.append(Node(title: "iCloud Drive", url: iCloud, isHeader: false))
        }

        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        if let urls = try? fm.contentsOfDirectory(
            at: cloudStorage, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        {
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }
                children.append(Node(title: Self.cloudLabel(url.lastPathComponent), url: url, isHeader: false))
            }
        }

        guard !children.isEmpty else { return nil }
        return Node(title: "Cloud", url: nil, isHeader: true, children: children)
    }

    /// "GoogleDrive-me@x.com" -> "Google Drive". Falls back to the raw name.
    static func cloudLabel(_ directoryName: String) -> String {
        let provider = directoryName.split(separator: "-").first.map(String.init) ?? directoryName
        var spaced = ""
        for character in provider {
            if character.isUppercase, !spaced.isEmpty { spaced.append(" ") }
            spaced.append(character)
        }
        return spaced.isEmpty ? directoryName : spaced
    }

    private func volumesNode() -> Node {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
        let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var volumes: [Node] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.volumeIsBrowsable == false { continue }
            volumes.append(Node(title: values?.volumeName ?? url.lastPathComponent, url: url, isHeader: false))
        }
        return Node(title: "Volumes", url: nil, isHeader: true, children: volumes)
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return roots.count }
        return (item as? Node)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.isHeader ?? false
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
            cell.textField?.stringValue = node.title.uppercased()
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("place")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? Self.makePlaceCell(id)
        cell.textField?.stringValue = node.title
        if let url = node.url { cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path) }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node, let url = node.url else { return }
        onSelect?(url)
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
