import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// An NSOutlineView subclass that offers each key press to a handler (keymap chords) and reports
/// when it becomes first responder, mirroring KeyTableView for the tree view.
final class KeyOutlineView: NSOutlineView {
    var onKeyChord: ((KeyChord) -> Bool)?
    var onBecomeActive: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecomeActive?() }
        return ok
    }
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let chord = KeyChord.from(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
            cmd: flags.contains(.command), opt: flags.contains(.option),
            ctrl: flags.contains(.control), shift: flags.contains(.shift))
        if onKeyChord?(chord) == true { return }
        super.keyDown(with: event)
    }
}

/// The tree / outline view: the current folder as an expandable outline, so a subtree is visible
/// without losing the parent (Directory Opus-style). Folders load their children lazily on expand.
/// Conforms to PaneContentView, so PaneController can swap it in like the list/icon/column views.
@MainActor
final class TreeOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, PaneContentView {
    /// One row: a file entry plus its real URL, with children loaded on demand.
    private final class Node {
        let entry: FileEntry
        let url: URL
        var children: [Node]?  // nil until first expanded
        init(entry: FileEntry, url: URL) {
            self.entry = entry
            self.url = url
        }
        /// A location-aware entry so the pane's file ops resolve to this node's real path.
        var located: FileEntry {
            FileEntry(
                name: entry.name, isDirectory: entry.isDirectory, size: entry.size,
                modificationDate: entry.modificationDate, creationDate: entry.creationDate,
                accessDate: entry.accessDate, isDataless: entry.isDataless,
                location: url.deletingLastPathComponent().path, rawName: entry.rawName)
        }
    }

    let scrollView = NSScrollView()
    private let outline = KeyOutlineView()
    private let placeholder = NSTextField(labelWithString: "")
    private let contextMenu = FileContextMenuController()
    private var roots: [Node] = []
    private var includesHidden = false
    private var fontSize: CGFloat = 13

    var directoryURL: URL?
    var resolutionURL: URL?
    var onOpen: ((FileEntry) -> Void)?
    var onBecomeActive: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onSortChanged: ((ViewFormat.SortKey, Bool) -> Void)?
    var onDropFiles: ((_ urls: [URL], _ move: Bool, _ destination: URL?) -> Void)?
    var onDropOntoFile: ((_ dragged: [URL], _ target: URL) -> Void)?
    var onMouseGesture: ((String) -> Bool)?

    var keyView: NSView { outline }
    var onKeyChord: ((KeyChord) -> Bool)? {
        get { outline.onKeyChord }
        set { outline.onKeyChord = newValue }
    }

    override init() {
        super.init()
        build()
    }

    var entries: [FileEntry] { roots.map(\.entry) }
    var selectedEntries: [FileEntry] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.located }
    }

    func setEntries(_ newEntries: [FileEntry], preserveState: Bool) {
        let expanded = preserveState ? expandedPaths() : []
        let base = directoryURL
        includesHidden = newEntries.contains { $0.name.hasPrefix(".") }
        // On an in-place refresh (a watcher tick), reuse the previous node for any top-level
        // folder whose name and modification date are unchanged, keeping its already-loaded
        // children. Otherwise re-expanding would re-enumerate and re-sort every expanded subtree
        // on every tick (a build writing one file could restat tens of thousands of entries).
        var previous: [String: Node] = [:]
        if preserveState { for node in roots { previous[node.entry.name] = node } }
        roots = newEntries.map { entry in
            if let old = previous[entry.name], old.entry.modificationDate == entry.modificationDate {
                return old
            }
            return Node(entry: entry, url: nodeURL(entry, parent: base))
        }
        outline.reloadData()
        reexpand(expanded)
    }

    func showPlaceholder(_ text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = text == nil
    }

    func select(name: String) {
        guard let index = roots.firstIndex(where: { $0.entry.name == name }) else { return }
        let row = outline.row(forItem: roots[index])
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    func selectNames(_ names: Set<String>) {
        var rows = IndexSet()
        for node in roots where names.contains(node.entry.name) {
            let row = outline.row(forItem: node)
            if row >= 0 { rows.insert(row) }
        }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
    }

    /// Expand the top-level folders with the given names (PATHEM_VIEW_SHOT tree render).
    func debugExpand(names: [String]) {
        for node in roots where names.contains(node.entry.name) {
            outline.expandItem(node)
        }
    }

    func showSortIndicator(key: ViewFormat.SortKey, ascending: Bool) {}  // no sortable header in the tree
    func applyStyle(rowHeight: CGFloat, fontSize: CGFloat, alternatingRows: Bool) {
        self.fontSize = fontSize
        outline.rowHeight = rowHeight
        outline.usesAlternatingRowBackgroundColors = alternatingRows
        outline.reloadData()
    }

    func setBackgroundColor(_ color: NSColor?) {
        let transparent = (color?.alphaComponent ?? 1) < 0.02
        outline.backgroundColor = transparent ? .clear : (color ?? .controlBackgroundColor)
        scrollView.backgroundColor = transparent ? .clear : (color ?? .controlBackgroundColor)
        scrollView.drawsBackground = !transparent
    }

    // MARK: Lazy children

    private func nodeURL(_ entry: FileEntry, parent: URL?) -> URL {
        if let location = entry.location { return URL(fileURLWithPath: location).appendingPathComponent(entry.name) }
        return (parent ?? URL(fileURLWithPath: "/")).appendingPathComponent(entry.name)
    }

    private func loadChildrenIfNeeded(_ node: Node) {
        guard node.children == nil, node.entry.isDirectory else { return }
        let kids = (try? BulkEnumerator().entries(of: node.url, includingHidden: includesHidden)) ?? []
        node.children = kids
            .sorted {
                $0.isDirectory != $1.isDirectory
                    ? $0.isDirectory && !$1.isDirectory
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .map { Node(entry: $0, url: node.url.appendingPathComponent($0.name)) }
    }

    /// The full paths of currently-expanded folders, to restore across an in-place refresh.
    private func expandedPaths() -> Set<String> {
        var paths = Set<String>()
        func walk(_ node: Node) {
            if outline.isItemExpanded(node) { paths.insert(node.url.path); node.children?.forEach(walk) }
        }
        roots.forEach(walk)
        return paths
    }
    private func reexpand(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        func walk(_ node: Node) {
            if paths.contains(node.url.path) {
                outline.expandItem(node)
                node.children?.forEach(walk)
            }
        }
        roots.forEach(walk)
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return roots.count }
        loadChildrenIfNeeded(node)
        return node.children?.count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return roots[index] }
        return node.children![index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.entry.isDirectory ?? false
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? Self.makeCell(id)
        cell.textField?.stringValue = node.entry.name
        let ruleStyle = FileColorStyle.style(for: node.entry, rules: colorRules, baseFont: .systemFont(ofSize: fontSize))
        cell.textField?.font = ruleStyle?.font ?? .systemFont(ofSize: fontSize)
        cell.textField?.textColor = ruleStyle?.color ?? (node.entry.isDataless ? .secondaryLabelColor : .labelColor)
        let baseIcon = FileIconCache.icon(  // kind-cached; bundles (.app) resolved per-file
            for: node.entry, in: node.url.deletingLastPathComponent())
        cell.imageView?.image = CloudBadge.decorate(
            baseIcon, for: node.entry, in: node.url.deletingLastPathComponent())
        cell.alphaValue = node.entry.isHidden ? 0.5 : 1.0
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) { onSelectionChanged?() }

    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        if node.entry.isDirectory {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else {
            onOpen?(node.located)
        }
    }

    func selectionRectInWindow() -> NSRect? {
        let rows = outline.selectedRowIndexes
        guard !rows.isEmpty else { return nil }
        var union = NSRect.null
        for row in rows { union = union.union(outline.rect(ofRow: row)) }
        guard !union.isNull else { return nil }
        let visible = union.intersection(outline.visibleRect)
        guard !visible.isNull, visible.height > 1 else { return nil }
        return outline.convert(visible, to: nil)
    }

    func setHiddenContextItems(_ ids: Set<String>) { contextMenu.hiddenItems = ids }
    func setContextMenuOrder(_ order: [String]) { contextMenu.menuOrder = order }
    private var colorRules = ColorRules()
    func setColorRules(_ rules: ColorRules) {
        guard rules != colorRules else { return }
        colorRules = rules
        outline.reloadData()
    }

    // MARK: Build

    private static func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.imageView = icon
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func build() {
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 20
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = true
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.menu = contextMenu.menu
        outline.autoresizesOutlineColumn = true
        outline.indentationPerLevel = 14
        outline.onBecomeActive = { [weak self] in self?.onBecomeActive?() }
        contextMenu.selectedURLs = { [weak self] in
            (self?.selectedEntries ?? []).compactMap { entry in
                entry.location.map { URL(fileURLWithPath: $0).appendingPathComponent(entry.name) }
            }
        }

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.isHidden = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }
}
