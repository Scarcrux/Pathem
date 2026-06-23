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
    private var activeColumn = 0
    private var rootURL: URL?
    private var storedResolutionURL: URL?
    private let columnWidth: CGFloat = 220

    // PaneContentView callbacks.
    var onOpen: ((FileEntry) -> Void)?
    var onBecomeActive: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onSortChanged: ((ViewFormat.SortKey, Bool) -> Void)?
    var onDropFiles: ((_ urls: [URL], _ move: Bool) -> Void)?
    var onKeyChord: ((KeyChord) -> Bool)?

    override init() {
        super.init()
        build()
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
        table.onBecomeActive = { [weak self, weak table] in
            guard let self, let table, let i = self.columnIndex(of: table) else { return }
            self.activeColumn = i
            self.onBecomeActive?()
        }
        let column = NSTableColumn(identifier: .init("name"))
        column.width = columnWidth - 4
        table.addTableColumn(column)

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
        return Column(folder: folder, entries: entries, scroll: scroll, table: table)
    }

    /// Rebuild the columns' layout (left to right, full height). The container's
    /// leading/top/height are fixed in build(); here we chain columns and pin the
    /// container's trailing to the last one (which sets the scrollable width).
    private func relayout() {
        for sub in container.subviews { sub.removeFromSuperview() }
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
        if let last = columns.last {
            container.trailingAnchor.constraint(equalTo: last.scroll.trailingAnchor).isActive = true
        } else {
            container.trailingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
        }
        container.layoutSubtreeIfNeeded()
    }

    /// Load a folder's children off the main thread, then append the next column,
    /// but only if that folder is still the active selection (no newer click won).
    private func openFolder(_ folder: URL, after index: Int) {
        if columns.count > index + 1 { columns.removeSubrange((index + 1)...) }  // drop deeper now
        relayout()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = (try? BulkEnumerator().entries(of: folder, includingHidden: false)) ?? []
            let sorted = ViewFormat.default.sorted(entries)
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
        cell.textField?.stringValue = entry.name
        cell.textField?.textColor = entry.isDataless ? .secondaryLabelColor : .labelColor
        let url = columns[index].folder.appendingPathComponent(entry.name)
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
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
            if entry.isDirectory {
                openFolder(columns[index].folder.appendingPathComponent(entry.name), after: index)
            } else if columns.count > index + 1 {
                columns.removeSubrange((index + 1)...)  // a file: no children column
                relayout()
            }
        }
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
        field.lineBreakMode = .byTruncatingTail
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
        let first = makeColumn(folder: root, entries: entries, index: 0)
        columns = [first]
        activeColumn = 0
        relayout()
        first.table.reloadData()
        outerScroll.contentView.scroll(to: .zero)
    }

    func showPlaceholder(_ text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = (text == nil)
    }

    func select(name: String) {
        guard let first = columns.first, let row = first.entries.firstIndex(where: { $0.name == name })
        else { return }
        first.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        first.table.scrollRowToVisible(row)
    }

    func selectNames(_ names: Set<String>) {
        guard let first = columns.first else { return }
        var rows = IndexSet()
        for (index, entry) in first.entries.enumerated() where names.contains(entry.name) { rows.insert(index) }
        first.table.selectRowIndexes(rows, byExtendingSelection: false)
    }

    func showSortIndicator(key: ViewFormat.SortKey, ascending: Bool) {}
    func applyStyle(rowHeight: CGFloat, fontSize: CGFloat, alternatingRows: Bool) {}
}
