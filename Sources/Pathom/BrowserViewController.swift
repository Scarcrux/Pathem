import AppKit
import PathomEngine

/// The dual-pane browser: two independent panes side by side in a split view,
/// one "active" pane (accent border), and one-key copy/move between them
/// (F5 and F6, the classic dual-pane bindings). A fast, native, two-pane file
/// manager.
@MainActor
final class BrowserViewController: NSViewController, NSMenuDelegate {
    private let left: PaneController
    private let right: PaneController
    private weak var activePane: PaneController?
    private let split = NSSplitView()
    private let searchField = NSSearchField()
    private var didSetInitialSplit = false

    /// Cap on items embedded per search, to bound the cost on huge folders.
    /// The scale path (background incremental indexing and a cached vector
    /// store) is in DESIGN.md section 2.
    private static let maxSemanticItems = 5_000
    /// Marker on the pasteboard meaning "these files were cut" (paste = move).
    private static let cutPasteboardType = NSPasteboard.PasteboardType("ai.scarcrux.pathom.cut")

    /// The command bus (DESIGN.md section 10). Every browser action is a named
    /// command; keybindings, the palette, and the AI bar will dispatch by id.
    let commands = CommandRegistry()
    /// Chord -> command id, defaults overlaid with any user keymap.json.
    private var keymap = Keymap.standard
    /// Per-folder saved view formats (the exact/subtree cascade), shared by both panes.
    private var folderFormats = FolderFormats()
    /// Saved workspace layouts (pane paths + split position).
    private var layouts = Layouts()
    private let layoutsMenu = NSMenu(title: "Layouts")
    private var didInstallLayoutsMenu = false

    /// Per-folder semantic index cache: pre-built when a pane enters a folder,
    /// invalidated when that folder changes on disk, so searches are instant.
    private var cachedDir: URL?
    private var cachedIndex: FolderSemanticIndex?
    private var cachedEntries: [FileEntry]?

    init(start: URL) {
        left = PaneController(start: start)
        right = PaneController(start: start)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(left.containerView)
        split.addArrangedSubview(right.containerView)

        searchField.placeholderString = "Semantic search in this folder (on-device)…"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(runSearch)

        let host = NSView()
        host.addSubview(searchField)
        host.addSubview(split)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            split.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        registerCommands()
        loadKeymap()
        loadFolderFormats()
        loadLayouts()
        installLayoutsMenu()
        left.onBecomeActive = { [weak self] in self?.setActive(self?.left) }
        right.onBecomeActive = { [weak self] in self?.setActive(self?.right) }
        for pane in [left, right] {
            pane.list.tableView.onKeyChord = { [weak self] chord in self?.handleKeyChord(chord) ?? false }
            pane.onDirectoryDidChange = { [weak self] url in self?.directoryChanged(pane, url) }
            pane.resolveFormat = { [weak self] url in self?.folderFormats.format(for: url.path) ?? .default }
            pane.rememberFormat = { [weak self] url, format in self?.rememberFormat(url, format) }
        }
        // The panes loaded with the default format during init (before the store
        // and closures were wired); reload now to apply any saved per-folder views.
        left.reload()
        right.reload()
        setActive(left)
    }

    /// Register every browser action as a named command. This is the spine the
    /// keymap, command palette, and AI bar will all bind to (DESIGN.md 10).
    private func registerCommands() {
        func add(
            _ id: String, _ title: String,
            enabled: @escaping () -> Bool = { true }, _ run: @escaping () -> Void
        ) {
            commands.register(.init(id: id, title: title, isEnabled: enabled, run: run))
        }
        let hasSelection: () -> Bool = { [weak self] in
            self?.activePane?.selectedEntries.isEmpty == false
        }
        add("files.copyToOtherPane", "Copy to Other Pane", enabled: hasSelection) {
            [weak self] in self?.transfer(move: false)
        }
        add("files.moveToOtherPane", "Move to Other Pane", enabled: hasSelection) {
            [weak self] in self?.transfer(move: true)
        }
        add("files.copy", "Copy", enabled: hasSelection) {
            [weak self] in self?.writeSelectionToPasteboard(cut: false)
        }
        add("files.cut", "Cut", enabled: hasSelection) {
            [weak self] in self?.writeSelectionToPasteboard(cut: true)
        }
        add("files.paste", "Paste") { [weak self] in self?.paste(nil) }
        add("files.open", "Open", enabled: hasSelection) { [weak self] in self?.activePane?.openSelection() }
        add("view.toggleHidden", "Show Hidden Files", enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.activePane?.toggleHidden()
        }
        add("view.applyToSubfolders", "Apply View to Subfolders", enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.applyViewToSubfolders()
        }
        add("layout.save", "Save Layout…") { [weak self] in self?.saveLayoutPrompt() }
        add("nav.back", "Back", enabled: { [weak self] in self?.activePane?.canGoBack ?? false }) {
            [weak self] in self?.activePane?.goBack()
        }
        add("nav.forward", "Forward", enabled: { [weak self] in self?.activePane?.canGoForward ?? false }) {
            [weak self] in self?.activePane?.goForward()
        }
        add("nav.up", "Enclosing Folder", enabled: { [weak self] in self?.activePane?.canGoUp ?? false }) {
            [weak self] in self?.activePane?.goUp()
        }
        add("edit.undo", "Undo", enabled: { [weak self] in self?.view.window?.undoManager?.canUndo ?? false }) {
            [weak self] in self?.undo(nil)
        }
        add("edit.redo", "Redo", enabled: { [weak self] in self?.view.window?.undoManager?.canRedo ?? false }) {
            [weak self] in self?.redo(nil)
        }
    }

    /// Resolve a key chord against the keymap and dispatch via the registry.
    /// Returns true if a binding existed (so the key is consumed even when the
    /// command is currently disabled).
    private func handleKeyChord(_ chord: KeyChord) -> Bool {
        guard let id = keymap.commandID(for: chord) else { return false }
        commands.perform(id)
        return true
    }

    private func loadKeymap() {
        guard let url = Self.appSupportDirectory()?.appendingPathComponent("keymap.json"),
            let data = try? Data(contentsOf: url),
            let user = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            keymap = .standard
            return
        }
        keymap = Keymap.standard.merging(userBindings: user)
    }

    private static func appSupportDirectory() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("Pathom", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Per-folder view formats

    private static var folderFormatsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("formats.json")
    }

    private func loadFolderFormats() {
        guard let url = Self.folderFormatsURL, let data = try? Data(contentsOf: url),
            let saved = try? JSONDecoder().decode(FolderFormats.self, from: data)
        else { return }
        folderFormats = saved
    }

    private func saveFolderFormats() {
        guard let url = Self.folderFormatsURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(folderFormats) { try? data.write(to: url) }
    }

    /// Auto-remember: the active folder gets its own exact-path format.
    private func rememberFormat(_ url: URL, _ format: ViewFormat) {
        folderFormats.setExact(url.path, format)
        saveFolderFormats()
    }

    /// Apply the active pane's current view to its whole subtree, then refresh
    /// both panes so any visible descendants pick up the new format.
    private func applyViewToSubfolders() {
        guard let pane = activePane else { return }
        folderFormats.setSubtree(pane.currentURL.path, pane.format)
        saveFolderFormats()
        left.reload()
        right.reload()
    }

    // MARK: - Layouts

    private static var layoutsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("layouts.json")
    }

    private func loadLayouts() {
        guard let url = Self.layoutsURL, let data = try? Data(contentsOf: url),
            let saved = try? JSONDecoder().decode(Layouts.self, from: data)
        else { return }
        layouts = saved
    }

    private func saveLayouts() {
        guard let url = Self.layoutsURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(layouts) { try? data.write(to: url) }
    }

    /// Add a "Layouts" menu to the main menu, rebuilt on demand from the saved set.
    private func installLayoutsMenu() {
        guard !didInstallLayoutsMenu, let mainMenu = NSApp.mainMenu else { return }
        let item = NSMenuItem()
        item.title = "Layouts"
        item.submenu = layoutsMenu
        layoutsMenu.delegate = self
        mainMenu.addItem(item)
        didInstallLayoutsMenu = true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === layoutsMenu else { return }
        menu.removeAllItems()
        let save = menu.addItem(withTitle: "Save Layout…", action: #selector(saveLayoutMenu), keyEquivalent: "")
        save.target = self
        guard !layouts.names.isEmpty else { return }
        menu.addItem(.separator())
        for name in layouts.names {
            let item = menu.addItem(withTitle: name, action: #selector(applyLayoutMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
        }
    }

    @objc private func saveLayoutMenu() { saveLayoutPrompt() }

    @objc private func applyLayoutMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let layout = layouts.named(name) else { return }
        applyLayout(layout)
    }

    private func saveLayoutPrompt() {
        let alert = NSAlert()
        alert.messageText = "Save Layout"
        alert.informativeText = "Name this arrangement of folders and panes."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "Layout \(layouts.names.count + 1)"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        layouts.save(captureLayout(name: name))
        saveLayouts()
    }

    private func captureLayout(name: String) -> Layout {
        Layout(
            name: name,
            leftPath: left.currentURL.path,
            rightPath: right.currentURL.path,
            dividerFraction: dividerFraction())
    }

    private func dividerFraction() -> Double {
        let total = split.bounds.width
        guard total > 0 else { return 0.5 }
        return Double(left.containerView.frame.width / total)
    }

    private func applyLayout(_ layout: Layout) {
        left.navigate(to: URL(fileURLWithPath: layout.leftPath))
        right.navigate(to: URL(fileURLWithPath: layout.rightPath))
        let total = split.bounds.width
        if total > 0 { split.setPosition(total * CGFloat(layout.dividerFraction), ofDividerAt: 0) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didSetInitialSplit, split.bounds.width > 0 {
            split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
            didSetInitialSplit = true
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(left.list.tableView)
    }

    private func setActive(_ pane: PaneController?) {
        activePane = pane
        left.setActive(pane === left)
        right.setActive(pane === right)
        if let directory = pane?.currentURL, directory != cachedDir { preIndex(directory) }
    }

    /// Copy (or move) the active pane's selection into the other pane's folder.
    /// If names already exist there, ask how to resolve (replace, keep both, or
    /// skip), then register an undo for whatever was performed (DESIGN.md §6.5).
    private func transfer(move: Bool) {
        guard let source = activePane else { return }
        let destination = (source === left) ? right : left
        let names = source.selectedEntries.map(\.name)
        guard !names.isEmpty else { NSSound.beep(); return }

        let sourceURL = source.currentURL
        let destinationURL = destination.currentURL

        var resolution = FileOperations.ConflictResolution.skip
        let conflicts = FileOperations.conflicts(names, from: sourceURL, to: destinationURL)
        if !conflicts.isEmpty {
            guard let chosen = askConflictResolution(conflictCount: conflicts.count, move: move) else {
                return  // user cancelled
            }
            resolution = chosen
        }

        let outcome =
            move
            ? FileOperations.move(names, from: sourceURL, to: destinationURL, onConflict: resolution)
            : FileOperations.copy(names, from: sourceURL, to: destinationURL, onConflict: resolution)

        if move { source.reload() }
        destination.reload()

        if !outcome.performed.isEmpty {
            registerUndo(outcome.performed, actionName: move ? "Move" : "Copy")
        }
        if !outcome.failures.isEmpty {
            presentFailures(outcome.failures, title: "\(move ? "Move" : "Copy") failed")
        }
    }

    private func askConflictResolution(conflictCount: Int, move: Bool)
        -> FileOperations.ConflictResolution?
    {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            "\(conflictCount) item\(conflictCount == 1 ? "" : "s") already exist at the destination"
        alert.informativeText = "Choose how to handle the \(move ? "move" : "copy")."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .keepBoth
        case .alertThirdButtonReturn: return .skip
        default: return nil
        }
    }

    private func registerUndo(_ performed: [FileOperations.Performed], actionName: String) {
        guard let undoManager = view.window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            let result = FileOperations.undo(performed)
            target.left.reload()
            target.right.reload()
            if !result.failures.isEmpty {
                target.presentFailures(result.failures, title: "Undo failed")
            }
        }
        undoManager.setActionName(actionName)
    }

    @objc func undo(_ sender: Any?) {
        guard let undoManager = view.window?.undoManager, undoManager.canUndo else {
            NSSound.beep()
            return
        }
        undoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard let undoManager = view.window?.undoManager, undoManager.canRedo else {
            NSSound.beep()
            return
        }
        undoManager.redo()
    }

    // MARK: - File clipboard (cut / copy / paste)
    //
    // Routed via the Edit menu's cut:/copy:/paste:. When the search field is
    // focused the field editor handles them as text editing; when a pane's table
    // is focused they reach here and act on files.

    @objc func copy(_ sender: Any?) { writeSelectionToPasteboard(cut: false) }
    @objc func cut(_ sender: Any?) { writeSelectionToPasteboard(cut: true) }

    @objc func paste(_ sender: Any?) {
        guard let pane = activePane else { return }
        let pasteboard = NSPasteboard.general
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
        guard !urls.isEmpty else { NSSound.beep(); return }

        let isMove = pasteboard.data(forType: Self.cutPasteboardType) != nil
        let destination = pane.currentURL

        var resolution = FileOperations.ConflictResolution.skip
        let conflicts = FileOperations.conflicts(urls: urls, into: destination)
        if !conflicts.isEmpty {
            guard let chosen = askConflictResolution(conflictCount: conflicts.count, move: isMove) else {
                return
            }
            resolution = chosen
        }

        let outcome =
            isMove
            ? FileOperations.move(urls: urls, into: destination, onConflict: resolution)
            : FileOperations.copy(urls: urls, into: destination, onConflict: resolution)

        left.reload()
        right.reload()
        if !outcome.performed.isEmpty {
            registerUndo(outcome.performed, actionName: isMove ? "Move" : "Copy")
        }
        if isMove { pasteboard.clearContents() }  // cut items are gone; don't move them twice
        if !outcome.failures.isEmpty { presentFailures(outcome.failures, title: "Paste failed") }
    }

    private func writeSelectionToPasteboard(cut: Bool) {
        guard let pane = activePane else { return }
        let urls = pane.selectedEntries.map { pane.currentURL.appendingPathComponent($0.name) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        if cut {
            pasteboard.addTypes([Self.cutPasteboardType], owner: nil)
            pasteboard.setData(Data(), forType: Self.cutPasteboardType)
        }
    }

    private func presentFailures(_ failures: [FileOperations.Failure], title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(title) for \(failures.count) item(s)"
        alert.informativeText =
            failures.prefix(8).map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
        alert.runModal()
    }

    // MARK: - Semantic search (on-device, free)

    /// Re-rank the active pane's folder by semantic similarity to the query.
    /// An empty query restores the normal directory listing. All embedding runs
    /// off the main thread, so the UI never blocks.
    @objc private func runSearch(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pane = activePane else { return }
        guard !query.isEmpty else {
            pane.reload()  // cleared search, restore the directory listing
            return
        }
        let directory = pane.currentURL
        Task {
            await ensureIndex(for: directory)
            guard let index = cachedIndex, let entries = cachedEntries, cachedDir == directory
            else { return }
            let order = await Task.detached { SemanticSearcher.rank(query: query, in: index) }.value
            let ranked = order.compactMap { $0 < entries.count ? entries[$0] : nil }
            if activePane?.currentURL == directory { pane.showResults(ranked) }
        }
    }

    /// Build the semantic index for `directory` in the background (if not already
    /// cached for it), so the next search there is instant.
    private func preIndex(_ directory: URL) {
        Task { await ensureIndex(for: directory) }
    }

    /// Ensure the cache holds a fresh index for `directory`. Enumerates and
    /// embeds off the main thread; only adopts the result if the active pane is
    /// still on that folder.
    private func ensureIndex(for directory: URL) async {
        guard cachedDir != directory || cachedIndex == nil else { return }
        let maxItems = Self.maxSemanticItems
        let dirEntries = await Task.detached {
            (try? BulkEnumerator().entries(of: directory, includingHidden: false)) ?? []
        }.value
        let built = await Task.detached {
            SemanticSearcher.index(dirEntries, in: directory, maxItems: maxItems)
        }.value
        if activePane?.currentURL == directory {
            cachedDir = directory
            cachedEntries = dirEntries
            cachedIndex = built
        }
    }

    /// A pane's folder changed (navigation or on-disk edit): drop a stale cache
    /// for it, and rebuild in the background if it is the active pane.
    private func directoryChanged(_ pane: PaneController, _ url: URL) {
        if cachedDir == url {
            cachedDir = nil
            cachedIndex = nil
            cachedEntries = nil
        }
        if pane === activePane { preIndex(url) }
    }
}
