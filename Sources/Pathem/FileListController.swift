import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// The file list: a view-based `NSTableView` driven directly by an array of
/// `FileEntry` value types (DESIGN.md §4). View-based + fixed row height + cell
/// recycling is what lets the list render 100k+ (here 1M) rows without
/// materializing them all — the table only asks for the rows it is about to
/// show. `cellRequests` instruments exactly that for the Gate A proof.
@MainActor
final class FileListController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSTextFieldDelegate
{
    let scrollView = NSScrollView()
    let tableView = KeyTableView()
    private let placeholder = NSTextField(labelWithString: "")

    private(set) var entries: [FileEntry] = []

    // MARK: - Arrange By (grouping)
    //
    // `entries` stays the ungrouped, sorted source of truth. `displayRows` is the table's
    // actual rows: header + item rows when grouping, or 1:1 identity items when not (so the
    // ungrouped path is byte-for-byte unchanged). Everything that maps a table row to an entry
    // goes through entryIndex(forRow:); everything that maps an entry to a row uses
    // rows(forNames:).
    private var groupKey: ViewFormat.GroupKey = .none
    private var displayRows: [FileGrouping.Row] = []
    /// Reverse index entryIndex -> table row, rebuilt once with displayRows (O(n)). Avoids the
    /// O(n) firstIndex scan per lookup that made folder-size publishing and cut-marking O(n^2)
    /// on 100k-row folders.
    private var rowForEntry: [Int: Int] = [:]
    /// Group titles the user has collapsed (their items are hidden until re-expanded). Reset on
    /// navigation and on a group-key change, so it never carries stale titles across folders.
    private var collapsedGroups: Set<String> = []
    /// Item count per group title, from the full grouping (so a collapsed header still shows it).
    private var groupCounts: [String: Int] = [:]
    private func rebuildDisplayRows() {
        let full = FileGrouping.rows(entries, by: groupKey, now: Date(), tagColors: { [weak self] in
            self?.tagColors(for: $0) ?? []
        })
        var counts: [String: Int] = [:]
        var currentTitle = ""
        for row in full {
            switch row {
            case .header(let title): currentTitle = title; counts[title] = 0
            case .item: counts[currentTitle, default: 0] += 1
            }
        }
        groupCounts = counts
        guard !collapsedGroups.isEmpty else { displayRows = full; rebuildRowIndex(); return }
        // Drop the item rows under any collapsed header, keeping the header itself.
        var result: [FileGrouping.Row] = []
        var hidingItems = false
        for row in full {
            if case .header(let title) = row {
                hidingItems = collapsedGroups.contains(title)
                result.append(row)
            } else if !hidingItems {
                result.append(row)
            }
        }
        displayRows = result
        rebuildRowIndex()
    }

    /// Rebuild the entryIndex -> row map from the current displayRows (called whenever
    /// displayRows changes: grouping, collapse, and the ungrouped fast path).
    private func rebuildRowIndex() {
        rowForEntry.removeAll(keepingCapacity: true)
        for (row, dr) in displayRows.enumerated() {
            if case .item(let idx) = dr { rowForEntry[idx] = row }
        }
    }

    /// Toggle a group's collapsed state (from a click on its header), preserving the selection.
    private func toggleGroupCollapsed(_ title: String) {
        let names = Set(tableView.selectedRowIndexes.compactMap { entryIndex(forRow: $0).map { entries[$0].name } })
        if collapsedGroups.contains(title) { collapsedGroups.remove(title) } else { collapsedGroups.insert(title) }
        rebuildDisplayRows()
        tableView.reloadData()
        tableView.selectRowIndexes(rows(forNames: names), byExtendingSelection: false)
    }
    /// The entries index a table row shows, or nil for a group-header row.
    private func entryIndex(forRow row: Int) -> Int? {
        guard row >= 0, row < displayRows.count, case .item(let index) = displayRows[row] else { return nil }
        return index
    }
    /// The table row showing the entry at `index`, or nil if not currently displayed. O(1) via
    /// the reverse index instead of an O(n) scan of displayRows.
    private func row(forEntryIndex index: Int) -> Int? { rowForEntry[index] }
    /// The table rows (item rows) whose entry name is in `names`.
    private func rows(forNames names: Set<String>) -> IndexSet {
        var set = IndexSet()
        for (row, displayRow) in displayRows.enumerated() {
            if case .item(let index) = displayRow, index < entries.count, names.contains(entries[index].name) {
                set.insert(row)
            }
        }
        return set
    }
    /// Change the grouping key, preserving the selection by name across the regroup.
    func setGroupKey(_ key: ViewFormat.GroupKey) {
        guard key != groupKey else { return }
        let selected = Set(selectedEntries.map(\.name))
        groupKey = key
        collapsedGroups.removeAll()  // titles differ per key; don't carry collapsed state across
        rebuildDisplayRows()
        tableView.reloadData()
        tableView.selectRowIndexes(rows(forNames: selected), byExtendingSelection: false)
    }

    /// Smoke: group by kind, select the first entry by name, and confirm headers appear and the
    /// table selection maps back to exactly that entry (the row<->entry mapping under grouping).
    func debugGroupedSelectionRoundTrips() -> Bool {
        guard let first = entries.first else { return true }
        let original = groupKey
        setGroupKey(.kind)
        select(name: first.name)
        let hasHeaders = displayRows.contains { if case .header = $0 { return true }; return false }
        let mapped = selectedEntries.count == 1 && selectedEntries.first?.name == first.name
        let sameCount = displayRows.filter { if case .item = $0 { return true }; return false }.count == entries.count
        setGroupKey(original)
        return hasHeaders && mapped && sameCount
    }

    /// Smoke: group by kind, collapse the first group, and confirm its items vanish from the
    /// display rows while the header stays; restore afterward.
    func debugCollapseHidesItems() -> Bool {
        let original = groupKey
        setGroupKey(.kind)
        let before = displayRows.count
        guard let headerRow = displayRows.firstIndex(where: { if case .header = $0 { return true }; return false }),
            case .header(let title) = displayRows[headerRow]
        else { setGroupKey(original); return false }
        toggleGroupCollapsed(title)
        let after = displayRows.count
        let headerStays = displayRows.contains { if case .header(let t) = $0 { return t == title }; return false }
        toggleGroupCollapsed(title)  // re-expand
        let restored = displayRows.count == before
        setGroupKey(original)
        return after < before && headerStays && restored
    }

    /// Count of `viewFor` calls — i.e. how many cell views the table has asked
    /// for. For a virtualized table this stays proportional to the visible
    /// window, never to `entries.count`.
    private(set) var cellRequests = 0

    /// Opened a row (double-click or Cmd-Down; Return now renames, matching Finder).
    var onOpen: ((FileEntry) -> Void)?
    /// This list's table became first responder (its pane became active).
    var onBecomeActive: (() -> Void)?
    /// User changed the sort by clicking a column header.
    var onSortChanged: ((ViewFormat.SortKey, Bool) -> Void)?
    /// The row selection changed (used to update the status bar).
    var onSelectionChanged: (() -> Void)?
    /// Right-drag flick phases, for the super-drag flick + swipe trail (PaneContentView).
    var onDragSession: ((DragSessionEvent) -> Void)?
    /// The user committed an in-place (Finder-style) rename; the pane performs it (+ undo).
    var onInlineRename: ((FileEntry, String) -> Void)?
    /// The item being edited in place, its display row, and a flag set when Esc abandoned the edit
    /// so committing doesn't rename.
    private var editingEntry: FileEntry?
    private var editingRow = -1
    private var renameCancelled = false
    private var suppressSortCallback = false
    /// Open a row on a single click (Finder's single-click mode).
    private var singleClickToOpen = false
    /// Underline the name under the pointer.
    private var underlineOnHover = false
    private var hoveredRow = -1
    private var hoverTrackingArea: NSTrackingArea?
    /// Row font size, applied per cell so a preference change takes effect on reload.
    private var listFontSize: CGFloat = 13
    /// Tag colors per file path, filled by an off-main read after each listing so
    /// the cell path never does a syscall. Reused across refreshes for names
    /// already read.
    private var tagCache: [String: [FileTag.Color]] = [:]
    /// Bumped per listing so a stale background tag read can't clobber a newer one.
    private var tagReadGeneration = 0
    /// Values for the metadata-derived columns (dimensions, permissions, …), keyed by path,
    /// computed off-main only when such a column is visible.
    private var extendedInfo: [String: FileColumns.Extended] = [:]
    private var extendedGeneration = 0
    /// Git state per absolute path (set by the pane after an off-main `git status`).
    private var gitStates: [String: GitFileState] = [:]
    /// Folder sizes (Finder's "calculate all sizes"), computed off-main and cached.
    private var calculateFolderSizes = false
    private var folderSizeCache: [String: DirectorySize.Measurement] = [:]
    /// Thread-safe generation so the background size walk can be cancelled (a new
    /// listing or disabling the option bumps it, stopping in-flight walks).
    private let sizeGen = GenerationBox()
    /// The folder these rows live in, so a dragged row maps to a file URL. nil
    /// while showing search results, which disables drag.
    var directoryURL: URL? {
        didSet { directoryPath = directoryURL?.path }  // cached so cell keys avoid URL building
    }
    /// `directoryURL.path`, cached so per-cell cache lookups don't rebuild it.
    private var directoryPath: String?
    /// The folder used to resolve a row to a URL for actions like Open With. Set
    /// even during search (results are ranked from this folder), so those actions
    /// keep working when drag is disabled.
    var resolutionURL: URL?
    /// Files were dropped onto this list: copy (or move) them into this folder.
    var onDropFiles: ((_ urls: [URL], _ move: Bool, _ destination: URL?) -> Void)?
    /// Files were dropped onto another file (target): show a menu (group / archive / replace / here).
    var onDropOntoFile: ((_ dragged: [URL], _ target: URL) -> Void)?

    /// Entries currently selected in the table.
    var selectedEntries: [FileEntry] {
        tableView.selectedRowIndexes.compactMap { entryIndex(forRow: $0).map { entries[$0] } }
    }

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Apply the user's size (decimal/binary) and date (relative/short/medium) formats to the
    /// size and date columns.
    func setFormats(size: Preferences.SizeFormat, date: Preferences.DateDisplay) {
        byteFormatter.countStyle = size == .binary ? .binary : .file
        switch date {
        case .relative:
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short
            dateFormatter.doesRelativeDateFormatting = true  // "Today" / "Yesterday"
        case .short:
            dateFormatter.dateStyle = .short
            dateFormatter.timeStyle = .short
            dateFormatter.doesRelativeDateFormatting = false
        case .medium:
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .none
            dateFormatter.doesRelativeDateFormatting = false
        }
        tableView.reloadData()
    }

    /// Distinguishes each list's column-autosave key so concurrent panes don't share one.
    private static var instanceCount = 0

    private enum Column: String, CaseIterable {
        case name, size, kind, date, dateCreated, dateAccessed, ext, git, path
        case dimensions, permissions, owner, whereFrom, comment
        var title: String {
            switch self {
            case .name: return L("list.columnName", "Name")
            case .size: return L("list.columnSize", "Size")
            case .kind: return L("list.columnKind", "Kind")
            case .date: return L("list.columnDate", "Date Modified")
            case .dateCreated: return L("list.columnDateCreated", "Date Created")
            case .dateAccessed: return L("list.columnDateAccessed", "Date Last Opened")
            case .ext: return L("list.columnExt", "Extension")
            case .git: return L("list.columnGit", "Git")
            case .path: return L("list.columnPath", "Path")
            case .dimensions: return L("list.columnDimensions", "Dimensions")
            case .permissions: return L("list.columnPermissions", "Permissions")
            case .owner: return L("list.columnOwner", "Owner")
            case .whereFrom: return L("list.columnWhereFrom", "Where From")
            case .comment: return L("list.columnComment", "Comment")
            }
        }
        var width: CGFloat {
            switch self {
            case .name: return 240
            case .size: return 90
            case .kind: return 130
            case .date, .dateCreated, .dateAccessed: return 150
            case .ext: return 90
            case .git: return 56
            case .path: return 280
            case .dimensions, .permissions: return 110
            case .owner: return 120
            case .whereFrom: return 160
            case .comment: return 200
            }
        }
        /// The width the column can be squeezed to before the list gives up and scrolls
        /// horizontally. Chosen so the value still reads (a truncated date beats a scrollbar).
        var squeezeFloor: CGFloat {
            switch self {
            case .name: return 120
            case .size: return 60
            case .kind: return 80
            case .date, .dateCreated, .dateAccessed: return 100
            case .ext: return 56
            case .git: return 44
            case .path: return 120
            case .dimensions: return 80
            case .permissions: return 84
            case .owner: return 80
            case .whereFrom, .comment: return 100
            }
        }
        /// Only columns backed by a ViewFormat sort key get a clickable header.
        var isSortable: Bool { [.name, .size, .date, .dateCreated, .dateAccessed].contains(self) }
        /// Shown by default; the rest are opt-in via the header menu (persisted).
        var defaultVisible: Bool { [.name, .size, .date].contains(self) }
        /// Metadata-derived columns whose values are computed off-main and cached.
        var isExtended: Bool { [.dimensions, .permissions, .owner, .whereFrom, .comment].contains(self) }
    }

    override init() {
        super.init()
        configure()
        ThemeManager.shared.onChange(owner: self) { [weak self] in self?.tableView.reloadData() }
    }

    private func configure() {
        tableView.rowHeight = 24  // fixed height — required for cheap virtualization
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.style = .inset
        // Name flexes to fill the pane (see fitColumns, driven by the clip-view frame change);
        // the value columns stay fixed. We drive it ourselves because AppKit's column autoresize
        // doesn't reconcile oversized columns on first layout.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing

        for column in Column.allCases {
            let col = NSTableColumn(identifier: .init(column.rawValue))
            col.title = column.title
            col.width = column.width
            // Name flexes down in narrow panes, and the value columns squeeze toward their
            // floors before any h-scrollbar appears (see fitColumns). Caps keep columns from
            // ballooning; floors double as the manual-resize minimum.
            col.minWidth = column.squeezeFloor
            switch column {
            case .size, .kind, .ext, .git: col.maxWidth = column.width + 40
            case .date, .dateCreated, .dateAccessed: col.maxWidth = 220
            default: break
            }
            col.sortDescriptorPrototype =
                column.isSortable ? NSSortDescriptor(key: column.rawValue, ascending: true) : nil
            col.isHidden = !column.defaultVisible  // Kind/Extension/Git/Path are opt-in
            tableView.addTableColumn(col)
        }
        // Let users reorder, resize, and show/hide columns; AppKit persists the layout
        // per instance (a unique name avoids multiple live tables stomping one shared
        // autosave key).
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        Self.instanceCount += 1
        // v2: bump the autosave key so the previously-persisted (Date-stretched) column widths are
        // discarded and the sensible defaults above take effect.
        tableView.autosaveName = "PathemFileList.v3.\(Self.instanceCount)"
        tableView.autosaveTableColumns = true
        tableView.headerView?.menu = makeHeaderMenu()

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.action = #selector(handleSingleClick)  // header collapse (+ single-click-open when on)
        tableView.onBecomeActive = { [weak self] in self?.onBecomeActive?() }
        tableView.onSuperDrag = { [weak self] event in self?.onDragSession?(event) }
        tableView.onDragExited = { [weak self] in self?.springLoader.cancel() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        // Name flexes to fit the pane, so most of the time no horizontal bar appears
        // (autohidesScrollers). But once the visible columns outgrow the pane, Name clamps to its
        // minimum and the table genuinely overflows; without a scroller that overflow would be
        // unreachable.
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        // Flex the Name column to fill the pane whenever the pane resizes. Done off a clip-view
        // frame-change notification (not in layout()) so setting the column width can't re-enter
        // the layout pass.
        let clip = scrollView.contentView
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(fitColumns), name: NSView.frameDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnResized(_:)), name: NSTableView.columnDidResizeNotification,
            object: tableView)

        contextMenu.selectedURLs = { [weak self] in self?.selectedFileURLs() ?? [] }
        contextMenu.currentFolder = { [weak self] in self?.directoryURL }
        tableView.menu = contextMenu.menu
        tableView.onBackgroundMenu = { [weak self] in self?.makeBackgroundMenu() }
        tableView.onMiddleClick = { [weak self] row in self?.middleClicked(row) }

        // Drag rows out (to Finder, the other pane, or the sidebar) and accept
        // file drops into this folder.
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        // Advertise every operation to other apps (effectAllowed = "all"), exactly as Finder
        // does. Some browser upload drop zones (e.g. Google Colab) gate acceptance on a broad
        // effectAllowed during dragover and silently refuse a copy-only drag. We never delete a
        // source on an outside move (no move-completion handler), so this stays non-destructive.
        tableView.setDraggingSourceOperationMask(.every, forLocal: false)

        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.maximumNumberOfLines = 0
        placeholder.lineBreakMode = .byWordWrapping
        placeholder.isHidden = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(placeholder)  // floats over the table, does not scroll
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -48),
        ])
    }

    /// A centered message shown over an empty or unreadable folder (nil hides it).
    func showPlaceholder(_ text: String?) {
        if let text {
            placeholder.stringValue = text
            placeholder.isHidden = false
        } else {
            placeholder.isHidden = true
        }
    }

    /// The right-click menu: thin bindings to the command registry (validated and
    /// dispatched by BrowserViewController, same as the menu bar).
    /// The command-backed items that may appear in the right-click menu (for the Settings
    /// toggles and the smoke icon check). The menu itself is built by the shared
    /// `FileContextMenuController`; this stays as the canonical list's public name.
    static var contextCommands: [(id: String, title: String)] { FileContextMenuController.hideableCommands }

    /// The one shared file context menu, used by every pane view so they never drift.
    private let contextMenu = FileContextMenuController()
    func setHiddenContextItems(_ ids: Set<String>) { contextMenu.hiddenItems = ids }
    func setContextMenuOrder(_ order: [String]) { contextMenu.menuOrder = order }

    /// The right-click menu for empty space: folder-level actions on the current directory
    /// (copy its path/name, plus New Folder / New File / Paste). nil for a remote or smart
    /// listing, so the normal item menu shows instead.
    private func makeBackgroundMenu() -> NSMenu? {
        guard let dir = directoryURL else { return nil }
        let menu = NSMenu()
        let copyPath = menu.addItem(withTitle: L("bvc.cmd.copyPath", "Copy Path"), action: #selector(copyFolderPath), keyEquivalent: "")
        copyPath.target = self
        copyPath.image = MenuIcons.image(forCommand: "files.copyPath")
        let copyName = menu.addItem(withTitle: L("bvc.cmd.copyName", "Copy Name"), action: #selector(copyFolderName), keyEquivalent: "")
        copyName.target = self
        copyName.image = MenuIcons.image(forCommand: "files.copyName")
        menu.addItem(.separator())
        for (id, title) in [
            ("files.newFolder", L("list.newFolder", "New Folder")),
            ("files.newFile", L("bvc.cmd.newFile", "New File")),
            ("files.paste", L("list.paste", "Paste")),
        ] {
            let item = menu.addItem(
                withTitle: title, action: #selector(BrowserViewController.performMenuCommand(_:)), keyEquivalent: "")
            item.representedObject = id
            item.image = MenuIcons.image(forCommand: id)
        }
        // In the Trash, offer Empty Trash right on the background, the way Finder does -- otherwise
        // there's no way to empty it without first selecting an item.
        if FileContextMenuController.isTrashFolder(dir) {
            menu.addItem(.separator())
            let empty = menu.addItem(
                withTitle: L("bvc.cmd.emptyTrash", "Empty Trash"),
                action: #selector(BrowserViewController.performMenuCommand(_:)), keyEquivalent: "")
            empty.representedObject = "files.emptyTrash"
            empty.image = MenuIcons.image(forCommand: "files.emptyTrash")
        }
        return menu
    }
    @objc private func copyFolderPath() {
        guard let dir = directoryURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dir.path, forType: .string)
    }
    @objc private func copyFolderName() {
        guard let dir = directoryURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dir.lastPathComponent, forType: .string)
    }

    private var colorRules = ColorRules()
    func setColorRules(_ rules: ColorRules) {
        guard rules != colorRules else { return }
        colorRules = rules
        tableView.reloadData()  // re-color the visible rows
    }

    private var middleClickNewTab = false
    private var openInNewTabHandler: ((URL) -> Void)?
    func setMiddleClickOpensNewTab(_ enabled: Bool) { middleClickNewTab = enabled }
    func setOpenInNewTabHandler(_ handler: ((URL) -> Void)?) { openInNewTabHandler = handler }

    /// Middle-clicking a folder opens it in a new tab (when the preference is on).
    private func middleClicked(_ row: Int) {
        guard middleClickNewTab, let index = entryIndex(forRow: row) else { return }
        let entry = entries[index]
        guard entry.isDirectory else { return }
        openInNewTabHandler?(URL(fileURLWithPath: PaneItemKey.path(for: entry, in: directoryURL)))
    }

    /// Apply display preferences (density-derived row height, font size,
    /// alternating rows). Reloads so recycled cells pick up the new font.
    /// The configured alternating-rows setting, remembered so it can be restored when a folder
    /// background (which forces a uniform background) is cleared.
    private var configuredAlternating = true

    func applyStyle(rowHeight: CGFloat, fontSize: CGFloat, alternatingRows: Bool) {
        listFontSize = fontSize
        configuredAlternating = alternatingRows
        tableView.rowHeight = rowHeight
        if backgroundColor == nil { tableView.usesAlternatingRowBackgroundColors = alternatingRows }
        tableView.reloadData()
    }

    /// The active folder-background color (nil = default). Kept so applyStyle doesn't re-enable
    /// alternating rows while a background is showing.
    private var backgroundColor: NSColor?

    func setBackgroundColor(_ color: NSColor?) {
        backgroundColor = color
        if let color {
            let transparent = color.alphaComponent < 0.02  // a picture is behind; show through
            tableView.backgroundColor = transparent ? .clear : color
            scrollView.backgroundColor = transparent ? .clear : color
            scrollView.drawsBackground = !transparent
            tableView.usesAlternatingRowBackgroundColors = false  // uniform under a folder background
        } else {
            tableView.backgroundColor = .controlBackgroundColor
            scrollView.backgroundColor = .controlBackgroundColor
            scrollView.drawsBackground = true
            tableView.usesAlternatingRowBackgroundColors = configuredAlternating
        }
        tableView.reloadData()
    }

    /// Replace the listing. With `preserveState` (an in-place refresh: a sort, a
    /// file op, a watcher tick) the selection is restored by name and the scroll
    /// position is held, so the list never jumps or deselects under the user.
    /// Without it (navigation, search results) the view resets to the top.
    func setEntries(_ entries: [FileEntry], preserveState: Bool = false) {
        cancelInlineEdit()  // a reload recycles the editing cell; don't let it commit a partial name
        defer {
            refreshTagsAsync()  // read tag colors off the main thread, then redraw
            refreshFolderSizesAsync()  // and folder sizes if enabled
            refreshExtendedColumnsAsync()  // and any metadata columns that are shown
        }
        guard preserveState else {
            self.entries = entries
            collapsedGroups.removeAll()  // a fresh folder: don't carry collapsed titles across
            rebuildDisplayRows()
            tableView.reloadData()
            if !displayRows.isEmpty { tableView.scrollRowToVisible(0) }
            return
        }
        let selectedNames = Set(selectedEntries.map(\.name))
        let origin = scrollView.contentView.bounds.origin
        // A view that had no rows is being filled for the first time -- a fresh list built by a
        // view-mode swap. There is no scroll position worth preserving there, and restoring the
        // clip view's (not-yet-settled) origin is what left the list scrolled past the top, hiding
        // the folders that sort first. Show the top instead.
        let wasPopulated = !self.entries.isEmpty
        self.entries = entries
        rebuildDisplayRows()
        tableView.reloadData()
        // Re-tile now so the table's frame matches the new (possibly much smaller) row
        // count before we clamp and scroll. Right after reloadData the frame is still the
        // OLD height, so both our clamp and the clip view's own bounds constraint would use
        // a stale, too-large size, leaving the view stranded scrolled into empty space
        // below the remaining rows (the "panels scroll down after a change" bug).
        tableView.layoutSubtreeIfNeeded()
        if !selectedNames.isEmpty {
            // Always apply (an empty set clears a selection whose item vanished, instead of
            // leaving NSTableView's stale index-based highlight). Maps names to table rows,
            // which differ from entry indices when grouping is on.
            tableView.selectRowIndexes(rows(forNames: selectedNames), byExtendingSelection: false)
        }
        guard wasPopulated else {  // fresh list (view-mode swap): nothing to preserve, show the top
            if !displayRows.isEmpty { tableView.scrollRowToVisible(0) }
            return
        }
        let maxY = max(0, tableView.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: min(max(origin.y, 0), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Scroll-clamp diagnostics (the shrink-while-scrolled regression check)

    /// Lay the list out at a fixed size so a headless scroll test has real geometry.
    func debugLayout(width: CGFloat, height: CGFloat) {
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        scrollView.layoutSubtreeIfNeeded()
    }

    /// Scroll to the very bottom of the content (for the shrink test).
    func debugScrollToBottom() {
        let y = max(0, tableView.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The current vertical scroll offset (0 == top).
    func debugScrollOriginY() -> CGFloat { scrollView.contentView.bounds.origin.y }

    @objc private func handleDoubleClick() {
        guard let index = entryIndex(forRow: tableView.clickedRow) else { return }
        onOpen?(entries[index])
    }

    /// Begin a Finder-style in-place edit of the single selected row's name. The row's name field,
    /// normally a label, is flipped editable and focused with the base name (sans extension)
    /// selected. Returns false if it can't start, so the pane falls back to the rename sheet.
    func beginInlineRename() -> Bool {
        guard editingEntry == nil else { return false }  // already editing
        let row = tableView.selectedRow
        guard row >= 0, let index = entryIndex(forRow: row) else { return false }
        let entry = entries[index]
        tableView.scrollRowToVisible(row)
        let nameCol = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(Column.name.rawValue))
        guard nameCol >= 0,
            let cell = tableView.view(atColumn: nameCol, row: row, makeIfNecessary: true) as? NSTableCellView,
            let field = cell.textField
        else { return false }
        editingEntry = entry
        editingRow = row
        renameCancelled = false
        field.stringValue = entry.name  // the plain name, without tag-dot / git decoration
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.focusRingType = .default
        tableView.window?.makeFirstResponder(field)
        // Select the base name only (exclude the extension), the way Finder does.
        if let editor = field.currentEditor() {
            let ns = entry.name as NSString
            let ext = ns.pathExtension as NSString
            let baseLength = (!entry.isDirectory && ext.length > 0) ? ns.length - ext.length - 1 : ns.length
            editor.selectedRange = NSRange(location: 0, length: max(0, baseLength))
        }
        return true
    }

    /// Restore an edited name field to its plain-label appearance.
    private func endInlineEditing(_ field: NSTextField) {
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
    }

    /// Abandon an in-progress inline rename without committing. Called before a reload recycles the
    /// editing cell: otherwise a background folder change (FSEvents from another process) resigns
    /// the field and `controlTextDidEndEditing` would commit a half-typed name as a real rename.
    /// Clears the state first so that resignation is a no-op.
    func cancelInlineEdit() {
        guard editingEntry != nil else { return }
        let row = editingRow
        editingEntry = nil
        editingRow = -1
        renameCancelled = false
        let nameCol = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(Column.name.rawValue))
        if nameCol >= 0, row >= 0, row < tableView.numberOfRows,
            let cell = tableView.view(atColumn: nameCol, row: row, makeIfNecessary: false) as? NSTableCellView,
            let field = cell.textField
        {
            endInlineEditing(field)
            if field.currentEditor() != nil { tableView.window?.makeFirstResponder(tableView) }
        }
    }

    // MARK: NSTextFieldDelegate (in-place rename)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {  // Esc abandons the edit
            renameCancelled = true
            tableView.window?.makeFirstResponder(tableView)
            return true
        }
        return false  // let Return / Tab end editing the usual way
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
        // Repaint the row so the stripped tag/git decoration returns, whether or not the name
        // changed; a successful rename also triggers a full re-list from the pane.
        if row >= 0, row < displayRows.count {
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: row),
                columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        }
        guard !cancelled, !newName.isEmpty, newName != entry.name else { return }
        onInlineRename?(entry, newName)
    }

    /// A plain single click: toggle a group header's collapsed state, or (in single-click-to-open
    /// mode) open the clicked row. Wired to the table's action unconditionally so header toggling
    /// always works, independent of the single-click-open preference.
    @objc private func handleSingleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < displayRows.count else { return }
        if case .header(let title) = displayRows[row] { toggleGroupCollapsed(title); return }
        guard singleClickToOpen else { return }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift) || flags.contains(.command) { return }  // extending a selection
        guard let index = entryIndex(forRow: row) else { return }
        onOpen?(entries[index])
    }

    func setClickBehavior(singleClick: Bool, underlineHover: Bool) {
        singleClickToOpen = singleClick
        // The table's action stays wired (see setup) so header-collapse clicks always work; the
        // handler itself consults singleClickToOpen for the open-on-click behavior.
        if underlineHover != underlineOnHover {
            underlineOnHover = underlineHover
            if underlineHover {
                let area = NSTrackingArea(
                    rect: .zero,
                    options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                    owner: self, userInfo: nil)
                tableView.addTrackingArea(area)
                hoverTrackingArea = area
            } else {
                if let area = hoverTrackingArea { tableView.removeTrackingArea(area) }
                hoverTrackingArea = nil
                setHovered(-1)
            }
        }
    }

    @objc func mouseMoved(with event: NSEvent) {
        guard underlineOnHover else { return }
        setHovered(tableView.row(at: tableView.convert(event.locationInWindow, from: nil)))
    }

    @objc func mouseExited(with event: NSEvent) { setHovered(-1) }

    /// Move the hover highlight, reloading just the name cell of the old and new rows.
    private func setHovered(_ row: Int) {
        guard row != hoveredRow else { return }
        let old = hoveredRow
        hoveredRow = row
        let nameCol = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(Column.name.rawValue))
        guard nameCol >= 0 else { return }
        var rows = IndexSet()
        if old >= 0, old < displayRows.count { rows.insert(old) }
        if row >= 0, row < displayRows.count { rows.insert(row) }
        if !rows.isEmpty { tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: nameCol)) }
    }

    // MARK: Open With

    private func selectedFileURLs() -> [URL] {
        return tableView.selectedRowIndexes.compactMap { row -> URL? in
            guard let index = entryIndex(forRow: row) else { return nil }
            let entry = entries[index]
            // Smart-result rows carry their real folder; normal rows use resolutionURL.
            if let location = entry.location {
                return URL(fileURLWithPath: location).appendingPathComponent(entry.name)
            }
            return resolutionURL?.appendingPathComponent(entry.name)
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !suppressSortCallback,
            let descriptor = tableView.sortDescriptors.first,
            let key = descriptor.key,
            let sortKey = ViewFormat.SortKey(rawValue: key)
        else { return }
        onSortChanged?(sortKey, descriptor.ascending)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChanged?()
    }

    /// Select and scroll to a row by name (no-op if not present).
    func select(name: String) {
        let rows = rows(forNames: [name])
        guard let row = rows.first else { return }
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Select all rows whose names are in the set (used to carry selection).
    func selectNames(_ names: Set<String>) {
        tableView.selectRowIndexes(rows(forNames: names), byExtendingSelection: false)
    }

    /// Reflect the active sort in the header: the sorted column shows an up/down
    /// triangle and is highlighted. Setting `sortDescriptors` alone does NOT draw the
    /// triangle (AppKit only does that in response to a live header click), so on load
    /// and after a menu-driven sort the indicator would be missing. Set the indicator
    /// image and highlighted column explicitly, and do it without re-firing onSortChanged.
    func showSortIndicator(key: ViewFormat.SortKey, ascending: Bool) {
        suppressSortCallback = true
        tableView.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: ascending)]
        suppressSortCallback = false
        let sorted = tableView.tableColumn(withIdentifier: .init(key.rawValue))
        // The system sort-indicator triangles (public named images, not exposed as Swift
        // static members): up for ascending, down for descending.
        let arrow = NSImage(
            named: ascending ? NSImage.Name("NSAscendingSortIndicator")
                : NSImage.Name("NSDescendingSortIndicator"))
        for column in tableView.tableColumns {
            tableView.setIndicatorImage(column === sorted ? arrow : nil, in: column)
        }
        tableView.highlightedTableColumn = sorted
    }

    /// The union of the selected rows' rects, clipped to the visible area, in window
    /// coordinates. Nil when nothing is selected or the selection is scrolled out of view.
    func selectionRectInWindow() -> NSRect? {
        let rows = tableView.selectedRowIndexes
        guard !rows.isEmpty else { return nil }
        var union = NSRect.null
        for row in rows { union = union.union(tableView.rect(ofRow: row)) }
        let visible = union.intersection(tableView.visibleRect)
        guard !visible.isNull, visible.height > 1 else { return nil }  // scrolled out of view
        return tableView.convert(visible, to: nil)
    }

    /// The real header state (which column is marked, its direction, and whether the
    /// triangle is actually drawn), for the layout smoke check.
    var debugSortIndicator: (column: String, ascending: Bool, drawn: Bool)? {
        guard let column = tableView.highlightedTableColumn else { return nil }
        return (
            column.identifier.rawValue, tableView.sortDescriptors.first?.ascending ?? true,
            tableView.indicatorImage(in: column) != nil)
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { displayRows.count }

    /// Size the Name column so all columns exactly fill the visible width (Finder-style: Name grows
    /// and shrinks with the pane, value columns fixed). Runs on pane resize, so no column is ever
    /// clipped and no horizontal scrollbar is needed.
    /// Fit the visible columns into the pane without a horizontal scrollbar wherever
    /// possible: Name flexes first (down to its floor), then the value columns squeeze
    /// proportionally from their wanted widths toward their floors. Only when every
    /// column is floored does the table overflow and the scrollbar appear.
    @objc private func fitColumns() {
        guard let name = tableView.tableColumns.first(where: { $0.identifier.rawValue == Column.name.rawValue && !$0.isHidden })
        else { return }
        let others = tableView.tableColumns.filter { $0 !== name && !$0.isHidden }
        // Seed wanted widths lazily from each column's sensible default, NOT the current width:
        // AppKit's autosave may have restored a squeezed width from last quit, and seeding from
        // that would lock the column at its squeeze floor forever. User drags update wanted via
        // columnResized, so deliberate in-session sizing is still honored.
        for col in others where wantedWidths[col.identifier.rawValue] == nil {
            wantedWidths[col.identifier.rawValue] = Column(rawValue: col.identifier.rawValue)?.width ?? col.width
        }
        func wanted(_ col: NSTableColumn) -> CGFloat { wantedWidths[col.identifier.rawValue] ?? col.width }
        func floorOf(_ col: NSTableColumn) -> CGFloat {
            Column(rawValue: col.identifier.rawValue)?.squeezeFloor ?? 80
        }
        // The table is wider than its columns: the .inset style pads the sides (32 pt) and
        // each gap adds intercell spacing. Compute that overhead analytically, and only
        // trust a live measurement when the table genuinely overflows the clip. Measuring
        // `frame - columns` unconditionally was a trap: when the columns are NARROWER than
        // the pane, AppKit stretches the table frame to the clip width, the blank space
        // reads as "chrome", and every column gets locked at its floor (the tiny-columns
        // bug in the right pane).
        let clipWidth = scrollView.contentView.bounds.width
        guard clipWidth > 60 else { return }  // mid-layout slivers would squeeze for nothing
        let visibleCount = others.count + 1
        let sumVisible = name.width + others.reduce(CGFloat(0)) { $0 + $1.width }
        if tableView.frame.width > clipWidth + 0.5 {
            measuredChrome = (max(0, tableView.frame.width - sumVisible), visibleCount)  // true overflow: exact
        }
        let overhead: CGFloat
        if let m = measuredChrome, m.columns == visibleCount {
            overhead = m.width  // chrome grows with column count, so only reuse a matching measurement
        } else {
            overhead = 32 + tableView.intercellSpacing.width * CGFloat(max(0, visibleCount - 1))
        }
        let available = clipWidth - overhead
        let wantedOthers = others.reduce(CGFloat(0)) { $0 + wanted($1) }

        adjustingColumns = true
        defer { adjustingColumns = false }

        if available - wantedOthers >= name.minWidth {
            // Roomy: every value column at its wanted width, Name takes the rest.
            for col in others where abs(col.width - wanted(col)) > 0.5 { col.width = wanted(col) }
            let target = available - wantedOthers
            if abs(name.width - target) > 0.5 { name.width = target }
            return
        }
        // Tight: Name at its floor; squeeze the value columns toward their floors in
        // proportion to how much give each one has, so they land exactly on the pane
        // width until even the floors no longer fit.
        let sumFloors = others.reduce(CGFloat(0)) { $0 + floorOf($1) }
        let remaining = available - name.minWidth
        let give = wantedOthers - sumFloors
        let t = give > 0 ? max(0, min(1, (remaining - sumFloors) / give)) : 0
        for col in others {
            let target = floorOf(col) + (wanted(col) - floorOf(col)) * t
            if abs(col.width - target) > 0.5 { col.width = target }
        }
        if abs(name.width - name.minWidth) > 0.5 { name.width = name.minWidth }
    }

    /// The widths the user (or the defaults) asked for, keyed by column id; compression
    /// works from these, never overwriting intent with squeezed values.
    private var wantedWidths: [String: CGFloat] = [:]
    /// The table's horizontal chrome (side padding + intercell gaps) measured the last
    /// time the table truly overflowed the clip, with the visible column count it was
    /// measured at; nil until then (an analytic estimate covers the gap).
    private var measuredChrome: (width: CGFloat, columns: Int)?
    /// True while fitColumns itself is writing widths, so its own resize notifications
    /// aren't mistaken for user drags.
    private var adjustingColumns = false

    /// PATHEM_SMOKE: how fully the visible columns (plus chrome) fill the clip after a
    /// fit. ~1.0 = exact fit, > 1 = genuine overflow (scrollbar), well under 1 = the
    /// tiny-columns regression.
    func debugColumnFillRatio() -> CGFloat {
        fitColumns()
        let visible = tableView.tableColumns.filter { !$0.isHidden }
        let sum = visible.reduce(CGFloat(0)) { $0 + $1.width }
        let overhead: CGFloat
        if let m = measuredChrome, m.columns == visible.count {
            overhead = m.width
        } else {
            overhead = 32 + tableView.intercellSpacing.width * CGFloat(max(0, visible.count - 1))
        }
        let clip = scrollView.contentView.bounds.width
        return clip > 0 ? (sum + overhead) / clip : 0
    }

    /// A user drag updates the column's wanted width and refits the rest around it.
    @objc private func columnResized(_ note: Notification) {
        guard !adjustingColumns,
            let col = note.userInfo?["NSTableColumn"] as? NSTableColumn,
            col.identifier.rawValue != Column.name.rawValue
        else { return }
        wantedWidths[col.identifier.rawValue] = col.width
        fitColumns()
    }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let index = entryIndex(forRow: row) else { return nil }  // headers don't drag
        let entry = entries[index]
        guard !entry.isDataless, let url = entryURL(entry) else { return nil }  // no location -> can't drag
        // A promise + file URL, so the drag lands in browsers/sandboxed apps and Finder alike.
        return FileDrag.item(for: url)
    }

    /// PATHEM_SMOKE: rows are draggable iff the pane's directory is known (each row resolves its
    /// URL against it). directoryURL is set synchronously by PaneController.reload, so this is true
    /// the instant the view exists -- a regression guard for the "rows show but nothing drags" bug.
    func debugRowsDraggable() -> Bool {
        guard let first = tableView.selectedRowIndexes.first ?? (numberOfRows(in: tableView) > 0 ? 0 : nil)
        else { return directoryURL != nil }  // no rows yet: fall back to the gate itself
        return tableView(tableView, pasteboardWriterForRow: first) != nil
    }

    /// Whether an inline rename is currently in progress (for the reload-safety smoke guard).
    var debugInlineEditActive: Bool { editingEntry != nil }

    /// Whether the name cell at `row` exposes the clean filename to VoiceOver (A8 guard).
    func debugNameAXMatchesEntry(row: Int) -> Bool {
        guard let index = entryIndex(forRow: row) else { return false }
        let col = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(Column.name.rawValue))
        guard col >= 0,
            let cell = tableView.view(atColumn: col, row: row, makeIfNecessary: true) as? NSTableCellView
        else { return false }
        return cell.textField?.accessibilityLabel() == entries[index].name
    }

    func tableView(
        _ tableView: NSTableView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet
    ) {
        let urls = rowIndexes.compactMap { row -> URL? in
            guard let index = entryIndex(forRow: row), !entries[index].isDataless else { return nil }
            return entryURL(entries[index])
        }
        FileDrag.addLegacyFilenames(urls, to: session.draggingPasteboard)
    }

    /// The real file URL for an entry: its own `location` (smart/search results span folders)
    /// or the listed `directoryURL`. nil when neither is known.
    private func entryURL(_ entry: FileEntry) -> URL? {
        let path = PaneItemKey.path(for: entry, in: directoryURL)
        return path == entry.name ? nil : URL(fileURLWithPath: path)
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
        proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let urls = draggedURLs(from: info), !urls.isEmpty else { springLoader.cancel(); return [] }
        // Over a folder row (that isn't one of the dragged items) -> drop INTO it, with
        // the row highlighted. Otherwise drop into the current folder.
        if let folder = folderRow(at: row, excluding: urls), !incomingURLs(urls, into: folder).isEmpty {
            tableView.setDropRow(row, dropOperation: .on)
            armSpring(atRow: row, folder: folder)  // dwell here to spring the folder open
        } else if fileRow(at: row, excluding: urls) != nil {
            // Dropping onto another file: highlight it: the drop offers a menu (group / archive /
            // replace) rather than the meaningless "into a file".
            springLoader.cancel()
            tableView.setDropRow(row, dropOperation: .on)
        } else {
            springLoader.cancel()
            guard !incomingURLs(urls, into: directoryURL).isEmpty else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)  // into this folder
        }
        return resolvedDragOperation(for: info)
    }

    /// Spring-loaded folders: dwelling over a folder row during a drag opens it (via onOpen, which
    /// descends), so a drag can walk into a tree without dropping.
    private let springLoader = SpringLoader()
    private func armSpring(atRow row: Int, folder: URL) {
        guard let index = entryIndex(forRow: row) else { springLoader.cancel(); return }
        let entry = entries[index]
        springLoader.arm(key: folder.path) { [weak self] in self?.onOpen?(entry) }
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
        row: Int, dropOperation: NSTableView.DropOperation
    ) -> Bool {
        springLoader.cancel()  // the drop resolved; don't spring afterward
        guard let urls = draggedURLs(from: info), !urls.isEmpty else { return false }
        if let folder = folderRow(at: row, excluding: urls) {
            let incoming = incomingURLs(urls, into: folder)
            guard !incoming.isEmpty else { return false }
            onDropFiles?(incoming, resolvedDragOperation(for: info) == .move, folder)
            return true
        }
        if let target = fileRow(at: row, excluding: urls) {
            onDropOntoFile?(urls, target)  // dropped onto a file -> the drop menu decides what to do
            return true
        }
        let incoming = incomingURLs(urls, into: directoryURL)
        guard !incoming.isEmpty else { return false }
        onDropFiles?(incoming, resolvedDragOperation(for: info) == .move, nil)
        return true
    }

    /// The file URL at `row`, if it's a non-directory not among the dragged items (the target of a
    /// file-onto-file drop).
    private func fileRow(at row: Int, excluding dragged: [URL]) -> URL? {
        guard let index = entryIndex(forRow: row), !entries[index].isDirectory, let dir = directoryURL else { return nil }
        let file = dir.appendingPathComponent(entries[index].name)
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        if dragged.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == path }) { return nil }
        return file
    }

    /// The folder URL at `row`, if it's a directory not among the dragged items.
    private func folderRow(at row: Int, excluding dragged: [URL]) -> URL? {
        guard let index = entryIndex(forRow: row), entries[index].isDirectory, let dir = directoryURL else { return nil }
        let folder = dir.appendingPathComponent(entries[index].name)
        let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        // Don't allow dropping a folder onto itself.
        if dragged.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == folderPath }) {
            return nil
        }
        return folder
    }

    /// All file URLs on the drag pasteboard.
    private func draggedURLs(from info: NSDraggingInfo) -> [URL]? {
        FileDrag.readFileURLs(from: info.draggingPasteboard)
    }

    /// Of `urls`, the ones not already directly inside `destination` (dropping onto their
    /// own folder is a no-op). Symlink-resolved + case-insensitive.
    private func incomingURLs(_ urls: [URL], into destination: URL?) -> [URL] {
        guard let destination else { return [] }
        let destPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        return urls.filter {
            let parent = $0.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            return parent.compare(destPath, options: .caseInsensitive) != .orderedSame
        }
    }

    /// When dragging items between folders moves by default (Settings > General);
    /// Command then copies. When off (the Finder-like default) it copies and Command
    /// moves.
    var dragMovesByDefault = false

    /// Resolve copy vs move from the default and the Command modifier (which inverts
    /// it). Move only when the source actually offers it (e.g. same volume).
    private func resolvedDragOperation(for info: NSDraggingInfo) -> NSDragOperation {
        let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        let wantMove = dragMovesByDefault != commandHeld  // Command inverts the default
        return wantMove && info.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Group-header rows span the width; render the header once (nil column or the name
        // column) and nothing for the other columns.
        if row < displayRows.count, case .header(let title) = displayRows[row] {
            let isNameOrSpanning = tableColumn == nil || tableColumn?.identifier.rawValue == Column.name.rawValue
            return isNameOrSpanning ? groupHeaderView(title) : nil
        }
        guard let tableColumn, let entryIndex = entryIndex(forRow: row) else { return nil }
        cellRequests += 1

        let id = tableColumn.identifier
        let isName = id.rawValue == Column.name.rawValue
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? Self.makeCell(id, withIcon: isName)

        let entry = entries[entryIndex]
        cell.textField?.font = .systemFont(ofSize: listFontSize)
        // Dim items marked for cut, then hidden (dotfile) items -- so when "show hidden
        // files" is on you can tell the hidden ones apart from ordinary files, as Finder does.
        cell.alphaValue = isCut(entry) ? 0.45 : (entry.isHidden ? 0.5 : 1.0)
        switch Column(rawValue: id.rawValue) {
        case .name:
            cell.textField?.delegate = self  // so in-place rename commits reach us
            // A matching color rule tints/styles the name; else the dataless/normal default.
            let ruleStyle = FileColorStyle.style(
                for: entry, rules: colorRules, baseFont: .systemFont(ofSize: listFontSize))
            cell.textField?.font = ruleStyle?.font ?? .systemFont(ofSize: listFontSize)
            let defaultColor: NSColor = entry.isDataless ? .secondaryLabelColor : .labelColor
            cell.textField?.textColor = ruleStyle?.color ?? defaultColor
            let baseIcon = entry.isDataless ? Self.cloudIcon : FileIconCache.icon(for: entry, in: directoryURL)
            cell.imageView?.image = CloudBadge.decorate(baseIcon, for: entry, in: directoryURL)
            let colors = tagColors(for: entry)
            let git = gitState(for: entry)
            if colors.isEmpty, git == nil {
                cell.textField?.stringValue = entry.name
            } else {
                cell.textField?.attributedStringValue = FileNameDecoration.decoratedName(
                    entry.name, git: git, dots: colors, size: listFontSize,
                    nameFont: ruleStyle?.font, nameColor: ruleStyle?.color)
            }
            // VoiceOver otherwise reads the git letter + tag-dot glyphs in the attributed name; give
            // it the clean filename instead (A8).
            cell.textField?.setAccessibilityLabel(entry.name)
            if underlineOnHover, row == hoveredRow, let field = cell.textField {
                let text =
                    field.attributedStringValue.length > 0
                    ? NSMutableAttributedString(attributedString: field.attributedStringValue)
                    : NSMutableAttributedString(
                        string: field.stringValue,
                        attributes: [
                            .font: NSFont.systemFont(ofSize: listFontSize),
                            .foregroundColor: field.textColor ?? NSColor.labelColor,
                        ])
                text.addAttribute(
                    .underlineStyle, value: NSUnderlineStyle.single.rawValue,
                    range: NSRange(location: 0, length: text.length))
                field.attributedStringValue = text
            }
        case .size:
            if entry.isDirectory {
                if let measure = folderSize(for: entry) {
                    // A trailing "+" marks an undercount from an unreadable subtree.
                    cell.textField?.stringValue =
                        byteFormatter.string(fromByteCount: measure.bytes) + (measure.complete ? "" : "+")
                } else {
                    cell.textField?.stringValue = "--"
                }
            } else {
                cell.textField?.stringValue = byteFormatter.string(fromByteCount: entry.size)
            }
        case .kind:
            cell.textField?.stringValue = Self.kind(for: entry)
        case .date:
            cell.textField?.stringValue = entry.modificationDate.map { dateFormatter.string(from: $0) } ?? ""
        case .dateCreated:
            cell.textField?.stringValue = entry.creationDate.map { dateFormatter.string(from: $0) } ?? ""
        case .dateAccessed:
            cell.textField?.stringValue = entry.accessDate.map { dateFormatter.string(from: $0) } ?? ""
        case .ext:
            cell.textField?.stringValue =
                entry.isDirectory ? "" : (entry.name as NSString).pathExtension.lowercased()
        case .git:
            cell.textField?.stringValue = gitState(for: entry).map { FileNameDecoration.gitBadge($0).letter } ?? ""
        case .path:
            cell.textField?.stringValue = entry.location ?? directoryURL?.path ?? ""
            cell.textField?.textColor = .secondaryLabelColor
        case .dimensions, .permissions, .owner, .whereFrom, .comment:
            let info = extendedInfo[Self.key(base: entry.location ?? directoryURL?.path, name: entry.name)]
            let value: String?
            switch Column(rawValue: id.rawValue) {
            case .dimensions: value = info?.dimensions
            case .permissions: value = info?.permissions
            case .owner: value = info?.owner
            case .whereFrom: value = info?.whereFrom
            case .comment: value = info?.comment
            default: value = nil
            }
            cell.textField?.stringValue = value ?? ""
            cell.textField?.textColor = .secondaryLabelColor
        case .none:
            break
        }
        return cell
    }

    // MARK: Group rows (Arrange By)

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if row < displayRows.count, case .header = displayRows[row] { return true }
        return false
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        entryIndex(forRow: row) != nil  // headers are not selectable
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if row < displayRows.count, case .header = displayRows[row] { return 20 }
        return tableView.rowHeight
    }

    /// A section-header cell for a group row: a small, semibold, uppercase-ish label.
    private func groupHeaderView(_ title: String) -> NSView {
        let id = NSUserInterfaceItemIdentifier("groupHeader")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let view = NSTableCellView()
                view.identifier = id
                let field = NSTextField(labelWithString: "")
                field.font = .systemFont(ofSize: 11, weight: .semibold)
                field.textColor = .secondaryLabelColor
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(field)
                view.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
                    field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
                    field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
                return view
            }()
        let collapsed = collapsedGroups.contains(title)
        let count = groupCounts[title] ?? 0
        cell.textField?.stringValue = "\(collapsed ? "▸" : "▾")  \(title)  (\(count))"
        return cell
    }

    /// Tint a tagged row with its (first) label color, so labels read as colored
    /// rows, not just dots.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("tintRow")
        let rowView =
            (tableView.makeView(withIdentifier: id, owner: self) as? TintRowView)
            ?? {
                let view = TintRowView()
                view.identifier = id
                return view
            }()
        let color = entryIndex(forRow: row).flatMap { tagColors(for: entries[$0]).first }
        rowView.tint = color.map { TagColors.nsColor($0) }
        return rowView
    }

    /// A human-readable file kind (localized) derived from the type, no I/O.
    private static func kind(for entry: FileEntry) -> String {
        if entry.isDirectory { return L("list.kindFolder", "Folder") }
        let ext = (entry.name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type.localizedDescription ?? String(format: L("list.kindExtFile", "%@ file"), ext.uppercased())
        }
        return L("list.kindDocument", "Document")
    }

    /// The right-click menu on the column header: toggle each optional column.
    private func makeHeaderMenu() -> NSMenu {
        let menu = NSMenu()
        for column in Column.allCases where column != .name {  // Name is always shown
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let column = tableView.tableColumn(withIdentifier: .init(id))
        else { return }
        column.isHidden.toggle()
        // Showing a metadata column needs its values computed; hiding one lets the pass stop.
        if Column(rawValue: id)?.isExtended == true { refreshExtendedColumnsAsync() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Check the header-menu items that map to a column's visibility.
        if let id = menuItem.representedObject as? String,
            let column = tableView.tableColumn(withIdentifier: .init(id))
        {
            menuItem.state = column.isHidden ? .off : .on
        }
        return true
    }

    private static func makeCell(_ id: NSUserInterfaceItemIdentifier, withIcon: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        // The Name column reads as a label but can be flipped to an editable field for in-place
        // rename (see beginInlineRename); other columns stay plain labels.
        let field: NSTextField
        if withIcon {
            field = NSTextField()
            field.isEditable = false
            field.isSelectable = false
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.backgroundColor = .clear
            field.focusRingType = .none
        } else {
            field = NSTextField(labelWithString: "")
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.font = .systemFont(ofSize: 13)
        cell.addSubview(field)
        cell.textField = field

        if withIcon {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            cell.addSubview(icon)
            cell.imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    /// Tag colors for a row, read only from the cache so the cell path never does
    /// a filesystem syscall on the main thread. The cache is filled by
    /// refreshTagsAsync after each listing change.
    private func tagColors(for entry: FileEntry) -> [FileTag.Color] {
        guard directoryURL != nil else { return [] }  // search results span folders: no dots
        return tagCache[cacheKey(for: entry)] ?? []
    }

    /// Update the git overlays and redraw if anything changed.
    func setGitStates(_ states: [String: GitFileState]) {
        guard states != gitStates else { return }
        let hadAny = !gitStates.isEmpty
        gitStates = states
        if hadAny || !states.isEmpty { tableView.reloadData() }
    }

    private func gitState(for entry: FileEntry) -> GitFileState? {
        guard !gitStates.isEmpty else { return nil }
        return gitStates[cacheKey(for: entry)]
    }

    /// Drop cached tag colors so the next refresh re-reads from disk (call after
    /// the app itself changes tags).
    func invalidateTagCache() { tagCache.removeAll() }

    /// Paths currently marked for cut, dimmed until pasted or the cut is cleared.
    private var cutPaths: Set<String> = []

    func setCutPaths(_ paths: Set<String>) {
        guard paths != cutPaths else { return }
        let changed = paths.symmetricDifference(cutPaths)  // only these rows change appearance
        cutPaths = paths
        var rows = IndexSet()
        for (index, entry) in entries.enumerated() where changed.contains(cacheKey(for: entry)) {
            if let row = row(forEntryIndex: index) { rows.insert(row) }  // entry index -> table row
        }
        guard !rows.isEmpty else { return }  // the cut/clear was in another folder
        tableView.reloadData(
            forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    /// The on-disk path of an entry (smart-result rows carry their own folder;
    /// normal rows live in directoryURL).
    /// The absolute on-disk path of a row, used as the key for the tag, size, and
    /// cut caches. Built with `NSString` (cheap) rather than `URL.appendingPathComponent`
    /// so it can run per cell in the scroll hot path; smart-result rows carry their
    /// own folder, normal rows live in `directoryPath`. All cache writers build keys
    /// the same way (see `Self.key`) so lookups always hit.
    private func cacheKey(for entry: FileEntry) -> String {
        Self.key(base: entry.location ?? directoryPath, name: entry.name)
    }

    private static func key(base: String?, name: String) -> String {
        guard let base else { return name }
        return (base as NSString).appendingPathComponent(name)
    }

    private func isCut(_ entry: FileEntry) -> Bool {
        guard !cutPaths.isEmpty else { return false }
        return cutPaths.contains(cacheKey(for: entry))
    }

    /// A cached folder size, or nil when not computed (or the option is off).
    private func folderSize(for entry: FileEntry) -> DirectorySize.Measurement? {
        guard calculateFolderSizes, entry.isDirectory, directoryURL != nil else { return nil }
        return folderSizeCache[cacheKey(for: entry)]
    }

    /// Turn the "calculate all sizes" option on or off.
    func setCalculateFolderSizes(_ on: Bool) {
        guard on != calculateFolderSizes else { return }
        calculateFolderSizes = on
        if on {
            refreshFolderSizesAsync()
        } else {
            _ = sizeGen.bump()  // cancel any in-flight computation
            tableView.reloadData()  // folders go back to "--"
        }
    }

    /// Compute folder sizes off the main thread, publishing each row as it finishes
    /// (reusing already-computed sizes). The walk stops early once its generation is
    /// stale (a newer listing or the option turned off), and each publish is O(1).
    private func refreshFolderSizesAsync() {
        guard calculateFolderSizes, let dir = directoryURL else { return }
        let generation = sizeGen.bump()
        let folders: [(name: String, row: Int)] = entries.enumerated()
            .compactMap { row, entry in entry.isDirectory ? (entry.name, row) : nil }
        let known = folderSizeCache
        let gen = sizeGen
        let base = dir.path
        let sizeColumn = tableView.column(withIdentifier: .init(Column.size.rawValue))
        // Each folder's subtree walk is independent, so compute several at once instead
        // of one-at-a-time. Workers stride through the list (interleaved) and each keeps
        // its own batch, publishing on the main thread as sizes finish, so they fill in
        // progressively and a folder full of large subfolders is much faster.
        let workers = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount - 1))
        for offset in 0..<workers {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var batch: [(path: String, name: String, row: Int, size: DirectorySize.Measurement)] = []
                func flush() {
                    let pending = batch
                    batch = []
                    DispatchQueue.main.async { [weak self] in
                        self?.publishFolderSizes(pending, generation: generation, sizeColumn: sizeColumn)
                    }
                }
                var index = offset
                while index < folders.count {
                    guard gen.isCurrent(generation) else { return }  // navigated away / disabled
                    let folder = folders[index]
                    let path = Self.key(base: base, name: folder.name)  // same key as viewFor
                    let size = known[path] ?? DirectorySize.total(of: URL(fileURLWithPath: path))
                    batch.append((path, folder.name, folder.row, size))
                    if batch.count >= 16 { flush() }
                    index += workers
                }
                if !batch.isEmpty { flush() }
            }
        }
    }

    /// Apply a batch of computed folder sizes and redraw just those rows' size cells.
    private func publishFolderSizes(
        _ pending: [(path: String, name: String, row: Int, size: DirectorySize.Measurement)],
        generation: Int, sizeColumn: Int
    ) {
        guard sizeGen.isCurrent(generation) else { return }
        var rows = IndexSet()
        for item in pending
        where item.row < entries.count && entries[item.row].isDirectory
            && entries[item.row].name == item.name {
            folderSizeCache[item.path] = item.size
            if let tableRow = row(forEntryIndex: item.row) { rows.insert(tableRow) }  // entry index -> table row
        }
        guard !rows.isEmpty else { return }
        let columns =
            sizeColumn >= 0 ? IndexSet(integer: sizeColumn) : IndexSet(integersIn: 0..<tableView.numberOfColumns)
        tableView.reloadData(forRowIndexes: rows, columnIndexes: columns)
    }

    /// Read tag colors for the current entries off the main thread (reusing the
    /// cache for names already read), then redraw. Generation-guarded so a later
    /// listing supersedes an in-flight read.
    private func refreshTagsAsync() {
        guard let dir = directoryURL else {
            tagCache.removeAll()
            return
        }
        tagReadGeneration += 1
        let generation = tagReadGeneration
        let base = dir.path
        let names = entries.map(\.name)
        let known = tagCache
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result: [String: [FileTag.Color]] = [:]
            result.reserveCapacity(names.count)
            for name in names {
                let path = Self.key(base: base, name: name)  // same key construction as viewFor's lookups
                if let cached = known[path] {
                    result[path] = cached
                } else {
                    result[path] = FileTags.tags(of: URL(fileURLWithPath: path)).map(\.color)
                        .filter { $0 != .none }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.tagReadGeneration == generation else { return }
                let hadDots = self.tagCache.contains { !$0.value.isEmpty }
                self.tagCache = result
                // When grouping by tag, the buckets depend on the tags we just read, so rebuild
                // the display rows (preserving selection) and reload.
                if self.groupKey == .tag {
                    let selected = Set(self.selectedEntries.map(\.name))
                    self.rebuildDisplayRows()
                    self.tableView.reloadData()
                    self.tableView.selectRowIndexes(self.rows(forNames: selected), byExtendingSelection: false)
                } else if hadDots || result.contains(where: { !$0.value.isEmpty }) {
                    // Only redraw if any row actually shows a dot, so the common
                    // untagged case never triggers a second reload.
                    self.tableView.reloadData()
                }
            }
        }
    }

    /// Which metadata columns are currently visible (so the pass only does needed work).
    private func visibleExtendedRequest() -> FileColumns.Request {
        var request: FileColumns.Request = []
        func on(_ column: Column, _ flag: FileColumns.Request) {
            if let col = tableView.tableColumn(withIdentifier: .init(column.rawValue)), !col.isHidden {
                request.insert(flag)
            }
        }
        on(.dimensions, .dimensions)
        on(.permissions, .permissions)
        on(.owner, .owner)
        on(.whereFrom, .whereFrom)
        on(.comment, .comment)
        return request
    }

    /// Compute the visible metadata columns off-main, then cache and redraw. Skips entirely
    /// when none are shown (the common case), so it costs nothing by default.
    func refreshExtendedColumnsAsync() {
        let request = visibleExtendedRequest()
        guard !request.isEmpty else {
            if !extendedInfo.isEmpty { extendedInfo = [:] }
            return
        }
        extendedGeneration += 1
        let generation = extendedGeneration
        let base = directoryURL?.path
        let items = entries.map { (name: $0.name, location: $0.location) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result: [String: FileColumns.Extended] = [:]
            result.reserveCapacity(items.count)
            for item in items {
                let path = Self.key(base: item.location ?? base, name: item.name)
                result[path] = FileColumns.gather(URL(fileURLWithPath: path), request)
            }
            DispatchQueue.main.async {
                guard let self, self.extendedGeneration == generation else { return }
                self.extendedInfo = result
                self.tableView.reloadData()
            }
        }
    }

    // Name decoration (git badge + tag dots) lives in the shared `FileNameDecoration` so the
    // list and column views render identically.

    /// Badge for online-only (dataless) cloud placeholders.
    private static let cloudIcon: NSImage =
        NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: L("list.onlineOnly", "Online only"))
        ?? NSImage()

    /// A type icon for the entry, cached by extension (via the shared FileIconCache so the
    /// list, column, and tree views share one cache) so scrolling a huge directory never does
    /// per-row disk work.
}

/// A lock-guarded generation counter, readable from a background queue so an
/// in-flight computation can detect it has been superseded and stop.
final class GenerationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == generation
    }
}

/// A list row that paints a faint wash of its label color behind the content, so a
/// tagged file reads as a colored row (not just a dot). Skipped while selected so the
/// selection highlight stays clear.
final class TintRowView: NSTableRowView {
    var tint: NSColor? {
        didSet { if tint != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let tint, !isSelected else { return }
        tint.withAlphaComponent(0.16).setFill()
        dirtyRect.fill()
    }

    /// Recolor the selection with the skin's accent when one is set; otherwise the stock look.
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, let accent = ThemeManager.shared.customAccent else {
            super.drawSelection(in: dirtyRect)
            return
        }
        (isEmphasized ? accent : accent.withAlphaComponent(0.55)).setFill()
        dirtyRect.fill()
    }
}
