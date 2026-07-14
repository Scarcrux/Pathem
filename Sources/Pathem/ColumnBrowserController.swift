import AppKit
import PathemEngine

/// Finder-style column (miller) view. The root folder is the first column; clicking
/// a folder reveals its contents in the next column. The "active" column (the last
/// one clicked) defines the current folder and selection, so file operations resolve
/// against a single real folder (PaneController.currentURL returns directoryURL).
@MainActor
final class ColumnBrowserController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private struct Column {
        let folder: URL
        var entries: [FileEntry]
        let scroll: NSScrollView
        let table: NSTableView
    }

    let outerScroll = NSScrollView()
    private let container = NSView()
    private let placeholder = NSTextField(labelWithString: "")
    private var columns: [Column] = []
    private var previewColumn: NSView?  // a file preview shown after the last column
    private let previewWidth: CGFloat = 280
    private var activeColumn = 0
    private var rootURL: URL?
    private var storedResolutionURL: URL?
    private var trailingConstraint: NSLayoutConstraint?
    private var sortFormat = ViewFormat.default  // how every column (incl. drilled) is sorted
    private let columnWidth: CGFloat = 220
    /// The one shared file context menu, same as every other pane view. Column view had no
    /// right-click menu at all before; now it gets the full set (Open With, Tags, Extract, ...).
    private let contextMenu = FileContextMenuController()
    func setHiddenContextItems(_ ids: Set<String>) { contextMenu.hiddenItems = ids }
    func setContextMenuOrder(_ order: [String]) { contextMenu.menuOrder = order }
    private var colorRules = ColorRules()
    func setColorRules(_ rules: ColorRules) {
        guard rules != colorRules else { return }
        colorRules = rules
        for column in columns { column.table.reloadData() }
    }

    // PaneContentView callbacks.
    var onOpen: ((FileEntry) -> Void)?
    var onBecomeActive: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onSortChanged: ((ViewFormat.SortKey, Bool) -> Void)?
    var onDropFiles: ((_ urls: [URL], _ move: Bool, _ destination: URL?) -> Void)?
    var onDropOntoFile: ((_ dragged: [URL], _ target: URL) -> Void)?
    var onKeyChord: ((KeyChord) -> Bool)?
    var onMouseGesture: ((String) -> Bool)?
    /// Right-drag flick + swipe trail (super-drag), forwarded from each column's KeyTableView.
    var onDragSession: ((DragSessionEvent) -> Void)?

    override init() {
        super.init()
        build()
        // The active column's selection drives the shared menu's archive gating + Open With.
        contextMenu.selectedURLs = { [weak self] in self?.contextSelectionURLs() ?? [] }
    }

    /// The active column's selection as file URLs, for the shared context menu.
    private func contextSelectionURLs() -> [URL] {
        guard columns.indices.contains(activeColumn) else { return [] }
        let col = columns[activeColumn]
        return col.table.selectedRowIndexes.compactMap {
            $0 < col.entries.count ? col.folder.appendingPathComponent(col.entries[$0].name) : nil
        }
    }

    // MARK: - Cut dimming + selection anchor (parity with the list view)

    /// Paths marked for cut, dimmed until pasted. A cut can span any open column.
    private var cutPaths: Set<String> = []
    func setCutPaths(_ paths: Set<String>) {
        guard paths != cutPaths else { return }
        cutPaths = paths
        // Redraw every column: a cut/clear elsewhere can affect any of them, and there are few.
        for column in columns { column.table.reloadData() }
    }

    /// Shared tag-color cache, so every open column shows the same dots the list does.
    private lazy var decorations: PaneDecorationCache = {
        let cache = PaneDecorationCache()
        cache.onTagsChanged = { [weak self] in
            for column in self?.columns ?? [] { column.table.reloadData() }
        }
        return cache
    }()
    func invalidateTagCache() { decorations.invalidateTags() }

    /// Re-read tag colors across every open column, then redraw if the visible dots changed.
    private func refreshColumnTags() {
        decorations.refreshTags(groups: columns.map { (entries: $0.entries, directory: $0.folder) })
    }

    /// Git working-tree states keyed by absolute path; drives the per-name status letter.
    private var gitStates: [String: GitFileState] = [:]
    func setGitStates(_ states: [String: GitFileState]) {
        guard states != gitStates else { return }
        let hadAny = !gitStates.isEmpty
        gitStates = states
        if hadAny || !states.isEmpty {
            for column in columns { column.table.reloadData() }
        }
    }

    /// The active column's selected rows in window coordinates, so the quick-actions bar hugs
    /// the selection rather than centering on the whole column scroller.
    func selectionRectInWindow() -> NSRect? {
        guard columns.indices.contains(activeColumn) else { return nil }
        let table = columns[activeColumn].table
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return nil }
        var union = NSRect.null
        for row in rows { union = union.union(table.rect(ofRow: row)) }
        let visible = union.intersection(table.visibleRect)
        guard !visible.isNull, visible.height > 1 else { return nil }
        return table.convert(visible, to: nil)
    }

    private func build() {
        container.translatesAutoresizingMaskIntoConstraints = false
        outerScroll.documentView = container
        outerScroll.hasHorizontalScroller = true
        outerScroll.hasVerticalScroller = false
        outerScroll.autohidesScrollers = true
        outerScroll.borderType = .noBorder
        // The document view is as tall as the clip view (no vertical scroll) and
        // grows horizontally as columns are added. These persist; per-column and
        // trailing-width constraints are rebuilt in relayout().
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: outerScroll.contentView.leadingAnchor),
            container.topAnchor.constraint(equalTo: outerScroll.contentView.topAnchor),
            container.heightAnchor.constraint(equalTo: outerScroll.contentView.heightAnchor),
        ])
        placeholder.font = .systemFont(ofSize: 12)
        placeholder.textColor = .secondaryLabelColor
        placeholder.isHidden = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        outerScroll.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: outerScroll.centerXAnchor),
            placeholder.topAnchor.constraint(equalTo: outerScroll.topAnchor, constant: 12),
        ])
    }

    // MARK: Columns

    private func makeColumn(folder: URL, entries: [FileEntry], index: Int) -> Column {
        let table = KeyTableView()
        table.headerView = nil
        table.rowHeight = 20
        table.allowsMultipleSelection = true
        table.tag = index
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.onKeyChord = { [weak self] chord in self?.onKeyChord?(chord) ?? false }
        table.onMouseGesture = { [weak self] stroke in self?.onMouseGesture?(stroke) ?? false }
        table.onSuperDrag = { [weak self] event in self?.onDragSession?(event) }  // right-drag flick + trail
        table.onBecomeActive = { [weak self, weak table] in
            guard let self, let table, let i = self.columnIndex(of: table) else { return }
            self.activeColumn = i
            self.onBecomeActive?()
        }
        let column = NSTableColumn(identifier: .init("name"))
        column.width = columnWidth - 4
        table.addTableColumn(column)
        table.registerForDraggedTypes([.fileURL])  // accept file drops into this column
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)  // drag to the other pane
        table.setDraggingSourceOperationMask(.every, forLocal: false)  // and to Finder / other apps
        table.menu = contextMenu.menu  // right-click; KeyTableView selects the clicked row first

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        if index > 0 {
            // a hairline separator look via the scroll's background
            scroll.drawsBackground = false
        }
        let made = Column(folder: folder, entries: entries, scroll: scroll, table: table)
        applyBackground(to: made)  // a newly drilled column inherits the folder background
        return made
    }

    /// The active folder-background color (nil = default), applied to every column.
    private var backgroundColor: NSColor?
    func setBackgroundColor(_ color: NSColor?) {
        backgroundColor = color
        for column in columns { applyBackground(to: column) }
    }
    private func applyBackground(to column: Column) {
        let transparent = (backgroundColor?.alphaComponent ?? 1) < 0.02
        column.table.backgroundColor = transparent ? .clear : (backgroundColor ?? .controlBackgroundColor)
        column.scroll.backgroundColor = transparent ? .clear : (backgroundColor ?? .controlBackgroundColor)
        column.scroll.drawsBackground = !transparent
    }

    /// Rebuild the columns' layout (left to right, full height). The container's
    /// leading/top/height are fixed in build(); here we chain columns and pin the
    /// container's trailing to the last one (which sets the scrollable width).
    private func relayout() {
        for sub in container.subviews { sub.removeFromSuperview() }
        trailingConstraint?.isActive = false  // the empty-case constraint isn't auto-removed
        var leading = container.leadingAnchor
        for (index, col) in columns.enumerated() {
            container.addSubview(col.scroll)
            NSLayoutConstraint.activate([
                col.scroll.leadingAnchor.constraint(equalTo: leading, constant: index == 0 ? 0 : 1),
                col.scroll.topAnchor.constraint(equalTo: container.topAnchor),
                col.scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                col.scroll.widthAnchor.constraint(equalToConstant: columnWidth),
            ])
            leading = col.scroll.trailingAnchor
        }
        var trailingView: NSView? = columns.last?.scroll
        if let preview = previewColumn {  // file preview as a final, wider column
            container.addSubview(preview)
            preview.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: leading, constant: 1),
                preview.topAnchor.constraint(equalTo: container.topAnchor),
                preview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                preview.widthAnchor.constraint(equalToConstant: previewWidth),
            ])
            trailingView = preview
        }
        if let trailingView {
            trailingConstraint = container.trailingAnchor.constraint(equalTo: trailingView.trailingAnchor)
        } else {
            trailingConstraint = container.trailingAnchor.constraint(equalTo: container.leadingAnchor)
        }
        trailingConstraint?.isActive = true
        container.layoutSubtreeIfNeeded()
        refreshColumnTags()  // structural change: re-read tag dots across the open columns
    }

    /// Load a folder's children off the main thread, then append the next column,
    /// but only if that folder is still the active selection (no newer click won).
    private func openFolder(_ folder: URL, after index: Int) {
        if columns.count > index + 1 { columns.removeSubrange((index + 1)...) }  // drop deeper now
        relayout()
        let format = sortFormat
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = (try? BulkEnumerator().entries(of: folder, includingHidden: false)) ?? []
            let sorted = format.sorted(entries)
            DispatchQueue.main.async {
                guard let self, self.columns.indices.contains(index), self.columns.count == index + 1
                else { return }  // a deeper column already opened, or the parent is gone
                // The parent column must still have exactly this folder selected.
                let parent = self.columns[index]
                let selected = parent.table.selectedRowIndexes
                guard selected.count == 1, let row = selected.first, row < parent.entries.count,
                    parent.folder.appendingPathComponent(parent.entries[row].name) == folder
                else { return }
                let new = self.makeColumn(folder: folder, entries: sorted, index: index + 1)
                self.columns.append(new)
                self.relayout()
                new.table.reloadData()
                self.scrollToEnd()
            }
        }
    }

    private func scrollToEnd() {
        container.layoutSubtreeIfNeeded()
        let maxX = max(0, container.frame.width - outerScroll.contentView.bounds.width)
        outerScroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
        outerScroll.reflectScrolledClipView(outerScroll.contentView)
    }

    private func columnIndex(of table: NSTableView) -> Int? {
        columns.firstIndex { $0.table === table }
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let index = columnIndex(of: tableView) else { return 0 }
        return columns[index].entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let index = columnIndex(of: tableView), row < columns[index].entries.count else { return nil }
        let entry = columns[index].entries[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? Self.makeCell(id)
        let ruleStyle = FileColorStyle.style(for: entry, rules: colorRules, baseFont: .systemFont(ofSize: 13))
        cell.textField?.font = ruleStyle?.font ?? .systemFont(ofSize: 13)
        cell.textField?.textColor = ruleStyle?.color ?? (entry.isDataless ? .secondaryLabelColor : .labelColor)
        // Prefix a colored git-status letter and suffix tag dots when present (shared with the
        // list view). Middle truncation keeps both ends even when a long name is clipped.
        let folder = columns[index].folder
        let git = gitStates.isEmpty ? nil : gitStates[PaneItemKey.path(for: entry, in: folder)]
        let dots = decorations.tagColors(for: entry, in: folder)
        if git != nil || !dots.isEmpty {
            cell.textField?.attributedStringValue = FileNameDecoration.decoratedName(
                entry.name, git: git, dots: dots, size: 13, nameFont: ruleStyle?.font, nameColor: ruleStyle?.color)
        } else {
            cell.textField?.stringValue = entry.name
        }
        let url = columns[index].folder.appendingPathComponent(entry.name)
        let baseIcon = FileIconCache.icon(for: entry, in: columns[index].folder)  // kind-cached; bundles per-file
        cell.imageView?.image = CloudBadge.decorate(baseIcon, for: entry, in: columns[index].folder)
        // Dim cut items (until pasted), then hidden (dotfile) entries. Keyed on this column's
        // own folder, since a cut can live in any drilled column.
        let isCut = !cutPaths.isEmpty && cutPaths.contains(PaneItemKey.path(for: entry, in: columns[index].folder))
        cell.alphaValue = isCut ? 0.45 : (entry.isHidden ? 0.5 : 1.0)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, let index = columnIndex(of: table) else { return }
        activeColumn = index
        onBecomeActive?()
        onSelectionChanged?()
        // Single folder selected -> reveal its contents in the next column.
        let selected = table.selectedRowIndexes
        if selected.count == 1, let row = selected.first, row < columns[index].entries.count {
            let entry = columns[index].entries[row]
            let url = columns[index].folder.appendingPathComponent(entry.name)
            if entry.isDirectory {
                previewColumn = nil  // drilling replaces any preview
                openFolder(url, after: index)
            } else {
                if columns.count > index + 1 { columns.removeSubrange((index + 1)...) }
                previewColumn = makePreviewColumn(for: url)  // show a preview of the file
                relayout()
                scrollToEnd()
            }
        }
    }

    /// A Finder-style preview column: the thumbnail letterboxed in a soft rounded well, the
    /// name under it, and an aligned label/value metadata table (kind, size, dates) instead
    /// of centered free-floating lines.
    private func makePreviewColumn(for url: URL) -> NSView {
        let box = NSView()

        // Thumbnail well: a subtle rounded surface the (arbitrary aspect) thumbnail floats in,
        // so images, icons, and previews all sit in the same calm frame.
        let well = NSView()
        well.translatesAutoresizingMaskIntoConstraints = false
        well.wantsLayer = true
        well.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        well.layer?.cornerRadius = 10
        well.layer?.cornerCurve = .continuous
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        image.image = NSWorkspace.shared.icon(forFile: url.path)
        well.addSubview(image)

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.translatesAutoresizingMaskIntoConstraints = false
        name.alignment = .center
        name.font = .boldSystemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle

        // Metadata rows: right-aligned dim labels, left-aligned values, like Finder / Get Info.
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        func addRow(_ label: String, _ value: String) {
            let key = NSTextField(labelWithString: label)
            key.font = .systemFont(ofSize: 11)
            key.textColor = .tertiaryLabelColor
            let val = NSTextField(labelWithString: value)
            val.font = .systemFont(ofSize: 11)
            val.textColor = .secondaryLabelColor
            val.lineBreakMode = .byTruncatingMiddle
            grid.addRow(with: [key, val])
        }

        box.addSubview(well)
        box.addSubview(name)
        box.addSubview(grid)
        NSLayoutConstraint.activate([
            well.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
            well.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            well.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            well.heightAnchor.constraint(equalToConstant: 210),
            image.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            image.widthAnchor.constraint(lessThanOrEqualTo: well.widthAnchor, constant: -24),
            image.heightAnchor.constraint(lessThanOrEqualTo: well.heightAnchor, constant: -24),
            name.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 12),
            name.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            name.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            grid.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 10),
            grid.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -12),
        ])

        let size = CGSize(width: 256, height: 256)
        if let cached = ThumbnailProvider.shared.cached(url, size: size) {
            image.image = cached
        } else {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            ThumbnailProvider.shared.generate(url, size: size, scale: scale) { [weak image] thumbnail in
                image?.image = thumbnail
            }
        }
        if let fileInfo = FileInfo.gather(for: url) {
            let formatter = ByteCountFormatter()
            let date = DateFormatter()
            date.dateStyle = .medium
            date.timeStyle = .short
            addRow(L("preview.kind", "Kind"), fileInfo.kind)
            addRow(L("preview.size", "Size"), formatter.string(fromByteCount: fileInfo.size))
            if let created = fileInfo.created { addRow(L("preview.created", "Created"), date.string(from: created)) }
            if let modified = fileInfo.modified { addRow(L("preview.modified", "Modified"), date.string(from: modified)) }
        }
        return box
    }

    // MARK: Drag source (drag files OUT of a column to the other pane, Finder, other apps)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let index = columnIndex(of: tableView), row < columns[index].entries.count else { return nil }
        let entry = columns[index].entries[row]
        guard !entry.isDataless else { return nil }  // don't drag online-only placeholders
        // A promise + file URL, so the drag lands in browsers/sandboxed apps and Finder alike.
        return FileDrag.item(for: columns[index].folder.appendingPathComponent(entry.name))
    }

    func tableView(
        _ tableView: NSTableView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet
    ) {
        guard let index = columnIndex(of: tableView) else { return }
        let folder = columns[index].folder
        let urls = rowIndexes.compactMap { row -> URL? in
            guard row < columns[index].entries.count, !columns[index].entries[row].isDataless else { return nil }
            return folder.appendingPathComponent(columns[index].entries[row].name)
        }
        FileDrag.addLegacyFilenames(urls, to: session.draggingPasteboard)
    }

    // MARK: Drops (into a column's folder, or onto a folder row within it)

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
        proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let index = columnIndex(of: tableView), draggedURLs(info) != nil else { return [] }
        let folder = columns[index].folder
        if row >= 0, row < columns[index].entries.count, columns[index].entries[row].isDirectory {
            tableView.setDropRow(row, dropOperation: .on)  // into that subfolder
        } else {
            tableView.setDropRow(-1, dropOperation: .on)  // into this column's folder
        }
        _ = folder
        return resolvedDragOperation(info)
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let index = columnIndex(of: tableView), let urls = draggedURLs(info), !urls.isEmpty else {
            return false
        }
        var destination = columns[index].folder
        if row >= 0, row < columns[index].entries.count, columns[index].entries[row].isDirectory {
            destination = destination.appendingPathComponent(columns[index].entries[row].name)
        }
        let destPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let incoming = urls.filter {
            $0.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                .compare(destPath, options: .caseInsensitive) != .orderedSame
        }
        guard !incoming.isEmpty else { return false }
        onDropFiles?(incoming, resolvedDragOperation(info) == .move, destination)
        return true
    }

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL]? {
        FileDrag.readFileURLs(from: info.draggingPasteboard)
    }

    /// Move dragged items between folders by default (else copy); Command inverts it, matching
    /// the list. Driven by the pref via PaneController.
    var dragMovesByDefault = false

    private func resolvedDragOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        let wantMove = dragMovesByDefault != commandHeld  // Command inverts the default
        return wantMove && info.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let table = sender as? NSTableView, let index = columnIndex(of: table) else { return }
        let row = table.clickedRow
        guard row >= 0, row < columns[index].entries.count else { return }
        let entry = columns[index].entries[row]
        if !entry.isDirectory { onOpen?(entry) }  // folders drill via single-click; files open
    }

    private static func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.imageView = icon
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingMiddle  // keep the leading git letter and trailing tag dots
        field.font = .systemFont(ofSize: 13)
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

extension ColumnBrowserController: PaneContentView {
    var scrollView: NSScrollView { outerScroll }
    var keyView: NSView { columns.indices.contains(activeColumn) ? columns[activeColumn].table : container }

    var entries: [FileEntry] {
        columns.indices.contains(activeColumn) ? columns[activeColumn].entries : []
    }
    var selectedEntries: [FileEntry] {
        guard columns.indices.contains(activeColumn) else { return [] }
        let col = columns[activeColumn]
        return col.table.selectedRowIndexes.compactMap { $0 < col.entries.count ? col.entries[$0] : nil }
    }

    var directoryURL: URL? {
        get { columns.indices.contains(activeColumn) ? columns[activeColumn].folder : rootURL }
        set { rootURL = newValue }
    }
    var resolutionURL: URL? {
        get { storedResolutionURL }
        set { storedResolutionURL = newValue }
    }

    func setEntries(_ entries: [FileEntry], preserveState: Bool) {
        guard let root = rootURL else {
            columns = []
            relayout()
            return
        }
        // An in-place refresh (a watcher tick on the root) updates the first column
        // without collapsing the drilled columns or losing focus/selection.
        if preserveState, let first = columns.first, first.folder == root {
            let names = Set(first.table.selectedRowIndexes.compactMap {
                $0 < columns[0].entries.count ? columns[0].entries[$0].name : nil
            })
            columns[0].entries = entries
            first.table.reloadData()
            var rows = IndexSet()
            for (index, entry) in entries.enumerated() where names.contains(entry.name) { rows.insert(index) }
            first.table.selectRowIndexes(rows, byExtendingSelection: false)
            refreshColumnTags()  // a watcher tick may include external tag edits
            return
        }
        let wasFocused = outerScroll.window?.firstResponder === container
            || columns.contains { $0.table === outerScroll.window?.firstResponder }
        previewColumn = nil
        let first = makeColumn(folder: root, entries: entries, index: 0)
        columns = [first]
        activeColumn = 0
        relayout()
        first.table.reloadData()
        outerScroll.contentView.scroll(to: .zero)
        if wasFocused { outerScroll.window?.makeFirstResponder(first.table) }  // not the empty container
    }

    /// Programmatically select a row in the first column (PATHEM_VIEW_SHOT drill test).
    func debugSelect(row: Int, inColumn column: Int = 0) {
        guard column < columns.count else { return }
        let target = columns[column]
        guard row < target.entries.count else { return }
        target.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: target.table))
    }

    func showPlaceholder(_ text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = (text == nil)
    }

    func select(name: String) {
        // The active column is where a new-folder/rename happened, so select there
        // (not always the root column).
        guard columns.indices.contains(activeColumn) else { return }
        let column = columns[activeColumn]
        guard let row = column.entries.firstIndex(where: { $0.name == name }) else { return }
        column.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // Only scroll when the row is actually off screen. An operation on a visible
        // file (rename, new-folder-with-selection) reloads the column, and forcing
        // scrollRowToVisible would snap the file to the top edge even though it never
        // left the viewport. Following it only when it genuinely scrolled away keeps
        // the column steady.
        let visible = column.table.rows(in: column.table.visibleRect)
        if visible.length == 0 || !NSLocationInRange(row, visible) {
            column.table.scrollRowToVisible(row)
        }
    }

    func selectNames(_ names: Set<String>) {
        guard columns.indices.contains(activeColumn) else { return }
        let column = columns[activeColumn]
        var rows = IndexSet()
        for (index, entry) in column.entries.enumerated() where names.contains(entry.name) { rows.insert(index) }
        column.table.selectRowIndexes(rows, byExtendingSelection: false)
    }

    func showSortIndicator(key: ViewFormat.SortKey, ascending: Bool) {}
    func applyStyle(rowHeight: CGFloat, fontSize: CGFloat, alternatingRows: Bool) {}

    /// Re-enumerate the drilled (non-root) columns after a file operation, so an op
    /// inside a drilled column shows its result instead of stale rows. The root
    /// column is refreshed separately by setEntries; here we prune any column whose
    /// folder vanished and reload the rest, preserving each column's selection.
    func refreshDrilledColumns() {
        guard columns.count > 1 else { return }
        let fm = FileManager.default
        while columns.count > 1, !fm.fileExists(atPath: columns[columns.count - 1].folder.path) {
            columns.removeLast()  // the folder this column showed was deleted/moved
        }
        if activeColumn >= columns.count { activeColumn = max(0, columns.count - 1) }
        // relayout() below tears down and re-adds every column's scroll view, which can
        // reset the vertical offset. Capture each column's scroll position so a file op
        // in a drilled column doesn't jump that column back to the top.
        var savedOffsets: [Int: NSPoint] = [:]
        for index in columns.indices where index > 0 {
            let folder = columns[index].folder
            let entries = (try? BulkEnumerator().entries(of: folder, includingHidden: false)) ?? []
            let sorted = sortFormat.sorted(entries)
            let names = Set(columns[index].table.selectedRowIndexes.compactMap {
                $0 < columns[index].entries.count ? columns[index].entries[$0].name : nil
            })
            savedOffsets[index] = columns[index].scroll.contentView.bounds.origin
            columns[index].entries = sorted
            columns[index].table.reloadData()
            var rows = IndexSet()
            for (row, entry) in sorted.enumerated() where names.contains(entry.name) { rows.insert(row) }
            columns[index].table.selectRowIndexes(rows, byExtendingSelection: false)
        }
        relayout()
        for (index, origin) in savedOffsets where columns.indices.contains(index) {
            let clip = columns[index].scroll.contentView
            clip.scroll(to: origin)
            columns[index].scroll.reflectScrolledClipView(clip)
        }
    }

    /// Adopt the pane's sort and re-sort every open column (including drilled ones)
    /// so all columns order consistently, not just the first.
    func setSortFormat(_ format: ViewFormat) {
        sortFormat = format
        for index in columns.indices {
            columns[index].entries = format.sorted(columns[index].entries)
            columns[index].table.reloadData()
        }
    }
}
