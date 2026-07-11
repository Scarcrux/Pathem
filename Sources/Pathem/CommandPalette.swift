import AppKit
import PathemEngine

/// The one search-and-command overlay (DESIGN.md section 10, Phase 3). One widget, VS
/// Code-style, modes chosen by the first character:
///   - bare text runs the on-device semantic search in the active folder (live, debounced),
///   - a leading ">" fuzzy-finds and runs any registered command,
///   - "/" or "~/" jumps to a filesystem path (with directory completion).
/// Cmd-F opens it empty (search mode); Cmd-K opens it with ">" pre-typed (command mode).
/// Because every action is a Command in the registry, the command mode lists the whole
/// surface for free. Driven entirely from the field editor's command selectors, so
/// up/down/return/escape work while typing.
@MainActor
final class CommandPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let panel: NSPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()

    private var all: [(id: String, title: String)] = []
    private var filtered: [(id: String, title: String)] = []
    private var onRun: ((String) -> Void)?
    private var onNavigate: ((URL) -> Void)?
    private var onSemantic: ((String) -> Void)?
    private var liveSearch: Task<Void, Never>?
    private var lastLiveQuery = ""

    private enum Mode { case command, path, semantic }
    private var mode: Mode {
        let s = field.stringValue
        if s.hasPrefix("/") || s.hasPrefix("~/") { return .path }
        if s.hasPrefix(">") { return .command }  // ">" is the explicit command prefix (Cmd-K prefills it)
        return .semantic  // plain text (and empty) is search: Cmd-F opens here, not on the command list
    }

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: true)
        super.init()
        configure()
    }

    private func configure() {
        panel.title = L("palette.runCommandTitle", "Command Bar")
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.delegate = self  // cancel a pending live search when the bar auto-hides on deactivate
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        field.placeholderString = L("palette.multiPlaceholder", "Search this folder, > for commands, / for paths")
        field.delegate = self
        field.font = .systemFont(ofSize: 15)
        field.translatesAutoresizingMaskIntoConstraints = false

        table.headerView = nil
        table.rowHeight = 24
        table.style = .inset
        let column = NSTableColumn(identifier: .init("title"))
        column.width = 520
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runClicked)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(field)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    /// Show the bar over `window`. The callbacks route the non-command modes; command mode
    /// uses `onRun` with the chosen command id. `prefill` picks the opening mode: "" opens
    /// in search mode (Cmd-F), ">" opens in command mode (Cmd-K). `onSemantic` fires live
    /// (debounced) as the query is typed, and with "" when the search is dismissed or
    /// cleared so the caller can restore the plain listing.
    func present(
        commands: [(id: String, title: String)],
        prefill: String = "",
        onRun: @escaping (String) -> Void,
        onNavigate: @escaping (URL) -> Void,
        onSemantic: @escaping (String) -> Void,
        over window: NSWindow
    ) {
        all = commands
        self.onRun = onRun
        self.onNavigate = onNavigate
        self.onSemantic = onSemantic
        lastLiveQuery = ""
        field.stringValue = prefill
        refilter()

        let windowFrame = window.frame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: windowFrame.midX - size.width / 2, y: windowFrame.maxY - size.height - 80))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func refilter() {
        switch mode {
        case .command:
            let query = field.stringValue.hasPrefix(">")
                ? String(field.stringValue.dropFirst()) : field.stringValue
            filtered = FuzzyMatch.rank(all, query: query, key: { $0.title })
            scheduleLiveSearch("")  // leaving search mode restores the plain listing
        case .path:
            filtered = pathCompletions(field.stringValue)
            scheduleLiveSearch("")
        case .semantic:
            let query = field.stringValue.trimmingCharacters(in: .whitespaces)
            // An empty field (e.g. just after Cmd-F opens) has nothing to run: show no row so
            // Return does nothing, rather than auto-selecting and firing an arbitrary action.
            filtered = query.isEmpty
                ? []
                : [(id: query, title: String(format: L("palette.searchFor", "Search for “%@”"), query))]
            scheduleLiveSearch(query)  // rank the pane live while typing (no-op when empty)
        }
        table.reloadData()
        if !filtered.isEmpty { select(0) }
    }

    /// Debounced live search: rank the pane ~a quarter second after typing pauses, so every
    /// keystroke doesn't embed a query. An empty query restores the plain listing (fired when
    /// search text is cleared or the field switches mode), but only if a search actually ran.
    private func scheduleLiveSearch(_ query: String) {
        guard query != lastLiveQuery else { return }
        liveSearch?.cancel()
        if query.isEmpty {
            lastLiveQuery = ""
            onSemantic?("")
            return
        }
        liveSearch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 275_000_000)
            guard !Task.isCancelled, let self else { return }
            self.lastLiveQuery = query
            self.onSemantic?(query)
        }
    }

    /// Child directories of the path's parent that match its trailing component.
    private func pathCompletions(_ input: String) -> [(id: String, title: String)] {
        let expanded = (input as NSString).expandingTildeInPath
        let endsWithSlash = expanded.hasSuffix("/")
        let dir = endsWithSlash ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = endsWithSlash ? "" : (expanded as NSString).lastPathComponent
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    && (prefix.isEmpty || url.lastPathComponent.lowercased().hasPrefix(prefix.lowercased()))
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(60)
            .map { (id: $0.path, title: $0.path) }
    }

    private func select(_ row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        select(min(max(table.selectedRow + delta, 0), filtered.count - 1))
    }

    private func runSelected() {
        switch mode {
        case .command:
            let row = table.selectedRow
            guard row >= 0, row < filtered.count else { return }
            let id = filtered[row].id
            close()
            onRun?(id)
        case .path:
            // A fully-typed existing directory wins; otherwise the selected completion.
            let typed = (field.stringValue as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: typed, isDirectory: &isDir), isDir.boolValue {
                close()
                onNavigate?(URL(fileURLWithPath: typed))
                return
            }
            let row = table.selectedRow
            guard row >= 0, row < filtered.count else { return }
            close()
            onNavigate?(URL(fileURLWithPath: filtered[row].id))
        case .semantic:
            let query = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return }
            liveSearch?.cancel()
            close()
            if query != lastLiveQuery { onSemantic?(query) }  // Return before the debounce fired
            lastLiveQuery = ""  // the results stay in the pane; don't undo them on next open
        }
    }

    @objc private func runClicked() {
        let row = table.clickedRow
        guard row >= 0, row < filtered.count else { return }
        select(row)
        runSelected()
    }

    private func close() {
        liveSearch?.cancel()  // don't let a debounced search fire after the bar is gone
        panel.orderOut(nil)
    }

    // hidesOnDeactivate hides the bar without routing through close(); cancel the pending
    // live search here too so clicking away can't fire a search against a since-changed pane.
    func windowDidResignKey(_ notification: Notification) { liveSearch?.cancel() }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape abandons the search: restore the plain listing if a live search ran.
            liveSearch?.cancel()
            scheduleLiveSearch("")
            close()
        default: return false
        }
        return true
    }

    // MARK: NSTableView data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? Self.makeCell(id)
        cell.textField?.stringValue = filtered[row].title
        return cell
    }

    private static func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 14)
        field.lineBreakMode = .byTruncatingMiddle
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
