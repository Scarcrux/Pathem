import AppKit
import PathemEngine

/// One pane of the dual-pane browser: a directory listing with its own
/// navigation history, an editable path/address bar, and back/forward/up
/// buttons. The pane is intentionally thin. NavigationState owns the history
/// logic and BulkEnumerator does the listing.
@MainActor
final class PaneController: NSObject, NSTextFieldDelegate {
    let containerView = NSView()
    let list = FileListController()
    private(set) var nav: NavigationState

    private let pathControl = NSPathControl()
    /// Editable address bar (Cmd-L): shows the current path so you can edit or
    /// paste a new one and press Return to jump there. Finder makes this awkward;
    /// here it's first-class.
    private let addressField = NSTextField()
    private var backButton = NSButton()
    private var forwardButton = NSButton()
    private var upButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// Fired when this pane becomes active (its list gains focus).
    var onBecomeActive: (() -> Void)?
    /// Fired when this pane's folder changes, by navigation or on-disk edits.
    /// The browser uses it to invalidate and rebuild the semantic-search cache.
    var onDirectoryDidChange: ((URL) -> Void)?
    /// Fired only on user navigation (not watcher refreshes), so the browser can
    /// clear the stale search query.
    var onDidNavigate: (() -> Void)?
    /// Files were dropped onto this pane: copy/move them into its folder.
    var onDropFiles: ((_ urls: [URL], _ move: Bool, _ destination: URL) -> Void)?
    /// Opens a (non-folder) file, applying the browser's scoped opener rules.
    /// Falls back to the system default when unset.
    var openFile: ((URL) -> Void)?

    private var watcher: DirectoryWatcher?
    private var pendingRefresh: DispatchWorkItem?
    private var showingSearchResults = false

    /// How this pane sorts and filters its listing (resolved per folder).
    var format = ViewFormat.default
    /// Asks the browser for the saved format for a folder (the per-folder cascade).
    var resolveFormat: ((URL) -> ViewFormat)?
    /// Tells the browser to remember a format for this folder.
    var rememberFormat: ((URL, ViewFormat) -> Void)?

    init(start: URL) {
        nav = NavigationState(current: start.standardizedFileURL)
        super.init()
        build()
        wire()
        enterDirectory()
    }

    var currentURL: URL { nav.current }
    var selectedEntries: [FileEntry] { list.selectedEntries }
    var canGoBack: Bool { nav.canGoBack }
    var canGoForward: Bool { nav.canGoForward }
    var canGoUp: Bool { nav.parent != nil }

    /// Entries currently shown (directory listing, or ranked search results).
    var entries: [FileEntry] { list.entries }

    /// Replace the listing with an explicit set (e.g. ranked search results).
    func showResults(_ entries: [FileEntry]) {
        showingSearchResults = true
        list.directoryURL = nil  // disable row drag during search
        list.resolutionURL = nav.current  // but results are from this folder, so actions resolve
        list.setEntries(entries)
        list.showPlaceholder(entries.isEmpty ? "No matching files" : nil)
        updateStatus()
    }

    /// Refresh the listing. In-place refreshes (sort, file op, watcher) preserve
    /// the selection and scroll; navigation passes preserveState: false to reset.
    func reload(preserveState: Bool = true) {
        showingSearchResults = false
        list.directoryURL = nav.current  // rows in this folder are draggable
        list.resolutionURL = nav.current
        if let resolveFormat { format = resolveFormat(nav.current) }
        do {
            let entries = try BulkEnumerator().entries(of: nav.current, includingHidden: format.showHidden)
            list.setEntries(format.sorted(entries), preserveState: preserveState)
            list.showPlaceholder(entries.isEmpty ? "This folder is empty" : nil)
        } catch {
            // A read failure (permission denied, missing) looks identical to an
            // empty folder unless we say so.
            list.setEntries([], preserveState: false)
            list.showPlaceholder(
                "Couldn’t read this folder.\nPathem may need Full Disk Access "
                    + "(System Settings ▸ Privacy & Security ▸ Full Disk Access).")
        }
        list.showSortIndicator(key: format.sortKey, ascending: format.ascending)
        updateStatus()
        pathControl.url = nav.current
        backButton.isEnabled = nav.canGoBack
        forwardButton.isEnabled = nav.canGoForward
        upButton.isEnabled = nav.parent != nil
    }

    /// Refresh the listing unless this pane is currently showing search results.
    /// File operations use this so an op elsewhere never wipes a pane's results
    /// (the on-disk change is still picked up by the watcher for index rebuild).
    func reloadIfShowingListing() {
        if !showingSearchResults { reload() }
    }

    /// Re-apply formats and notify observers once the owning controller has wired
    /// the pane's callbacks (init runs before resolveFormat / onDirectoryDidChange
    /// are set, so the initial listing and preindex must be triggered afterward).
    func refresh() {
        reload()
        onDirectoryDidChange?(nav.current)
    }

    /// Stop watching the folder; called when this pane's tab is closed.
    func teardown() {
        watcher?.stop()
        watcher = nil
        pendingRefresh?.cancel()
    }

    /// Apply display preferences to this pane's list.
    func applyStyle(rowHeight: Double, fontSize: Int, alternatingRows: Bool) {
        list.applyStyle(
            rowHeight: CGFloat(rowHeight), fontSize: CGFloat(fontSize), alternatingRows: alternatingRows)
    }

    func descend(into entry: FileEntry) {
        let url = nav.current.appendingPathComponent(entry.name)
        if entry.isDirectory {
            nav.go(to: url)
            enterDirectory()
        } else if let openFile {
            openFile(url)  // apply scoped opener rules
        } else {
            NSWorkspace.shared.open(url)  // system default
        }
    }

    /// Select (and scroll to) a row by name, e.g. a just-created folder.
    func select(name: String) { list.select(name: name) }

    @objc func goBack() { if nav.goBack() { enterDirectory() } }
    @objc func goForward() { if nav.goForward() { enterDirectory() } }
    @objc func goUp() { if nav.goUp() { enterDirectory() } }

    /// Move into nav.current: refresh the listing, watch the new folder for
    /// on-disk changes, and tell the browser the folder changed.
    private func enterDirectory() {
        startWatching()  // arm before snapshotting, to narrow the listing/watch gap
        reload(preserveState: false)  // navigation resets selection + scroll
        onDidNavigate?()
        onDirectoryDidChange?(nav.current)
    }

    private func startWatching() {
        let watched = nav.current
        watcher?.stop()  // tear down the previous watcher deterministically
        pendingRefresh?.cancel()
        watcher = DirectoryWatcher(path: watched.path) { [weak self] in
            Task { @MainActor in self?.directoryChangedOnDisk(watched: watched) }
        }
    }

    /// A disk change arrived for `watched`. Ignore it if we have navigated away,
    /// and debounce so a burst (an unzip, a large copy) collapses to one refresh.
    private func directoryChangedOnDisk(watched: URL) {
        guard watched == nav.current else { return }
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyDiskRefresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func applyDiskRefresh() {
        // Refresh the listing only if we're showing it (not search results),
        // but always tell the browser so it can rebuild the search index.
        if !showingSearchResults { reload() }
        onDirectoryDidChange?(nav.current)
    }

    func setActive(_ active: Bool) {
        containerView.layer?.borderColor =
            (active ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    // MARK: - Build

    private func build() {
        containerView.wantsLayer = true
        containerView.layer?.borderWidth = 1
        containerView.layer?.borderColor = NSColor.separatorColor.cgColor

        backButton = iconButton("chevron.backward", #selector(goBack))
        forwardButton = iconButton("chevron.forward", #selector(goForward))
        upButton = iconButton("chevron.up", #selector(goUp))

        pathControl.pathStyle = .standard
        pathControl.target = self
        pathControl.action = #selector(pathClicked)
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.setContentHuggingPriority(.init(1), for: .horizontal)
        pathControl.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        addressField.placeholderString = "Go to path"
        addressField.font = .systemFont(ofSize: 12)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.isHidden = true  // shown only while editing (Cmd-L)
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(commitPath)
        addressField.setContentHuggingPriority(.init(1), for: .horizontal)
        addressField.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let toolbar = NSStackView(views: [backButton, forwardButton, upButton, pathControl, addressField])
        toolbar.orientation = .horizontal
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let scroll = list.scrollView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(toolbar)
        containerView.addSubview(scroll)
        containerView.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: containerView.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            statusLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -5),
        ])
    }

    /// Update the bottom status line: item count, or the selection count and its
    /// total size when something is selected.
    private func updateStatus() {
        let all = list.entries
        let selected = list.selectedEntries
        if selected.isEmpty {
            let size = all.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
            let items = "\(all.count) item\(all.count == 1 ? "" : "s")"
            statusLabel.stringValue = size > 0 ? "\(items) · \(byteFormatter.string(fromByteCount: size))" : items
        } else {
            let size = selected.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
            let prefix = "\(selected.count) of \(all.count) selected"
            statusLabel.stringValue =
                size > 0 ? "\(prefix) · \(byteFormatter.string(fromByteCount: size))" : prefix
        }
    }

    private func iconButton(_ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func wire() {
        list.onOpen = { [weak self] entry in self?.descend(into: entry) }
        list.onBecomeActive = { [weak self] in self?.onBecomeActive?() }
        list.onSortChanged = { [weak self] key, ascending in
            guard let self else { return }
            self.format.sortKey = key
            self.format.ascending = ascending
            self.rememberFormat?(self.nav.current, self.format)
            self.reload()
        }
        list.onSelectionChanged = { [weak self] in self?.updateStatus() }
        list.onDropFiles = { [weak self] urls, move in
            guard let self else { return }
            self.onDropFiles?(urls, move, self.nav.current)
        }
    }

    func toggleHidden() {
        format.showHidden.toggle()
        rememberFormat?(nav.current, format)
        reload()
    }

    /// Open the current selection: descend into a folder (files are a no-op for
    /// now). Used by the "files.open" command.
    func openSelection() {
        guard let entry = selectedEntries.first else { return }
        descend(into: entry)
    }

    /// Jump to an arbitrary folder (used when restoring a layout).
    func navigate(to url: URL) {
        nav.go(to: url.standardizedFileURL)
        enterDirectory()
    }

    @objc private func pathClicked() {
        guard let url = pathControl.clickedPathItem?.url else { return }
        nav.go(to: url)
        enterDirectory()
    }

    // MARK: - Editable address bar (paste a path)

    /// Swap the breadcrumb for an editable field pre-filled with the current path,
    /// selected, so you can type or paste a new path and press Return.
    func beginEditingPath() {
        addressField.stringValue = nav.current.path
        pathControl.isHidden = true
        addressField.isHidden = false
        containerView.window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    private func endEditingPath() {
        addressField.isHidden = true
        pathControl.isHidden = false
    }

    @objc private func commitPath() {
        let raw = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        endEditingPath()
        containerView.window?.makeFirstResponder(list.tableView)  // restore focus on every path
        guard !raw.isEmpty else { return }
        // Resolve relative input against this pane's folder, not the process cwd.
        let expanded = (raw as NSString).expandingTildeInPath
        let url =
            expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded).standardizedFileURL
            : nav.current.appendingPathComponent(expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            NSSound.beep()  // no such path
            return
        }
        if isDirectory.boolValue {
            guard url != nav.current else { return }  // already here: don't push a duplicate history entry
            nav.go(to: url)
            enterDirectory()
        } else {
            // A file: open its folder and select it.
            nav.go(to: url.deletingLastPathComponent())
            enterDirectory()
            list.select(name: url.lastPathComponent)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicked away without committing: restore the breadcrumb.
        if !addressField.isHidden { endEditingPath() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {  // Esc cancels
            endEditingPath()
            containerView.window?.makeFirstResponder(list.tableView)
            return true
        }
        return false
    }
}
