import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// The file list: a view-based `NSTableView` driven directly by an array of
/// `FileEntry` value types (DESIGN.md §4). View-based + fixed row height + cell
/// recycling is what lets the list render 100k+ (here 1M) rows without
/// materializing them all — the table only asks for the rows it is about to
/// show. `cellRequests` instruments exactly that for the Gate A proof.
@MainActor
final class FileListController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let scrollView = NSScrollView()
    let tableView = KeyTableView()
    private let placeholder = NSTextField(labelWithString: "")
    /// Populated on demand with the apps that can open the selection.
    private let openWithMenu = NSMenu()

    private(set) var entries: [FileEntry] = []

    /// Count of `viewFor` calls — i.e. how many cell views the table has asked
    /// for. For a virtualized table this stays proportional to the visible
    /// window, never to `entries.count`.
    private(set) var cellRequests = 0

    /// Opened a row (double-click, Return/Enter, or Cmd-Down).
    var onOpen: ((FileEntry) -> Void)?
    /// This list's table became first responder (its pane became active).
    var onBecomeActive: (() -> Void)?
    /// User changed the sort by clicking a column header.
    var onSortChanged: ((ViewFormat.SortKey, Bool) -> Void)?
    /// The row selection changed (used to update the status bar).
    var onSelectionChanged: (() -> Void)?
    /// Row-drag phases, for the super-drag flick + swipe trail (PaneContentView).
    var onDragSession: ((DragSessionEvent) -> Void)?
    /// Where a row drag started, in screen coordinates, so its end can be reduced to a flick.
    private var dragStartScreen: NSPoint?
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

    /// Entries currently selected in the table.
    var selectedEntries: [FileEntry] {
        tableView.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }
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
            case .name: return 360
            case .size: return 110
            case .kind: return 130
            case .date, .dateCreated, .dateAccessed: return 180
            case .ext: return 90
            case .git: return 56
            case .path: return 280
            case .dimensions, .permissions: return 110
            case .owner: return 120
            case .whereFrom: return 160
            case .comment: return 200
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
    }

    private func configure() {
        tableView.rowHeight = 24  // fixed height — required for cheap virtualization
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.style = .inset
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        for column in Column.allCases {
            let col = NSTableColumn(identifier: .init(column.rawValue))
            col.title = column.title
            col.width = column.width
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
        tableView.autosaveName = "PathemFileList.\(Self.instanceCount)"
        tableView.autosaveTableColumns = true
        tableView.headerView?.menu = makeHeaderMenu()

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.onBecomeActive = { [weak self] in self?.onBecomeActive?() }
        tableView.onDragMoved = { [weak self] screen in self?.onDragSession?(.moved(screen: screen)) }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        tableView.menu = makeContextMenu()

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
    /// The command-backed items that may appear in the right-click menu, in default order.
    /// Config-as-data: the user can hide any of these (Settings > Menus).
    static var contextCommands: [(id: String, title: String)] {
        [
            ("files.open", L("common.open", "Open")),
            ("files.getInfo", L("list.getInfo", "Get Info")),
            ("files.download", L("list.download", "Download")),
            ("files.reveal", L("list.revealInFinder", "Reveal in Finder")),
            ("files.revealInPathem", L("list.revealInPathem", "Reveal in Pathem")),
            ("files.rename", L("list.rename", "Rename…")),
            ("files.trash", L("list.moveToTrash", "Move to Trash")),
            ("files.newFolder", L("list.newFolder", "New Folder")),
            ("files.newFile", L("bvc.cmd.newFile", "New File")),
            ("files.copy", L("list.copy", "Copy")),
            ("files.cut", L("list.cut", "Cut")),
            ("files.paste", L("list.paste", "Paste")),
        ]
    }

    /// Command ids hidden from the context menu (from the preference); rebuilds the menu.
    var hiddenContextItems: Set<String> = [] {
        didSet { if oldValue != hiddenContextItems { tableView.menu = makeContextMenu() } }
    }
    func setHiddenContextItems(_ ids: Set<String>) { hiddenContextItems = ids }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let titles = Dictionary(uniqueKeysWithValues: Self.contextCommands.map { ($0.id, $0.title) })
        func add(_ commandID: String) {
            guard !hiddenContextItems.contains(commandID), let title = titles[commandID] else { return }
            let item = NSMenuItem(
                title: title, action: #selector(BrowserViewController.performMenuCommand(_:)), keyEquivalent: "")
            item.representedObject = commandID
            item.image = MenuIcons.image(forCommand: commandID)
            menu.addItem(item)
        }
        add("files.open")
        let openWith = NSMenuItem(title: L("list.openWith", "Open With"), action: nil, keyEquivalent: "")
        openWith.image = MenuIcons.image("app.dashed")
        openWithMenu.delegate = self
        openWith.submenu = openWithMenu
        menu.addItem(openWith)
        add("files.getInfo")
        add("files.download")
        add("files.reveal")
        add("files.revealInPathem")
        add("files.rename")
        add("files.trash")
        menu.addItem(.separator())
        let tags = NSMenuItem(title: L("list.tags", "Tags"), action: nil, keyEquivalent: "")
        tags.image = MenuIcons.image("tag")
        let tagsMenu = NSMenu()
        for color in FileTag.Color.displayOrder {
            let item = NSMenuItem(
                title: color.label, action: #selector(BrowserViewController.performMenuCommand(_:)),
                keyEquivalent: "")
            item.representedObject = "tags.toggle.\(color.rawValue)"
            item.image = TagColors.dot(color)
            tagsMenu.addItem(item)
        }
        tagsMenu.addItem(.separator())
        let clearTags = NSMenuItem(
            title: L("list.clearTags", "Clear Tags"), action: #selector(BrowserViewController.performMenuCommand(_:)), keyEquivalent: "")
        clearTags.representedObject = "tags.clear"
        tagsMenu.addItem(clearTags)
        tags.submenu = tagsMenu
        menu.addItem(tags)
        menu.addItem(.separator())
        add("files.newFolder")
        add("files.newFile")
        menu.addItem(.separator())
        add("files.copy")
        add("files.cut")
        add("files.paste")
        return menu
    }

    /// Apply display preferences (density-derived row height, font size,
    /// alternating rows). Reloads so recycled cells pick up the new font.
    func applyStyle(rowHeight: CGFloat, fontSize: CGFloat, alternatingRows: Bool) {
        listFontSize = fontSize
        tableView.rowHeight = rowHeight
        tableView.usesAlternatingRowBackgroundColors = alternatingRows
        tableView.reloadData()
    }

    /// Replace the listing. With `preserveState` (an in-place refresh: a sort, a
    /// file op, a watcher tick) the selection is restored by name and the scroll
    /// position is held, so the list never jumps or deselects under the user.
    /// Without it (navigation, search results) the view resets to the top.
    func setEntries(_ entries: [FileEntry], preserveState: Bool = false) {
        defer {
            refreshTagsAsync()  // read tag colors off the main thread, then redraw
            refreshFolderSizesAsync()  // and folder sizes if enabled
            refreshExtendedColumnsAsync()  // and any metadata columns that are shown
        }
        guard preserveState else {
            self.entries = entries
            tableView.reloadData()
            if !entries.isEmpty { tableView.scrollRowToVisible(0) }
            return
        }
        let selectedNames = Set(selectedEntries.map(\.name))
        let origin = scrollView.contentView.bounds.origin
        self.entries = entries
        tableView.reloadData()
        // Re-tile now so the table's frame matches the new (possibly much smaller) row
        // count before we clamp and scroll. Right after reloadData the frame is still the
        // OLD height, so both our clamp and the clip view's own bounds constraint would use
        // a stale, too-large size, leaving the view stranded scrolled into empty space
        // below the remaining rows (the "panels scroll down after a change" bug).
        tableView.layoutSubtreeIfNeeded()
        if !selectedNames.isEmpty {
            var rows = IndexSet()
            for (index, entry) in entries.enumerated() where selectedNames.contains(entry.name) {
                rows.insert(index)
            }
            // Always apply (an empty set clears a selection whose item vanished,
            // instead of leaving NSTableView's stale index-based highlight).
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
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
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        onOpen?(entries[row])
    }

    /// Single click opens, in single-click mode, on a plain click of one row.
    @objc private func handleSingleClick() {
        guard singleClickToOpen else { return }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift) || flags.contains(.command) { return }  // extending a selection
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        onOpen?(entries[row])
    }

    func setClickBehavior(singleClick: Bool, underlineHover: Bool) {
        singleClickToOpen = singleClick
        tableView.action = singleClick ? #selector(handleSingleClick) : nil
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
        if old >= 0, old < entries.count { rows.insert(old) }
        if row >= 0, row < entries.count { rows.insert(row) }
        if !rows.isEmpty { tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: nameCol)) }
    }

    // MARK: Open With

    private func selectedFileURLs() -> [URL] {
        return tableView.selectedRowIndexes.compactMap { row -> URL? in
            guard row < entries.count else { return nil }
            let entry = entries[row]
            // Smart-result rows carry their real folder; normal rows use resolutionURL.
            if let location = entry.location {
                return URL(fileURLWithPath: location).appendingPathComponent(entry.name)
            }
            return resolutionURL?.appendingPathComponent(entry.name)
        }
    }

    /// Populate the Open With submenu with the apps that can open the selection
    /// (the default app first), plus "Other…".
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === openWithMenu else { return }
        menu.removeAllItems()
        func disabled(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        guard let first = selectedFileURLs().first else { disabled(L("list.noSelection", "No selection")); return }
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: first),
            let index = apps.firstIndex(of: preferred)
        {
            apps.remove(at: index)
            apps.insert(preferred, at: 0)
        }
        guard !apps.isEmpty else { disabled(L("list.noApplications", "No applications")); return }
        for app in apps {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path),
                action: #selector(openWithApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            // Copy before resizing: mutating the shared cached icon corrupts it process-wide.
            let icon = (NSWorkspace.shared.icon(forFile: app.path).copy() as? NSImage) ?? NSImage()
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(title: L("list.other", "Other…"), action: #selector(openWithOther(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        // Set a persistent/scoped default (handled by BrowserViewController via the
        // responder chain, since it owns the opener rules).
        let setDefault = NSMenuItem(
            title: L("list.alwaysOpenWith", "Always Open With…"), action: #selector(BrowserViewController.setDefaultOpener(_:)),
            keyEquivalent: "")
        menu.addItem(setDefault)
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        let urls = selectedFileURLs()
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openWithOther(_ sender: NSMenuItem) {
        let urls = selectedFileURLs()
        guard !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let app = panel.url else { return }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
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
        guard let row = entries.firstIndex(where: { $0.name == name }) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Select all rows whose names are in the set (used to carry selection).
    func selectNames(_ names: Set<String>) {
        var rows = IndexSet()
        for (index, entry) in entries.enumerated() where names.contains(entry.name) { rows.insert(index) }
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
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

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let dir = directoryURL, row < entries.count else { return nil }
        let entry = entries[row]
        guard !entry.isDataless else { return nil }  // don't drag online-only placeholders
        // A promise + file URL, so the drag lands in browsers/sandboxed apps and Finder alike.
        return FileDrag.item(for: dir.appendingPathComponent(entry.name))
    }

    func tableView(
        _ tableView: NSTableView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet
    ) {
        dragStartScreen = screenPoint
        onDragSession?(.began(screen: screenPoint))
        guard let dir = directoryURL else { return }
        let urls = rowIndexes.compactMap { row -> URL? in
            guard row < entries.count, !entries[row].isDataless else { return nil }
            return dir.appendingPathComponent(entries[row].name)
        }
        FileDrag.addLegacyFilenames(urls, to: session.draggingPasteboard)
    }

    func tableView(
        _ tableView: NSTableView, draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        // A super-drag flick is the start->end direction past a threshold, but only when no
        // drop target accepted the drag (else a real copy/move already ran). reduce with a
        // larger minSegment yields a single cardinal, or "" when the movement was too small.
        var flick: String? = nil
        if operation.isEmpty, let start = dragStartScreen {
            let direction = MouseGesture.reduce([start, screenPoint], minSegment: 44)
            flick = direction.isEmpty ? nil : direction
        }
        dragStartScreen = nil
        onDragSession?(.ended(flick: flick))
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
        proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let urls = draggedURLs(from: info), !urls.isEmpty else { return [] }
        // Over a folder row (that isn't one of the dragged items) -> drop INTO it, with
        // the row highlighted. Otherwise drop into the current folder.
        if let folder = folderRow(at: row, excluding: urls), !incomingURLs(urls, into: folder).isEmpty {
            tableView.setDropRow(row, dropOperation: .on)
        } else {
            guard !incomingURLs(urls, into: directoryURL).isEmpty else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)  // into this folder
        }
        return resolvedDragOperation(for: info)
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
        row: Int, dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let urls = draggedURLs(from: info), !urls.isEmpty else { return false }
        let folder = folderRow(at: row, excluding: urls)  // a subfolder, or nil for this folder
        let incoming = incomingURLs(urls, into: folder ?? directoryURL)
        guard !incoming.isEmpty else { return false }
        onDropFiles?(incoming, resolvedDragOperation(for: info) == .move, folder)
        return true
    }

    /// The folder URL at `row`, if it's a directory not among the dragged items.
    private func folderRow(at row: Int, excluding dragged: [URL]) -> URL? {
        guard row >= 0, row < entries.count, entries[row].isDirectory, let dir = directoryURL else { return nil }
        let folder = dir.appendingPathComponent(entries[row].name)
        let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        // Don't allow dropping a folder onto itself.
        if dragged.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == folderPath }) {
            return nil
        }
        return folder
    }

    /// All file URLs on the drag pasteboard.
    private func draggedURLs(from info: NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
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
        guard let tableColumn, row < entries.count else { return nil }
        cellRequests += 1

        let id = tableColumn.identifier
        let isName = id.rawValue == Column.name.rawValue
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? Self.makeCell(id, withIcon: isName)

        let entry = entries[row]
        cell.textField?.font = .systemFont(ofSize: listFontSize)
        // Dim items marked for cut, then hidden (dotfile) items -- so when "show hidden
        // files" is on you can tell the hidden ones apart from ordinary files, as Finder does.
        cell.alphaValue = isCut(entry) ? 0.45 : (entry.isHidden ? 0.5 : 1.0)
        switch Column(rawValue: id.rawValue) {
        case .name:
            // Online-only (dataless) items: a cloud badge + dimmed name.
            cell.textField?.textColor = entry.isDataless ? .secondaryLabelColor : .labelColor
            cell.imageView?.image = entry.isDataless ? Self.cloudIcon : Self.icon(for: entry)
            let colors = tagColors(for: entry)
            let git = gitState(for: entry)
            if colors.isEmpty, git == nil {
                cell.textField?.stringValue = entry.name
            } else {
                cell.textField?.attributedStringValue = Self.decoratedName(
                    entry.name, git: git, dots: colors, size: listFontSize)
            }
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
            cell.textField?.stringValue = gitState(for: entry).map { Self.gitBadge($0).letter } ?? ""
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
        let color = row < entries.count ? tagColors(for: entries[row]).first : nil
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
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
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
        for (row, entry) in entries.enumerated() where changed.contains(cacheKey(for: entry)) {
            rows.insert(row)
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
            rows.insert(item.row)
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
                // Only redraw if any row actually shows a dot, so the common
                // untagged case never triggers a second reload.
                if hadDots || result.contains(where: { !$0.value.isEmpty }) {
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

    /// The filename followed by a small colored dot for each tag color.
    /// Color + letter for a git state badge.
    private static func gitBadge(_ state: GitFileState) -> (letter: String, color: NSColor) {
        switch state {
        case .modified: return ("M", .systemOrange)
        case .added: return ("A", .systemGreen)
        case .deleted: return ("D", .systemRed)
        case .renamed: return ("R", .systemBlue)
        case .untracked: return ("?", .systemGray)
        case .conflicted: return ("!", .systemRed)
        }
    }

    /// The name cell content: an optional colored git-state letter, the name, then a
    /// colored dot per tag.
    private static func decoratedName(
        _ name: String, git: GitFileState?, dots colors: [FileTag.Color], size: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let git {
            let badge = gitBadge(git)
            result.append(
                NSAttributedString(
                    string: "\(badge.letter) ",
                    attributes: [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: badge.color]))
        }
        result.append(
            NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: size)]))
        appendDots(colors, to: result, size: size)
        return result
    }

    private static func name(_ name: String, withDots colors: [FileTag.Color], size: CGFloat)
        -> NSAttributedString
    {
        let result = NSMutableAttributedString(
            string: name, attributes: [.font: NSFont.systemFont(ofSize: size)])
        appendDots(colors, to: result, size: size)
        return result
    }

    private static func appendDots(
        _ colors: [FileTag.Color], to result: NSMutableAttributedString, size: CGFloat
    ) {
        let diameter = size - 2
        for color in colors {
            let attachment = NSTextAttachment()
            attachment.image = TagColors.dot(color, diameter: diameter)
            attachment.bounds = NSRect(x: 0, y: -1, width: diameter, height: diameter)
            result.append(NSAttributedString(string: " "))
            result.append(NSAttributedString(attachment: attachment))
        }
    }

    /// Badge for online-only (dataless) cloud placeholders.
    private static let cloudIcon: NSImage =
        NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: L("list.onlineOnly", "Online only"))
        ?? NSImage()

    private static var iconCache: [String: NSImage] = [:]

    /// A type icon for the entry, cached by extension (or folder) so scrolling a
    /// huge directory never does per-row disk work.
    private static func icon(for entry: FileEntry) -> NSImage {
        let key = entry.isDirectory ? "\u{0}folder" : (entry.name as NSString).pathExtension.lowercased()
        if let cached = iconCache[key] { return cached }
        let workspace = NSWorkspace.shared
        let image: NSImage
        if entry.isDirectory {
            image = workspace.icon(for: .folder)
        } else if !key.isEmpty, let type = UTType(filenameExtension: key) {
            image = workspace.icon(for: type)
        } else {
            image = workspace.icon(for: .data)
        }
        iconCache[key] = image
        return image
    }
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
}
