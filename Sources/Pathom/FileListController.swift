import AppKit
import PathomEngine

/// The file list: a view-based `NSTableView` driven directly by an array of
/// `FileEntry` value types (DESIGN.md §4). View-based + fixed row height + cell
/// recycling is what lets the list render 100k+ (here 1M) rows without
/// materializing them all — the table only asks for the rows it is about to
/// show. `cellRequests` instruments exactly that for the Gate A proof.
@MainActor
final class FileListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView()
    let tableView = KeyTableView()

    private(set) var entries: [FileEntry] = []

    /// Count of `viewFor` calls — i.e. how many cell views the table has asked
    /// for. For a virtualized table this stays proportional to the visible
    /// window, never to `entries.count`.
    private(set) var cellRequests = 0

    /// Opened a row (double-click, Return/Enter, or Cmd-Down).
    var onOpen: ((FileEntry) -> Void)?
    /// This list's table became first responder (its pane became active).
    var onBecomeActive: (() -> Void)?

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
        tableView.rowHeight = 22  // fixed height — required for cheap virtualization
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.style = .inset
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        for column in Column.allCases {
            let col = NSTableColumn(identifier: .init(column.rawValue))
            col.title = column.title
            col.width = column.width
            tableView.addTableColumn(col)
        }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.onActivateRow = { [weak self] in self?.activateSelection() }
        tableView.onBecomeActive = { [weak self] in self?.onBecomeActive?() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
    }

    func setEntries(_ entries: [FileEntry]) {
        self.entries = entries
        tableView.reloadData()
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        onOpen?(entries[row])
    }

    private func activateSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < entries.count else { return }
        onOpen?(entries[row])
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < entries.count else { return nil }
        cellRequests += 1

        let id = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? Self.makeCell(id)

        let entry = entries[row]
        switch Column(rawValue: id.rawValue) {
        case .name:
            cell.textField?.stringValue = entry.name
        case .size:
            cell.textField?.stringValue = entry.isDirectory ? "--" : byteFormatter.string(fromByteCount: entry.size)
        case .date:
            cell.textField?.stringValue = entry.modificationDate.map { dateFormatter.string(from: $0) } ?? ""
        case .none:
            break
        }
        return cell
    }

    private static func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: 13)
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
