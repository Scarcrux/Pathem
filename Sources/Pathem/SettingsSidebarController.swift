import AppKit

/// The Settings window's always-visible source-list sidebar (desktop-style, no overflow
/// chevron), with a search field that filters the panes by title and by the labels of the
/// settings they contain. Isolated from SettingsWindowController so it doesn't tangle with
/// the shortcut/gesture table data sources.
@MainActor
final class SettingsSidebarController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate
{
    struct Item {
        let key: String  // Pane.rawValue
        let title: String
        let symbol: String
    }

    let view = NSView()
    private let search = NSSearchField()
    private let table = NSTableView()
    private var all: [Item] = []
    private var shown: [Item] = []

    /// Extra searchable text for an item (the labels of its settings), lowercased.
    var searchText: ((Item) -> String)?
    /// A pane was chosen (by click or by search auto-select).
    var onSelect: ((String) -> Void)?

    override init() {
        super.init()
        build()
    }

    func setItems(_ items: [Item]) {
        all = items
        shown = items
        table.reloadData()
    }

    /// Apply a search query programmatically (PATHEM_SETTINGS_SHOT verification).
    func debugSearch(_ query: String) {
        search.stringValue = query
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
    }

    /// Programmatically select a pane (e.g. the initial pane) without re-filtering.
    func select(key: String) {
        guard let row = shown.firstIndex(where: { $0.key == key }) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    private func build() {
        view.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = L("settings.searchPlaceholder", "Search")
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        search.sendsWholeSearchString = false

        table.style = .sourceList
        table.headerView = nil
        table.rowHeight = 28
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.addTableColumn(NSTableColumn(identifier: .init("pane")))
        table.selectionHighlightStyle = .regular

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(search)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 200),
            search.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
    }

    func controlTextDidChange(_ obj: Notification) {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            shown = all
        } else {
            shown = all.filter { item in
                item.title.lowercased().contains(query) || (searchText?(item) ?? "").contains(query)
            }
        }
        table.reloadData()
        if let first = shown.first {
            table.selectRowIndexes([0], byExtendingSelection: false)  // jump to the top match
            onSelect?(first.key)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < shown.count else { return nil }
        let item = shown[row]
        let id = NSUserInterfaceItemIdentifier("paneCell")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let c = NSTableCellView()
                c.identifier = id
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingTail
                c.addSubview(image)
                c.addSubview(label)
                c.imageView = image
                c.textField = label
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                    image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 18),
                    label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
                    label.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                    label.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
        cell.imageView?.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)
        cell.textField?.stringValue = item.title
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return }
        onSelect?(shown[row].key)
    }
}
