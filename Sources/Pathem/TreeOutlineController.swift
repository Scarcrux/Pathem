import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// An NSOutlineView subclass that offers each key press to a handler (keymap chords) and reports
/// when it becomes first responder, mirroring KeyTableView for the tree view.
final class KeyOutlineView: NSOutlineView {
    /// Stripes stop at the last real row, as in the list view (see KeyTableView).
    override func drawBackground(inClipRect clipRect: NSRect) {
        drawStripesOnlyBehindRows(in: clipRect) { rect in
            if !drawThemedStripes(in: rect) { super.drawBackground(inClipRect: rect) }
        }
    }
    var onKeyChord: ((KeyChord) -> Bool)?
    var onBecomeActive: (() -> Void)?

    /// The selected files for a Service (set by the owning controller; location-aware).
    var servicesURLs: (() -> [URL])?
    /// Whether the selection is local files at all. False on a remote pane, whose rows have no
    /// file URL to hand a service. Kept separate from `servicesURLs` because AppKit asks
    /// `validRequestor` on every menu update, and building every URL there would be wasteful.
    var servicesAvailable: () -> Bool = { true }
    // Services: answer for file types only with a selection and no return type, else defer.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if FileServices.accepts(
            sendType: sendType, returnType: returnType,
            hasSelection: !selectedRowIndexes.isEmpty && servicesAvailable())
        {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    @objc func writeSelection(
        to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        FileServices.write(servicesURLs?() ?? [], to: pboard, types: types)
    }

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
final class TreeOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSTextFieldDelegate, PaneContentView
{
    /// One row: a file entry plus its real URL, with children loaded on demand.
    private final class Node {
        var entry: FileEntry
        let url: URL
        let canLoadChildren: Bool
        var children: [Node]?  // nil until first expanded
        init(entry: FileEntry, url: URL, canLoadChildren: Bool = true) {
            self.entry = entry
            self.url = url
            self.canLoadChildren = canLoadChildren
        }
        /// A location-aware entry so the pane's file ops resolve to this node's real path.
        var located: FileEntry {
            FileEntry(
                name: entry.name, isDirectory: entry.isDirectory, size: entry.size,
                modificationDate: entry.modificationDate, creationDate: entry.creationDate,
                accessDate: entry.accessDate, isDataless: entry.isDataless,
                location: url.deletingLastPathComponent().path, rawName: entry.rawName,
                viewMetadata: entry.viewMetadata)
        }
    }

    let scrollView = NSScrollView()
    private let outline = KeyOutlineView()
    #if DEBUG
    func debugMatrixFirstVisibleName() -> String? {
        let range = outline.rows(in: outline.visibleRect)
        guard range.location != NSNotFound, let node = outline.item(atRow: range.location) as? Node
        else { return nil }
        return node.entry.name
    }
    #endif
    private let placeholder = NSTextField(labelWithString: "")
    private let contextMenu = FileContextMenuController()
    private var roots: [Node] = []
    private var includesHidden = false
    private var fontSize: CGFloat = 13
    private var sortFormat = ViewFormat.default
    private var loadGeneration: UInt64 = 0
    private var childLoads: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var loadedSort: Task<Void, Never>?
    private var desiredExpandedPaths: Set<String> = []
    private var restoringTreeState = false
    private var editorWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var allowsLocalMetadata = true {
        didSet {
            if oldValue != allowsLocalMetadata { invalidateChildLoads() }
        }
    }
    #if DEBUG
    /// Blocks completed work before delivery, allowing a test to start an edit, collapse,
    /// navigate or close first. The Bool distinguishes loaded-branch sorts from lazy loads.
    var debugBeforeTreeDelivery: (@Sendable (URL, Bool) async -> Void)?
    var debugBeforeTreeDeliveryWithGeneration: (@Sendable (URL, Bool, UInt64) async -> Void)?
    var debugTreeWorkGeneration: UInt64 { loadGeneration }
    private(set) var debugTreeDeliveryCount = 0
    private(set) var debugTreeDeliveryTerminals = 0
    var debugDeferredTreeDeliveries: Int { editorWaiters.count }
    #endif

    var directoryURL: URL?
    var resolutionURL: URL?
    var onOpen: ((FileEntry) -> Void)?
    var onBecomeActive: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onSortChanged: ((ViewFormat.SortKey, Bool) -> Void)?
    var onDropFiles: ((_ urls: [URL], _ move: Bool, _ destination: URL?) -> Void)?
    var onDropOntoFile: ((_ dragged: [URL], _ target: URL) -> Void)?
    var onMouseGesture: ((String) -> Bool)?
    /// The committed name of an in-place rename (Finder-style edit in the outline).
    var onInlineRename: ((FileEntry, String) -> Void)?
    private var editingEntry: FileEntry?
    var isInlineEditing: Bool { editingEntry != nil }
    private var editingRow = -1
    private var renameCancelled = false

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

    // MARK: In-place rename (Finder-style, so New Folder drops straight into editing here too)

    /// Begin editing the single selected row's name inline. Returns false when it can't, so the
    /// pane falls back to the rename sheet.
    func beginInlineRename() -> Bool {
        guard editingEntry == nil else { return false }
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return false }
        let entry = node.located
        outline.scrollRowToVisible(row)
        guard
            let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? NSTableCellView,
            let field = cell.textField
        else { return false }
        editingEntry = entry
        editingRow = row
        renameCancelled = false
        field.delegate = self
        field.stringValue = entry.name
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.focusRingType = .default
        outline.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let ns = entry.name as NSString
            let ext = ns.pathExtension as NSString
            let baseLength =
                (!entry.isDirectory && ext.length > 0) ? ns.length - ext.length - 1 : ns.length
            editor.selectedRange = NSRange(location: 0, length: max(0, baseLength))
        }
        return true
    }

    private func endInlineEditing(_ field: NSTextField) {
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
    }

    /// Abandon an in-progress inline edit without committing (before a reload recycles the cell).
    func cancelInlineEdit() {
        guard editingEntry != nil else { return }
        let row = editingRow
        editingEntry = nil
        editingRow = -1
        renameCancelled = false
        if row >= 0, row < outline.numberOfRows,
            let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? NSTableCellView,
            let field = cell.textField
        {
            endInlineEditing(field)
            if field.currentEditor() != nil { outline.window?.makeFirstResponder(outline) }
        }
        resumeEditorWaiters()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
        if selector == #selector(NSResponder.cancelOperation(_:)) {  // Esc abandons the edit
            renameCancelled = true
            outline.window?.makeFirstResponder(outline)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let entry = editingEntry else { return }
        endInlineEditing(field)
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let row = editingRow
        let cancelled = renameCancelled
        editingEntry = nil
        editingRow = -1
        renameCancelled = false
        resumeEditorWaiters()
        if row >= 0, row < outline.numberOfRows, let node = outline.item(atRow: row) as? Node {
            outline.reloadItem(node)
        }
        guard !cancelled, !newName.isEmpty, newName != entry.name else { return }
        onInlineRename?(entry, newName)
    }

    func setEntries(_ newEntries: [FileEntry], preserveState: Bool) {
        cancelInlineEdit()  // a reload recycles the editing cell; don't let it commit a partial name
        invalidateChildLoads()
        let expanded = preserveState ? expandedPaths() : []
        desiredExpandedPaths = preserveState ? desiredExpandedPaths.union(expanded) : []
        let selectedPaths: Set<String> =
            preserveState
            ? Set(
                outline.selectedRowIndexes.compactMap {
                    (outline.item(atRow: $0) as? Node)?.url.standardizedFileURL.path
                }) : []
        let origin = scrollView.contentView.bounds.origin
        let base = directoryURL
        let oldHidden = includesHidden
        includesHidden = newEntries.contains { $0.name.hasPrefix(".") }
        // On an in-place refresh (a watcher tick), reuse the previous node for any top-level
        // folder whose name and modification date are unchanged, keeping its already-loaded
        // children. Otherwise re-expanding would re-enumerate and re-sort every expanded subtree
        // on every tick (a build writing one file could restat tens of thousands of entries).
        var previous: [String: Node] = [:]
        if preserveState, oldHidden == includesHidden {
            for node in roots { previous[node.entry.name] = node }
        }
        roots = newEntries.map { entry in
            let url = nodeURL(entry, parent: base)
            if let old = previous[entry.name], old.url == url,
                old.entry.isDirectory == entry.isDirectory,
                old.entry.modificationDate == entry.modificationDate
            {
                old.entry = entry
                return old
            }
            return Node(
                entry: entry, url: url, canLoadChildren: base != nil || entry.location != nil)
        }
        restoringTreeState = true
        defer { restoringTreeState = false }
        outline.reloadData()
        reexpand(desiredExpandedPaths)
        if preserveState {
            // reloadData can clear even a reused node's selection. Restore by
            // full location (not name: expanded subfolders can share filenames).
            var rows = IndexSet()
            for row in 0..<outline.numberOfRows {
                if let node = outline.item(atRow: row) as? Node,
                    selectedPaths.contains(node.url.standardizedFileURL.path)
                {
                    rows.insert(row)
                }
            }
            outline.selectRowIndexes(rows, byExtendingSelection: false)
            outline.layoutSubtreeIfNeeded()
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        sortLoadedChildren(refreshingExpanded: expandedPaths())
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

    #if DEBUG
    var debugPendingChildLoads: Int { childLoads.count + (loadedSort == nil ? 0 : 1) }
    var debugTreeExpandedPaths: Set<String> { expandedPaths() }
    var debugTreeSelectedPaths: [String] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.url.path }
    }
    var debugTreeOrigin: NSPoint { scrollView.contentView.bounds.origin }
    func debugChildren(ofFolder name: String) -> [FileEntry]? {
        roots.first { $0.entry.name == name }?.children?.map(\.entry)
    }
    func debugCollapse(names: [String]) {
        for node in roots where names.contains(node.entry.name) {
            outline.collapseItem(node)
        }
    }
    func debugSelectTreePath(_ path: String) {
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? Node, node.url.path == path {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
    }
    #endif

    func showSortIndicator(key: ViewFormat.SortKey, ascending: Bool) {
        var format = sortFormat
        format.sortKey = key
        format.ascending = ascending
        setSortFormat(format)
    }

    func setSortFormat(_ format: ViewFormat) {
        let changed =
            sortFormat.sortKey != format.sortKey
            || sortFormat.ascending != format.ascending
            || sortFormat.foldersFirst != format.foldersFirst
        sortFormat = format
        guard changed else { return }
        invalidateChildLoads()
        sortLoadedChildren()
        // Pending expansions canceled above must restart under the new sort snapshot.
        reloadTreePreservingLocations {}
    }
    func applyStyle(rowHeight: CGFloat, fontSize: CGFloat, alternatingRows: Bool) {
        reloadAppearancePreservingState {
            self.fontSize = fontSize
            outline.rowHeight = rowHeight
            configuredAlternating = alternatingRows
            outline.usesAlternatingRowBackgroundColors =
                alternatingRows && ThemeManager.shared.allowsSystemStripes
        }
    }

    func setBackgroundColor(_ color: NSColor?) {
        let transparent = (color?.alphaComponent ?? 1) < 0.02
        outline.backgroundColor =
            transparent ? .clear : (color ?? ThemeManager.shared.contentBackground)
        scrollView.backgroundColor =
            transparent ? .clear : (color ?? ThemeManager.shared.contentBackground)
        scrollView.drawsBackground = !transparent
        outline.usesAlternatingRowBackgroundColors =
            configuredAlternating && ThemeManager.shared.allowsSystemStripes
    }
    /// The alternating-rows setting as configured, kept so a theme change can restore it.
    private var configuredAlternating = true

    // MARK: Lazy children

    private func nodeURL(_ entry: FileEntry, parent: URL?) -> URL {
        if let location = entry.location {
            return URL(fileURLWithPath: location).appendingPathComponent(entry.name)
        }
        return (parent ?? URL(fileURLWithPath: "/")).appendingPathComponent(entry.name)
    }

    private func loadChildrenIfNeeded(_ node: Node) {
        let id = ObjectIdentifier(node)
        guard allowsLocalMetadata, node.children == nil, node.entry.isDirectory,
            node.canLoadChildren,
            childLoads[id] == nil
        else { return }
        let generation = loadGeneration
        let rootURL = directoryURL
        var workerFormat = sortFormat
        workerFormat.groupKey = .none  // Tree renders no groups: do not gather unused group metadata.
        let format = workerFormat
        let url = node.url
        let hidden = includesHidden
        #if DEBUG
        let deliveryGate = debugBeforeTreeDelivery
        let generationGate = debugBeforeTreeDeliveryWithGeneration
        #endif
        let worker = Task.detached(priority: .utility) {
            let entries = (try? BulkEnumerator().entries(of: url, includingHidden: hidden)) ?? []
            guard !Task.isCancelled else { return [FileEntry]() }
            return format.sorted(
                ListingViewMetadata.enrich(entries, directory: url, format: format))
        }
        childLoads[id] = Task { [weak self, weak node] in
            #if DEBUG
            defer { self?.debugTreeDeliveryTerminals += 1 }
            #endif
            let entries = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, let node, self.allowsLocalMetadata,
                self.loadGeneration == generation, self.directoryURL == rootURL,
                self.contains(node), node.children == nil,
                self.sortFormat.sortKey == format.sortKey,
                self.sortFormat.ascending == format.ascending,
                self.sortFormat.foldersFirst == format.foldersFirst
            else { return }
            #if DEBUG
            if let generationGate { await generationGate(url, false, generation) }
            if let deliveryGate { await deliveryGate(url, false) }
            #endif
            await self.awaitEditorEnd()
            guard !Task.isCancelled, self.allowsLocalMetadata,
                self.loadGeneration == generation, self.directoryURL == rootURL,
                self.contains(node), node.children == nil,
                self.sortFormat.sortKey == format.sortKey,
                self.sortFormat.ascending == format.ascending,
                self.sortFormat.foldersFirst == format.foldersFirst
            else { return }
            self.childLoads[id] = nil
            self.reloadTreePreservingLocations {
                node.children = entries.map {
                    Node(entry: $0, url: url.appendingPathComponent($0.name))
                }
            }
            #if DEBUG
            self.debugTreeDeliveryCount += 1
            #endif
        }
    }

    func cancelPendingWork() {
        invalidateChildLoads()
    }

    private func invalidateChildLoads() {
        loadGeneration &+= 1
        childLoads.values.forEach { $0.cancel() }
        childLoads.removeAll()
        loadedSort?.cancel()
        loadedSort = nil
        resumeEditorWaiters()
    }

    /// Event-driven waiting, not a polling timer: end/cancel of the active editor releases
    /// workers, which must still pass their original ownership guards before touching rows.
    private func awaitEditorEnd() async {
        while editingEntry != nil, !Task.isCancelled {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if Task.isCancelled || editingEntry == nil {
                        continuation.resume()
                    } else {
                        editorWaiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.editorWaiters.removeValue(forKey: id)?.resume()
                }
            }
        }
    }

    private func resumeEditorWaiters() {
        let waiting = Array(editorWaiters.values)
        editorWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func contains(_ target: Node) -> Bool {
        func walk(_ nodes: [Node]) -> Bool {
            nodes.contains { $0 === target || walk($0.children ?? []) }
        }
        return walk(roots)
    }

    /// Already expanded branches retain their Node identities. Their value snapshots are
    /// enriched/sorted away from AppKit; a changed pane generation rejects stale results.
    private func sortLoadedChildren(refreshingExpanded: Set<String> = []) {
        guard allowsLocalMetadata else { return }
        var snapshots: [(URL, [FileEntry])] = []
        func collect(_ nodes: [Node]) {
            for node in nodes {
                if let children = node.children {
                    snapshots.append((node.url, children.map(\.entry)))
                    collect(children)
                }
            }
        }
        collect(roots)
        guard !snapshots.isEmpty else { return }
        let generation = loadGeneration
        let rootURL = directoryURL
        var workerFormat = sortFormat
        workerFormat.groupKey = .none
        let format = workerFormat
        let captured = snapshots
        let hidden = includesHidden
        #if DEBUG
        let deliveryGate = debugBeforeTreeDelivery
        let generationGate = debugBeforeTreeDeliveryWithGeneration
        #endif
        let worker = Task.detached(priority: .utility) {
            var sorted: [String: [FileEntry]] = [:]
            for (url, entries) in captured {
                guard !Task.isCancelled else { return [String: [FileEntry]]() }
                // An in-place listing refresh must see content-only edits in visible branches.
                // Sort-only updates and collapsed branches can keep their existing stat snapshots.
                let current =
                    refreshingExpanded.contains(url.path)
                    ? (try? BulkEnumerator().entries(of: url, includingHidden: hidden)) ?? entries
                    : entries
                sorted[url.path] = format.sorted(
                    ListingViewMetadata.enrich(current, directory: url, format: format))
            }
            return sorted
        }
        loadedSort = Task { [weak self] in
            #if DEBUG
            defer { self?.debugTreeDeliveryTerminals += 1 }
            #endif
            let sorted = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.allowsLocalMetadata,
                self.loadGeneration == generation, self.directoryURL == rootURL,
                self.sortFormat.sortKey == format.sortKey,
                self.sortFormat.ascending == format.ascending,
                self.sortFormat.foldersFirst == format.foldersFirst
            else { return }
            #if DEBUG
            if let generationGate {
                await generationGate(rootURL ?? URL(fileURLWithPath: "/"), true, generation)
            }
            if let deliveryGate { await deliveryGate(rootURL ?? URL(fileURLWithPath: "/"), true) }
            #endif
            await self.awaitEditorEnd()
            guard !Task.isCancelled, self.allowsLocalMetadata,
                self.loadGeneration == generation, self.directoryURL == rootURL
            else { return }
            self.loadedSort = nil
            self.reloadTreePreservingLocations {
                func update(_ nodes: [Node]) {
                    for node in nodes {
                        if let entries = sorted[node.url.path], let children = node.children {
                            let previous = Dictionary(
                                uniqueKeysWithValues: children.map { ($0.url.path, $0) })
                            node.children = entries.map { entry in
                                let url = node.url.appendingPathComponent(entry.name)
                                if let old = previous[url.path],
                                    old.entry.isDirectory == entry.isDirectory
                                {
                                    old.entry = entry
                                    return old
                                }
                                return Node(entry: entry, url: url)
                            }
                        }
                        update(node.children ?? [])
                    }
                }
                update(self.roots)
            }
            #if DEBUG
            self.debugTreeDeliveryCount += 1
            #endif
        }
    }

    /// Sort/async child delivery changes row indices, so restore by real URL, never by index.
    private func reloadTreePreservingLocations(_ update: () -> Void) {
        guard !restoringTreeState else {
            update()
            return
        }
        let expanded = expandedPaths().union(desiredExpandedPaths)
        let selected = Set(
            outline.selectedRowIndexes.compactMap {
                (outline.item(atRow: $0) as? Node)?.url.path
            })
        let origin = scrollView.contentView.bounds.origin
        restoringTreeState = true
        defer { restoringTreeState = false }
        update()
        outline.reloadData()
        reexpand(expanded)
        var selection = IndexSet()
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? Node, selected.contains(node.url.path) {
                selection.insert(row)
            }
        }
        outline.selectRowIndexes(selection, byExtendingSelection: false)
        outline.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let minimumY = min(
            0, clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).minY)
        let maximumY = max(0, outline.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: origin.x, y: min(max(origin.y, minimumY), maximumY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The full paths of currently-expanded folders, to restore across an in-place refresh.
    private func expandedPaths() -> Set<String> {
        var paths = Set<String>()
        func walk(_ node: Node) {
            if outline.isItemExpanded(node) {
                paths.insert(node.url.path)
                node.children?.forEach(walk)
            }
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
        guard let node = item as? Node else { return false }
        return allowsLocalMetadata && node.entry.isDirectory && node.canLoadChildren
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any)
        -> NSView?
    {
        guard let node = item as? Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell =
            (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? Self.makeCell(id)
        cell.textField?.stringValue = node.entry.name
        cell.textField?.setAccessibilityLabel(FileAXLabel.describe(node.entry))  // name + kind/size/date
        let ruleStyle = FileColorStyle.style(
            for: node.entry, rules: colorRules, baseFont: .systemFont(ofSize: fontSize))
        cell.textField?.font = ruleStyle?.font ?? .systemFont(ofSize: fontSize)
        cell.textField?.textColor =
            ruleStyle?.color ?? (node.entry.isDataless ? .secondaryLabelColor : .labelColor)
        let baseIcon = FileIconCache.icon(  // kind-cached; bundles (.app) resolved per-file
            for: node.entry, in: node.url.deletingLastPathComponent(),
            allowFileLookup: allowsLocalMetadata)
        cell.imageView?.image =
            allowsLocalMetadata
            ? CloudBadge.decorate(
                baseIcon, for: node.entry, in: node.url.deletingLastPathComponent())
            : baseIcon
        cell.alphaValue = node.entry.isHidden ? 0.5 : 1.0
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        if !restoringTreeState { onSelectionChanged?() }
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard !restoringTreeState, let node = notification.userInfo?["NSObject"] as? Node else {
            return
        }
        desiredExpandedPaths.insert(node.url.path)
    }

    func outlineViewItemWillCollapse(_ notification: Notification) {
        guard !restoringTreeState, let node = notification.userInfo?["NSObject"] as? Node else {
            return
        }
        desiredExpandedPaths.remove(node.url.path)
    }

    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        if node.entry.isDirectory {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else {
            onOpen?(node.located)
        }
    }

    private var singleClickToOpen = false

    /// Single-click-to-open: a plain click on a file opens it when the preference is on. Folders keep
    /// their in-place expand/collapse (via the disclosure triangle or double-click), and a modified
    /// click (extending a selection) is left alone.
    @objc private func singleClicked() {
        guard singleClickToOpen else { return }
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node, !node.entry.isDirectory else {
            return
        }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        guard !flags.contains(.shift), !flags.contains(.command) else { return }
        onOpen?(node.located)
    }

    func setClickBehavior(singleClick: Bool, underlineHover: Bool) {
        singleClickToOpen = singleClick  // hover-underline isn't applied in the tree outline
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
        reloadAppearancePreservingState { colorRules = rules }
    }

    private func reloadAppearancePreservingState(_ update: () -> Void) {
        let expanded = expandedPaths()
        PaneAppearanceReload.table(
            outline, in: scrollView, update: update,
            afterReload: { self.reexpand(expanded) })
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
        outline.action = #selector(singleClicked)  // single-click-to-open (a file) when the pref is on
        outline.doubleAction = #selector(doubleClicked)
        outline.menu = contextMenu.menu
        outline.autoresizesOutlineColumn = true
        outline.indentationPerLevel = 14
        outline.onBecomeActive = { [weak self] in self?.onBecomeActive?() }
        // The tree root, so folder-scoped entries (Eject, Empty Trash) can show with nothing
        // selected, as in the other views.
        contextMenu.currentFolder = { [weak self] in
            guard let self, self.allowsLocalMetadata else { return nil }
            return self.directoryURL
        }
        contextMenu.selectedURLs = { [weak self] in
            (self?.selectedEntries ?? []).compactMap { entry in
                entry.location.map { URL(fileURLWithPath: $0).appendingPathComponent(entry.name) }
            }
        }
        outline.servicesURLs = contextMenu.selectedURLs
        outline.servicesAvailable = { [weak self] in self?.allowsLocalMetadata ?? false }

        scrollView.documentView = outline
        scrollView.verticalScroller = ThemedScroller()
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
