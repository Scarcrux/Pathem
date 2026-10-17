import AppKit
import PathemEngine

private final class FileSearchPanel: NSPanel {
    var dismiss: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

private final class FileSearchTable: NSTableView {
    var reveal: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            reveal?()  // Return and the numeric keypad's Enter activate the same result.
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Literal file search with explicit mode/location, separate from semantic ranking and commands.
@MainActor
final class GlobalSearchController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate, NSWindowDelegate
{
    typealias Backend = @Sendable (FileSearch.Request) async -> FileSearch.Response
    private let search: Backend
    private let panel = FileSearchPanel(
        contentRect: NSRect(x: 0, y: 0, width: 740, height: 500),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
    private let searchField = NSSearchField()
    private let table = FileSearchTable()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let locationLabel = NSTextField(labelWithString: "")
    private let coverageLabel = NSTextField(wrappingLabelWithString: "")
    private let scopePopup = NSPopUpButton()
    private let modePopup = NSPopUpButton()
    private let subfolders = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let chooseButton = NSButton()
    private let revealButton = NSButton()
    private let openButton = NSButton()
    private var results: [URL] = []
    private var currentFolder: URL?
    private var otherFolder: URL?
    private var onReveal: ((URL) -> Void)?
    private var onOpen: ((URL) -> Void)?
    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private var isSearching = false
    private var folderPicker: NSOpenPanel?
    private var committedScopeIndex = 0

    private var mode: FileSearch.Mode { modePopup.indexOfSelectedItem == 0 ? .filename : .contents }
    private var scope: FileSearch.Scope {
        if scopePopup.indexOfSelectedItem == 1 { return .mac }
        return .folder(
            (scopePopup.indexOfSelectedItem == 2 ? otherFolder : currentFolder)
                ?? FileManager.default.homeDirectoryForCurrentUser,
            recursive: subfolders.state == .on)
    }

    init(search: @escaping Backend = { await FileSearch.search($0) }) {
        self.search = search
        super.init()
        build()
    }

    func present(
        over window: NSWindow, currentFolder: URL, everywhere: Bool = false,
        onReveal: @escaping (URL) -> Void, onOpen: @escaping (URL) -> Void
    ) {
        cancelFolderPicker()
        invalidate()
        self.currentFolder = currentFolder
        self.onReveal = onReveal
        self.onOpen = onOpen
        modePopup.selectItem(at: 0)
        scopePopup.selectItem(at: everywhere ? 1 : 0)
        committedScopeIndex = scopePopup.indexOfSelectedItem
        subfolders.state = .on
        searchField.stringValue = ""
        setResults([])
        updateLocation()
        statusLabel.stringValue = L("filesearch.hint", "Type a keyword to search.")
        panel.centerOverMainWindow()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    private func invalidate() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    func windowWillClose(_ notification: Notification) {
        cancelFolderPicker()
        invalidate()
    }
    private func dismiss() {
        cancelFolderPicker()
        invalidate()
        panel.orderOut(nil)
    }
    private func cancelFolderPicker() {
        let picker = folderPicker
        // Relinquish ownership before cancelling: AppKit may deliver completion later,
        // after present() has installed a new scope, results and action callbacks.
        folderPicker = nil
        picker?.cancel(nil)
    }
    func controlTextDidChange(_ obj: Notification) { performSearch() }

    private func performSearch() {
        invalidate()
        let request = FileSearch.Request(keyword: searchField.stringValue, mode: mode, scope: scope)
        setResults([])  // old query/scope results must not remain actionable
        guard !request.keyword.isEmpty else {
            statusLabel.stringValue = L("filesearch.hint", "Type a keyword to search.")
            return
        }
        let gen = generation
        isSearching = true
        statusLabel.stringValue = L("filesearch.loading", "Searching…")
        let backend = search
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let response = await backend(request)
            #if DEBUG
            self?.debugCompletedBackendRequests.append(request)
            #endif
            guard !Task.isCancelled, let self, gen == self.generation, self.panel.isVisible else {
                return
            }
            self.isSearching = false
            self.setResults(response.urls)
            if let error = response.error {
                self.statusLabel.stringValue = L("filesearch.error", "Search failed: ") + error
            } else {
                var status =
                    response.urls.isEmpty
                    ? L("filesearch.noMatches", "No matching files.")
                    : String(
                        format: L("filesearch.count", "%d matching items."), response.urls.count)
                if response.truncated {
                    status += " " + L("filesearch.limited", "Results limited; narrow your search.")
                }
                if response.skipped > 0 {
                    status +=
                        " "
                        + String(
                            format: L(
                                "filesearch.skipped",
                                "%d files or folders could not be fully searched."),
                            response.skipped)
                }
                if response.indexedDocumentsUnavailable {
                    status +=
                        " "
                        + L(
                            "filesearch.textOnly",
                            "Document index unavailable; showing text-file matches only.")
                }
                self.statusLabel.stringValue = status
            }
        }
    }

    private func updateLocation() {
        subfolders.isEnabled = scopePopup.indexOfSelectedItem != 1
        chooseButton.isHidden = scopePopup.indexOfSelectedItem != 2
        switch scope {
        case .mac:
            locationLabel.stringValue = L(
                "filesearch.indexHint",
                "Spotlight-indexed files on this Mac; unindexed locations are not included.")
        case .folder(let url, _): locationLabel.stringValue = url.path
        }
        searchField.placeholderString =
            mode == .filename
            ? L("filesearch.namePlaceholder", "Keyword in file name…")
            : L("filesearch.contentPlaceholder", "Keyword in file contents…")
        locationLabel.toolTip = locationLabel.stringValue
        coverageLabel.stringValue =
            mode == .contents && scopePopup.indexOfSelectedItem != 1
            ? L(
                "filesearch.contentHint",
                "Searches text files directly and other documents through Spotlight. Unindexed document contents may not be found."
            ) : ""
        subfolders.toolTip = L(
            "filesearch.folderHint",
            "Folder search excludes hidden items. Contents combines direct UTF-8 text search (up to 32 MiB per file) with Spotlight-indexed documents, without downloading cloud-only files."
        )
    }

    @objc private func optionsChanged() {
        committedScopeIndex = scopePopup.indexOfSelectedItem
        updateLocation()
        performSearch()
    }
    @objc private func scopeChanged() {
        if scopePopup.indexOfSelectedItem == 2, otherFolder == nil {
            chooseFolder()
            return
        }
        optionsChanged()
    }
    @objc private func chooseFolder() {
        guard folderPicker == nil else { return }
        // Selecting Other Folder changes the popup before its action fires. Keep
        // the last committed scope so native Cancel can undo that pending choice.
        let returnScope = committedScopeIndex
        invalidate()
        setResults([])
        let picker = NSOpenPanel()
        folderPicker = picker
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = otherFolder ?? currentFolder
        picker.prompt = L("filesearch.choose", "Choose Folder")
        picker.beginSheetModal(for: panel) { [weak self] result in
            guard let self else { return }
            #if DEBUG
            self.debugFolderPickerCompletions += 1
            #endif
            guard self.folderPicker === picker else { return }
            self.folderPicker = nil
            if result == .OK, let url = picker.url {
                self.otherFolder = url
                self.scopePopup.selectItem(at: 2)
            } else {
                self.scopePopup.selectItem(at: returnScope)
            }
            self.optionsChanged()
        }
    }

    private func setResults(_ urls: [URL]) {
        results = urls
        table.reloadData()
        if !urls.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        updateActions()
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    private func updateActions() {
        let enabled = !isSearching && results.indices.contains(table.selectedRow)
        revealButton.isEnabled = enabled
        openButton.isEnabled = enabled
    }
    @objc private func revealSelected() { activateSelected(open: false) }
    @objc private func openSelected() { activateSelected(open: true) }
    private func activateSelected(open: Bool) {
        guard !isSearching, results.indices.contains(table.selectedRow) else { return }
        let url = results[table.selectedRow]
        dismiss()
        if open { onOpen?(url) } else { onReveal?(url) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(max(table.selectedRow + delta, 0), results.count - 1)
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        case #selector(NSResponder.insertNewline(_:)): revealSelected()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    private func build() {
        panel.title = L("filesearch.title", "Search Files")
        panel.minSize = NSSize(width: 680, height: 380)
        panel.delegate = self
        panel.dismiss = { [weak self] in self?.dismiss() }
        searchField.delegate = self
        searchField.font = .systemFont(ofSize: 15)
        searchField.setAccessibilityLabel(L("filesearch.keyword", "Search keyword"))
        modePopup.addItems(withTitles: [
            L("filesearch.filename", "File name"), L("filesearch.contents", "File contents"),
        ])
        scopePopup.addItems(withTitles: [
            L("gsearch.scopeFolder", "This Folder"), L("gsearch.scopeMac", "This Mac"),
            L("filesearch.other", "Other Folder…"),
        ])
        modePopup.setAccessibilityLabel(L("filesearch.mode", "Search in"))
        scopePopup.setAccessibilityLabel(L("filesearch.scope", "Search location"))
        for control in [modePopup, subfolders] as [NSControl] {
            control.target = self
            control.action = #selector(optionsChanged)
        }
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged)
        subfolders.title = L("filesearch.subfolders", "Include subfolders")
        chooseButton.title = L("filesearch.choose", "Choose Folder")
        chooseButton.target = self
        chooseButton.action = #selector(chooseFolder)
        chooseButton.bezelStyle = .rounded
        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.font = .systemFont(ofSize: 11)
        coverageLabel.font = .systemFont(ofSize: 11)
        coverageLabel.textColor = .secondaryLabelColor
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let options = NSStackView(views: [modePopup, scopePopup, subfolders, chooseButton])
        options.spacing = 12
        options.alignment = .centerY
        for (id, title, width) in [
            ("name", L("gsearch.colName", "Name"), CGFloat(230)),
            ("path", L("gsearch.colPath", "Where"), CGFloat(440)),
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(revealSelected)
        table.reveal = { [weak self] in self?.revealSelected() }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        revealButton.title = L("filesearch.reveal", "Reveal in Folder")
        openButton.title = L("filesearch.open", "Open")
        for (button, action) in [
            (revealButton, #selector(revealSelected)), (openButton, #selector(openSelected)),
        ] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        let actions = NSStackView(views: [openButton, revealButton])
        actions.spacing = 12
        let content = panel.contentView!
        for v in [searchField, options, locationLabel, coverageLabel, scroll, statusLabel, actions]
        {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            options.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            options.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            options.trailingAnchor.constraint(lessThanOrEqualTo: searchField.trailingAnchor),
            locationLabel.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 8),
            locationLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            locationLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            coverageLabel.topAnchor.constraint(equalTo: locationLabel.bottomAnchor, constant: 4),
            coverageLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            coverageLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: coverageLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            actions.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            actions.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let tableColumn, results.indices.contains(row) else { return nil }
        let url = results[row]
        let field = NSTextField(
            labelWithString: tableColumn.identifier.rawValue == "name"
                ? url.lastPathComponent : url.deletingLastPathComponent().path)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = url.path
        return field
    }

    #if DEBUG
    private(set) var debugFolderPickerCompletions = 0
    private(set) var debugCompletedBackendRequests: [FileSearch.Request] = []
    var debugPanel: NSPanel { panel }
    var debugField: NSSearchField { searchField }
    var debugMode: NSPopUpButton { modePopup }
    var debugScope: NSPopUpButton { scopePopup }
    var debugSubfolders: NSButton { subfolders }
    var debugResults: [URL] { results }
    var debugTable: NSTableView { table }
    var debugStatus: String { statusLabel.stringValue }
    var debugLocation: String { locationLabel.stringValue }
    var debugBusy: Bool { isSearching }
    var debugOpen: NSButton { openButton }
    var debugReveal: NSButton { revealButton }
    var debugChooseButton: NSButton { chooseButton }
    func debugChooseFolder(_ url: URL) {
        otherFolder = url
        scopePopup.selectItem(at: 2)
        optionsChanged()
    }
    func debugSetKeyword(_ text: String) {
        searchField.stringValue = text
        controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: searchField))
    }
    #endif
}
