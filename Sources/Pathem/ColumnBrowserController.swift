import AppKit
import PathemEngine

/// Finder-style column (miller) view. The root folder is the first column; clicking
/// a folder reveals its contents in the next column. The "active" column (the last
/// one clicked) defines the current folder and selection, so file operations resolve
/// against a single real folder (PaneController.currentURL returns directoryURL).
@MainActor
final class ColumnBrowserController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate
{
    private struct Column {
        let id = UUID()
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
    private var previewTarget: (url: URL, dataless: Bool)?
    private var dateDisplay = Preferences.DateDisplay.relative
    private var sizeDisplay = Preferences.SizeFormat.decimal
    private var columnFontSize: CGFloat = 13
    private var columnRowHeight: CGFloat = 20
    private var alternatingRows = false

    func setFormats(size: Preferences.SizeFormat, date: Preferences.DateDisplay) {
        guard dateDisplay != date || sizeDisplay != size else { return }
        dateDisplay = date
        sizeDisplay = size
        if let target = previewTarget, previewColumn != nil {
            let origin = outerScroll.contentView.bounds.origin
            previewColumn = makePreviewColumn(for: target.url, isDataless: target.dataless)
            relayout()
            outerScroll.contentView.scroll(to: origin)
            outerScroll.reflectScrolledClipView(outerScroll.contentView)
        }
    }
    private let previewWidth: CGFloat = 280
    private var activeColumn = 0
    private var rootURL: URL?
    private var storedResolutionURL: URL?
    private var trailingConstraint: NSLayoutConstraint?
    private var sortFormat = ViewFormat.default  // how every column (incl. drilled) is sorted
    private struct PendingFolderOpen: Sendable {
        let token: Int
        let folder: URL
        let index: Int
        let parentID: UUID
        let root: URL?
    }
    private var pendingFolderOpen: PendingFolderOpen?
    private var folderOpenGeneration = 0
    private var columnWorkGeneration = 0
    private var deferredDrilledRefresh = false
    private var deferredDrilledCompletions: [@MainActor () -> Void] = []
    private var pendingDrilledRefreshGeneration: Int?
    var isRefreshingDrilledColumns: Bool {
        deferredDrilledRefresh || pendingDrilledRefreshGeneration == columnWorkGeneration
    }
    #if DEBUG
    var debugWillApplyColumnLoad: (() -> Void)?
    var debugWillApplyDrilledRefresh: (() -> Void)?
    var debugHasPendingColumnLoad: Bool { pendingFolderOpen != nil }
    var debugColumnFolders: [URL] { columns.map(\.folder) }
    func debugMatrixFirstVisibleName() -> String? {
        let visible = columns.filter { $0.scroll.frame.intersects(outerScroll.contentView.bounds) }
        if visible.isEmpty {
            guard let previewColumn, previewColumn.frame.intersects(outerScroll.contentView.bounds)
            else { return nil }
            return previewTarget.map { "preview:" + $0.url.lastPathComponent }
        }
        return visible.prefix(1).map { column in
            let range = column.table.rows(in: column.table.visibleRect)
            guard range.location != NSNotFound, column.entries.indices.contains(range.location)
            else { return "<empty>" }
            return column.folder.lastPathComponent + ":" + column.entries[range.location].name
        }.joined(separator: "|")
    }
    func debugMatrixTagsReady() -> Bool {
        guard let column = columns.first,
            let entry = column.entries.first(where: { $0.name == "Lofoten Dawn.jpg" })
        else { return false }
        return decorations.tagColors(for: entry, in: column.folder).contains(.orange)
    }
    func debugColumnNames(_ index: Int) -> [String] {
        columns.indices.contains(index) ? columns[index].entries.map(\.name) : []
    }
    func debugColumnOffset(_ index: Int) -> NSPoint? {
        columns.indices.contains(index) ? columns[index].scroll.contentView.bounds.origin : nil
    }
    func debugSetColumnOffset(_ origin: NSPoint, inColumn index: Int) {
        guard columns.indices.contains(index) else { return }
        let column = columns[index]
        column.scroll.contentView.scroll(to: origin)
        column.scroll.reflectScrolledClipView(column.scroll.contentView)
    }
    #endif
    private var restoringSortSelection = false
    private var selectingProgrammatically = false
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
        let wasRestoring = restoringSortSelection
        restoringSortSelection = true
        defer { restoringSortSelection = wasRestoring }
        for column in columns {
            PaneAppearanceReload.table(column.table, in: column.scroll, update: {})
        }
    }

    // PaneContentView callbacks.
    var onOpen: ((FileEntry) -> Void)?
    var onBecomeActive: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onSortChanged: ((ViewFormat.SortKey, Bool) -> Void)?
    var onDropFiles: ((_ urls: [URL], _ move: Bool, _ destination: URL?) -> Void)?
    var onDropOntoFile: ((_ dragged: [URL], _ target: URL) -> Void)?
    /// The committed name of an in-place rename (Finder-style edit in the active column).
    var onInlineRename: ((FileEntry, String) -> Void)?
    private var editingEntry: FileEntry?
    var isInlineEditing: Bool { editingEntry != nil }
    private weak var editingTable: NSTableView?
    private var editingRow = -1
    private var renameCancelled = false
    var onKeyChord: ((KeyChord) -> Bool)?
    var onMouseGesture: ((String) -> Bool)?
    /// Right-drag flick + swipe trail (super-drag), forwarded from each column's KeyTableView.
    var onDragSession: ((DragSessionEvent) -> Void)?

    override init() {
        super.init()
        build()
        // The active column's selection drives the shared menu's archive gating + Open With.
        contextMenu.selectedURLs = { [weak self] in self?.contextSelectionURLs() ?? [] }
        contextMenu.currentFolder = { [weak self] in self?.directoryURL }
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
            guard let self else { return }
            #if DEBUG
            let matrixBefore = self.debugMatrixDecorationState()
            #endif
            for column in self.columns {
                column.table.reloadData()
            }
            #if DEBUG
            LayoutMatrixGeometry.recordDecoration(
                "column-tag-reload", before: matrixBefore, after: self.debugMatrixDecorationState())
            #endif
        }
        return cache
    }()
    func invalidateTagCache() { decorations.invalidateTags() }

    /// Re-read tag colors across every open column, then redraw if the visible dots changed.
    private func refreshColumnTags() {
        decorations.refreshTags(groups: columns.map { (entries: $0.entries, directory: $0.folder) })
    }

    #if DEBUG
    private func debugMatrixDecorationState() -> LayoutMatrixGeometry.DecorationState {
        .init(
            names: selectedEntries.map(\.name), firstVisible: debugMatrixFirstVisibleName(),
            origins: [outerScroll.contentView.bounds.origin]
                + columns.map { $0.scroll.contentView.bounds.origin },
            structure: columns.map { $0.id.uuidString } + [
                String(activeColumn), String(folderOpenGeneration), String(columnWorkGeneration),
                previewColumn.map { String(describing: ObjectIdentifier($0)) } ?? "no-preview",
            ], callbacks: LayoutMatrixGeometry.selectionCallbacks)
    }
    #endif

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
        table.rowHeight = columnRowHeight
        table.usesAlternatingRowBackgroundColors = alternatingRows
        table.allowsMultipleSelection = true
        table.tag = index
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(singleClicked(_:))  // single-click-to-open (a file) when the pref is on
        table.doubleAction = #selector(doubleClicked(_:))
        table.onKeyChord = { [weak self] chord in self?.onKeyChord?(chord) ?? false }
        table.onMouseGesture = { [weak self] stroke in self?.onMouseGesture?(stroke) ?? false }
        table.onSuperDrag = { [weak self] event in self?.onDragSession?(event) }  // right-drag flick + trail
        table.onBecomeActive = { [weak self, weak table] in
            guard let self, let table, let i = self.columnIndex(of: table) else { return }
            guard !self.restoringSortSelection else { return }
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
        column.table.backgroundColor =
            transparent ? .clear : (backgroundColor ?? .controlBackgroundColor)
        column.scroll.backgroundColor =
            transparent ? .clear : (backgroundColor ?? .controlBackgroundColor)
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
            trailingConstraint = container.trailingAnchor.constraint(
                equalTo: trailingView.trailingAnchor)
        } else {
            trailingConstraint = container.trailingAnchor.constraint(
                equalTo: container.leadingAnchor)
        }
        trailingConstraint?.isActive = true
        container.layoutSubtreeIfNeeded()
        refreshColumnTags()  // structural change: re-read tag dots across the open columns
    }

    /// Load a folder's children off the main thread, then append the next column,
    /// but only if that folder is still the active selection (no newer click won).
    private func openFolder(_ folder: URL, after index: Int) {
        guard columns.indices.contains(index) else { return }
        columnWorkGeneration += 1
        folderOpenGeneration += 1
        let request = PendingFolderOpen(
            token: folderOpenGeneration, folder: folder, index: index,
            parentID: columns[index].id, root: rootURL)
        pendingFolderOpen = request
        if columns.count > index + 1 { columns.removeSubrange((index + 1)...) }  // drop deeper now
        relayout()
        loadPendingFolder(request)
    }

    private func loadPendingFolder(_ request: PendingFolderOpen) {
        let format = sortFormat
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries =
                (try? BulkEnumerator().entries(of: request.folder, includingHidden: false)) ?? []
            let sorted = format.sorted(
                ListingViewMetadata.enrich(entries, directory: request.folder, format: format))
            DispatchQueue.main.async {
                guard let self, self.pendingFolderOpen?.token == request.token,
                    self.rootURL == request.root,
                    self.columns.indices.contains(request.index),
                    self.columns[request.index].id == request.parentID,
                    self.columns.count == request.index + 1
                else { return }  // a deeper column already opened, or the parent is gone
                #if DEBUG
                let beforeApply = self.debugWillApplyColumnLoad
                self.debugWillApplyColumnLoad = nil
                beforeApply?()
                #endif
                guard self.pendingFolderOpen?.token == request.token,
                    self.rootURL == request.root,
                    self.columns.indices.contains(request.index),
                    self.columns[request.index].id == request.parentID,
                    self.columns.count == request.index + 1
                else { return }
                // The parent column must still have exactly this folder selected.
                let parent = self.columns[request.index]
                let selected = parent.table.selectedRowIndexes
                guard selected.count == 1, let row = selected.first, row < parent.entries.count,
                    parent.folder.appendingPathComponent(parent.entries[row].name) == request.folder
                else {
                    self.pendingFolderOpen = nil
                    return
                }
                // A sort can change while the same folder is still selected. Keep the user's
                // pending drill, but do not append a column prepared with obsolete metadata.
                guard self.sortFormat == format else {
                    self.loadPendingFolder(request)
                    return
                }
                self.pendingFolderOpen = nil
                let new = self.makeColumn(
                    folder: request.folder, entries: sorted, index: request.index + 1)
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let index = columnIndex(of: tableView), row < columns[index].entries.count else {
            return nil
        }
        let entry = columns[index].entries[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? Self.makeCell(id)
        let ruleStyle = FileColorStyle.style(
            for: entry, rules: colorRules, baseFont: .systemFont(ofSize: columnFontSize))
        cell.textField?.font = ruleStyle?.font ?? .systemFont(ofSize: columnFontSize)
        cell.textField?.textColor =
            ruleStyle?.color ?? (entry.isDataless ? .secondaryLabelColor : .labelColor)
        // Prefix a colored git-status letter and suffix tag dots when present (shared with the
        // list view). Middle truncation keeps both ends even when a long name is clipped.
        let folder = columns[index].folder
        let git = gitStates.isEmpty ? nil : gitStates[PaneItemKey.path(for: entry, in: folder)]
        let dots = decorations.tagColors(for: entry, in: folder)
        if git != nil || !dots.isEmpty {
            cell.textField?.attributedStringValue = FileNameDecoration.decoratedName(
                entry.name, git: git, dots: dots, size: columnFontSize, nameFont: ruleStyle?.font,
                nameColor: ruleStyle?.color)
        } else {
            cell.textField?.stringValue = entry.name
        }
        cell.textField?.setAccessibilityLabel(FileAXLabel.describe(entry))  // name + kind/size/date, not glyphs
        let baseIcon = FileIconCache.icon(for: entry, in: columns[index].folder)  // kind-cached; bundles per-file
        cell.imageView?.image = CloudBadge.decorate(baseIcon, for: entry, in: columns[index].folder)
        // Dim cut items (until pasted), then hidden (dotfile) entries. Keyed on this column's
        // own folder, since a cut can live in any drilled column.
        let isCut =
            !cutPaths.isEmpty
            && cutPaths.contains(PaneItemKey.path(for: entry, in: columns[index].folder))
        cell.alphaValue = isCut ? 0.45 : (entry.isHidden ? 0.5 : 1.0)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !restoringSortSelection else { return }  // display refreshes are not drill/preview gestures
        guard let table = notification.object as? NSTableView, let index = columnIndex(of: table)
        else { return }
        activeColumn = index
        // Any new gesture supersedes a pending read, even a file/multiple selection which
        // does not start another folder read. An in-place listing restoration is filtered above.
        folderOpenGeneration += 1
        pendingFolderOpen = nil
        columnWorkGeneration += 1
        // Programmatic Reveal/selection restoration updates this column, but
        // must not steal active-side ownership from a pane the user has focused.
        if !selectingProgrammatically { onBecomeActive?() }
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
                previewColumn = makePreviewColumn(for: url, isDataless: entry.isDataless)
                relayout()
                scrollToEnd()
            }
        }
    }

    /// A Finder-style preview column: a live Quick Look preview letterboxed in a soft rounded
    /// well, the name under it, and an aligned label/value metadata table (kind, size, dates)
    /// instead of centered free-floating lines. Quick Look renders many file types (PDFs, text,
    /// code, images, media) rather than just a static thumbnail.
    private func makePreviewColumn(for url: URL, isDataless: Bool) -> NSView {
        previewTarget = (url, isDataless)
        let box = NSView()

        // Preview well: a subtle rounded surface the (arbitrary aspect) preview floats in, so
        // images, documents, and icons all sit in the same calm frame. Clipped to the corners.
        let well = NSView()
        well.translatesAutoresizingMaskIntoConstraints = false
        well.wantsLayer = true
        well.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        well.layer?.cornerRadius = 10
        well.layer?.cornerCurve = .continuous
        well.layer?.masksToBounds = true
        let preview = QuickLookPreview()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.show(
            url, isDataless: isDataless, fallbackIcon: NSWorkspace.shared.icon(forFile: url.path))
        well.addSubview(preview)

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
            preview.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            preview.topAnchor.constraint(equalTo: well.topAnchor),
            preview.bottomAnchor.constraint(equalTo: well.bottomAnchor),
            name.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 12),
            name.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            name.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            grid.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 10),
            grid.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -12),
        ])

        if let fileInfo = FileInfo.gather(for: url) {
            let formatter = ByteCountFormatter()
            formatter.countStyle = sizeDisplay == .binary ? .binary : .file
            let date = DateFormatter()
            date.dateStyle = dateDisplay == .short ? .short : .medium
            date.timeStyle = dateDisplay == .medium ? .none : .short
            date.doesRelativeDateFormatting = dateDisplay == .relative
            addRow(L("preview.kind", "Kind"), fileInfo.kind)
            addRow(L("preview.size", "Size"), formatter.string(fromByteCount: fileInfo.size))
            if let created = fileInfo.created {
                addRow(L("preview.created", "Created"), date.string(from: created))
            }
            if let modified = fileInfo.modified {
                addRow(L("preview.modified", "Modified"), date.string(from: modified))
            }
        }
        return box
    }

    // MARK: Drag source (drag files OUT of a column to the other pane, Finder, other apps)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> NSPasteboardWriting?
    {
        guard let index = columnIndex(of: tableView), row < columns[index].entries.count else {
            return nil
        }
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
            guard row < columns[index].entries.count, !columns[index].entries[row].isDataless else {
                return nil
            }
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
        guard let index = columnIndex(of: tableView), let urls = draggedURLs(info), !urls.isEmpty
        else {
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
        guard !resolvedDragOperation(info).isEmpty else { return false }
        onDropFiles?(incoming, resolvedDragOperation(info) == .move, destination)
        return true
    }

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL]? {
        FileDrag.readFileURLs(from: info.draggingPasteboard)
    }

    /// Move dragged items between folders by default (else copy); Command inverts it, matching
    /// the list. Driven by the pref via PaneController.
    var dragMovesByDefault = Preferences.default.dragMovesByDefault

    private func resolvedDragOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        FileDrag.operation(for: info, movesByDefault: dragMovesByDefault)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let table = sender as? NSTableView, let index = columnIndex(of: table) else { return }
        let row = table.clickedRow
        guard row >= 0, row < columns[index].entries.count else { return }
        let entry = columns[index].entries[row]
        if !entry.isDirectory { onOpen?(entry) }  // folders drill via single-click; files open
    }

    private var singleClickToOpen = false

    /// Single-click-to-open: a plain click on a file opens it when the preference is on. Folders keep
    /// drilling (the column view's normal behavior), and a modified click (extending a selection) is
    /// left alone. Double-click still opens regardless of the preference.
    @objc private func singleClicked(_ sender: Any?) {
        guard singleClickToOpen, let table = sender as? NSTableView,
            let index = columnIndex(of: table)
        else { return }
        let row = table.clickedRow
        guard row >= 0, row < columns[index].entries.count else { return }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        guard !flags.contains(.shift), !flags.contains(.command) else { return }
        let entry = columns[index].entries[row]
        if !entry.isDirectory { onOpen?(entry) }
    }

    func setClickBehavior(singleClick: Bool, underlineHover: Bool) {
        singleClickToOpen = singleClick  // hover-underline isn't applied in the dense column view
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
    var keyView: NSView {
        columns.indices.contains(activeColumn) ? columns[activeColumn].table : container
    }

    var entries: [FileEntry] {
        columns.indices.contains(activeColumn) ? columns[activeColumn].entries : []
    }
    var selectedEntries: [FileEntry] {
        guard columns.indices.contains(activeColumn) else { return [] }
        let col = columns[activeColumn]
        return col.table.selectedRowIndexes.compactMap {
            $0 < col.entries.count ? col.entries[$0] : nil
        }
    }

    var directoryURL: URL? {
        get { columns.indices.contains(activeColumn) ? columns[activeColumn].folder : rootURL }
        set {
            if rootURL != newValue {
                folderOpenGeneration += 1
                pendingFolderOpen = nil
                columnWorkGeneration += 1
                deferredDrilledRefresh = false
                deferredDrilledCompletions = []
                pendingDrilledRefreshGeneration = nil
            }
            rootURL = newValue
        }
    }
    var resolutionURL: URL? {
        get { storedResolutionURL }
        set { storedResolutionURL = newValue }
    }

    // MARK: In-place rename (Finder-style, so New Folder drops straight into editing here too)

    /// Begin editing the single selected item's name inline, in the active column's table. Returns
    /// false when it can't, so the pane falls back to the rename sheet.
    func beginInlineRename() -> Bool {
        guard editingEntry == nil, columns.indices.contains(activeColumn) else { return false }
        let col = columns[activeColumn]
        let row = col.table.selectedRow
        guard row >= 0, row < col.entries.count else { return false }
        let entry = col.entries[row]
        col.table.scrollRowToVisible(row)
        guard
            let cell = col.table.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? NSTableCellView,
            let field = cell.textField
        else { return false }
        editingEntry = entry
        editingTable = col.table
        editingRow = row
        renameCancelled = false
        field.delegate = self
        field.stringValue = entry.name  // the plain name, without git/tag decoration
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.focusRingType = .default
        col.table.window?.makeFirstResponder(field)
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
        let table = editingTable
        let row = editingRow
        editingEntry = nil
        editingTable = nil
        editingRow = -1
        renameCancelled = false
        if let table, row >= 0, row < table.numberOfRows,
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? NSTableCellView,
            let field = cell.textField
        {
            endInlineEditing(field)
            if field.currentEditor() != nil { table.window?.makeFirstResponder(table) }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
        if selector == #selector(NSResponder.cancelOperation(_:)) {  // Esc abandons the edit
            renameCancelled = true
            editingTable?.window?.makeFirstResponder(editingTable)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let entry = editingEntry else { return }
        endInlineEditing(field)
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let table = editingTable
        let row = editingRow
        let cancelled = renameCancelled
        editingEntry = nil
        editingTable = nil
        editingRow = -1
        renameCancelled = false
        defer {
            if deferredDrilledRefresh {
                deferredDrilledRefresh = false
                let completions = deferredDrilledCompletions
                deferredDrilledCompletions = []
                refreshDrilledColumns(afterApply: { completions.forEach { $0() } })
            }
        }
        if let table, row >= 0, row < table.numberOfRows {
            table.reloadData(
                forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
        guard !cancelled, !newName.isEmpty, newName != entry.name else { return }
        onInlineRename?(entry, newName)
    }

    func setEntries(_ entries: [FileEntry], preserveState: Bool) {
        cancelInlineEdit()  // a reload recycles the editing cell; don't let it commit a partial name
        guard let root = rootURL else {
            pendingFolderOpen = nil
            folderOpenGeneration += 1
            columnWorkGeneration += 1
            columns = []
            relayout()
            return
        }
        // An in-place refresh (a watcher tick on the root) updates the first column
        // without collapsing the drilled columns or losing focus/selection.
        if preserveState, let first = columns.first, first.folder == root {
            // Restoring selection is not a user drill gesture. Otherwise reselecting the
            // root's folder opens it again, replaces the child table and steals activeColumn.
            preservingColumnState {
                columns[0].entries = entries
                first.table.reloadData()
            }
            refreshColumnTags()  // a watcher tick may include external tag edits
            return
        }
        pendingFolderOpen = nil
        folderOpenGeneration += 1
        columnWorkGeneration += 1
        let wasFocused =
            outerScroll.window?.firstResponder === container
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
        tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: target.table))
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
        let wasSelecting = selectingProgrammatically
        selectingProgrammatically = true
        defer { selectingProgrammatically = wasSelecting }
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
        for (index, entry) in column.entries.enumerated() where names.contains(entry.name) {
            rows.insert(index)
        }
        let wasSelecting = selectingProgrammatically
        selectingProgrammatically = true
        defer { selectingProgrammatically = wasSelecting }
        column.table.selectRowIndexes(rows, byExtendingSelection: false)
    }

    func showSortIndicator(key: ViewFormat.SortKey, ascending: Bool) {}
    func applyStyle(rowHeight: CGFloat, fontSize: CGFloat, alternatingRows: Bool) {
        let wasRestoring = restoringSortSelection
        restoringSortSelection = true
        defer { restoringSortSelection = wasRestoring }
        columnFontSize = fontSize
        columnRowHeight = rowHeight
        self.alternatingRows = alternatingRows
        for column in columns {
            PaneAppearanceReload.table(column.table, in: column.scroll) {
                column.table.rowHeight = rowHeight
                column.table.usesAlternatingRowBackgroundColors = alternatingRows
            }
        }
    }

    /// Preserve state at delivery time, not when the worker starts: the user can scroll,
    /// select another row or focus the other pane while a metadata read is running.
    private func preservingColumnState(_ update: () -> Void) {
        let wasRestoring = restoringSortSelection
        restoringSortSelection = true
        defer { restoringSortSelection = wasRestoring }
        let outerOrigin = outerScroll.contentView.bounds.origin
        let activeID = columns.indices.contains(activeColumn) ? columns[activeColumn].id : nil
        let focusedTable = columns.first { $0.table === outerScroll.window?.firstResponder }?.table
        let states = columns.map { column in
            (
                column.id,
                Set(
                    column.table.selectedRowIndexes.compactMap {
                        $0 < column.entries.count ? column.entries[$0].name : nil
                    }),
                column.scroll.contentView.bounds.origin
            )
        }
        update()
        for (id, names, origin) in states {
            guard let column = columns.first(where: { $0.id == id }) else { continue }
            let rows = IndexSet(
                column.entries.indices.filter { names.contains(column.entries[$0].name) })
            column.table.selectRowIndexes(rows, byExtendingSelection: false)
            column.table.layoutSubtreeIfNeeded()
            column.scroll.contentView.scroll(to: origin)
            column.scroll.reflectScrolledClipView(column.scroll.contentView)
        }
        if let activeID, let index = columns.firstIndex(where: { $0.id == activeID }) {
            activeColumn = index
        } else {
            activeColumn = min(activeColumn, max(0, columns.count - 1))
        }
        outerScroll.contentView.scroll(to: outerOrigin)
        outerScroll.reflectScrolledClipView(outerScroll.contentView)
        if let focusedTable, columns.contains(where: { $0.table === focusedTable }),
            outerScroll.window?.firstResponder !== focusedTable
        {
            outerScroll.window?.makeFirstResponder(focusedTable)
        }
    }

    /// Re-enumerate the drilled (non-root) columns after a file operation, so an op
    /// inside a drilled column shows its result instead of stale rows. The root
    /// column is refreshed separately by setEntries; here we prune any column whose
    /// folder vanished and reload the rest, preserving each column's selection.
    func refreshDrilledColumns() {
        refreshDrilledColumns(afterApply: {})
    }

    /// The pane's queued create/reveal can only run once its active drilled column is fresh.
    /// Completion belongs to this read, not a shared callback that a later sort could replace.
    func refreshDrilledColumns(afterApply: @escaping @MainActor () -> Void) {
        guard columns.count > 1 else {
            afterApply()
            return
        }
        if isInlineEditing {
            deferredDrilledRefresh = true
            deferredDrilledCompletions.append(afterApply)
            return
        }
        deferredDrilledRefresh = false
        columnWorkGeneration += 1
        let generation = columnWorkGeneration
        pendingDrilledRefreshGeneration = generation
        let root = rootURL
        let format = sortFormat
        let targets = columns.dropFirst().map { ($0.id, $0.folder) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = targets.map { id, folder in
                let exists = FileManager.default.fileExists(atPath: folder.path)
                let entries =
                    exists
                    ? ((try? BulkEnumerator().entries(of: folder, includingHidden: false)) ?? [])
                    : []
                return (
                    id, folder, exists,
                    format.sorted(
                        ListingViewMetadata.enrich(entries, directory: folder, format: format))
                )
            }
            DispatchQueue.main.async {
                guard let self, self.columnWorkGeneration == generation,
                    self.rootURL == root, self.sortFormat == format
                else { return }
                #if DEBUG
                let beforeApply = self.debugWillApplyDrilledRefresh
                self.debugWillApplyDrilledRefresh = nil
                beforeApply?()
                #endif
                guard self.columnWorkGeneration == generation,
                    self.rootURL == root, self.sortFormat == format,
                    targets.count == self.columns.count - 1,
                    targets.enumerated().allSatisfy({ offset, target in
                        self.columns[offset + 1].id == target.0
                            && self.columns[offset + 1].folder == target.1
                    })
                else { return }
                if self.isInlineEditing {
                    self.pendingDrilledRefreshGeneration = nil
                    self.deferredDrilledRefresh = true
                    self.deferredDrilledCompletions.append(afterApply)
                    return
                }
                self.pendingDrilledRefreshGeneration = nil
                self.preservingColumnState {
                    for (id, folder, exists, entries) in results {
                        guard
                            let index = self.columns.firstIndex(where: {
                                $0.id == id && $0.folder == folder
                            })
                        else { continue }
                        if !exists {
                            self.columns.removeSubrange(index...)
                            self.previewColumn = nil
                            break
                        }
                        self.columns[index].entries = entries
                        self.columns[index].table.reloadData()
                    }
                    self.relayout()
                }
                afterApply()
            }
        }
    }

    /// Adopt the pane's sort and re-sort every open column (including drilled ones)
    /// so all columns order consistently, not just the first.
    func setSortFormat(_ format: ViewFormat) {
        guard sortFormat != format else { return }
        sortFormat = format
        columnWorkGeneration += 1
        preservingColumnState {
            for index in columns.indices {
                columns[index].entries = format.sorted(columns[index].entries)
                columns[index].table.reloadData()
            }
        }
        // Comparisons above are pure and immediate. Additional filesystem/Spotlight/default-app
        // reads for a newly selected key happen only in the guarded background worker.
        if !format.metadataRequirements.isEmpty { refreshDrilledColumns() }
    }
}
