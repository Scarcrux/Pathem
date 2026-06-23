import AppKit
import PathemEngine
import PathemTerminal
import Quartz

/// The dual-pane browser: two independent panes side by side in a split view,
/// one "active" pane (accent border), and one-key copy/move between them
/// (F5 and F6, the classic dual-pane bindings). A fast, native, two-pane file
/// manager.
@MainActor
final class BrowserViewController: NSViewController, NSMenuDelegate, QLPreviewPanelDataSource,
    NSSplitViewDelegate, NSMenuItemValidation
{
    private let leftTabs: TabbedPaneController
    private let rightTabs: TabbedPaneController
    private weak var activePane: PaneController?
    private weak var activeSide: TabbedPaneController?
    private let split = NSSplitView()  // the two sides
    private let outerSplit = NSSplitView()  // sidebar | panes
    private let vSplit = NSSplitView()  // browser (top) | terminal (bottom)
    private let sidebar = SidebarController()
    private let terminal = TerminalController()
    private let searchField = NSSearchField()
    private var didSetInitialSplit = false
    /// Opt-in: when true the terminal `cd`s as the active folder changes. Off by
    /// default so navigation never disturbs whatever you're running in the shell.
    private var terminalFollows = UserDefaults.standard.bool(forKey: "pathem.terminalFollows")
    /// True while restoring the saved session, so restore activity doesn't trigger
    /// a (partial) save.
    private var isRestoringSession = false
    private var pendingSessionSave: DispatchWorkItem?

    /// Cap on items embedded per search, to bound the cost on huge folders.
    /// The scale path (background incremental indexing and a cached vector
    /// store) is in DESIGN.md section 2.
    private static let maxSemanticItems = 5_000
    /// Marker on the pasteboard meaning "these files were cut" (paste = move).
    private static let cutPasteboardType = NSPasteboard.PasteboardType("ai.scarcrux.pathem.cut")

    /// The command bus (DESIGN.md section 10). Every browser action is a named
    /// command; keybindings, the palette, and the AI bar will dispatch by id.
    let commands = CommandRegistry()
    /// Chord -> command id, defaults overlaid with any user keymap.json.
    private var keymap = Keymap.standard
    /// Per-folder saved view formats (the exact/subtree cascade), shared by both panes.
    private var folderFormats = FolderFormats()
    /// Scoped default-opener rules (by file / folder / type), persisted.
    private var openerRules = OpenerRules()
    /// Session-only opener overrides, keyed by lowercased extension (not persisted).
    private var sessionOpenersByType: [String: String] = [:]
    /// Saved workspace layouts (pane paths + split position).
    private var layouts = Layouts()
    /// Fuzzy command palette over the registry (Cmd-Shift-P).
    private lazy var palette = CommandPalette()
    /// Natural-language command bar (Cmd-Shift-A): Foundation Model when
    /// available, the engine heuristic otherwise.
    private lazy var aiBar = AICommandBar()
    /// Batch-rename sheet for the active pane's selection.
    private lazy var batchRename = BatchRenameController()
    private lazy var preferencesPanel = PreferencesController()
    /// User preferences (density, font, alternating rows, search OCR).
    private var prefs = Preferences.default
    /// Progress sheet for copy/move; one transfer at a time.
    private lazy var transferProgress = TransferProgress()
    private var transferInFlight = false
    /// Whether a copy/move is running (so the app can warn before quitting).
    var isTransferring: Bool { transferInFlight }
    /// Guided Full Disk Access walkthrough (first launch, until granted).
    private lazy var fdaGuide = FullDiskAccessGuide()
    private lazy var infoInspector = InfoInspectorController()
    private lazy var connectionsController = ConnectionsController()
    private lazy var transferController = TransferController()
    private let layoutsMenu = NSMenu(title: "Layouts")
    private var didInstallLayoutsMenu = false

    /// Per-folder semantic index cache: pre-built when a pane enters a folder,
    /// invalidated when that folder changes on disk, so searches are instant.
    private var cachedDir: URL?
    private var cachedIndex: FolderSemanticIndex?
    private var cachedEntries: [FileEntry]?

    init(start: URL) {
        leftTabs = TabbedPaneController(start: start)
        rightTabs = TabbedPaneController(start: start)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(leftTabs.containerView)
        split.addArrangedSubview(rightTabs.containerView)

        outerSplit.isVertical = true
        outerSplit.dividerStyle = .thin
        outerSplit.delegate = self
        outerSplit.translatesAutoresizingMaskIntoConstraints = false
        outerSplit.addArrangedSubview(sidebar.containerView)
        outerSplit.addArrangedSubview(split)
        // Keep the sidebar's width when the window resizes; the panes absorb it.
        outerSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        // Durably pin the sidebar to a sane default width so the panes always get
        // the rest. setPosition() alone is transient in an auto-layout split and
        // can let the sidebar swallow the whole window; this constraint stays put
        // and is still draggable (its priority is below the divider-drag priority).
        let sidebarWidth = sidebar.containerView.widthAnchor.constraint(equalToConstant: 200)
        sidebarWidth.priority = NSLayoutConstraint.Priority(260)
        sidebarWidth.isActive = true

        searchField.placeholderString = "Search"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(runSearch)
        searchField.sendsSearchStringImmediately = false
        searchField.toolTip = "Semantic search in this folder (on-device)"

        // Vertical split: the browser (sidebar + panes) on top, the optional
        // terminal drawer at the bottom. The terminal starts collapsed.
        vSplit.isVertical = false
        vSplit.dividerStyle = .thin
        vSplit.translatesAutoresizingMaskIntoConstraints = false
        vSplit.addArrangedSubview(outerSplit)
        vSplit.addArrangedSubview(terminal.view)
        vSplit.delegate = self
        // The terminal keeps its height; the browser absorbs window resize.
        vSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 1)
        terminal.view.isHidden = true

        let host = NSView()
        host.addSubview(searchField)
        host.addSubview(vSplit)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            searchField.widthAnchor.constraint(equalToConstant: 240),  // top-right, like Finder
            vSplit.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            vSplit.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            vSplit.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            vSplit.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        view = host
    }

    // Constrain the sidebar width (outer split) and the terminal drawer height
    // (vertical split) so neither the sidebar, the panes, nor the terminal can be
    // dragged away to nothing.
    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        if splitView === outerSplit, dividerIndex == 0 { return 140 }  // min sidebar width
        if splitView === vSplit, dividerIndex == 0 { return 160 }  // min browser height
        return proposedMin
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        if splitView === outerSplit, dividerIndex == 0 { return 320 }  // max sidebar width
        if splitView === vSplit, dividerIndex == 0 { return splitView.bounds.height - 120 }  // min terminal height
        return proposedMax
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        registerCommands()
        loadKeymap()
        loadFolderFormats()
        loadLayouts()
        loadPreferences()
        loadSidebar()
        loadTerminalTheme()
        loadOpenerRules()
        loadConnections()
        installLayoutsMenu()
        for side in [leftTabs, rightTabs] {
            side.configurePane = { [weak self] pane in
                pane.onKeyChordHandler = { [weak self] chord in self?.handleKeyChord(chord) ?? false }
                pane.resolveFormat = { [weak self] url in self?.folderFormats.format(for: url.path) ?? .default }
                pane.rememberFormat = { [weak self] url, format in self?.rememberFormat(url, format) }
                pane.openFile = { [weak self] url in self?.applyOpen(url) }
                pane.onUploadFiles = { [weak self, weak pane] urls, connection, remotePath, password in
                    guard let self, let pane else { return }
                    self.uploadFiles(urls, to: connection, remotePath: remotePath, password: password, pane: pane)
                }
                pane.onOpenRemoteFile = { [weak self] connection, remotePath, password, name in
                    self?.openRemoteFile(connection, remotePath: remotePath, password: password, name: name)
                }
            }
            side.onPaneBecameActive = { [weak self, weak side] pane in
                guard let self, let side else { return }
                self.setActiveSide(side, pane: pane)
            }
            side.onPaneDirectoryDidChange = { [weak self] pane, url in self?.directoryChanged(pane, url) }
            side.onPaneDidNavigate = { [weak self] pane in
                guard pane === self?.activePane else { return }
                self?.searchField.stringValue = ""
                self?.updateWindowTitle()  // covers remote nav too
            }
            side.onPaneDropFiles = { [weak self] urls, move, destination in
                self?.dropFiles(urls, move: move, into: destination)
            }
        }
        // Restore the last session's tabs/folders (or open initial tabs) now that
        // configurePane + callbacks are set, so each pane is fully wired.
        restoreSession()
        sidebar.onSelect = { [weak self] url in self?.activePane?.navigate(to: url) }
        sidebar.onModelChange = { [weak self] model in self?.saveSidebar(model) }
        sidebar.currentFolder = { [weak self] in self?.activePane?.currentURL }
        applyPreferences()
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
        add("view.asList", "as List") { [weak self] in self?.activePane?.setViewMode(.list) }
        add("view.asIcons", "as Icons") { [weak self] in self?.activePane?.setViewMode(.icon) }
        add("view.asGallery", "as Gallery") { [weak self] in self?.activePane?.setViewMode(.gallery) }
        add("terminal.toggle", "Toggle Terminal") { [weak self] in self?.toggleTerminal() }
        add("terminal.here", "Open Terminal Here") { [weak self] in self?.openTerminalHere() }
        add("terminal.toggleFollow", "Terminal Follows Folder") {
            [weak self] in self?.toggleTerminalFollows()
        }
        add("files.paste", "Paste") { [weak self] in self?.paste(nil) }
        add("files.open", "Open", enabled: hasSelection) { [weak self] in self?.activePane?.openSelection() }
        add("files.batchRename", "Batch Rename…", enabled: hasSelection) { [weak self] in self?.showBatchRename() }
        add("files.newFolder", "New Folder") { [weak self] in self?.newFolder() }
        add("files.rename", "Rename…", enabled: { [weak self] in self?.activePane?.selectedEntries.count == 1 }) {
            [weak self] in self?.renameSelection()
        }
        add("files.trash", "Move to Trash", enabled: hasSelection) { [weak self] in self?.trashSelection() }
        add("files.reveal", "Reveal in Finder", enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.revealSelection()
        }
        add("files.getInfo", "Get Info", enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.showInfo()
        }
        add(
            "files.download", "Download",
            enabled: { [weak self] in self?.activePane?.selectedEntries.contains(where: \.isDataless) ?? false }
        ) { [weak self] in self?.downloadSelection() }
        add("view.preferences", "Preferences…") { [weak self] in self?.showPreferences() }
        add("view.fullPathTitle", "Show Full Path in Title Bar") { [weak self] in self?.toggleFullPathTitle() }
        add("search.toggleOCR", "Toggle Image OCR in Search") { [weak self] in self?.toggleOCR() }
        add("view.toggleHidden", "Show Hidden Files", enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.activePane?.toggleHidden()
        }
        add("view.applyToSubfolders", "Apply View to Subfolders", enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.applyViewToSubfolders()
        }
        add("layout.save", "Save Layout…") { [weak self] in self?.saveLayoutPrompt() }
        add("palette.show", "Command Palette…") { [weak self] in self?.showPalette() }
        add("ai.run", "Ask Pathem (Natural Language)…") { [weak self] in self?.showAICommandBar() }
        add("view.quickLook", "Quick Look", enabled: hasSelection) { [weak self] in self?.toggleQuickLook() }
        add("tab.new", "New Tab") { [weak self] in self?.activeSide?.newTab(duplicatingCurrent: true) }
        add("tab.close", "Close Tab", enabled: { [weak self] in (self?.activeSide?.tabCount ?? 0) > 1 }) {
            [weak self] in self?.activeSide?.closeActiveTab()
        }
        add("tab.next", "Next Tab", enabled: { [weak self] in (self?.activeSide?.tabCount ?? 0) > 1 }) {
            [weak self] in self?.activeSide?.selectNextTab()
        }
        add("tab.previous", "Previous Tab", enabled: { [weak self] in (self?.activeSide?.tabCount ?? 0) > 1 }) {
            [weak self] in self?.activeSide?.selectPreviousTab()
        }
        add("nav.back", "Back", enabled: { [weak self] in self?.activePane?.canGoBack ?? false }) {
            [weak self] in self?.activePane?.goBack()
        }
        add("nav.forward", "Forward", enabled: { [weak self] in self?.activePane?.canGoForward ?? false }) {
            [weak self] in self?.activePane?.goForward()
        }
        add("nav.up", "Enclosing Folder", enabled: { [weak self] in self?.activePane?.canGoUp ?? false }) {
            [weak self] in self?.activePane?.goUp()
        }
        add("nav.editPath", "Go to Path…") { [weak self] in self?.activePane?.beginEditingPath() }
        add("connections.manage", "Connections…") {
            [weak self] in self?.connectionsController.present(over: self?.view.window)
        }
        add("connections.newTabToggle", "Open Connections in a New Tab") {
            [weak self] in self?.toggleConnectionsNewTab()
        }
        add(
            "remote.download", "Download from Server…",
            enabled: { [weak self] in
                guard let pane = self?.activePane, pane.isRemote else { return false }
                return pane.selectedEntries.contains { !$0.isDirectory }
            }
        ) { [weak self] in self?.downloadSelectedRemote() }
        add("edit.undo", "Undo", enabled: { [weak self] in self?.view.window?.undoManager?.canUndo ?? false }) {
            [weak self] in self?.undo(nil)
        }
        add("edit.redo", "Redo", enabled: { [weak self] in self?.view.window?.undoManager?.canRedo ?? false }) {
            [weak self] in self?.redo(nil)
        }
    }

    /// Open the command palette over the current window, dispatching the chosen
    /// command through the registry.
    private func showPalette() {
        guard let window = view.window else { return }
        let items = commands.all.map { (id: $0.id, title: $0.title) }
        palette.present(commands: items, onRun: { [weak self] id in self?.commands.perform(id) }, over: window)
    }

    /// Open the batch-rename sheet for the active pane's selection.
    private func showBatchRename() {
        guard let window = view.window, let pane = activePane else { return }
        let names = pane.selectedEntries.map(\.name)
        guard !names.isEmpty else { NSSound.beep(); return }
        let existing = Set(pane.entries.map(\.name))
        batchRename.present(names: names, in: pane.currentURL, existing: existing, over: window) {
            [weak self] in self?.activePane?.reloadIfShowingListing()
        }
    }

    // MARK: - New folder / Trash / Reveal

    /// Local-only commands must not act while a remote pane is active: the pane's
    /// selection is remote names but its currentURL is the saved LOCAL folder, so
    /// running them would hit the local disk. Returns true (and beeps) if blocked.
    private func blockedByRemote() -> Bool {
        if activePane?.isRemote == true {
            NSSound.beep()
            return true
        }
        return false
    }

    private func newFolder() {
        if blockedByRemote() { return }
        guard let pane = activePane else { return }
        do {
            let name = try FileOperations.makeFolder(in: pane.currentURL)
            pane.reloadIfShowingListing()
            pane.select(name: name)
            registerNewFolderUndo(name: name, in: pane.currentURL)
        } catch {
            presentFailures(
                [FileOperations.Failure(name: "New Folder", reason: error.localizedDescription)],
                title: "Couldn’t create folder")
        }
    }

    private func registerNewFolderUndo(name: String, in directory: URL) {
        guard let undoManager = view.window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            let result = FileOperations.trash([name], in: directory)  // undo = trash the new folder
            target.reloadBothSides()
            if !result.failures.isEmpty { target.presentFailures(result.failures, title: "Undo failed") }
            if !result.trashed.isEmpty {
                target.registerNewFolderRedo(name: name, in: directory, trashed: result.trashed)
            }
        }
        undoManager.setActionName("New Folder")
    }

    private func registerNewFolderRedo(name: String, in directory: URL, trashed: [FileOperations.Trashed]) {
        guard let undoManager = view.window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            let failures = FileOperations.untrash(trashed)  // redo = restore the folder
            target.reloadBothSides()
            target.paneShowing(directory)?.select(name: name)
            if !failures.isEmpty { target.presentFailures(failures, title: "Redo failed") }
            target.registerNewFolderUndo(name: name, in: directory)
        }
        undoManager.setActionName("New Folder")
    }

    private func renameSelection() {
        if blockedByRemote() { return }
        guard let pane = activePane, pane.selectedEntries.count == 1,
            let entry = pane.selectedEntries.first
        else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(entry.name)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = entry.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != entry.name else { return }
        let directory = pane.currentURL
        do {
            try FileOperations.rename(entry.name, to: newName, in: directory)
            registerRenameUndo(from: newName, to: entry.name, in: directory)
            pane.reloadIfShowingListing()
            pane.select(name: newName)
        } catch {
            presentFailures(
                [FileOperations.Failure(name: entry.name, reason: error.localizedDescription)],
                title: "Rename failed")
        }
    }

    private func registerRenameUndo(from current: String, to original: String, in directory: URL) {
        guard let undoManager = view.window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            do {
                try FileOperations.rename(current, to: original, in: directory)
                target.reloadBothSides()
                target.paneShowing(directory)?.select(name: original)
                target.registerRenameUndo(from: original, to: current, in: directory)  // redo
            } catch {
                target.presentFailures(
                    [FileOperations.Failure(name: current, reason: error.localizedDescription)],
                    title: "Undo failed")
            }
        }
        undoManager.setActionName("Rename")
    }

    private func trashSelection() {
        if blockedByRemote() { return }
        guard let pane = activePane else { return }
        let names = pane.selectedEntries.map(\.name)
        guard !names.isEmpty else { NSSound.beep(); return }
        let result = FileOperations.trash(names, in: pane.currentURL)
        pane.reloadIfShowingListing()
        if !result.trashed.isEmpty { registerTrashUndo(result.trashed) }
        if !result.failures.isEmpty { presentFailures(result.failures, title: "Move to Trash failed") }
    }

    private func registerTrashUndo(_ trashed: [FileOperations.Trashed]) {
        guard let undoManager = view.window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            let failures = FileOperations.untrash(trashed)
            target.reloadBothSides()
            if !failures.isEmpty { target.presentFailures(failures, title: "Undo failed") }
            target.registerTrashRedo(trashed)  // redo = move them back to the Trash
        }
        undoManager.setActionName("Move to Trash")
    }

    private func registerTrashRedo(_ trashed: [FileOperations.Trashed]) {
        guard let undoManager = view.window?.undoManager,
            let directory = trashed.first?.original.deletingLastPathComponent()
        else { return }
        undoManager.registerUndo(withTarget: self) { target in
            let names = trashed.map { $0.original.lastPathComponent }
            let result = FileOperations.trash(names, in: directory)
            target.reloadBothSides()
            if !result.failures.isEmpty { target.presentFailures(result.failures, title: "Redo failed") }
            if !result.trashed.isEmpty { target.registerTrashUndo(result.trashed) }
        }
        undoManager.setActionName("Move to Trash")
    }

    /// Refresh the active pane on each side (used by undo/redo handlers).
    private func reloadBothSides() {
        leftTabs.activePane?.reloadIfShowingListing()
        rightTabs.activePane?.reloadIfShowingListing()
    }

    /// The pane (on either side) currently showing `directory`, if any.
    private func paneShowing(_ directory: URL) -> PaneController? {
        for side in [leftTabs, rightTabs] {
            for pane in side.tabs where pane.currentURL == directory { return pane }
        }
        return nil
    }

    private func revealSelection() {
        if blockedByRemote() { return }
        guard let pane = activePane else { return }
        let urls = pane.selectedEntries.map { pane.currentURL.appendingPathComponent($0.name) }
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [pane.currentURL] : urls)
    }

    /// Get Info on the selection, or on the current folder when nothing is selected.
    private func showInfo() {
        if blockedByRemote() { return }
        guard let pane = activePane else { return }
        let names = pane.selectedEntries.map(\.name)
        let urls = names.isEmpty ? [pane.currentURL] : names.map { pane.currentURL.appendingPathComponent($0) }
        infoInspector.present(urls: urls, over: view.window)
    }

    /// Pull down online-only (dataless) cloud files. The provider materializes
    /// them; the watcher refreshes the badge as they land.
    private func downloadSelection() {
        if blockedByRemote() { return }
        guard let pane = activePane else { return }
        let directory = pane.currentURL
        for entry in pane.selectedEntries where entry.isDataless {
            try? FileManager.default.startDownloadingUbiquitousItem(
                at: directory.appendingPathComponent(entry.name))
        }
    }

    /// Run a registry command from a menu item carrying its id in representedObject.
    @objc func performMenuCommand(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { commands.perform(id) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectTerminalTheme(_:)) {
            menuItem.state = (menuItem.representedObject as? String == terminal.theme.name) ? .on : .off
            return true
        }
        guard menuItem.action == #selector(performMenuCommand(_:)),
            let id = menuItem.representedObject as? String
        else { return true }
        if id == "terminal.toggleFollow" { menuItem.state = terminalFollows ? .on : .off }
        switch id {
        case "view.asList": menuItem.state = activePane?.viewMode == .list ? .on : .off
        case "view.asIcons": menuItem.state = activePane?.viewMode == .icon ? .on : .off
        case "view.asGallery": menuItem.state = activePane?.viewMode == .gallery ? .on : .off
        case "view.fullPathTitle": menuItem.state = prefs.showFullPathInTitle ? .on : .off
        case "connections.newTabToggle": menuItem.state = prefs.openConnectionsInNewTab ? .on : .off
        default: break
        }
        return commands.command(id)?.isEnabled() ?? true
    }

    // MARK: - Preferences

    private static var preferencesURL: URL? {
        appSupportDirectory()?.appendingPathComponent("prefs.json")
    }

    private func loadPreferences() {
        if let saved = loadConfig(Preferences.self, from: Self.preferencesURL) { prefs = saved }
    }

    private func showPreferences() {
        guard let window = view.window else { return }
        preferencesPanel.present(prefs, over: window) { [weak self] updated in
            guard let self else { return }
            self.prefs = updated
            self.applyPreferences()
        }
    }

    private func toggleOCR() {
        prefs.searchOCR.toggle()
        applyPreferences()
    }

    private func toggleFullPathTitle() {
        prefs.showFullPathInTitle.toggle()
        saveConfig(prefs, to: Self.preferencesURL)
        updateWindowTitle()
    }

    private func toggleConnectionsNewTab() {
        prefs.openConnectionsInNewTab.toggle()
        saveConfig(prefs, to: Self.preferencesURL)
    }

    /// Apply preferences to every tab in both sides, persist them, and rebuild the
    /// search index (OCR can change what gets embedded).
    private func applyPreferences() {
        for side in [leftTabs, rightTabs] {
            for pane in side.tabs {
                pane.applyStyle(
                    rowHeight: prefs.rowHeight, fontSize: prefs.fontSize,
                    alternatingRows: prefs.alternatingRows)
            }
        }
        saveConfig(prefs, to: Self.preferencesURL)
        cachedDir = nil
        cachedIndex = nil
        cachedEntries = nil
        if let directory = activePane?.currentURL { preIndex(directory) }
    }

    /// Open the natural-language command bar.
    private func showAICommandBar() {
        guard let window = view.window else { return }
        aiBar.present(
            over: window,
            resolve: { [weak self] query in await self?.resolveCommand(query) ?? nil },
            run: { [weak self] id in self?.commands.perform(id) })
    }

    /// Resolve a natural-language request to a command: the on-device Foundation
    /// Model when available, the engine heuristic otherwise.
    private func resolveCommand(_ query: String) async -> (id: String, title: String)? {
        let items = commands.all.map { (id: $0.id, title: $0.title) }
        if #available(macOS 26.0, *),
            let id = await FoundationModelMatcher.match(query, to: items),
            let command = commands.command(id)
        {
            return (command.id, command.title)
        }
        if let id = CommandResolver.resolve(query, commands: items), let command = commands.command(id) {
            return (command.id, command.title)
        }
        return nil
    }

    // MARK: - Quick Look

    @objc private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// File URLs for the active pane's current selection (Quick Look targets).
    private var quickLookURLs: [URL] {
        guard let pane = activePane else { return [] }
        return pane.selectedEntries.map { pane.currentURL.appendingPathComponent($0.name) }
    }

    // Quick Look invokes these on the main thread, but the protocol/responder
    // methods are nonisolated, so hop onto the main actor explicitly.
    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { quickLookURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        // Return URL (Sendable) out of the actor hop, then bridge to NSURL.
        let url: URL? = MainActor.assumeIsolated {
            let urls = quickLookURLs
            return index < urls.count ? urls[index] : nil
        }
        return url.map { $0 as NSURL }
    }

    /// Resolve a key chord against the keymap and dispatch via the registry.
    /// Returns true if a binding existed (so the key is consumed even when the
    /// command is currently disabled).
    private func handleKeyChord(_ chord: KeyChord) -> Bool {
        // Don't consume a chord whose command is currently disabled, so the event
        // falls through (e.g. Cmd-W with one tab should reach Close Window).
        guard let id = keymap.commandID(for: chord), commands.command(id)?.isEnabled() == true else {
            return false
        }
        commands.perform(id)
        return true
    }

    private func loadKeymap() {
        let url = Self.appSupportDirectory()?.appendingPathComponent("keymap.json")
        if let user = loadConfig([String: String].self, from: url) {
            keymap = Keymap.standard.merging(userBindings: user)
        } else {
            keymap = .standard
        }
    }

    private static func appSupportDirectory() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("Pathem", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("Pathem: cannot create Application Support directory: %@", String(describing: error))
            return nil  // callers stop rather than write into a nonexistent dir
        }
        return dir
    }

    /// Decode config from `url`. A missing file returns nil (use defaults). A
    /// present-but-undecodable file (corrupt, hand-edit typo, newer schema) is
    /// moved aside to <name>.corrupt and returns nil, so the next save cannot
    /// silently overwrite and destroy still-recoverable config.
    private func loadConfig<T: Decodable>(_ type: T.Type, from url: URL?) -> T? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        if let decoded = try? JSONDecoder().decode(T.self, from: data) { return decoded }
        let fm = FileManager.default
        let aside = url.appendingPathExtension("corrupt")
        try? fm.removeItem(at: aside)
        try? fm.moveItem(at: url, to: aside)
        NSLog("Pathem: %@ was unreadable; moved aside to %@", url.lastPathComponent, aside.lastPathComponent)
        return nil
    }

    /// Encode and write config atomically (temp file + rename), so a crash or
    /// power loss mid-write never truncates the existing file.
    private func saveConfig<T: Encodable>(_ value: T, to url: URL?) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: - Per-folder view formats

    private static var folderFormatsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("formats.json")
    }

    private func loadFolderFormats() {
        if let saved = loadConfig(FolderFormats.self, from: Self.folderFormatsURL) { folderFormats = saved }
    }

    private func saveFolderFormats() {
        saveConfig(folderFormats, to: Self.folderFormatsURL)
    }

    /// Auto-remember: the active folder gets its own exact-path format.
    private func rememberFormat(_ url: URL, _ format: ViewFormat) {
        folderFormats.setExact(url.path, format)
        saveFolderFormats()
    }

    /// Apply the active pane's current view to its whole subtree, then refresh
    /// both panes so any visible descendants pick up the new format. Descendant
    /// exact rules are cleared first, otherwise they would shadow the new subtree
    /// rule and silently keep their old view.
    private func applyViewToSubfolders() {
        guard let pane = activePane else { return }
        folderFormats.clearExactRulesUnder(pane.currentURL.path)
        folderFormats.setSubtree(pane.currentURL.path, pane.format)
        saveFolderFormats()
        leftTabs.activePane?.reloadIfShowingListing()
        rightTabs.activePane?.reloadIfShowingListing()
    }

    // MARK: - Layouts

    private static var layoutsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("layouts.json")
    }

    private func loadLayouts() {
        if let saved = loadConfig(Layouts.self, from: Self.layoutsURL) { layouts = saved }
    }

    private func saveLayouts() {
        saveConfig(layouts, to: Self.layoutsURL)
    }

    // MARK: - Customizable sidebar

    private static var sidebarURL: URL? {
        appSupportDirectory()?.appendingPathComponent("sidebar.json")
    }

    private func loadSidebar() {
        if let saved = loadConfig(Sidebar.self, from: Self.sidebarURL) {
            sidebar.model = saved
        } else {
            sidebar.model = .makeDefault(home: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    private func saveSidebar(_ model: Sidebar) {
        saveConfig(model, to: Self.sidebarURL)
    }

    // MARK: - Terminal theme

    private static var terminalThemeURL: URL? {
        appSupportDirectory()?.appendingPathComponent("terminal.json")
    }

    private func loadTerminalTheme() {
        if let saved = loadConfig(TerminalTheme.self, from: Self.terminalThemeURL) {
            terminal.theme = saved
        }
    }

    // MARK: - Session restoration

    /// The last window session: each side's tab folders, active tab, active side.
    private struct SessionState: Codable, Equatable {
        var left: [String]
        var leftActive: Int
        var right: [String]
        var rightActive: Int
        var leftIsActive: Bool
    }
    private var lastSavedSession: SessionState?

    private static var sessionURL: URL? {
        appSupportDirectory()?.appendingPathComponent("session.json")
    }

    /// Reopen the last session's tabs/folders, or open initial tabs if none.
    private func restoreSession() {
        isRestoringSession = true
        defer { isRestoringSession = false }
        if let session = loadConfig(SessionState.self, from: Self.sessionURL),
            !(session.left.isEmpty && session.right.isEmpty)
        {
            leftTabs.restoreTabs(session.left, active: session.leftActive)
            rightTabs.restoreTabs(session.right, active: session.rightActive)
            let side = session.leftIsActive ? leftTabs : rightTabs
            if let pane = (side.activePane ?? leftTabs.activePane) {
                setActiveSide(side.activePane != nil ? side : leftTabs, pane: pane)
            }
        } else {
            leftTabs.openInitialTab()
            rightTabs.openInitialTab()
            if let pane = leftTabs.activePane { setActiveSide(leftTabs, pane: pane) }
        }
    }

    /// Persist the session a moment after a change (coalesces navigation bursts).
    private func saveSessionSoon() {
        guard !isRestoringSession else { return }
        pendingSessionSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSessionNow() }
        pendingSessionSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Persist the session immediately (called on quit).
    func saveSessionNow() {
        let state = SessionState(
            left: leftTabs.tabFolders, leftActive: leftTabs.activeTabIndex,
            right: rightTabs.tabFolders, rightActive: rightTabs.activeTabIndex,
            leftIsActive: activeSide === leftTabs)
        guard state != lastSavedSession else { return }  // skip no-op writes (e.g. watcher ticks)
        lastSavedSession = state
        saveConfig(state, to: Self.sessionURL)
    }

    // MARK: - Remote connections

    private static var connectionsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("connections.json")
    }

    private func loadConnections() {
        if let saved = loadConfig([RemoteConnection].self, from: Self.connectionsURL) {
            connectionsController.connections = saved
        }
        connectionsController.onChange = { [weak self] conns in
            self?.saveConfig(conns, to: Self.connectionsURL)
        }
        connectionsController.onConnect = { [weak self] connection in self?.connectToRemote(connection) }
    }

    /// Prompt for a password and open the server in the active pane.
    private func connectToRemote(_ connection: RemoteConnection) {
        guard let pane = activePane, let window = view.window else { return }
        let who = connection.user.isEmpty ? "anonymous" : connection.user
        let alert = NSAlert()
        alert.messageText = "Connect to \(connection.host)"
        alert.informativeText = "Enter the password for \(who)@\(connection.host)."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var target = pane
            if self.prefs.openConnectionsInNewTab, let side = self.activeSide {
                side.newTab(duplicatingCurrent: true)  // the new tab becomes active
                target = self.activePane ?? pane
            }
            target.openRemote(connection, password: field.stringValue)
        }
    }

    // MARK: - Remote file transfer

    /// Download the selected remote files (in the active remote pane) to a folder.
    private func downloadSelectedRemote() {
        guard let pane = activePane, let ctx = pane.remoteContext, let window = view.window else {
            NSSound.beep()
            return
        }
        let entries = pane.selectedEntries.filter { !$0.isDirectory }  // folder download is a later step
        guard !entries.isEmpty else {
            NSSound.beep()
            return
        }
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.prompt = "Download Here"
        openPanel.message = "Choose where to save \(entries.count) item(s) from \(ctx.connection.host)"
        openPanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let dir = openPanel.url, let self else { return }
            let provider = RemoteProviders.make(for: ctx.connection.proto)
            let items = entries.map { entry -> TransferController.Item in
                let remotePath = PaneController.joinRemote(ctx.path, entry.name)
                let local = self.uniqueLocalURL(dir.appendingPathComponent(entry.name))
                return TransferController.Item(name: entry.name) {
                    try await provider.download(
                        ctx.connection, remotePath: remotePath, to: local, password: ctx.password)
                }
            }
            self.transferController.run(
                items, title: "Downloading from \(ctx.connection.host)", over: window
            ) { [weak self] failures, cancelled in
                self?.reportTransfer(failures, cancelled: cancelled, verb: "download")
            }
        }
    }

    /// Upload local files dropped onto a remote pane to its current folder.
    private func uploadFiles(
        _ urls: [URL], to connection: RemoteConnection, remotePath: String, password: String,
        pane: PaneController
    ) {
        guard let window = view.window else { return }
        let files = urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
        }
        guard !files.isEmpty else {
            NSSound.beep()  // folder upload isn't supported yet
            return
        }
        let provider = RemoteProviders.make(for: connection.proto)
        let items = files.map { url -> TransferController.Item in
            let dest = PaneController.joinRemote(remotePath, url.lastPathComponent)
            return TransferController.Item(name: url.lastPathComponent) {
                try await provider.upload(url, to: connection, remotePath: dest, password: password)
            }
        }
        transferController.run(
            items, title: "Uploading to \(connection.host)", over: window
        ) { [weak self, weak pane] failures, cancelled in
            pane?.refreshRemote()  // show the newly uploaded files
            self?.reportTransfer(failures, cancelled: cancelled, verb: "upload")
        }
    }

    /// Double-clicking a remote file: download it to a temp file and open it.
    private func openRemoteFile(
        _ connection: RemoteConnection, remotePath: String, password: String, name: String
    ) {
        guard let window = view.window else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Pathem-Remote", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = uniqueLocalURL(dir.appendingPathComponent(name))
        let provider = RemoteProviders.make(for: connection.proto)
        let item = TransferController.Item(name: name) {
            try await provider.download(connection, remotePath: remotePath, to: local, password: password)
        }
        transferController.run([item], title: "Opening \(name)", over: window) { [weak self] failures, cancelled in
            guard !cancelled else { return }
            if failures.isEmpty {
                NSWorkspace.shared.open(local)
            } else {
                self?.reportTransfer(failures, cancelled: false, verb: "download")
            }
        }
    }

    /// Avoid clobbering a local file: append " 2", " 3", … if the name is taken.
    private func uniqueLocalURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private func reportTransfer(_ failures: [(String, Error)], cancelled: Bool, verb: String) {
        guard !failures.isEmpty, let window = view.window else { return }  // success/cancel is silent
        let alert = NSAlert()
        alert.messageText = failures.count == 1 ? "A \(verb) failed" : "\(failures.count) \(verb)s failed"
        alert.informativeText = failures.prefix(8)
            .map { "\($0.0): \(Self.describeRemote($0.1))" }
            .joined(separator: "\n")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private static func describeRemote(_ error: Error) -> String {
        guard let error = error as? RemoteError else { return error.localizedDescription }
        switch error {
        case .unsupported(let message): return message
        case .curl(let code, let message): return message.isEmpty ? "curl error \(code)" : message
        case .curlMissing: return "curl was not found"
        case .sftp(let code, let message): return message.isEmpty ? "sftp error \(code)" : message
        case .sftpMissing: return "sftp was not found"
        }
    }

    // MARK: - Scoped openers

    private static var openersURL: URL? {
        appSupportDirectory()?.appendingPathComponent("openers.json")
    }

    private func loadOpenerRules() {
        if let saved = loadConfig(OpenerRules.self, from: Self.openersURL) { openerRules = saved }
    }

    /// Open a file with its resolved app: session override (by type) first, then
    /// the persisted file/folder/type rules, else the system default.
    private func applyOpen(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        // Precedence: a specific file/folder rule, then a session-by-type override,
        // then a persisted type rule, else the system default.
        let appPath =
            openerRules.appByFileOrFolder(path: url.path) ?? sessionOpenersByType[ext]
            ?? openerRules.app(forType: ext)
        if let appPath {
            NSWorkspace.shared.open(
                [url], withApplicationAt: URL(fileURLWithPath: appPath),
                configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Scope for "Always Open With".
    private enum OpenerScope: Int { case file, folder, type, session }

    /// Set a default opener for the active selection. Shown from Open With.
    @objc func setDefaultOpener(_ sender: Any?) {
        if blockedByRemote() { return }
        guard let pane = activePane, let entry = pane.selectedEntries.first, !entry.isDirectory else {
            NSSound.beep()
            return
        }
        let fileURL = pane.currentURL.appendingPathComponent(entry.name)
        let ext = fileURL.pathExtension.lowercased()

        let alert = NSAlert()
        alert.messageText = "Always Open With"
        alert.informativeText = "Choose an application and how widely to apply it."

        // App picker: candidate apps + Choose…
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        let appPopup = NSPopUpButton(frame: NSRect(x: 0, y: 34, width: 320, height: 26))
        for app in apps {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: nil, keyEquivalent: "")
            item.representedObject = app
            appPopup.menu?.addItem(item)
        }
        if !apps.isEmpty { appPopup.menu?.addItem(.separator()) }
        appPopup.addItem(withTitle: "Choose…")

        let scopePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        scopePopup.addItem(withTitle: "This file")
        scopePopup.addItem(withTitle: "Files in this folder")
        scopePopup.addItem(withTitle: ext.isEmpty ? "Files of this kind" : "All .\(ext) files")
        scopePopup.addItem(withTitle: "Just this session")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        accessory.addSubview(appPopup)
        accessory.addSubview(scopePopup)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.resolveChosenApp(appPopup, candidates: apps, over: window) { appURL in
                guard let appURL else { return }
                let scope = OpenerScope(rawValue: scopePopup.indexOfSelectedItem) ?? .file
                self.saveOpener(appPath: appURL.path, for: fileURL, ext: ext, scope: scope)
            }
        }
    }

    /// Resolve the app chosen in the popup; "Choose…" opens an app picker.
    private func resolveChosenApp(
        _ popup: NSPopUpButton, candidates: [URL], over window: NSWindow,
        completion: @escaping (URL?) -> Void
    ) {
        if let app = popup.selectedItem?.representedObject as? URL {
            completion(app)
            return
        }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    private func saveOpener(appPath: String, for fileURL: URL, ext: String, scope: OpenerScope) {
        switch scope {
        case .file: openerRules.setFile(fileURL.path, app: appPath)
        case .folder: openerRules.setFolder(fileURL.deletingLastPathComponent().path, app: appPath)
        case .type: openerRules.setType(ext, app: appPath)
        case .session: sessionOpenersByType[ext] = appPath
        }
        if scope != .session { saveConfig(openerRules, to: Self.openersURL) }
    }

    /// Apply a built-in terminal theme by name (from the View > Terminal Theme menu).
    @objc func selectTerminalTheme(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
            let preset = TerminalTheme.presets.first(where: { $0.name == name })
        else { return }
        terminal.theme = preset
        saveConfig(preset, to: Self.terminalThemeURL)
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
            leftPath: leftTabs.activePane?.currentURL.path ?? "",
            rightPath: rightTabs.activePane?.currentURL.path ?? "",
            dividerFraction: dividerFraction())
    }

    private func dividerFraction() -> Double {
        let total = split.bounds.width
        guard total > 0 else { return 0.5 }
        return Double(leftTabs.containerView.frame.width / total)
    }

    private func applyLayout(_ layout: Layout) {
        // Skip paths that no longer resolve to a folder (hand-edited, shared from
        // another machine, or since deleted) so a pane is never dropped onto the
        // process working directory or a missing path.
        if let url = Self.existingFolderURL(layout.leftPath) { leftTabs.activePane?.navigate(to: url) }
        if let url = Self.existingFolderURL(layout.rightPath) { rightTabs.activePane?.navigate(to: url) }
        let total = split.bounds.width
        if total > 0 { split.setPosition(total * CGFloat(layout.dividerFraction), ofDividerAt: 0) }
    }

    private static func existingFolderURL(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialSplitPositions()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyInitialSplitPositions()
        view.window?.makeFirstResponder(leftTabs.activePane?.keyView)
        updateWindowTitle()
        maybePromptFullDiskAccess()
    }

    /// Place the sidebar and pane dividers once, when a real width exists.
    /// Crucially this sets the sidebar to a fixed width and lets the panes take
    /// the rest; without it the sidebar's auto-layout could swallow the whole
    /// window (the "all I see is the sidebar" bug). Runs from whichever of
    /// viewDidLayout / viewDidAppear first has a laid-out width.
    private func applyInitialSplitPositions() {
        guard !didSetInitialSplit, outerSplit.bounds.width > 200 else { return }
        outerSplit.setPosition(200, ofDividerAt: 0)  // sidebar width
        outerSplit.layoutSubtreeIfNeeded()  // give the panes area its real width
        split.setPosition(split.bounds.width / 2, ofDividerAt: 0)  // even panes
        didSetInitialSplit = true
        // Restore the terminal drawer if it was open last session.
        if UserDefaults.standard.bool(forKey: "pathem.terminalVisible") { toggleTerminal() }
    }

    /// Show the guided Full Disk Access walkthrough when we don't have access and
    /// the user hasn't dismissed it. It auto-detects the grant and updates live;
    /// the home folder works without it, so this never blocks use.
    private func maybePromptFullDiskAccess() {
        guard !FullDiskAccess.isGranted() else { return }
        guard !UserDefaults.standard.bool(forKey: "pathem.fdaGuideDismissed") else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.view.window else { return }
            self.fdaGuide.present(over: window) {
                // Remember a skip only when access still isn't granted, so we stop
                // nagging but reappear nothing once it's actually on.
                if !FullDiskAccess.isGranted() {
                    UserDefaults.standard.set(true, forKey: "pathem.fdaGuideDismissed")
                }
            }
        }
    }

    /// Mark a pane (in some side) as the active one: move the accent border to it
    /// and remember which side it belongs to (so transfers target the other side).
    private func setActiveSide(_ side: TabbedPaneController, pane: PaneController) {
        if activePane !== pane { activePane?.setActive(false) }
        activePane = pane
        activeSide = side
        pane.setActive(true)
        updateWindowTitle()
        // Note: the search field is cleared on navigation (onDidNavigate), not on
        // every focus change, so a mid-typed query or visible results survive a
        // pane re-focus.
        if pane.currentURL != cachedDir { preIndex(pane.currentURL) }
        saveSessionSoon()
    }

    /// Copy (or move) the active pane's selection into the other pane's folder.
    /// If names already exist there, ask how to resolve (replace, keep both, or
    /// skip), then register an undo for whatever was performed (DESIGN.md §6.5).
    /// Copy or move files dropped onto a pane into its folder, reusing the same
    /// off-main progress + undo path as the transfer commands.
    private func dropFiles(_ allURLs: [URL], move: Bool, into destination: URL) {
        guard !transferInFlight else { NSSound.beep(); return }
        // Never copy/move a folder into itself or one of its own descendants.
        // Resolve symlinks and compare case-insensitively so a different spelling
        // of the same folder is still caught (the engine has a final backstop).
        let destPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let urls = allURLs.filter {
            let src = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return destPath.compare(src, options: .caseInsensitive) != .orderedSame
                && !destPath.lowercased().hasPrefix(src.lowercased() + "/")
        }
        guard !urls.isEmpty else { NSSound.beep(); return }
        let fm = FileManager.default
        let conflicts = urls.filter {
            fm.fileExists(atPath: destination.appendingPathComponent($0.lastPathComponent).path)
        }
        var resolution = FileOperations.ConflictResolution.skip
        if !conflicts.isEmpty {
            guard let chosen = askConflictResolution(conflictCount: conflicts.count, move: move) else { return }
            resolution = chosen
        }
        runTransfer(urls: urls, into: destination, move: move, resolution: resolution) { [weak self] outcome in
            guard let self else { return }
            self.leftTabs.activePane?.reloadIfShowingListing()
            self.rightTabs.activePane?.reloadIfShowingListing()
            if !outcome.performed.isEmpty {
                self.registerUndo(outcome.performed, actionName: move ? "Move" : "Copy")
            }
            if !outcome.failures.isEmpty {
                self.presentFailures(outcome.failures, title: "\(move ? "Move" : "Copy") failed")
            }
        }
    }

    private func transfer(move: Bool) {
        if blockedByRemote() { return }
        guard !transferInFlight else { NSSound.beep(); return }  // don't prompt for a refused op
        guard let source = activePane, let activeSide else { return }
        let otherSide = (activeSide === leftTabs) ? rightTabs : leftTabs
        guard let destination = otherSide.activePane else { NSSound.beep(); return }
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

        let urls = names.map { sourceURL.appendingPathComponent($0) }
        runTransfer(urls: urls, into: destinationURL, move: move, resolution: resolution) {
            [weak self] outcome in
            guard let self else { return }
            if move { source.reloadIfShowingListing() }
            destination.reloadIfShowingListing()
            if !outcome.performed.isEmpty {
                self.registerUndo(outcome.performed, actionName: move ? "Move" : "Copy")
            }
            if !outcome.failures.isEmpty {
                self.presentFailures(outcome.failures, title: "\(move ? "Move" : "Copy") failed")
            }
        }
    }

    /// Run a copy/move off the main thread with a deferred progress sheet (so the
    /// window never freezes and quick ops never flash a sheet), then hand the
    /// outcome back on the main actor. One transfer at a time.
    private func runTransfer(
        urls: [URL], into destination: URL, move: Bool,
        resolution: FileOperations.ConflictResolution,
        completion: @escaping (FileOperations.Outcome) -> Void
    ) {
        guard !transferInFlight else { NSSound.beep(); return }
        transferInFlight = true
        let total = urls.count
        let verb = move ? "Moving" : "Copying"
        let state = TransferState(total: total)

        // Main-actor monitor: wait 0.25s before showing the sheet (so quick ops
        // never flash it), then poll progress until cancelled by the worker.
        let monitor = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.transferProgress.begin(verb: verb, total: total, over: self.view.window) { state.cancel() }
            while !Task.isCancelled {
                self.transferProgress.update(completed: state.completed)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> FileOperations.Outcome in
                if move {
                    return FileOperations.move(
                        urls: urls, into: destination, onConflict: resolution,
                        shouldCancel: { state.isCancelled }, progress: { state.setCompleted($0) })
                }
                return FileOperations.copy(
                    urls: urls, into: destination, onConflict: resolution,
                    shouldCancel: { state.isCancelled }, progress: { state.setCompleted($0) })
            }.value
            monitor.cancel()
            self?.transferProgress.end()
            self?.transferInFlight = false
            completion(outcome)
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
            target.reloadBothSides()
            if !result.failures.isEmpty { target.presentFailures(result.failures, title: "Undo failed") }
            target.registerTransferRedo(performed, actionName: actionName)  // wire up redo
        }
        undoManager.setActionName(actionName)
    }

    private func registerTransferRedo(_ performed: [FileOperations.Performed], actionName: String) {
        guard let undoManager = view.window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            let result = FileOperations.redo(performed)
            target.reloadBothSides()
            if !result.failures.isEmpty { target.presentFailures(result.failures, title: "Redo failed") }
            target.registerUndo(performed, actionName: actionName)  // back to undo
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
        if blockedByRemote() { return }
        guard !transferInFlight else { NSSound.beep(); return }  // don't prompt for a refused op
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

        runTransfer(urls: urls, into: destination, move: isMove, resolution: resolution) {
            [weak self] outcome in
            guard let self else { return }
            self.leftTabs.activePane?.reloadIfShowingListing()
            self.rightTabs.activePane?.reloadIfShowingListing()
            if !outcome.performed.isEmpty {
                self.registerUndo(outcome.performed, actionName: isMove ? "Move" : "Copy")
            }
            if isMove { pasteboard.clearContents() }  // cut items are gone; don't move them twice
            if !outcome.failures.isEmpty { self.presentFailures(outcome.failures, title: "Paste failed") }
        }
    }

    private func writeSelectionToPasteboard(cut: Bool) {
        if blockedByRemote() { return }
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
        guard !pane.isRemote else { NSSound.beep(); return }  // search indexes the local folder only
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
            // Only adopt results if the very pane we searched is still active and
            // on that folder (not merely some pane that shares the path).
            if activePane === pane, pane.currentURL == directory { pane.showResults(ranked) }
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
        let ocr = prefs.searchOCR
        let built = await Task.detached {
            SemanticSearcher.index(dirEntries, in: directory, maxItems: maxItems, ocrImages: ocr)
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
        if pane === activePane {
            preIndex(url)
            updateWindowTitle()
            // The terminal follows the active folder only when the user opted in
            // and the drawer is open (changeDirectory itself ignores TUIs).
            if terminalFollows, !terminal.view.isHidden { terminal.changeDirectory(to: url) }
        }
        saveSessionSoon()
    }

    /// The window title: folder name by default (like Finder), full POSIX path
    /// when the preference is on, or the server location for a remote pane. Also
    /// sets representedURL so the title gets a proxy icon and path popup.
    private func updateWindowTitle() {
        guard let window = view.window else { return }
        guard let pane = activePane else {
            window.title = "Pathem"
            window.representedURL = nil
            return
        }
        if let ctx = pane.remoteContext {
            window.representedURL = nil
            window.title = "\(ctx.connection.host)\(ctx.path)"
            return
        }
        let url = pane.currentURL
        window.representedURL = url
        let name = url.lastPathComponent
        window.title = prefs.showFullPathInTitle ? url.path : (name.isEmpty ? url.path : name)
    }

    // MARK: - Terminal

    /// Show or hide the embedded terminal drawer. On first show it starts a login
    /// shell in the active folder and gives the drawer a reasonable height.
    func toggleTerminal() {
        let show = terminal.view.isHidden
        terminal.view.isHidden = !show
        UserDefaults.standard.set(show, forKey: "pathem.terminalVisible")
        guard show else { return }
        terminal.ensureStarted(in: activePane?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser)
        sizeTerminalDrawer()
        terminal.focus()
    }

    /// Give the terminal drawer a fixed height and the browser the rest. When the
    /// split has no real height yet (e.g. restoring on launch before layout), the
    /// terminal's holding priority would otherwise collapse the browser, so retry
    /// on the next runloop once the window has laid out.
    private func sizeTerminalDrawer() {
        let height = vSplit.bounds.height
        if height > 280 {
            vSplit.setPosition(height - 240, ofDividerAt: 0)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.terminal.view.isHidden else { return }
                let h = self.vSplit.bounds.height
                if h > 280 { self.vSplit.setPosition(h - 240, ofDividerAt: 0) }
            }
        }
    }

    /// Reveal the terminal (if hidden) and point it at the active folder. If it
    /// was already running we send a `cd`; if it had to start, it already launched
    /// in the active folder, so we skip the redundant (and racy) `cd`.
    func openTerminalHere() {
        let wasRunning = terminal.isRunning
        if terminal.view.isHidden { toggleTerminal() }
        if wasRunning, let url = activePane?.currentURL { terminal.changeDirectory(to: url) }
        terminal.focus()
    }

    /// Toggle whether the terminal follows the active folder, and persist it.
    func toggleTerminalFollows() {
        terminalFollows.toggle()
        UserDefaults.standard.set(terminalFollows, forKey: "pathem.terminalFollows")
        if terminalFollows, !terminal.view.isHidden, let url = activePane?.currentURL {
            terminal.changeDirectory(to: url)
        }
    }

    var terminalFollowsFolder: Bool { terminalFollows }

    /// Hang up the embedded shell. Called on quit so no orphan shell survives.
    func terminateTerminal() { terminal.shutdown() }

    /// Structural UI smoke check (run via PATHEM_SMOKE=1). Asserts the window and
    /// panes laid out sanely: exactly the class of regression that the engine
    /// tests can't see (the window-sliver and dual-pane-collapse bugs). Returns
    /// a pass/fail plus human-readable lines.
    /// Idempotent geometry invariants, polled by the smoke harness until the
    /// window has actually laid out (layout can lag a beat right after launch or
    /// under load, so a single fixed delay is flaky).
    func layoutSettled() -> Bool {
        let size = view.window?.frame.size ?? .zero
        return size.width >= 700 && size.height >= 400
            && leftTabs.containerView.frame.width > 50
            && rightTabs.containerView.frame.width > 50
            && (100...360).contains(sidebar.containerView.frame.width)
    }

    func smokeReport() -> (ok: Bool, lines: [String]) {
        var lines: [String] = []
        var ok = true
        func check(_ name: String, _ pass: Bool, _ detail: String) {
            if !pass { ok = false }
            lines.append("\(pass ? "ok  " : "FAIL") \(name) (\(detail))")
        }
        let size = view.window?.frame.size ?? .zero
        check("window-size", size.width >= 700 && size.height >= 400, "\(Int(size.width))x\(Int(size.height))")
        let sidebarW = sidebar.containerView.frame.width
        check("sidebar-width", (100...360).contains(sidebarW), "\(Int(sidebarW))")
        check("left-pane-visible", leftTabs.containerView.frame.width > 50, "\(Int(leftTabs.containerView.frame.width))")
        check("right-pane-visible", rightTabs.containerView.frame.width > 50, "\(Int(rightTabs.containerView.frame.width))")
        check("left-pane-has-rows", leftTabs.activePane?.entries.isEmpty == false, "\(leftTabs.activePane?.entries.count ?? -1) entries")
        lines.append("info left-folder (\(leftTabs.activePane?.currentURL.path ?? "?"))")
        // Open the terminal only if needed (a prior run may have persisted it
        // open), check, then undo exactly what we changed so the run leaves no
        // state behind (pref, visibility, or a spawned shell).
        let wasVisible = !terminal.view.isHidden
        let wasRunning = terminal.isRunning
        let savedVisible = UserDefaults.standard.bool(forKey: "pathem.terminalVisible")
        if terminal.view.isHidden { toggleTerminal() }
        check("terminal-opens", !terminal.view.isHidden && terminal.isRunning,
            "visible=\(!terminal.view.isHidden) running=\(terminal.isRunning)")
        if !wasVisible, !terminal.view.isHidden { toggleTerminal() }  // we opened it; hide again
        if !wasRunning, terminal.isRunning { terminal.shutdown() }  // we started the shell; stop it
        UserDefaults.standard.set(savedVisible, forKey: "pathem.terminalVisible")
        // Icon view hosts the same entries (checked in isolation so the smoke run
        // doesn't persist a view-mode rule for the home folder).
        let iconView = IconCollectionController(gallery: false)
        iconView.setEntries(leftTabs.activePane?.entries ?? [], preserveState: false)
        check("icon-view-renders", iconView.entries.count > 0, "\(iconView.entries.count) entries")
        return (ok, lines)
    }
}
