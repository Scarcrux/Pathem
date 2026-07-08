import AppKit
import PathemEngine

/// A floating "find files by name, everywhere" palette: type a name and Spotlight (mdfind) returns
/// matches across the scope near-instantly. Enter or double-click reveals the chosen file in the
/// active pane. Debounced + stale-guarded so fast typing only shows the latest query's results.
@MainActor
final class GlobalSearchController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let panel: NSPanel
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let scopePopup = NSPopUpButton()
    private var results: [URL] = []
    /// The active pane's folder, offered as the "This Folder" scope.
    private var currentFolder: URL?
    private var onReveal: ((URL) -> Void)?
    private var generation = 0

    /// The mdfind scope for the selected picker item: whole index, Home, or the current folder.
    private var scope: URL? {
        switch scopePopup.indexOfSelectedItem {
        case 1: return FileManager.default.homeDirectoryForCurrentUser
        case 2: return currentFolder
        default: return nil  // This Mac (the whole Spotlight index)
        }
    }

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        build()
    }

    func present(over window: NSWindow, currentFolder: URL, onReveal: @escaping (URL) -> Void) {
        self.currentFolder = currentFolder
        self.onReveal = onReveal
        searchField.stringValue = ""
        results = []
        table.reloadData()
        statusLabel.stringValue = L("gsearch.hint", "Type a file name to search everywhere.")
        panel.centerOverMainWindow()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ obj: Notification) { performSearch() }

    /// Re-run the current query (from a keystroke or a scope change), debounced + stale-guarded.
    private func performSearch() {
        generation += 1
        let gen = generation
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))  // debounce: only the last change searches
            guard gen == self.generation else { return }
            let query = SpotlightSearch.filenameQuery(self.searchField.stringValue)
            guard !query.isEmpty else {
                self.setResults([])
                self.statusLabel.stringValue = L("gsearch.hint", "Type a file name to search everywhere.")
                return
            }
            let urls = await SpotlightSearch.matching(query, scope: self.scope, limit: 200)
            guard gen == self.generation else { return }  // a newer query superseded this
            self.setResults(urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        }
    }

    @objc private func scopeChanged() { performSearch() }

    private func setResults(_ urls: [URL]) {
        results = urls
        table.reloadData()
        statusLabel.stringValue = String(format: L("gsearch.count", "%d results"), urls.count)
        if !urls.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @objc private func revealSelected() {
        let row = table.selectedRow
        let index = (0..<results.count).contains(row) ? row : (results.isEmpty ? -1 : 0)
        guard index >= 0 else { NSSound.beep(); return }
        onReveal?(results[index])
        panel.performClose(nil)
    }

    private func build() {
        panel.title = L("gsearch.title", "Find Files Everywhere")
        searchField.placeholderString = L("gsearch.placeholder", "File name…")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(revealSelected)  // Enter reveals the selected/first result
        searchField.translatesAutoresizingMaskIntoConstraints = false

        for (id, title, width) in [
            ("name", L("gsearch.colName", "Name"), CGFloat(220)),
            ("path", L("gsearch.colPath", "Where"), 360),
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(revealSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Scope picker: whole index, Home, or the current folder. Re-runs on change.
        scopePopup.addItems(withTitles: [
            L("gsearch.scopeMac", "This Mac"),
            L("gsearch.scopeHome", "Home"),
            L("gsearch.scopeFolder", "This Folder"),
        ])
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged)
        scopePopup.translatesAutoresizingMaskIntoConstraints = false
        scopePopup.setContentHuggingPriority(.required, for: .horizontal)

        let content = panel.contentView!
        content.addSubview(searchField)
        content.addSubview(scroll)
        content.addSubview(statusLabel)
        content.addSubview(scopePopup)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: scopePopup.leadingAnchor, constant: -8),
            scopePopup.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            scopePopup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    // MARK: Table
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < results.count else { return nil }
        let url = results[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let c = NSTableCellView()
                c.identifier = id
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingMiddle
                field.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(field)
                c.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                    field.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                    field.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
        if tableColumn.identifier.rawValue == "name" {
            cell.textField?.stringValue = url.lastPathComponent
            cell.textField?.textColor = .labelColor
        } else {
            cell.textField?.stringValue = url.deletingLastPathComponent().path
            cell.textField?.textColor = .secondaryLabelColor
        }
        return cell
    }
}
