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
    private var suppressSortCallback = false
    /// Row font size, applied per cell so a preference change takes effect on reload.
    private var listFontSize: CGFloat = 13
    /// Tag colors per file path, filled by an off-main read after each listing so
    /// the cell path never does a syscall. Reused across refreshes for names
    /// already read.
    private var tagCache: [String: [FileTag.Color]] = [:]
    /// Bumped per listing so a stale background tag read can't clobber a newer one.
    private var tagReadGeneration = 0
    /// Folder sizes (Finder's "calculate all sizes"), computed off-main and cached.
    private var calculateFolderSizes = false
    private var folderSizeCache: [String: Int64] = [:]
    private var sizeReadGeneration = 0
    /// The folder these rows live in, so a dragged row maps to a file URL. nil
    /// while showing search results, which disables drag.
    var directoryURL: URL?
    /// The folder used to resolve a row to a URL for actions like Open With. Set
    /// even during search (results are ranked from this folder), so those actions
    /// keep working when drag is disabled.
    var resolutionURL: URL?
    /// Files were dropped onto this list: copy (or move) them into this folder.
    var onDropFiles: ((_ urls: [URL], _ move: Bool) -> Void)?

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

    private enum Column: String, CaseIterable {
        case name, size, date
        var title: String {
            switch self {
            case .name: return "Name"
            case .size: return "Size"
            case .date: return "Date Modified"
            }
        }
        var width: CGFloat {
            switch self {
            case .name: return 360
            case .size: return 110
            case .date: return 180
            }
        }
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
            col.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            tableView.addTableColumn(col)
        }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.onBecomeActive = { [weak self] in self?.onBecomeActive?() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        tableView.menu = makeContextMenu()

        // Drag rows out (to Finder, the other pane, or the sidebar) and accept
        // file drops into this folder.
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)

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
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ commandID: String) {
            let item = NSMenuItem(
                title: title, action: #selector(BrowserViewController.performMenuCommand(_:)), keyEquivalent: "")
            item.representedObject = commandID
            menu.addItem(item)
        }
        add("Open", "files.open")
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWithMenu.delegate = self
        openWith.submenu = openWithMenu
        menu.addItem(openWith)
        add("Get Info", "files.getInfo")
        add("Download", "files.download")
        add("Reveal in Finder", "files.reveal")
        add("Rename…", "files.rename")
        add("Move to Trash", "files.trash")
        menu.addItem(.separator())
        let tags = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
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
            title: "Clear Tags", action: #selector(BrowserViewController.performMenuCommand(_:)), keyEquivalent: "")
        clearTags.representedObject = "tags.clear"
        tagsMenu.addItem(clearTags)
        tags.submenu = tagsMenu
        menu.addItem(tags)
        menu.addItem(.separator())
        add("New Folder", "files.newFolder")
        menu.addItem(.separator())
        add("Copy", "files.copy")
        add("Cut", "files.cut")
        add("Paste", "files.paste")
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
        if !selectedNames.isEmpty {
            var rows = IndexSet()
            for (index, entry) in entries.enumerated() where selectedNames.contains(entry.name) {
                rows.insert(index)
            }
            // Always apply (an empty set clears a selection whose item vanished,
            // instead of leaving NSTableView's stale index-based highlight).
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
        }
        // Clamp to the new document bounds so a shrunk listing never leaves the
        // view scrolled past the last row into empty space.
        let maxY = max(0, tableView.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: min(max(origin.y, 0), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        onOpen?(entries[row])
    }

    // MARK: Open With

    private func selectedFileURLs() -> [URL] {
        guard let dir = resolutionURL else { return [] }
        return tableView.selectedRowIndexes.compactMap {
            $0 < entries.count ? dir.appendingPathComponent(entries[$0].name) : nil
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
        guard let first = selectedFileURLs().first else { disabled("No selection"); return }
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: first),
            let index = apps.firstIndex(of: preferred)
        {
            apps.remove(at: index)
            apps.insert(preferred, at: 0)
        }
        guard !apps.isEmpty else { disabled("No applications"); return }
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
        let other = NSMenuItem(title: "Other…", action: #selector(openWithOther(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        // Set a persistent/scoped default (handled by BrowserViewController via the
        // responder chain, since it owns the opener rules).
        let setDefault = NSMenuItem(
            title: "Always Open With…", action: #selector(BrowserViewController.setDefaultOpener(_:)),
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

    /// Show the sort indicator on the header without triggering onSortChanged.
    func showSortIndicator(key: ViewFormat.SortKey, ascending: Bool) {
        suppressSortCallback = true
        tableView.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: ascending)]
        suppressSortCallback = false
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let dir = directoryURL, row < entries.count else { return nil }
        let entry = entries[row]
        guard !entry.isDataless else { return nil }  // don't drag online-only placeholders
        return dir.appendingPathComponent(entry.name) as NSURL
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
        proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        // Reject (no cursor) when there's nothing to drop here, so the cursor
        // matches what acceptDrop will actually do.
        guard !incomingURLs(from: info).isEmpty else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)  // drop into this folder, not between rows
        return resolvedDragOperation(for: info)
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
        row: Int, dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let incoming = incomingURLs(from: info)
        guard !incoming.isEmpty else { return false }
        onDropFiles?(incoming, resolvedDragOperation(for: info) == .move)
        return true
    }

    /// File URLs from the drag that are not already in this folder (a drop onto
    /// themselves is a no-op). Symlink-resolved and case-insensitive so a
    /// differently spelled path to the same folder still counts as "here".
    private func incomingURLs(from info: NSDraggingInfo) -> [URL] {
        guard let dir = directoryURL,
            let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return [] }
        let dirPath = dir.resolvingSymlinksInPath().standardizedFileURL.path
        return urls.filter {
            let parent = $0.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            return parent.compare(dirPath, options: .caseInsensitive) != .orderedSame
        }
    }

    /// Copy by default; move only when the source offers it and Command is held.
    private func resolvedDragOperation(for info: NSDraggingInfo) -> NSDragOperation {
        let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        return commandHeld && info.draggingSourceOperationMask.contains(.move) ? .move : .copy
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
        switch Column(rawValue: id.rawValue) {
        case .name:
            // Online-only (dataless) items: a cloud badge + dimmed name.
            cell.textField?.textColor = entry.isDataless ? .secondaryLabelColor : .labelColor
            cell.imageView?.image = entry.isDataless ? Self.cloudIcon : Self.icon(for: entry)
            let colors = tagColors(for: entry)
            if colors.isEmpty {
                cell.textField?.stringValue = entry.name
            } else {
                cell.textField?.attributedStringValue = Self.name(entry.name, withDots: colors, size: listFontSize)
            }
        case .size:
            if entry.isDirectory {
                if let bytes = folderSize(for: entry) {
                    cell.textField?.stringValue = byteFormatter.string(fromByteCount: bytes)
                } else {
                    cell.textField?.stringValue = "--"
                }
            } else {
                cell.textField?.stringValue = byteFormatter.string(fromByteCount: entry.size)
            }
        case .date:
            cell.textField?.stringValue = entry.modificationDate.map { dateFormatter.string(from: $0) } ?? ""
        case .none:
            break
        }
        return cell
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
        guard let dir = directoryURL else { return [] }  // search results span folders: no dots
        return tagCache[dir.appendingPathComponent(entry.name).path] ?? []
    }

    /// Drop cached tag colors so the next refresh re-reads from disk (call after
    /// the app itself changes tags).
    func invalidateTagCache() { tagCache.removeAll() }

    /// A cached folder size, or nil when not computed (or the option is off).
    private func folderSize(for entry: FileEntry) -> Int64? {
        guard calculateFolderSizes, entry.isDirectory, let dir = directoryURL else { return nil }
        return folderSizeCache[dir.appendingPathComponent(entry.name).path]
    }

    /// Turn the "calculate all sizes" option on or off.
    func setCalculateFolderSizes(_ on: Bool) {
        guard on != calculateFolderSizes else { return }
        calculateFolderSizes = on
        if on {
            refreshFolderSizesAsync()
        } else {
            sizeReadGeneration += 1  // drop any in-flight computation
            tableView.reloadData()  // folders go back to "--"
        }
    }

    /// Compute folder sizes off the main thread, publishing each row as it finishes
    /// (reusing already-computed sizes). Generation-guarded against a newer listing.
    private func refreshFolderSizesAsync() {
        guard calculateFolderSizes, let dir = directoryURL else { return }
        sizeReadGeneration += 1
        let generation = sizeReadGeneration
        let folders = entries.filter(\.isDirectory).map(\.name)
        let known = folderSizeCache
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for name in folders {
                let path = dir.appendingPathComponent(name).path
                let size = known[path] ?? DirectorySize.total(of: URL(fileURLWithPath: path))
                DispatchQueue.main.async {
                    guard let self, self.sizeReadGeneration == generation else { return }
                    self.folderSizeCache[path] = size
                    if let row = self.entries.firstIndex(where: { $0.isDirectory && $0.name == name }) {
                        self.tableView.reloadData(
                            forRowIndexes: IndexSet(integer: row),
                            columnIndexes: IndexSet(integersIn: 0..<self.tableView.numberOfColumns))
                    }
                }
            }
        }
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
        let names = entries.map(\.name)
        let known = tagCache
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result: [String: [FileTag.Color]] = [:]
            result.reserveCapacity(names.count)
            for name in names {
                let path = dir.appendingPathComponent(name).path
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

    /// The filename followed by a small colored dot for each tag color.
    private static func name(_ name: String, withDots colors: [FileTag.Color], size: CGFloat)
        -> NSAttributedString
    {
        let result = NSMutableAttributedString(
            string: name, attributes: [.font: NSFont.systemFont(ofSize: size)])
        let diameter = size - 2
        for color in colors {
            let attachment = NSTextAttachment()
            attachment.image = TagColors.dot(color, diameter: diameter)
            attachment.bounds = NSRect(x: 0, y: -1, width: diameter, height: diameter)
            result.append(NSAttributedString(string: " "))
            result.append(NSAttributedString(attachment: attachment))
        }
        return result
    }

    /// Badge for online-only (dataless) cloud placeholders.
    private static let cloudIcon: NSImage =
        NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: "Online only")
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
