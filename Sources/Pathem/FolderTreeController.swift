import AppKit
import PathemEngine

/// The optional folder tree column between the sidebar and the file panes (Directory Opus'
/// folder tree). Folders only, loaded one level at a time as nodes are expanded, rooted at the
/// home folder (or the volume root for a folder outside it). It reveals the active pane's folder
/// as it navigates, and clicking a folder navigates that pane. Never walks more than the
/// directories that are expanded.
@MainActor
final class FolderTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class Node {
        let url: URL
        let name: String
        var children: [Node]?  // nil until first expanded
        var isReadable = true
        var isLoading = false
        init(url: URL, name: String) {
            self.url = url
            self.name = name
        }
    }

    private final class RowView: NSTableRowView {
        override func drawSelection(in dirtyRect: NSRect) {
            guard isSelected else { return }
            ThemeManager.shared.accent.withAlphaComponent(isEmphasized ? 0.35 : 0.2).setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5
            ).fill()
        }
    }

    /// Paints the themed background through `updateLayer`, so it re-resolves when the
    /// appearance flips (a `cgColor` set once would stay on the old appearance).
    private final class BackgroundView: NSView {
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            layer?.backgroundColor =
                (ThemeManager.shared.sidebarBackground ?? .controlBackgroundColor).cgColor
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }

    let containerView: NSView = BackgroundView()
    private let scrollView = NSScrollView()
    private let outline = NSOutlineView()
    private let separator = NSBox()
    private var root: Node?
    private var generation = 0
    private var suppressSelection = false
    private let home: URL

    /// Called when the user picks a folder in the tree.
    var onSelectFolder: ((URL) -> Void)?
    /// Whether dotfolders are listed (follows the hidden-files preference).
    var includesHidden = false {
        didSet {
            guard oldValue != includesHidden, let root else { return }
            let target = selectedURL
            self.root = Node(url: root.url, name: root.name)
            outline.reloadData()
            if let target { reveal(target) }
        }
    }

    var selectedURL: URL? { (outline.item(atRow: outline.selectedRow) as? Node)?.url }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.setAccessibilityLabel(L("foldertree.accessibility", "Folder tree"))
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.addSubview(scrollView)
        containerView.addSubview(separator)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: containerView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: separator.leadingAnchor),
            separator.topAnchor.constraint(equalTo: containerView.topAnchor),
            separator.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            separator.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
        applyTheme()
        ThemeManager.shared.onChange(owner: self) { [weak self] in self?.applyTheme() }
    }

    private func applyTheme() {
        outline.backgroundColor = .clear
        containerView.needsDisplay = true
        outline.reloadData()
    }

    // MARK: Reveal

    /// Expand the ancestors of `folder` and select it. Loads only the folders along the way.
    func reveal(_ folder: URL) {
        let target = folder.standardizedFileURL
        var needsNewRoot = true
        if let root, FolderTree.revealChain(root: root.url, target: target) != nil {
            needsNewRoot = false
        }
        if needsNewRoot {
            let rootURL = FolderTree.root(for: target, home: home)
            let name =
                rootURL.path == "/"
                ? FileManager.default.displayName(atPath: "/")
                : L("breadcrumb.home", "Home")
            root = Node(url: rootURL, name: name)
            outline.reloadData()
        }
        guard let root, let chain = FolderTree.revealChain(root: root.url, target: target) else {
            return
        }
        if selectedURL == target { return }
        generation += 1
        let token = generation
        Task { @MainActor in
            var node = root
            if outline.row(forItem: node) < 0 { outline.reloadData() }
            for (index, next) in chain.enumerated() {
                guard token == generation else { return }
                if index > 0 {
                    await load(node)
                    guard token == generation else { return }
                    guard let child = node.children?.first(where: { $0.url.path == next.path })
                    else { break }
                    node = child
                }
                if index < chain.count - 1 {
                    await load(node)
                    guard token == generation else { return }
                    outline.expandItem(node)
                }
            }
            guard token == generation else { return }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            suppressSelection = true
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            suppressSelection = false
            outline.scrollRowToVisible(row)
        }
    }

    /// Load one level of subfolders off the main thread, once.
    private func load(_ node: Node) async {
        guard node.children == nil, !node.isLoading else { return }
        node.isLoading = true
        let url = node.url
        let hidden = includesHidden
        let listing = await Task.detached(priority: .userInitiated) {
            FolderTree.subfolders(of: url, includingHidden: hidden)
        }.value
        node.isLoading = false
        node.children = listing.folders.map { Node(url: $0.url, name: $0.name) }
        node.isReadable = listing.isReadable
        outline.reloadItem(node, reloadChildren: true)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return root == nil ? 0 : 1 }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return root as Any }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return node.children.map { !$0.isEmpty } ?? true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        if node.children != nil { return true }
        Task { @MainActor in  // first expand: load, then open
            await load(node)
            if node.children?.isEmpty == false { outlineView.expandItem(node) }
        }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        RowView()
    }

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let node = item as? Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("folderCell")
        let cell =
            outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? makeCell(id)
        cell.textField?.stringValue = node.name
        cell.textField?.textColor = node.isReadable ? .labelColor : .tertiaryLabelColor
        cell.toolTip =
            node.isReadable
            ? node.url.path
            : L("foldertree.unreadable", "Can’t read this folder (no permission)")
        let icon = NSWorkspace.shared.icon(forFile: node.url.path)
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        image.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Selection

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let url = selectedURL else { return }
        onSelectFolder?(url)
    }

    @objc private func rowClicked() {
        // A click on the row that is already selected doesn't change the selection.
        guard outline.clickedRow >= 0, outline.clickedRow == outline.selectedRow,
            let url = selectedURL
        else { return }
        onSelectFolder?(url)
    }

    #if DEBUG
    /// Names of the visible rows with their depth, for tests and renders.
    func debugVisibleRows() -> [String] {
        (0..<outline.numberOfRows).compactMap { row in
            (outline.item(atRow: row) as? Node).map {
                String(repeating: " ", count: outline.level(forRow: row)) + $0.name
            }
        }
    }
    var debugSelectedPath: String? { selectedURL?.path }
    #endif
}
