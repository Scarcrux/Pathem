import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// The file list: a view-based `NSTableView` driven directly by an array of
/// `FileEntry` value types (DESIGN.md §4). View-based + fixed row height + cell
/// recycling is what lets the list render 100k+ (here 1M) rows without
/// materializing them all — the table only asks for the rows it is about to
/// show. `cellRequests` instruments exactly that for the Gate A proof.
@MainActor
final class FileListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView()
    let tableView = KeyTableView()
    private let placeholder = NSTextField(labelWithString: "")

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
        add("Reveal in Finder", "files.reveal")
        add("Rename…", "files.rename")
        add("Move to Trash", "files.trash")
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

    /// Show the sort indicator on the header without triggering onSortChanged.
    func showSortIndicator(key: ViewFormat.SortKey, ascending: Bool) {
        suppressSortCallback = true
        tableView.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: ascending)]
        suppressSortCallback = false
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

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
            cell.textField?.stringValue = entry.name
            cell.imageView?.image = Self.icon(for: entry)
        case .size:
            cell.textField?.stringValue = entry.isDirectory ? "--" : byteFormatter.string(fromByteCount: entry.size)
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
