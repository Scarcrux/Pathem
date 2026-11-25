import AppKit
import PathemEngine

/// The optional folder tree column between the sidebar and the file panes (Directory Opus'
/// folder tree). Folders only, loaded one level at a time as nodes are expanded. The roots are
/// Home, each mounted volume and the folders the user pinned. It reveals the active pane's
/// folder as it navigates, marks where each pane is, accepts file drops onto its folders, and
/// remembers which folders were expanded. Clicking a folder navigates the active pane. Never
/// walks more than the directories that are expanded.
@MainActor
final class FolderTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuDelegate
{
    private final class Node {
        let url: URL
        let name: String
        let rootKind: FolderTree.Root.Kind?  // nil for a folder inside a root
        var children: [Node]?  // nil until first expanded
        var isReadable = true
        var loading: Task<Void, Never>?
        init(url: URL, name: String, rootKind: FolderTree.Root.Kind? = nil) {
            self.url = url
            self.name = name
            self.rootKind = rootKind
        }
    }

    /// Where one pane is, drawn as a small marker on its folder's row.
    struct PaneMark: Equatable {
        /// 0 for the left (or top) pane, 1 for the right (or bottom) pane.
        let slot: Int
        let url: URL
        let isActive: Bool
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
        var onLayout: (() -> Void)?
        override func layout() {
            super.layout()
            onLayout?()
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
    private var roots: [Node] = []
    private var generation = 0
    private var suppressSelection = false
    private var restoringExpansion = false
    private let home: URL
    private let volumes: () -> [(url: URL, name: String)]
    private var paneMarks: [PaneMark] = []
    private var markedNodes: [ObjectIdentifier: [PaneMark]] = [:]
    private var stacked = false

    /// The persisted pins and expansion. Set through `restore(_:)`; changes are reported to
    /// `onStateChange` so the owner can save them.
    private(set) var state = FolderTreeState()
    var onStateChange: ((FolderTreeState) -> Void)?
    /// Called when the user picks a folder in the tree.
    var onSelectFolder: ((URL) -> Void)?
    /// Files were dropped onto a tree folder: the same hook the sidebar's folders use.
    var onDropFiles: ((_ urls: [URL], _ folder: URL, _ move: Bool) -> Void)?
    /// Whether a plain drop moves (true) or copies; Command inverts it, like every drop target.
    var dragMovesByDefault = true
    /// Whether dotfolders are listed (follows the hidden-files preference).
    var includesHidden = false {
        didSet {
            guard oldValue != includesHidden, !roots.isEmpty else { return }
            let target = selectedURL
            roots = roots.map { Node(url: $0.url, name: $0.name, rootKind: $0.rootKind) }
            outline.reloadData()
            if let target { reveal(target) }
        }
    }

    var selectedURL: URL? { (outline.item(atRow: outline.selectedRow) as? Node)?.url }

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        volumes: @escaping () -> [(url: URL, name: String)] = FolderTreeController.mountedVolumes
    ) {
        self.home = home.standardizedFileURL
        self.volumes = volumes
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
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
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
        (containerView as? BackgroundView)?.onLayout = { [weak self] in self?.fitColumn() }
        applyTheme()
        ThemeManager.shared.onChange(owner: self) { [weak self] in self?.applyTheme() }
        rebuildRoots()
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(volumesChanged), name: name, object: nil)
        }
    }

    /// Browsable mounted volumes (the boot volume included), named like the sidebar names them.
    nonisolated static func mountedVolumes() -> [(url: URL, name: String)] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.volumeIsBrowsable == false { return nil }
            return (url, values?.volumeName ?? url.lastPathComponent)
        }
    }

    /// Keep the one column exactly as wide as the visible area, so trailing markers never sit
    /// past the clip edge (the outline otherwise grows wider than its scroll view).
    private func fitColumn() {
        let width = scrollView.contentSize.width
        guard width > 40, let column = outline.tableColumns.first, column.width != width else {
            return
        }
        column.minWidth = 40
        column.maxWidth = width
        column.width = width
    }

    @objc private func volumesChanged() { rebuildRoots() }

    // MARK: Roots, pins and persisted state

    /// Recompute the roots from Home, the mounted volumes and the pins. A root that is still
    /// there keeps its loaded folders.
    func rebuildRoots() {
        let existing = Dictionary(
            roots.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        let list = FolderTree.roots(
            home: home, homeName: L("breadcrumb.home", "Home"),
            volumes: volumes().map { (url: $0.url, name: $0.name) },
            pinned: state.pinned.map { URL(fileURLWithPath: $0, isDirectory: true) },
            pinnedName: { FileManager.default.displayName(atPath: $0.path) })
        let selected = selectedURL
        roots = list.map {
            if let node = existing[$0.url.path], node.rootKind == $0.kind { return node }
            return Node(url: $0.url, name: $0.name, rootKind: $0.kind)
        }
        outline.reloadData()
        // A pin can take over a folder the tree showed under Home (the deepest root wins), so
        // move the selection and the markers to match.
        if let selected { reveal(selected, force: true) }
        markedNodes = [:]
        refreshMarks()
    }

    /// Apply persisted pins and expansion (at launch), then reopen the remembered folders.
    func restore(_ saved: FolderTreeState) {
        state = saved
        rebuildRoots()
        restoreExpansion()
    }

    /// Reopen the remembered folders, shallowest first, loading one level each off the main
    /// thread. A folder that no longer exists is dropped from the saved state.
    private func restoreExpansion() {
        let urls = state.expandedShallowFirst
        Task { @MainActor in
            var stale: [URL] = []
            for url in urls {
                guard let node = existingNode(for: url) else { continue }
                await load(node)
                if node.children?.isEmpty == false {
                    restoringExpansion = true
                    outline.expandItem(node)
                    restoringExpansion = false
                } else if !node.isReadable || !FileManager.default.fileExists(atPath: url.path) {
                    stale.append(url)
                }
            }
            if !stale.isEmpty {
                for url in stale { state.setExpanded(url, false) }
                onStateChange?(state)
            }
            refreshMarks()
        }
    }

    private func updateState(_ change: (inout FolderTreeState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        onStateChange?(state)
    }

    func isPinned(_ url: URL) -> Bool { state.isPinned(url) }

    func pin(_ url: URL) {
        updateState { $0.pin(url) }
        rebuildRoots()
    }

    func unpin(_ url: URL) {
        updateState { $0.unpin(url) }
        rebuildRoots()
    }

    /// The loaded node for `url`, found by walking down from its root through loaded folders.
    private func existingNode(for url: URL) -> Node? {
        guard let index = FolderTree.rootIndex(containing: url, in: rootList),
            let chain = FolderTree.revealChain(root: roots[index].url, target: url)
        else { return nil }
        var node = roots[index]
        for next in chain.dropFirst() {
            guard let child = node.children?.first(where: { $0.url.path == next.path }) else {
                return nil
            }
            node = child
        }
        return node
    }

    private var rootList: [FolderTree.Root] {
        roots.map { FolderTree.Root(url: $0.url, name: $0.name, kind: $0.rootKind ?? .home) }
    }

    private func applyTheme() {
        outline.backgroundColor = .clear
        containerView.needsDisplay = true
        outline.reloadData()
    }

    // MARK: Reveal

    /// Expand the ancestors of `folder` and select it. Loads only the folders along the way.
    func reveal(_ folder: URL, force: Bool = false) {
        let target = folder.standardizedFileURL
        guard let index = FolderTree.rootIndex(containing: target, in: rootList),
            let chain = FolderTree.revealChain(root: roots[index].url, target: target)
        else { return }
        let root = roots[index]
        if selectedURL == target, !force { return }
        generation += 1
        let token = generation
        Task { @MainActor in
            var node = root
            for (position, next) in chain.enumerated() {
                guard token == generation else { return }
                if position > 0 {
                    await load(node)
                    guard token == generation else { return }
                    guard let child = node.children?.first(where: { $0.url.path == next.path })
                    else { break }
                    node = child
                }
                if position < chain.count - 1 {
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
            refreshMarks()
        }
    }

    /// Load one level of subfolders off the main thread, once. Concurrent callers (a reveal
    /// and a restore can overlap) wait for the same load.
    private func load(_ node: Node) async {
        if node.children != nil { return }
        if let running = node.loading {
            await running.value
            return
        }
        let url = node.url
        let hidden = includesHidden
        let task = Task { @MainActor in
            let listing = await Task.detached(priority: .userInitiated) {
                FolderTree.subfolders(of: url, includingHidden: hidden)
            }.value
            node.children = listing.folders.map { Node(url: $0.url, name: $0.name) }
            node.isReadable = listing.isReadable
            node.loading = nil
            outline.reloadItem(node, reloadChildren: true)
        }
        node.loading = task
        await task.value
    }

    // MARK: Pane markers

    /// Mark where the panes are. `stacked` picks the top/bottom symbols over left/right.
    func setPaneMarks(_ marks: [PaneMark], stacked: Bool) {
        guard marks != paneMarks || stacked != self.stacked else { return }
        paneMarks = marks
        self.stacked = stacked
        refreshMarks()
    }

    /// Recompute which row carries each marker: the pane's folder when its row is visible, else
    /// the deepest visible ancestor (a collapsed branch still shows that a pane is inside it).
    private func refreshMarks() {
        var next: [ObjectIdentifier: [PaneMark]] = [:]
        for mark in paneMarks {
            guard let index = FolderTree.rootIndex(containing: mark.url, in: rootList),
                let chain = FolderTree.revealChain(root: roots[index].url, target: mark.url)
            else { continue }
            var node = roots[index]
            for step in chain.dropFirst() {
                guard outline.isItemExpanded(node),
                    let child = node.children?.first(where: { $0.url.path == step.path })
                else { break }
                node = child
            }
            next[ObjectIdentifier(node), default: []].append(mark)
        }
        guard next != markedNodes else { return }
        let touched = Set(markedNodes.keys).union(next.keys)
        markedNodes = next
        var rows = IndexSet()
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? Node,
                touched.contains(ObjectIdentifier(node))
            {
                rows.insert(row)
            }
        }
        outline.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    private func markDescription(_ mark: PaneMark) -> String {
        switch (mark.slot, stacked) {
        case (0, false): return L("foldertree.paneLeft", "Left pane")
        case (_, false): return L("foldertree.paneRight", "Right pane")
        case (0, true): return L("foldertree.paneTop", "Top pane")
        default: return L("foldertree.paneBottom", "Bottom pane")
        }
    }

    private func markSymbol(_ mark: PaneMark) -> String {
        switch (mark.slot, stacked) {
        case (0, false): return "rectangle.lefthalf.filled"
        case (_, false): return "rectangle.righthalf.filled"
        case (0, true): return "rectangle.tophalf.filled"
        default: return "rectangle.bottomhalf.filled"
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return roots.count }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return roots[index] }
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
            outlineView.makeView(withIdentifier: id, owner: self) as? FolderCell
            ?? makeCell(id)
        cell.textField?.stringValue = node.name
        cell.textField?.textColor = node.isReadable ? .labelColor : .tertiaryLabelColor
        let marks = markedNodes[ObjectIdentifier(node)] ?? []
        var tip =
            node.isReadable
            ? node.url.path
            : L("foldertree.unreadable", "Can’t read this folder (no permission)")
        if !marks.isEmpty {
            tip += "\n" + marks.map(markDescription).joined(separator: ", ")
        }
        cell.toolTip = tip
        let icon = NSWorkspace.shared.icon(forFile: node.url.path)
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        configureMarkers(of: cell, marks: marks, node: node)
        return cell
    }

    /// The folder cell: icon, name, and up to two small pane markers at the trailing edge.
    private final class FolderCell: NSTableCellView {
        let markers = NSStackView()
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> FolderCell {
        let cell = FolderCell()
        cell.identifier = id
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setContentHuggingPriority(.required, for: .horizontal)
        cell.markers.orientation = .horizontal
        cell.markers.spacing = 2
        cell.markers.setHuggingPriority(.required, for: .horizontal)
        cell.markers.setContentCompressionResistancePriority(.required, for: .horizontal)
        image.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.markers.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.addSubview(cell.markers)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            // The markers follow the name (the cell can be laid out past the clip edge, so a
            // trailing anchor would hide them); a long name truncates to leave room for them.
            cell.markers.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 4),
            text.trailingAnchor.constraint(
                lessThanOrEqualTo: cell.trailingAnchor, constant: -72),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            cell.markers.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Show a small symbol per pane on this row: the accent color for the pane that has
    /// focus, a quiet gray for the other. Pinned roots also carry a pin glyph.
    private func configureMarkers(of cell: FolderCell, marks: [PaneMark], node: Node) {
        for view in cell.markers.arrangedSubviews {
            cell.markers.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        func glyph(_ symbol: String, _ color: NSColor, _ description: String) {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            let view = NSImageView(image: image ?? NSImage())
            view.contentTintColor = color
            view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            view.imageScaling = .scaleProportionallyDown
            view.setAccessibilityLabel(description)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 12).isActive = true
            view.heightAnchor.constraint(equalToConstant: 12).isActive = true
            cell.markers.addArrangedSubview(view)
        }
        if node.rootKind == .pinned {
            glyph("pin.fill", .tertiaryLabelColor, L("bvc.cmd.pinFolderTree", "Pin to Folder Tree"))
        }
        for mark in marks.sorted(by: { $0.slot < $1.slot }) {
            glyph(
                markSymbol(mark),
                mark.isActive ? ThemeManager.shared.accent : .tertiaryLabelColor,
                markDescription(mark))
        }
    }

    // MARK: Selection

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let url = selectedURL else { return }
        onSelectFolder?(url)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? Node, !restoringExpansion {
            updateState { $0.setExpanded(node.url, true) }
        }
        refreshMarks()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? Node, !restoringExpansion {
            updateState { $0.setExpanded(node.url, false) }
        }
        refreshMarks()
    }

    // MARK: Drops

    /// Dropping files on a folder uses the same rule as the sidebar's folders: Command inverts
    /// the move or copy default, and the owner's transfer path does the work.
    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let node = item as? Node, node.isReadable,
            info.draggingPasteboard.canReadObject(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        else { return [] }
        if index != NSOutlineViewDropOnItemIndex {  // between rows: drop on the folder itself
            outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        return FileDrag.operation(for: info, movesByDefault: dragMovesByDefault)
    }

    func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let node = item as? Node,
            let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty
        else { return false }
        let operation = FileDrag.operation(for: info, movesByDefault: dragMovesByDefault)
        guard !operation.isEmpty else { return false }
        onDropFiles?(urls, node.url, operation == .move)
        return true
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        buildMenu(menu, for: node)
    }

    private func buildMenu(_ menu: NSMenu, for node: Node) {
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node.url
            menu.addItem(item)
        }
        add(L("bvc.cmd.open", "Open"), #selector(menuOpen(_:)))
        add(L("bvc.cmd.openInNewTab", "Open in New Tab"), #selector(menuOpenInNewTab(_:)))
        menu.addItem(.separator())
        if isPinned(node.url) {
            add(L("bvc.cmd.unpinFolderTree", "Unpin from Folder Tree"), #selector(menuUnpin(_:)))
        } else if node.url.path != "/" {
            add(L("bvc.cmd.pinFolderTree", "Pin to Folder Tree"), #selector(menuPin(_:)))
        }
        menu.addItem(.separator())
        add(L("bvc.cmd.revealInFinder", "Reveal in Finder"), #selector(menuRevealInFinder(_:)))
        add(L("bvc.cmd.copyPath", "Copy Path"), #selector(menuCopyPath(_:)))
    }

    /// Called for "Open in New Tab"; the owner opens a tab in the active pane.
    var onOpenInNewTab: ((URL) -> Void)?
    @objc private func menuOpen(_ sender: NSMenuItem) {
        (sender.representedObject as? URL).map { onSelectFolder?($0) }
    }
    @objc private func menuOpenInNewTab(_ sender: NSMenuItem) {
        (sender.representedObject as? URL).map { onOpenInNewTab?($0) }
    }
    @objc private func menuPin(_ sender: NSMenuItem) { (sender.representedObject as? URL).map(pin) }
    @objc private func menuUnpin(_ sender: NSMenuItem) {
        (sender.representedObject as? URL).map(unpin)
    }
    @objc private func menuRevealInFinder(_ sender: NSMenuItem) {
        (sender.representedObject as? URL).map {
            NSWorkspace.shared.activateFileViewerSelecting([$0])
        }
    }
    @objc private func menuCopyPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
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
    /// Root names in order, for tests and renders.
    var debugRootNames: [String] { roots.map(\.name) }
    /// Folder names carrying a pane marker, with the slots marked there.
    var debugMarks: [String: [Int]] {
        var result: [String: [Int]] = [:]
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? Node,
                let marks = markedNodes[ObjectIdentifier(node)]
            {
                result[node.name] = marks.map(\.slot).sorted()
            }
        }
        return result
    }
    /// Deliver a drop on a visible folder as the outline would. Returns the operation offered.
    func debugDrop(_ info: NSDraggingInfo, onto url: URL, accept: Bool) -> NSDragOperation {
        guard
            let node = (0..<outline.numberOfRows).compactMap({ outline.item(atRow: $0) as? Node })
                .first(where: { $0.url.path == url.standardizedFileURL.path })
        else { return [] }
        let operation = outlineView(
            outline, validateDrop: info, proposedItem: node,
            proposedChildIndex: NSOutlineViewDropOnItemIndex)
        if accept, !operation.isEmpty {
            _ = outlineView(
                outline, acceptDrop: info, item: node, childIndex: NSOutlineViewDropOnItemIndex)
        }
        return operation
    }
    /// The context menu's item titles for a visible folder.
    func debugMenuTitles(for url: URL) -> [String] {
        guard
            let row = (0..<outline.numberOfRows).first(where: {
                (outline.item(atRow: $0) as? Node)?.url.path == url.standardizedFileURL.path
            })
        else { return [] }
        let menu = NSMenu()
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // menuNeedsUpdate reads clickedRow; emulate by building for this node directly.
        buildMenu(menu, for: outline.item(atRow: row) as! Node)
        return menu.items.map(\.title)
    }
    func debugExpandedPaths() -> [String] { state.expanded }
    /// Column, clip and outline widths plus the first marked row's cell frame, to catch markers
    /// drawn outside the visible column.
    var debugGeometry: String {
        var text =
            "clip=\(Int(scrollView.contentView.bounds.width)) outline=\(Int(outline.frame.width)) col=\(Int(outline.tableColumns[0].width))"
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? Node,
                markedNodes[ObjectIdentifier(node)] != nil,
                let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? FolderCell
            {
                text +=
                    " cell=\(Int(cell.frame.minX))..\(Int(cell.frame.maxX)) markers=\(Int(cell.markers.frame.minX))..\(Int(cell.markers.frame.maxX))"
                break
            }
        }
        return text
    }
    #endif
}
