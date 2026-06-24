import AppKit
import NetFS
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
    private let shelf = ShelfController()  // stash shelf / drop stack across the bottom
    private var shelfHiddenConstraint: NSLayoutConstraint?
    private var shelfShownConstraint: NSLayoutConstraint?
    private let previewView = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
    private var previewVisible = false
    private lazy var sizeBrowser = SizeBrowserController()
    private lazy var cleanup = CleanupController()
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
    private static let cutPasteboardType = NSPasteboard.PasteboardType("com.scarcrux.pathem.cut")
    private static let searchItemID = NSToolbarItem.Identifier("com.scarcrux.pathem.search")
    private static let cleanupItemID = NSToolbarItem.Identifier("com.scarcrux.pathem.cleanup")

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
    private lazy var settings = SettingsWindowController()
    /// The shared Sparkle updater (set by the app), surfaced in Settings > Updates.
    var updater: UpdaterController?
    /// User preferences (density, font, alternating rows, search OCR).
    private var prefs = Preferences.default
    /// Progress sheet for copy/move; one transfer at a time.
    private lazy var transferProgress = TransferProgress()
    private var transferInFlight = false
    /// Whether a copy/move is running (so the app can warn before quitting).
    var isTransferring: Bool { transferInFlight }
    /// File paths currently marked for cut (dimmed until pasted or cleared).
    private var cutPaths: Set<String> = []
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var compactSidebar = false
    private static let compactSidebarWidth: CGFloat = 56
    /// Guided Full Disk Access walkthrough (first launch, until granted).
    private lazy var fdaGuide = FullDiskAccessGuide()
    private lazy var infoInspector = InfoInspectorController()
    private lazy var connectionsController = ConnectionsController()
    private lazy var transferController = TransferController()
    private let sharedDiscovery = SharedDiscovery()
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
        sidebarWidthConstraint = sidebarWidth

        searchField.placeholderString = L("bvc.searchPlaceholder", "Search")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(runSearch)
        searchField.sendsSearchStringImmediately = false
        searchField.toolTip = L("bvc.searchTip", "Semantic search in this folder (on-device)")
        // The search field lives in the window's unified toolbar (Finder-style),
        // not its own strip; pin a width for when it's in the toolbar item.
        searchField.widthAnchor.constraint(equalToConstant: 240).isActive = true

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
        host.addSubview(vSplit)
        host.addSubview(shelf.view)  // the stash shelf docks across the bottom
        shelf.view.isHidden = true
        NSLayoutConstraint.activate([
            vSplit.topAnchor.constraint(equalTo: host.topAnchor),
            vSplit.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            vSplit.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            shelf.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            shelf.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            shelf.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        // The browser fills the window; when the shelf shows, it gives up the bottom.
        shelfHiddenConstraint = vSplit.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        shelfShownConstraint = vSplit.bottomAnchor.constraint(equalTo: shelf.view.topAnchor)
        shelfHiddenConstraint?.isActive = true
        view = host
        configureShelf()
    }

    // Constrain the sidebar width (outer split) and the terminal drawer height
    // (vertical split) so neither the sidebar, the panes, nor the terminal can be
    // dragged away to nothing.
    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        // Compact mode lets the sidebar shrink to an icons-only width.
        if splitView === outerSplit, dividerIndex == 0 { return compactSidebar ? 48 : 140 }
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
        Self.cleanupRemoteTemp()
        registerCommands()
        loadSavedSearches()  // register before macros so a macro can run a search
        loadCollections()
        loadMacros()  // after base commands, so macros can chain them
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
                pane.runCommand = { [weak self] id in self?.commands.perform(id) }
                pane.setPathBar(atBottom: self?.prefs.pathBarAtBottom ?? false)
                pane.onUploadFiles = { [weak self, weak pane] urls, connection, remotePath, password in
                    guard let self, let pane else { return }
                    self.uploadFiles(urls, to: connection, remotePath: remotePath, password: password, pane: pane)
                }
                pane.onOpenRemoteFile = { [weak self] connection, remotePath, password, name in
                    self?.openRemoteFile(connection, remotePath: remotePath, password: password, name: name)
                }
                pane.onSelectionChanged = { [weak self] in self?.updatePreview() }
            }
            side.onPaneBecameActive = { [weak self, weak side] pane in
                guard let self, let side else { return }
                self.setActiveSide(side, pane: pane)
            }
            side.onPaneDirectoryDidChange = { [weak self] pane, url in self?.directoryChanged(pane, url) }
            side.onPaneDidNavigate = { [weak self] pane in
                pane.searchQuery = ""  // navigating clears that pane's query
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
        sidebar.onSelectSmart = { [weak self] query in self?.openSmart(query) }
        sidebar.onSelectShared = { [weak self] host in self?.connectToShared(host) }
        sidebar.onSelectConnection = { [weak self] connection in self?.connectToRemote(connection) }
        sidebar.onConnectConnectionInNewTab = { [weak self] connection in
            self?.connectToRemote(connection, forceNewTab: true)
        }
        sidebar.onEditConnection = { [weak self] connection in
            guard let self else { return }
            self.connectionsController.present(over: self.view.window)
            self.connectionsController.beginEdit(connection)
        }
        sidebar.onForgetConnection = { connection in
            KeychainStore.removePassword(for: connection.id)  // recover from a stale/wrong saved password
        }
        sidebar.onRemoveConnection = { [weak self] connection in
            KeychainStore.removePassword(for: connection.id)  // don't orphan a saved password
            self?.connectionsController.remove(connection)
        }
        sidebar.onManageConnections = { [weak self] in
            self?.connectionsController.present(over: self?.view.window)
        }
        sidebar.onOpenSettings = { [weak self] in self?.showPreferences() }
        sidebar.onModelChange = { [weak self] model in self?.saveSidebar(model) }
        sidebar.currentFolder = { [weak self] in self?.activePane?.currentURL }
        sharedDiscovery.onChange = { [weak self] hosts in self?.sidebar.setSharedHosts(hosts) }
        sharedDiscovery.start()
        applyPreferences()
    }

    /// Register every browser action as a named command. This is the spine the
    /// keymap, command palette, and AI bar will all bind to (DESIGN.md 10).
    private static var macrosURL: URL? { appSupportDirectory()?.appendingPathComponent("macros.json") }
    private static var savedSearchesURL: URL? { appSupportDirectory()?.appendingPathComponent("searches.json") }
    private static var collectionsConfigURL: URL? {
        appSupportDirectory()?.appendingPathComponent("collections.json")
    }
    private var collectionsStore = Collections()
    /// Macros currently executing, to break a self/mutually-referential macro cycle.
    private var runningMacroIDs: Set<String> = []

    /// Load collections and register each as a "Collection: <name>" command that
    /// shows its (still-existing) files as a cross-folder smart list.
    private func loadCollections() {
        collectionsStore = loadConfig(Collections.self, from: Self.collectionsConfigURL) ?? Collections()
        for name in collectionsStore.names { registerCollectionCommand(name) }
    }

    private func registerCollectionCommand(_ name: String) {
        commands.register(
            .init(
                id: "collection.\(name)", title: String(format: L("bvc.collectionCmdTitle", "Collection: %@"), name), isEnabled: { true },
                run: { [weak self] in self?.showCollection(name) }))
    }

    private func showCollection(_ name: String) {
        guard let pane = activePane, !pane.isRemote,
            let paths = collectionsStore.collection(named: name)?.paths
        else { NSSound.beep(); return }
        let token = pane.beginContentRequest()
        pane.showSmartResults([], title: String(format: L("bvc.collectionLoading", "Collection: %@…"), name))
        Task { @MainActor in
            let entries = await Task.detached { () -> [FileEntry] in
                paths.filter { FileManager.default.fileExists(atPath: $0) }
                    .map { FileEntry(contentsOf: URL(fileURLWithPath: $0)) }
            }.value
            guard self.activePane === pane, pane.isContentRequestCurrent(token) else { return }
            pane.showSmartResults(entries, title: String(format: L("bvc.collectionCount", "Collection: %@ (%d)"), name, entries.count))
        }
    }

    /// Add the selection to a collection (prompting for / creating the name).
    private func addToCollection() {
        guard let urls = activePane?.selectedLocalURLs(), !urls.isEmpty else { NSSound.beep(); return }
        guard let name = promptForName(title: L("bvc.addToCollectionPrompt", "Add to Collection"), default: L("bvc.collectionDefaultName", "Collection")) else { return }
        let isNew = collectionsStore.collection(named: name) == nil
        collectionsStore.add(urls.map(\.path), to: name)
        saveConfig(collectionsStore, to: Self.collectionsConfigURL)
        if isNew { registerCollectionCommand(name) }
    }

    /// Register each saved search (searches.json) as a command that runs its mdfind
    /// query and shows the results as a cross-folder smart list.
    private func loadSavedSearches() {
        let set = loadConfig(SavedSearches.self, from: Self.savedSearchesURL) ?? SavedSearches.default
        for search in set.searches where !search.name.isEmpty {
            let query = search.mdfindQuery()
            guard !query.isEmpty else { continue }
            let name = search.name
            commands.register(
                .init(
                    id: "search.\(name)", title: String(format: L("bvc.searchCmdTitle", "Search: %@"), name), isEnabled: { true },
                    run: { [weak self] in self?.runSavedSearch(name, query: query) }))
        }
    }

    private func runSavedSearch(_ name: String, query: String) {
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        let token = pane.beginContentRequest()
        pane.showSmartResults([], title: String(format: L("bvc.searchingLoading", "Searching: %@…"), name))
        Task { @MainActor in
            let urls = await SpotlightSearch.matching(query, scope: nil, limit: 1000)
            let entries = await Task.detached { urls.map { FileEntry(contentsOf: $0) } }.value
            guard self.activePane === pane, pane.isContentRequestCurrent(token) else { return }
            pane.showSmartResults(entries, title: String(format: L("bvc.searchCount", "Search: %@ (%d)"), name, entries.count))
        }
    }

    /// Register each user macro (macros.json) as a command that runs its command IDs
    /// in order; it then appears in the palette and is bindable like any command.
    private func loadMacros() {
        let set = loadConfig(Macros.self, from: Self.macrosURL) ?? Macros.default
        for macro in set.macros where !macro.name.isEmpty && !macro.commands.isEmpty {
            let ids = macro.commands
            let macroID = "macro.\(macro.name)"
            commands.register(
                .init(
                    id: macroID, title: String(format: L("bvc.macroCmdTitle", "Macro: %@"), macro.name), isEnabled: { true },
                    run: { [weak self] in
                        guard let self, !self.runningMacroIDs.contains(macroID) else { return }  // cycle guard
                        self.runningMacroIDs.insert(macroID)
                        defer { self.runningMacroIDs.remove(macroID) }
                        for id in ids { _ = self.commands.perform(id) }
                    }))
        }
    }

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
        add("files.copyToOtherPane", L("bvc.cmd.copyToOtherPane", "Copy to Other Pane"), enabled: hasSelection) {
            [weak self] in self?.transfer(move: false)
        }
        add("files.moveToOtherPane", L("bvc.cmd.moveToOtherPane", "Move to Other Pane"), enabled: hasSelection) {
            [weak self] in self?.transfer(move: true)
        }
        add("files.copy", L("bvc.cmd.copy", "Copy"), enabled: hasSelection) {
            [weak self] in self?.writeSelectionToPasteboard(cut: false)
        }
        add("files.cut", L("bvc.cmd.cut", "Cut"), enabled: hasSelection) {
            [weak self] in self?.writeSelectionToPasteboard(cut: true)
        }
        add("view.asList", L("bvc.cmd.asList", "as List")) { [weak self] in self?.activePane?.setViewMode(.list) }
        add("view.asIcons", L("bvc.cmd.asIcons", "as Icons")) { [weak self] in self?.activePane?.setViewMode(.icon) }
        add("view.asGallery", L("bvc.cmd.asGallery", "as Gallery")) { [weak self] in self?.activePane?.setViewMode(.gallery) }
        add("view.asColumn", L("bvc.cmd.asColumns", "as Columns")) { [weak self] in self?.activePane?.setViewMode(.column) }
        add("terminal.toggle", L("bvc.cmd.toggleTerminal", "Toggle Terminal")) { [weak self] in self?.toggleTerminal() }
        add("terminal.here", L("bvc.cmd.openTerminalHere", "Open Terminal Here")) { [weak self] in self?.openTerminalHere() }
        add("terminal.toggleFollow", L("bvc.cmd.terminalFollowsFolder", "Terminal Follows Folder")) {
            [weak self] in self?.toggleTerminalFollows()
        }
        add("files.paste", L("bvc.cmd.paste", "Paste")) { [weak self] in self?.paste(nil) }
        add("files.open", L("bvc.cmd.open", "Open"), enabled: hasSelection) { [weak self] in self?.activePane?.openSelection() }
        add("files.batchRename", L("bvc.cmd.batchRename", "Batch Rename…"), enabled: hasSelection) { [weak self] in self?.showBatchRename() }
        add("files.newFolder", L("bvc.cmd.newFolder", "New Folder")) { [weak self] in self?.newFolder() }
        add("files.newFile", L("bvc.cmd.newFile", "New File")) { [weak self] in self?.newFile() }
        add("files.rename", L("bvc.cmd.rename", "Rename…"), enabled: { [weak self] in self?.activePane?.selectedEntries.count == 1 }) {
            [weak self] in self?.renameSelection()
        }
        add("files.trash", L("bvc.cmd.moveToTrash", "Move to Trash"), enabled: hasSelection) { [weak self] in self?.trashSelection() }
        add("files.airdrop", L("bvc.cmd.sendViaAirDrop", "Send via AirDrop"), enabled: hasSelection) {
            [weak self] in self?.activePane?.airDropSelection()
        }
        add("files.copyPath", L("bvc.cmd.copyPath", "Copy Path"), enabled: hasSelection) { [weak self] in self?.copyPaths(asURL: false) }
        add("files.copyURL", L("bvc.cmd.copyAsFileURL", "Copy as File URL"), enabled: hasSelection) {
            [weak self] in self?.copyPaths(asURL: true)
        }
        add("files.copyName", L("bvc.cmd.copyName", "Copy Name"), enabled: hasSelection) { [weak self] in self?.copyNames() }
        add("files.addToCollection", L("bvc.cmd.addToCollection", "Add to Collection…"), enabled: hasSelection) {
            [weak self] in self?.addToCollection()
        }
        add("files.organizeAI", L("bvc.cmd.organizeWithAI", "Organize with AI…"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.organizeWithAI()
        }
        add("files.copySHA256", L("bvc.cmd.copySHA256", "Copy SHA-256"), enabled: hasSelection) { [weak self] in self?.copyChecksums() }
        add("files.verifyChecksum", L("bvc.cmd.verifyChecksum", "Verify Checksum…"), enabled: hasSelection) {
            [weak self] in self?.verifyChecksum()
        }
        add("files.reveal", L("bvc.cmd.revealInFinder", "Reveal in Finder"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.revealSelection()
        }
        add("files.getInfo", L("bvc.cmd.getInfo", "Get Info"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.showInfo()
        }
        add(
            "files.download", L("bvc.cmd.download", "Download"),
            enabled: { [weak self] in self?.activePane?.selectedEntries.contains(where: \.isDataless) ?? false }
        ) { [weak self] in self?.downloadSelection() }
        add("view.preferences", L("bvc.cmd.preferences", "Preferences…")) { [weak self] in self?.showPreferences() }
        add("view.fullPathTitle", L("bvc.cmd.showFullPathInTitleBar", "Show Full Path in Title Bar")) { [weak self] in self?.toggleFullPathTitle() }
        add("view.pathBarBottom", L("bvc.cmd.showPathBarAtBottom", "Show Path Bar at Bottom")) { [weak self] in self?.togglePathBarPosition() }
        add("search.toggleOCR", L("bvc.cmd.toggleImageOCRInSearch", "Toggle Image OCR in Search")) { [weak self] in self?.toggleOCR() }
        add("view.toggleHidden", L("bvc.cmd.showHiddenFiles", "Show Hidden Files"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.activePane?.toggleHidden()
        }
        add("view.applyToSubfolders", L("bvc.cmd.applyViewToSubfolders", "Apply View to Subfolders"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.applyViewToSubfolders()
        }
        add("view.useAsDefault", L("bvc.cmd.useAsDefaultView", "Use as Default View"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.useCurrentViewAsDefault()
        }
        add("view.calculateSizes", L("bvc.cmd.calculateAllSizes", "Calculate All Sizes")) { [weak self] in self?.toggleCalculateSizes() }
        add("view.compactSidebar", L("bvc.cmd.compactSidebar", "Compact Sidebar")) { [weak self] in self?.toggleCompactSidebar() }
        add("layout.save", L("bvc.cmd.saveLayout", "Save Layout…")) { [weak self] in self?.saveLayoutPrompt() }
        add("palette.show", L("bvc.cmd.commandPalette", "Command Palette…")) { [weak self] in self?.showPalette() }
        add("ai.run", L("bvc.cmd.askPathem", "Ask Pathem (Natural Language)…")) { [weak self] in self?.showAICommandBar() }
        add("view.quickLook", L("bvc.cmd.quickLook", "Quick Look"), enabled: hasSelection) { [weak self] in self?.toggleQuickLook() }
        add("tab.new", L("bvc.cmd.newTab", "New Tab")) { [weak self] in self?.activeSide?.newTab(duplicatingCurrent: true) }
        add("tab.close", L("bvc.cmd.closeTab", "Close Tab"), enabled: { [weak self] in (self?.activeSide?.tabCount ?? 0) > 1 }) {
            [weak self] in self?.activeSide?.closeActiveTab()
        }
        add("tab.next", L("bvc.cmd.nextTab", "Next Tab"), enabled: { [weak self] in (self?.activeSide?.tabCount ?? 0) > 1 }) {
            [weak self] in self?.activeSide?.selectNextTab()
        }
        add("tab.previous", L("bvc.cmd.previousTab", "Previous Tab"), enabled: { [weak self] in (self?.activeSide?.tabCount ?? 0) > 1 }) {
            [weak self] in self?.activeSide?.selectPreviousTab()
        }
        add("nav.back", L("bvc.cmd.back", "Back"), enabled: { [weak self] in self?.activePane?.canGoBack ?? false }) {
            [weak self] in self?.activePane?.goBack()
        }
        add("nav.forward", L("bvc.cmd.forward", "Forward"), enabled: { [weak self] in self?.activePane?.canGoForward ?? false }) {
            [weak self] in self?.activePane?.goForward()
        }
        add("nav.up", L("bvc.cmd.enclosingFolder", "Enclosing Folder"), enabled: { [weak self] in self?.activePane?.canGoUp ?? false }) {
            [weak self] in self?.activePane?.goUp()
        }
        add("nav.editPath", L("bvc.cmd.goToPath", "Go to Path…")) { [weak self] in self?.activePane?.beginEditingPath() }
        add("view.flatView", L("bvc.cmd.flatView", "Flat View"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.activePane?.showFlatView()
        }
        add("view.filter", L("bvc.cmd.filter", "Filter…"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.activePane?.beginFilter()
        }
        add("view.previewPane", L("bvc.cmd.previewPane", "Preview Pane"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.togglePreviewPane()
        }
        add("files.findDuplicates", L("bvc.cmd.findDuplicates", "Find Duplicates"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.findDuplicates()
        }
        add("view.sizeBrowser", L("bvc.cmd.sizeBrowser", "Size Browser…"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in
            guard let self, let url = self.activePane?.currentURL else { return }
            self.sizeBrowser.present(for: url, over: self.view.window)
        }
        add("view.cleanup", L("bvc.cmd.cleanup", "Cleanup…"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in
            guard let self, let url = self.activePane?.currentURL else { return }
            self.cleanup.present(for: url, over: self.view.window)
        }
        add("files.comparePanes", L("bvc.cmd.comparePanes", "Compare Panes…"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.comparePanes()
        }
        add("files.compress", L("bvc.cmd.compress", "Compress"), enabled: hasSelection) { [weak self] in self?.compressSelection() }
        add(
            "files.extract", L("bvc.cmd.extract", "Extract"),
            enabled: { [weak self] in
                (self?.activePane?.selectedLocalURLs() ?? []).contains { Archiver.canExtract($0) }
            }
        ) { [weak self] in self?.extractSelection() }
        add("shelf.add", L("bvc.cmd.addToShelf", "Add to Shelf"), enabled: { [weak self] in !(self?.activePane?.selectedEntries.isEmpty ?? true) })
        { [weak self] in self?.addSelectionToShelf() }
        add("shelf.toggle", L("bvc.cmd.showShelf", "Show Shelf")) { [weak self] in self?.toggleShelf() }
        add("connections.manage", L("bvc.cmd.connections", "Connections…")) {
            [weak self] in self?.connectionsController.present(over: self?.view.window)
        }
        add("connections.newTabToggle", L("bvc.cmd.openConnectionsInNewTab", "Open Connections in a New Tab")) {
            [weak self] in self?.toggleConnectionsNewTab()
        }
        for color in FileTag.Color.displayOrder {
            add("tags.toggle.\(color.rawValue)", String(format: L("bvc.cmd.tagColor", "Tag %@"), color.label), enabled: hasSelection) {
                [weak self] in self?.activePane?.tagSelection(toggle: color)
            }
        }
        add("tags.clear", L("bvc.cmd.clearTags", "Clear Tags"), enabled: hasSelection) {
            [weak self] in self?.activePane?.clearSelectionTags()
        }
        add(
            "remote.download", L("bvc.cmd.downloadFromServer", "Download from Server…"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, pane.isRemote else { return false }
                return pane.selectedEntries.contains { !$0.isDirectory }
            }
        ) { [weak self] in self?.downloadSelectedRemote() }
        add("edit.undo", L("bvc.cmd.undo", "Undo"), enabled: { [weak self] in self?.view.window?.undoManager?.canUndo ?? false }) {
            [weak self] in self?.undo(nil)
        }
        add("edit.redo", L("bvc.cmd.redo", "Redo"), enabled: { [weak self] in self?.view.window?.undoManager?.canRedo ?? false }) {
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
        if blockedByRemoteOrSmart() { return }  // operates within one folder
        guard let window = view.window, let pane = activePane else { return }
        let names = pane.selectedEntries.map(\.name)
        guard !names.isEmpty else { NSSound.beep(); return }
        let existing = Set(pane.entries.map(\.name))
        batchRename.present(names: names, in: pane.currentURL, existing: existing, over: window) {
            [weak self] in self?.activePane?.reloadIfShowingListing()
        }
    }

    // MARK: - New folder / Trash / Reveal

    /// Remote panes have no local file URLs, so file ops can't act there. Per-file
    /// ops (trash, rename, reveal, info, …) ARE allowed in cross-folder smart views
    /// because they resolve each item by its own folder (selectedLocalURLs). Returns
    /// true (and beeps) if blocked.
    private func blockedByRemote() -> Bool {
        if activePane?.isRemote == true {
            NSSound.beep()
            return true
        }
        return false
    }

    /// Ops that need one destination folder (paste, new folder) can't run in a
    /// remote pane or a cross-folder smart-result view (there's no single "here").
    private func blockedByRemoteOrSmart() -> Bool {
        if activePane?.isRemote == true || activePane?.isShowingSmartResults == true {
            NSSound.beep()
            return true
        }
        return false
    }

    /// Run a remote file operation off-main, refreshing the pane and reporting errors.
    private func performRemoteOp(
        _ pane: PaneController, verb: String,
        _ op: @escaping @Sendable (RemoteProvider, RemoteConnection, String, String) async throws -> Void
    ) {
        guard let ctx = pane.remoteContext else { return }
        let provider = RemoteProviders.make(for: ctx.connection.proto)
        Task { @MainActor [weak self] in
            do {
                try await op(provider, ctx.connection, ctx.path, ctx.password)
                pane.refreshRemote()
            } catch {
                self?.presentFailures(
                    [FileOperations.Failure(name: verb, reason: "\(error)")],
                    title: String(format: L("bvc.remoteOpFailed", "%@ failed"), verb))
            }
        }
    }

    /// A modal single-line name prompt; nil if cancelled or empty.
    private func promptForName(title: String, default value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: L("common.ok", "OK"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func newFolder() {
        guard let pane = activePane else { return }
        if pane.isShowingSmartResults { NSSound.beep(); return }  // no single destination
        if pane.isRemote {
            guard let name = promptForName(title: L("bvc.newFolderPrompt", "New Folder"), default: L("bvc.untitledFolder", "untitled folder")) else { return }
            performRemoteOp(pane, verb: L("bvc.newFolderVerb", "New Folder")) { provider, connection, path, password in
                try await provider.makeDirectory(
                    connection, path: PaneController.joinRemote(path, name), password: password)
            }
            return
        }
        do {
            let name = try FileOperations.makeFolder(in: pane.currentURL)
            pane.reloadIfShowingListing()
            pane.select(name: name)
            registerNewItemUndo(name: name, in: pane.currentURL, actionName: L("bvc.newFolderVerb", "New Folder"))
        } catch {
            presentFailures(
                [FileOperations.Failure(name: L("bvc.newFolderVerb", "New Folder"), reason: error.localizedDescription)],
                title: L("bvc.couldntCreateFolder", "Couldn’t create folder"))
        }
    }

    /// Create a new empty file (local panes only); the Finder pain point this app fixes.
    private func newFile() {
        guard let pane = activePane else { return }
        if pane.isShowingSmartResults || pane.isRemote { NSSound.beep(); return }
        do {
            let name = try FileOperations.makeFile(in: pane.currentURL)
            pane.reloadIfShowingListing()
            pane.select(name: name)
            registerNewItemUndo(name: name, in: pane.currentURL, actionName: L("bvc.cmd.newFile", "New File"))
        } catch {
            presentFailures(
                [FileOperations.Failure(name: L("bvc.cmd.newFile", "New File"), reason: error.localizedDescription)],
                title: L("bvc.couldntCreateFile", "Couldn’t create file"))
        }
    }

    private func registerNewItemUndo(name: String, in directory: URL, actionName: String) {
        guard let undoManager = view.window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            let result = FileOperations.trash([name], in: directory)  // undo = trash the new item
            target.reloadBothSides()
            if !result.failures.isEmpty { target.presentFailures(result.failures, title: L("bvc.undoFailed", "Undo failed")) }
            if !result.trashed.isEmpty {
                target.registerNewItemRedo(name: name, in: directory, trashed: result.trashed, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func registerNewItemRedo(
        name: String, in directory: URL, trashed: [FileOperations.Trashed], actionName: String
    ) {
        guard let undoManager = view.window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            let failures = FileOperations.untrash(trashed)  // redo = restore the item
            target.reloadBothSides()
            target.paneShowing(directory)?.select(name: name)
            if !failures.isEmpty { target.presentFailures(failures, title: L("bvc.redoFailed", "Redo failed")) }
            target.registerNewItemUndo(name: name, in: directory, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func renameSelection() {
        guard let pane = activePane, pane.selectedEntries.count == 1,
            let entry = pane.selectedEntries.first
        else { return }
        let alert = NSAlert()
        alert.messageText = String(format: L("bvc.renameTitle", "Rename “%@”"), entry.name)
        alert.addButton(withTitle: L("bvc.renameButton", "Rename"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = entry.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != entry.name else { return }
        if pane.isRemote {
            guard entry.rawName == nil else {
                presentInfo(
                    L("bvc.cantRenameTitle", "Can’t rename this item"),
                    L("bvc.cantRenameBody", "Its name isn’t valid UTF-8, which remote operations don’t support yet."))
                return
            }
            performRemoteOp(pane, verb: L("bvc.renameVerb", "Rename")) { provider, connection, path, password in
                try await provider.rename(
                    connection, from: PaneController.joinRemote(path, entry.name),
                    to: PaneController.joinRemote(path, newName), password: password)
            }
            return
        }
        // The file's real folder: its own location in a smart view, else current.
        let directory = entry.location.map { URL(fileURLWithPath: $0) } ?? pane.currentURL
        do {
            try FileOperations.rename(entry.name, to: newName, in: directory)
            registerRenameUndo(from: newName, to: entry.name, in: directory)
            pane.reloadIfShowingListing()
            pane.select(name: newName)
        } catch {
            presentFailures(
                [FileOperations.Failure(name: entry.name, reason: error.localizedDescription)],
                title: L("bvc.renameFailed", "Rename failed"))
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
                    title: L("bvc.undoFailed", "Undo failed"))
            }
        }
        undoManager.setActionName(L("bvc.renameVerb", "Rename"))
    }

    private func trashSelection() {
        guard let pane = activePane else { return }
        if pane.isRemote {
            let entries = pane.selectedEntries
            guard !entries.isEmpty else { NSSound.beep(); return }
            // A non-UTF-8 name only round-trips by its raw bytes; acting on the lossy
            // String could hit the wrong file, so refuse it for now.
            guard entries.allSatisfy({ $0.rawName == nil }) else {
                presentInfo(
                    L("bvc.cantDeleteTitle", "Can’t delete this item"),
                    L("bvc.cantDeleteBody", "Its name isn’t valid UTF-8, which remote operations don’t support yet."))
                return
            }
            // Remote delete is permanent (no Trash, no undo) — confirm explicitly.
            let host = pane.remoteContext?.connection.host ?? L("bvc.theServer", "the server")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText =
                "Permanently delete \(entries.count) item\(entries.count == 1 ? "" : "s") on \(host)?"
            alert.informativeText = L("bvc.cantBeUndone", "This can’t be undone.")
            alert.addButton(withTitle: L("common.delete", "Delete"))
            alert.addButton(withTitle: L("common.cancel", "Cancel"))
            guard let window = view.window else { return }
            let names = entries.map { ($0.name, $0.isDirectory) }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                self.performRemoteOp(pane, verb: L("bvc.deleteVerb", "Delete")) { provider, connection, path, password in
                    for (name, isDir) in names {
                        try await provider.remove(
                            connection, path: PaneController.joinRemote(path, name), isDirectory: isDir,
                            password: password)
                    }
                }
            }
            return
        }
        let urls = pane.selectedLocalURLs()  // location-aware: trashes the real files in smart views
        guard !urls.isEmpty else { NSSound.beep(); return }
        let result = FileOperations.trash(urls: urls)
        reloadBothSides()  // the trashed files may have lived in either visible folder
        pruneSmartEntries(Set(result.trashed.map(\.original.path)))  // drop stale rows in smart views
        if !result.trashed.isEmpty { registerTrashUndo(result.trashed) }
        if !result.failures.isEmpty { presentFailures(result.failures, title: L("bvc.moveToTrashFailed", "Move to Trash failed")) }
    }

    private func registerTrashUndo(_ trashed: [FileOperations.Trashed]) {
        guard let undoManager = view.window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            let failures = FileOperations.untrash(trashed)
            target.reloadBothSides()
            if !failures.isEmpty { target.presentFailures(failures, title: L("bvc.undoFailed", "Undo failed")) }
            target.registerTrashRedo(trashed)  // redo = move them back to the Trash
        }
        undoManager.setActionName(L("bvc.moveToTrashAction", "Move to Trash"))
    }

    private func registerTrashRedo(_ trashed: [FileOperations.Trashed]) {
        guard let undoManager = view.window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            // Trash by original URL so cross-folder selections redo correctly.
            let result = FileOperations.trash(urls: trashed.map(\.original))
            target.reloadBothSides()
            if !result.failures.isEmpty { target.presentFailures(result.failures, title: L("bvc.redoFailed", "Redo failed")) }
            if !result.trashed.isEmpty { target.registerTrashUndo(result.trashed) }
        }
        undoManager.setActionName(L("bvc.moveToTrashAction", "Move to Trash"))
    }

    /// Refresh the active pane on each side (used by undo/redo handlers).
    private func reloadBothSides() {
        leftTabs.activePane?.reloadIfShowingListing()
        rightTabs.activePane?.reloadIfShowingListing()
    }

    /// Copy the selection's paths (POSIX or file://) to the clipboard, one per line.
    private func copyPaths(asURL: Bool) {
        guard let urls = activePane?.selectedLocalURLs(), !urls.isEmpty else { NSSound.beep(); return }
        let lines = urls.map { asURL ? $0.absoluteString : $0.path }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines, forType: .string)
    }

    /// Hash the selected file(s) off the main thread and copy the digests (one per
    /// line; "hash  name" when multiple).
    private func copyChecksums(_ algorithm: FileHasher.Algorithm = .sha256) {
        let files = (activePane?.selectedLocalURLs() ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }
        guard !files.isEmpty else { NSSound.beep(); return }
        Task { @MainActor in
            let lines = await Task.detached { () -> [String] in
                files.compactMap { url in
                    guard let hash = try? FileHasher.hash(url, algorithm: algorithm) else { return nil }
                    return files.count == 1 ? hash : "\(hash)  \(url.lastPathComponent)"
                }
            }.value
            guard !lines.isEmpty else { NSSound.beep(); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }
    }

    /// Hash the one selected file and compare it to a checksum on the clipboard
    /// (algorithm inferred from the clipboard digest's length).
    private func verifyChecksum() {
        guard let url = (activePane?.selectedLocalURLs() ?? []).first,
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        else { NSSound.beep(); return }
        let expected = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).first?.lowercased() ?? ""
        // Only the lengths we can actually compute (MD5/SHA-1/SHA-256); accepting a
        // SHA-512-length digest and silently comparing it as SHA-256 would never match.
        let algorithm: FileHasher.Algorithm
        switch expected.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil ? expected.count : -1 {
        case 32: algorithm = .md5
        case 40: algorithm = .sha1
        case 64: algorithm = .sha256
        default:
            presentChecksumResult(
                title: L("bvc.unsupportedChecksum", "Unsupported checksum"),
                text: L("bvc.unsupportedChecksumBody", "Copy a hex MD5, SHA-1, or SHA-256 to the clipboard first."))
            return
        }
        Task { @MainActor in
            let actual = await Task.detached { try? FileHasher.hash(url, algorithm: algorithm) }.value
            guard let actual else {
                presentChecksumResult(title: L("bvc.couldntReadFile", "Couldn’t read the file"), text: url.lastPathComponent)
                return
            }
            let match = actual == expected
            presentChecksumResult(
                title: match
                    ? String(format: L("bvc.checksumMatches", "%@ matches ✓"), algorithm.label)
                    : String(format: L("bvc.checksumNoMatch", "%@ does NOT match"), algorithm.label),
                text: "\(url.lastPathComponent)\n\n"
                    + String(format: L("bvc.checksumExpectedActual", "Expected: %@\nActual:   %@"), expected, actual))
        }
    }

    private func presentChecksumResult(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: L("common.ok", "OK"))
        if let window = view.window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
    }

    /// Zip the selection into the current folder (off-main), then select the archive.
    private func compressSelection() {
        // Smart/flat/duplicate views span multiple folders; Archiver assumes one
        // shared parent, so restrict Compress to a single real folder.
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let folder = pane.currentURL
        let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let dest = uniqueLocalURL(folder.appendingPathComponent("\(base).zip"))
        Task { @MainActor [weak self] in
            do {
                try await Archiver.compress(urls, to: dest)
                self?.reloadBothSides()
                self?.activePane?.select(name: dest.lastPathComponent)
            } catch {
                self?.reportArchiveError(L("bvc.couldntCreateArchive", "Couldn’t create the archive"), error)
            }
        }
    }

    /// Extract each selected archive into its own folder in the current directory.
    private func extractSelection() {
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        let archives = pane.selectedLocalURLs().filter { Archiver.canExtract($0) }
        guard !archives.isEmpty else { NSSound.beep(); return }
        let folder = pane.currentURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failed = false
            for archive in archives {
                let name = (archive.lastPathComponent as NSString).deletingPathExtension
                let out = self.uniqueLocalURL(folder.appendingPathComponent(name))
                do { try await Archiver.extract(archive, to: out) } catch { failed = true }
            }
            self.reloadBothSides()
            if failed { self.reportArchiveError(L("bvc.couldntExtract", "Couldn’t extract one or more archives"), nil) }
        }
    }

    private func reportArchiveError(_ title: String, _ error: Error?) {
        let alert = NSAlert()
        alert.messageText = title
        if let error { alert.informativeText = "\(error)" }
        alert.addButton(withTitle: L("common.ok", "OK"))
        if let window = view.window { alert.beginSheetModal(for: window) { _ in } } else { NSSound.beep() }
    }

    /// Compare the two panes' folders and offer a one-way mirror (preview-then-apply).
    private func comparePanes() {
        guard let left = leftTabs.activePane, let right = rightTabs.activePane,
            !left.isRemote, !right.isRemote
        else { NSSound.beep(); return }
        let leftURL = left.currentURL
        let rightURL = right.currentURL
        guard leftURL != rightURL else { NSSound.beep(); return }
        Task { @MainActor [weak self] in
            let diffs = await Task.detached { FolderCompare.compare(left: leftURL, right: rightURL) }.value
            self?.presentCompare(diffs, leftURL: leftURL, rightURL: rightURL)
        }
    }

    private func presentCompare(_ diffs: [FolderCompare.Difference], leftURL: URL, rightURL: URL) {
        let s = FolderCompare.summary(diffs)
        let alert = NSAlert()
        alert.messageText = String(
            format: L("bvc.compareTitle", "Compare: %@ ↔ %@"),
            leftURL.lastPathComponent, rightURL.lastPathComponent)
        alert.informativeText = String(
            format: L("bvc.compareSummary", "Only on left: %d\nOnly on right: %d\nDiffer: %d\nIdentical: %d"),
            s.onlyLeft, s.onlyRight, s.differs, s.identical)
        let deleteExtras = NSButton(checkboxWithTitle: L("bvc.alsoDeleteMissing", "Also delete files missing from the source"), target: nil, action: nil)
        alert.accessoryView = deleteExtras
        alert.addButton(withTitle: L("bvc.mirrorLeftToRight", "Mirror Left → Right"))
        alert.addButton(withTitle: L("bvc.mirrorRightToLeft", "Mirror Right → Left"))
        alert.addButton(withTitle: L("common.close", "Close"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            let delete = deleteExtras.state == .on
            switch response {
            case .alertFirstButtonReturn: self?.runMirror(source: leftURL, target: rightURL, deleteExtras: delete)
            case .alertSecondButtonReturn: self?.runMirror(source: rightURL, target: leftURL, deleteExtras: delete)
            default: break
            }
        }
    }

    /// Mirror `source` onto `target` (recompute the diff fresh, then apply off-main).
    private func runMirror(source: URL, target: URL, deleteExtras: Bool) {
        Task { @MainActor [weak self] in
            let result = await Task.detached { () -> FolderCompare.MirrorResult in
                let diffs = FolderCompare.compare(left: source, right: target)
                return FolderCompare.mirror(from: source, to: target, differences: diffs, deleteExtras: deleteExtras)
            }.value
            guard let self else { return }
            self.reloadBothSides()
            let alert = NSAlert()
            alert.messageText = L("bvc.mirrorComplete", "Mirror complete")
            alert.informativeText =
                String(format: L("bvc.mirrorCopiedDeleted", "Copied %d, deleted %d"), result.copied, result.deleted)
                + (result.failures.isEmpty ? "" : String(format: L("bvc.mirrorFailedSuffix", ", %d failed"), result.failures.count))
            alert.addButton(withTitle: L("common.ok", "OK"))
            if let window = self.view.window { alert.beginSheetModal(for: window) { _ in } }
        }
    }

    /// Scan the active folder's subtree for content duplicates (off-main) and show
    /// them as one cross-folder list (per-group adjacency), so the extras can be
    /// selected and trashed.
    private func findDuplicates() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let root = pane.currentURL
        let token = pane.beginContentRequest()  // so navigating away discards stale results
        pane.showSmartResults([], title: String(format: L("bvc.findingDuplicates", "Finding duplicates in %@…"), root.lastPathComponent))
        Task { @MainActor [weak self] in
            let groups = await Task.detached { DuplicateFinder.find(in: [root]) }.value
            guard let self, self.activePane === pane, pane.isContentRequestCurrent(token) else { return }
            let files = groups.flatMap { $0.files }
            let title =
                groups.isEmpty
                ? String(format: L("bvc.noDuplicates", "No duplicates in %@"), root.lastPathComponent)
                : "Duplicates: \(groups.count) group\(groups.count == 1 ? "" : "s"), \(files.count) files"
            pane.showSmartResults(files, title: title)
        }
    }

    /// Show/hide the QuickLook preview pane docked at the right of the window.
    private func togglePreviewPane() {
        previewVisible.toggle()
        if previewVisible {
            previewView.translatesAutoresizingMaskIntoConstraints = true
            outerSplit.addArrangedSubview(previewView)  // [sidebar | panes | preview]
            outerSplit.setHoldingPriority(NSLayoutConstraint.Priority(255), forSubviewAt: 2)
            if previewView.frame.width < 100 {
                outerSplit.setPosition(outerSplit.bounds.width - 300, ofDividerAt: outerSplit.arrangedSubviews.count - 2)
            }
            updatePreview()
        } else {
            previewView.previewItem = nil
            outerSplit.removeArrangedSubview(previewView)
            previewView.removeFromSuperview()
        }
    }

    /// Point the preview at the active pane's single selected file (when visible).
    private func updatePreview() {
        guard previewVisible else { return }
        previewView.previewItem = activePane?.singleSelectedURL as NSURL?
    }

    // MARK: - Organize with AI (typed plan; the model proposes, our code executes)

    private func organizeWithAI() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        // Check the model up front (before prompting) so we explain instead of failing.
        if let reason = AIAvailability.unavailableReason() {
            AIAvailability.presentUnavailable(
                L("ai.organize.unavail", "Organize with AI is unavailable"), reason: reason,
                over: view.window)
            return
        }
        let folder = pane.currentURL
        let files = pane.selectedEntries.isEmpty ? pane.entries.map(\.name) : pane.selectedEntries.map(\.name)
        guard !files.isEmpty else { NSSound.beep(); return }
        guard let instruction = promptForName(
            title: L("ai.organize.title", "Organize with AI"), default: "group by file type")
        else { return }

        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                Task { @MainActor in
                    guard let plan = await proposeOrganizePlan(instruction: instruction, files: files),
                        !plan.steps.isEmpty
                    else {
                        self.presentInfo(
                            L("ai.organize.noPlan.title", "Couldn’t propose a plan"),
                            L("ai.organize.noPlan.body", "The model returned no steps."))
                        return
                    }
                    self.confirmAndRun(plan, in: folder)
                }
            }
        #endif
    }

    /// Preview the plan, then execute it on confirmation (off-main) and report.
    private func confirmAndRun(_ plan: OrganizePlan, in folder: URL) {
        let lines = plan.summary(in: folder)
        let alert = NSAlert()
        alert.messageText = String(format: L("bvc.organizeQ", "Organize %@?"), folder.lastPathComponent)
        alert.informativeText = lines.prefix(20).joined(separator: "\n") + (lines.count > 20 ? "\n…" : "")
        alert.addButton(withTitle: L("common.apply", "Apply"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                let result = await Task.detached { plan.execute(in: folder) }.value
                self.reloadBothSides()
                // Register undo like every other local file op (moves + trashes).
                if !result.performed.isEmpty { self.registerUndo(result.performed, actionName: L("bvc.organizeAction", "Organize")) }
                if !result.trashedItems.isEmpty { self.registerTrashUndo(result.trashedItems) }
                self.presentInfo(
                    L("bvc.organized", "Organized"),
                    String(format: L("bvc.organizedSummary", "Moved %d, trashed %d, labeled %d"), result.moved, result.trashed, result.labeled)
                        + (result.failures.isEmpty ? "" : String(format: L("bvc.organizedSkippedSuffix", ", %d skipped"), result.failures.count)))
            }
        }
    }

    private func presentInfo(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: L("common.ok", "OK"))
        if let window = view.window { alert.beginSheetModal(for: window) { _ in } }
    }

    /// Apply (toggle) the named label carried by a "Label" menu item to the selection.
    @objc func applyLabelFromMenu(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? FileLabel else { NSSound.beep(); return }
        activePane?.applyLabel(label)
    }

    /// The folder to open in an external editor: a single selected folder, else the
    /// active pane's current folder.
    private func editorTarget() -> URL? {
        if let urls = activePane?.selectedLocalURLs(), urls.count == 1,
            (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        {
            return urls[0]
        }
        return activePane?.currentURL
    }

    /// Open the target folder in the editor whose application URL is the menu item's
    /// represented object (set when the dynamic "Open in…" menu is built).
    @objc func openInExternalEditor(_ sender: NSMenuItem) {
        guard let editor = sender.representedObject as? URL, let target = editorTarget() else {
            NSSound.beep()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.promptsUserIfNeeded = true
        NSWorkspace.shared.open([target], withApplicationAt: editor, configuration: config) { _, error in
            if error != nil { DispatchQueue.main.async { NSSound.beep() } }
        }
    }

    /// Copy the selection's file names to the clipboard, one per line.
    private func copyNames() {
        guard let urls = activePane?.selectedLocalURLs(), !urls.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            urls.map { $0.lastPathComponent }.joined(separator: "\n"), forType: .string)
    }

    /// Prune the given paths from every pane's smart-result list (after a file op
    /// removed/moved them), so smart views don't keep stale rows.
    private func pruneSmartEntries(_ paths: Set<String>) {
        for side in [leftTabs, rightTabs] {
            for pane in side.tabs { pane.pruneSmartEntries(paths: paths) }
        }
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
        let urls = pane.selectedLocalURLs()  // location-aware (reveals the real file in smart views)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [pane.currentURL] : urls)
    }

    /// Get Info on the selection, or on the current folder when nothing is selected.
    private func showInfo() {
        if blockedByRemote() { return }
        guard let pane = activePane else { return }
        let selected = pane.selectedLocalURLs()  // location-aware
        let urls = selected.isEmpty ? [pane.currentURL] : selected
        infoInspector.present(urls: urls, over: view.window)
    }

    /// Pull down online-only (dataless) cloud files. The provider materializes
    /// them; the watcher refreshes the badge as they land.
    private func downloadSelection() {
        if blockedByRemote() { return }
        guard let pane = activePane else { return }
        for entry in pane.selectedEntries where entry.isDataless {
            let url = entry.location.map { URL(fileURLWithPath: $0).appendingPathComponent(entry.name) }
                ?? pane.currentURL.appendingPathComponent(entry.name)  // location-aware
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
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
        case "view.asColumn": menuItem.state = activePane?.viewMode == .column ? .on : .off
        case "view.fullPathTitle": menuItem.state = prefs.showFullPathInTitle ? .on : .off
        case "view.pathBarBottom": menuItem.state = prefs.pathBarAtBottom ? .on : .off
        case "view.calculateSizes": menuItem.state = prefs.calculateFolderSizes ? .on : .off
        case "view.compactSidebar": menuItem.state = prefs.compactSidebar ? .on : .off
        case "view.previewPane": menuItem.state = previewVisible ? .on : .off
        case "shelf.toggle":
            menuItem.state = shelf.view.isHidden ? .off : .on
            menuItem.title = shelf.view.isHidden ? L("bvc.showShelf", "Show Shelf") : L("bvc.hideShelf", "Hide Shelf")
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
        settings.present(
            prefs: prefs,
            commands: commands.all.map { (id: $0.id, title: $0.title) },
            effective: keymap.bindings,
            updater: updater,
            over: window,
            onChange: { [weak self] updated in
                guard let self else { return }
                self.prefs = updated
                self.applyPreferences()
            },
            onKeymapChange: { [weak self] overlay in
                guard let self else { return }
                self.saveConfig(overlay, to: Self.keymapURL)  // persist the user overlay
                self.keymap = Keymap.standard.merging(userBindings: overlay)  // apply live
            })
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

    private func toggleCompactSidebar() {
        prefs.compactSidebar.toggle()
        applyPreferences()  // applies labels + width and persists
    }

    /// Hide/show sidebar labels and narrow/restore the sidebar per the preference.
    private func applyCompactSidebar() {
        compactSidebar = prefs.compactSidebar
        sidebar.setShowsLabels(!compactSidebar)
        let width: CGFloat = compactSidebar ? Self.compactSidebarWidth : 200
        sidebarWidthConstraint?.constant = width
        if didSetInitialSplit { outerSplit.setPosition(width, ofDividerAt: 0) }  // resize live
    }

    private func togglePathBarPosition() {
        prefs.pathBarAtBottom.toggle()
        applyPreferences()  // moves the path bar in every pane and persists
    }

    private func toggleCalculateSizes() {
        prefs.calculateFolderSizes.toggle()
        applyPreferences()  // turns folder-size computation on/off in every pane
    }

    /// Apply preferences to every tab in both sides, persist them, and rebuild the
    /// search index (OCR can change what gets embedded).
    private func applyPreferences() {
        for side in [leftTabs, rightTabs] {
            for pane in side.tabs {
                pane.applyStyle(
                    rowHeight: prefs.rowHeight, fontSize: prefs.fontSize,
                    alternatingRows: prefs.alternatingRows)
                pane.setPathBar(atBottom: prefs.pathBarAtBottom)
                pane.setCalculateFolderSizes(prefs.calculateFolderSizes)
            }
        }
        applyCompactSidebar()
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
        return pane.selectedLocalURLs()  // location-aware: previews the right file in smart views too
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

    private static var keymapURL: URL? {
        appSupportDirectory()?.appendingPathComponent("keymap.json")
    }

    private func loadKeymap() {
        if let user = loadConfig([String: String].self, from: Self.keymapURL) {
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

    /// Make the active pane's current view (mode + sort) the global default for
    /// folders that don't have their own remembered format.
    private func useCurrentViewAsDefault() {
        guard let pane = activePane else { return }
        folderFormats.defaultFormat = pane.format
        saveFolderFormats()
        leftTabs.activePane?.reloadIfShowingListing()
        rightTabs.activePane?.reloadIfShowingListing()
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

        init(left: [String], leftActive: Int, right: [String], rightActive: Int, leftIsActive: Bool) {
            self.left = left
            self.leftActive = leftActive
            self.right = right
            self.rightActive = rightActive
            self.leftIsActive = leftIsActive
        }

        // Tolerant: a partial/older session.json restores what it can instead of
        // failing the whole decode (which would discard the session entirely).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            left = try c.decodeIfPresent([String].self, forKey: .left) ?? []
            leftActive = try c.decodeIfPresent(Int.self, forKey: .leftActive) ?? 0
            right = try c.decodeIfPresent([String].self, forKey: .right) ?? []
            rightActive = try c.decodeIfPresent(Int.self, forKey: .rightActive) ?? 0
            leftIsActive = try c.decodeIfPresent(Bool.self, forKey: .leftIsActive) ?? true
        }
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
        sidebar.setConnections(connectionsController.connections)
        connectionsController.onChange = { [weak self] conns in
            self?.saveConfig(conns, to: Self.connectionsURL)
            self?.sidebar.setConnections(conns)  // keep the sidebar Connections section in sync
        }
        connectionsController.onConnect = { [weak self] connection in self?.connectToRemote(connection) }
    }

    /// Prompt for a password and open the server in the active pane.
    private func connectToRemote(_ connection: RemoteConnection, forceNewTab: Bool = false) {
        guard let pane = activePane else { return }
        // A remembered password connects straight away, no prompt.
        if let saved = KeychainStore.password(for: connection.id) {
            openRemoteConnection(connection, password: saved, forceNewTab: forceNewTab, fallback: pane)
            return
        }
        guard let window = view.window else { return }
        let who = connection.user.isEmpty ? L("bvc.anonymous", "anonymous") : connection.user
        let alert = NSAlert()
        alert.messageText = String(format: L("bvc.connectTo", "Connect to %@"), connection.host)
        alert.informativeText = String(format: L("bvc.enterPasswordFor", "Enter the password for %@@%@."), who, connection.host)
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let remember = NSButton(checkboxWithTitle: L("bvc.rememberPasswordInKeychain", "Remember password in Keychain"), target: nil, action: nil)
        let accessory = NSStackView(views: [field, remember])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.frame = NSRect(x: 0, y: 0, width: 260, height: 52)
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        alert.accessoryView = accessory
        alert.addButton(withTitle: L("bvc.connect", "Connect"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if remember.state == .on {
                KeychainStore.setPassword(field.stringValue, for: connection.id)
            }
            self.openRemoteConnection(
                connection, password: field.stringValue, forceNewTab: forceNewTab, fallback: pane)
        }
    }

    private func openRemoteConnection(
        _ connection: RemoteConnection, password: String, forceNewTab: Bool, fallback: PaneController
    ) {
        var target = fallback
        if (forceNewTab || prefs.openConnectionsInNewTab), let side = activeSide {
            side.newTab(duplicatingCurrent: true)  // the new tab becomes active
            target = activePane ?? fallback
        }
        target.openRemote(connection, password: password)
    }

    // MARK: - Smart locations (Recents, tag filters)

    /// Run a Spotlight-backed smart query and show the (cross-folder) results in
    /// the active pane.
    private func openSmart(_ query: SmartQuery) {
        guard let pane = activePane else { return }
        let scope = FileManager.default.homeDirectoryForCurrentUser
        let token = pane.beginContentRequest()  // detect navigation / a newer request
        Task {
            let urls: [URL]
            let title: String
            switch query {
            case .recents:
                urls = await SpotlightSearch.recentFiles(scope: scope, days: 30, limit: 200)
                title = L("bvc.recents", "Recents")
            case .tag(let color):
                urls = await SpotlightSearch.taggedFiles(color.label, scope: scope, limit: 500)
                title = String(format: L("bvc.tagTitle", "Tag: %@"), color.label)
            }
            let entries = await Task.detached { urls.map { FileEntry(contentsOf: $0) } }.value
            guard self.activePane === pane, pane.isContentRequestCurrent(token) else { return }  // stale
            pane.showSmartResults(entries, title: title)
        }
    }

    // MARK: - Shared (SMB) computers

    /// Resolve a discovered Bonjour host and mount its SMB share, then browse it.
    private func connectToShared(_ name: String) {
        sharedDiscovery.resolveHost(named: name) { [weak self] host in
            guard let self, let host else {
                NSSound.beep()
                return
            }
            self.mountSMB(host: host)
        }
    }

    /// Mount smb://host via NetFS (the OS handles auth/Keychain and shows its own
    /// prompt when needed), then navigate the active pane to the mount point.
    private func mountSMB(host: String) {
        // The host comes from a Bonjour-resolved service on the LAN; validate it and
        // build the URL via URLComponents so a hostile name can't smuggle a path,
        // query, or alternate authority into the smb:// URL.
        guard RemoteConnection.isValidHost(host) else {
            NSSound.beep()
            return
        }
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host
        guard let url = components.url else {
            NSSound.beep()
            return
        }
        Task { [weak self] in
            let mount = await Self.mountShare(url)
            guard let self else { return }
            if let mount {
                self.activePane?.navigate(to: mount)
            } else {
                NSSound.beep()
            }
        }
    }

    /// Off-main NetFS mount. Returns the mount point, or nil on failure/cancel.
    nonisolated private static func mountShare(_ url: URL) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let openOptions = NSMutableDictionary()
                openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI  // let the OS prompt for credentials
                var mountpoints: Unmanaged<CFArray>?
                let status = NetFSMountURLSync(
                    url as CFURL, nil, nil, nil, openOptions as CFMutableDictionary, nil, &mountpoints)
                let paths = (mountpoints?.takeRetainedValue() as? [String]) ?? []
                cont.resume(returning: status == 0 ? paths.first.map { URL(fileURLWithPath: $0) } : nil)
            }
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
        openPanel.prompt = L("bvc.downloadHere", "Download Here")
        openPanel.message = String(
            format: L("bvc.chooseDownloadDest", "Choose where to save %d item(s) from %@"),
            entries.count, ctx.connection.host)
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
            guard !self.transferInFlight else { NSSound.beep(); return }  // one transfer at a time
            self.transferInFlight = true  // so Quit warns mid-transfer
            self.transferController.run(
                items, title: String(format: L("bvc.downloadingFrom", "Downloading from %@"), ctx.connection.host), over: window
            ) { [weak self] failures, cancelled in
                self?.transferInFlight = false
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
        guard !transferInFlight else { NSSound.beep(); return }  // one transfer at a time
        transferInFlight = true  // so Quit warns mid-transfer
        transferController.run(
            items, title: String(format: L("bvc.uploadingTo", "Uploading to %@"), connection.host), over: window
        ) { [weak self, weak pane] failures, cancelled in
            self?.transferInFlight = false
            pane?.refreshRemote()  // show the newly uploaded files
            self?.reportTransfer(failures, cancelled: cancelled, verb: "upload")
        }
    }

    /// Temp directory for remote files opened locally.
    private static var remoteTempDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Pathem-Remote", isDirectory: true)
    }

    /// Remove leftover opened-remote files from a previous run. Done once at launch
    /// so it never deletes a file the user is still editing this session.
    private static func cleanupRemoteTemp() {
        try? FileManager.default.removeItem(at: remoteTempDir)
    }

    /// Double-clicking a remote file: download it to a temp file and open it.
    private func openRemoteFile(
        _ connection: RemoteConnection, remotePath: String, password: String, name: String
    ) {
        guard let window = view.window else { return }
        let dir = Self.remoteTempDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = uniqueLocalURL(dir.appendingPathComponent(name))
        let provider = RemoteProviders.make(for: connection.proto)
        let item = TransferController.Item(name: name) {
            try await provider.download(connection, remotePath: remotePath, to: local, password: password)
        }
        guard !transferInFlight else { NSSound.beep(); return }  // one transfer at a time
        transferInFlight = true  // so Quit warns mid-transfer
        transferController.run([item], title: String(format: L("bvc.opening", "Opening %@"), name), over: window) { [weak self] failures, cancelled in
            self?.transferInFlight = false
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
        case .curl(let code, let message): return message.isEmpty ? String(format: L("bvc.curlError", "curl error %d"), code) : message
        case .curlMissing: return L("bvc.curlMissing", "curl was not found")
        case .sftp(let code, let message): return message.isEmpty ? String(format: L("bvc.sftpError", "sftp error %d"), code) : message
        case .sftpMissing: return L("bvc.sftpMissing", "sftp was not found")
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
        let fileURL = entry.location.map { URL(fileURLWithPath: $0).appendingPathComponent(entry.name) }
            ?? pane.currentURL.appendingPathComponent(entry.name)  // location-aware
        let ext = fileURL.pathExtension.lowercased()

        let alert = NSAlert()
        alert.messageText = L("bvc.alwaysOpenWith", "Always Open With")
        alert.informativeText = L("bvc.alwaysOpenWithBody", "Choose an application and how widely to apply it.")

        // App picker: candidate apps + Choose…
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        let appPopup = NSPopUpButton(frame: NSRect(x: 0, y: 34, width: 320, height: 26))
        for app in apps {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: nil, keyEquivalent: "")
            item.representedObject = app
            appPopup.menu?.addItem(item)
        }
        if !apps.isEmpty { appPopup.menu?.addItem(.separator()) }
        appPopup.addItem(withTitle: L("bvc.chooseEllipsis", "Choose…"))

        let scopePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        scopePopup.addItem(withTitle: L("bvc.scopeThisFile", "This file"))
        scopePopup.addItem(withTitle: L("bvc.scopeThisFolder", "Files in this folder"))
        scopePopup.addItem(withTitle: ext.isEmpty ? L("bvc.scopeThisKind", "Files of this kind") : String(format: L("bvc.scopeAllExt", "All .%@ files"), ext))
        scopePopup.addItem(withTitle: L("bvc.scopeThisSession", "Just this session"))

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        accessory.addSubview(appPopup)
        accessory.addSubview(scopePopup)
        alert.accessoryView = accessory
        alert.addButton(withTitle: L("bvc.set", "Set"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))

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
        item.title = L("bvc.layoutsMenu", "Layouts")
        item.submenu = layoutsMenu
        layoutsMenu.delegate = self
        mainMenu.addItem(item)
        didInstallLayoutsMenu = true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === layoutsMenu else { return }
        menu.removeAllItems()
        let save = menu.addItem(withTitle: L("bvc.saveLayoutMenuItem", "Save Layout…"), action: #selector(saveLayoutMenu), keyEquivalent: "")
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
        alert.messageText = L("bvc.saveLayoutTitle", "Save Layout")
        alert.informativeText = L("bvc.saveLayoutBody", "Name this arrangement of folders and panes.")
        alert.addButton(withTitle: L("common.save", "Save"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = String(format: L("bvc.layoutDefaultName", "Layout %d"), layouts.names.count + 1)
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
        installToolbarIfNeeded()
        applyInitialSplitPositions()
        // Focus the restored active pane, not always the left one.
        let focusPane = activePane ?? activeSide?.activePane ?? leftTabs.activePane
        view.window?.makeFirstResponder(focusPane?.keyView)
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
        outerSplit.setPosition(compactSidebar ? Self.compactSidebarWidth : 200, ofDividerAt: 0)  // sidebar width
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
        searchField.stringValue = pane.searchQuery  // show the focused pane's own query
        // Note: the search field is cleared on navigation (onDidNavigate), not on
        // every focus change, so a mid-typed query or visible results survive a
        // pane re-focus.
        if pane.currentURL != cachedDir { preIndex(pane.currentURL) }
        updatePreview()  // follow the newly active pane's selection
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
                self.registerUndo(outcome.performed, actionName: move ? L("bvc.moveAction", "Move") : L("bvc.copyAction", "Copy"))
            }
            if !outcome.failures.isEmpty {
                self.presentFailures(
                    outcome.failures,
                    title: move ? L("bvc.moveFailed", "Move failed") : L("bvc.copyFailed", "Copy failed"))
            }
        }
    }

    // MARK: - Stash shelf / drop stack

    private func configureShelf() {
        shelf.onChanged = { [weak self] in
            guard let self else { return }
            if !self.shelf.isEmpty, self.shelf.view.isHidden { self.setShelfVisible(true) }  // auto-show on first add
        }
        shelf.onCopyHere = { [weak self] urls in self?.shelfTransfer(urls, move: false) }
        shelf.onMoveHere = { [weak self] urls in self?.shelfTransfer(urls, move: true) }
        shelf.onTrash = { [weak self] urls in self?.shelfTrash(urls) }
        shelf.onReveal = { urls in
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        shelf.onShare = { urls, from in
            guard !urls.isEmpty else { return }
            let picker = NSSharingServicePicker(items: urls)
            picker.show(relativeTo: from.bounds, of: from, preferredEdge: .minY)
        }
        shelf.onHide = { [weak self] in self?.setShelfVisible(false) }
    }

    private func setShelfVisible(_ visible: Bool) {
        guard shelf.view.isHidden == visible else { return }
        shelf.view.isHidden = !visible
        shelfHiddenConstraint?.isActive = !visible
        shelfShownConstraint?.isActive = visible
    }

    private func toggleShelf() { setShelfVisible(shelf.view.isHidden) }

    /// Add the active pane's selection to the shelf (location-aware, so smart-result
    /// rows contribute their real paths).
    private func addSelectionToShelf() {
        guard let urls = activePane?.selectedLocalURLs(), !urls.isEmpty else { NSSound.beep(); return }
        shelf.add(urls)
    }

    /// Copy or move shelved items into the active pane's folder, reusing the same
    /// conflict-aware, undoable transfer path as F5/F6.
    private func shelfTransfer(_ urls: [URL], move: Bool) {
        guard !transferInFlight else { NSSound.beep(); return }
        guard let destination = activePane else { NSSound.beep(); return }
        let destinationURL = destination.currentURL
        // Don't act on items that are already in (or are) the destination folder.
        let sources = urls.filter { $0.deletingLastPathComponent().standardizedFileURL != destinationURL.standardizedFileURL }
        guard !sources.isEmpty else { NSSound.beep(); return }

        var resolution = FileOperations.ConflictResolution.skip
        let conflicts = FileOperations.conflicts(urls: sources, into: destinationURL)
        if !conflicts.isEmpty {
            guard let chosen = askConflictResolution(conflictCount: conflicts.count, move: move) else { return }
            resolution = chosen
        }
        runTransfer(urls: sources, into: destinationURL, move: move, resolution: resolution) {
            [weak self] outcome in
            guard let self else { return }
            self.reloadBothSides()
            if move {
                let moved = Set(outcome.performed.map(\.source.path))
                self.pruneSmartEntries(moved)
                self.shelf.itemsRemoved(outcome.performed.map(\.source))  // gone from source now
            }
            if !outcome.performed.isEmpty {
                self.registerUndo(outcome.performed, actionName: move ? L("bvc.moveAction", "Move") : L("bvc.copyAction", "Copy"))
            }
            if !outcome.failures.isEmpty {
                self.presentFailures(
                    outcome.failures,
                    title: move ? L("bvc.moveFailed", "Move failed") : L("bvc.copyFailed", "Copy failed"))
            }
        }
    }

    private func shelfTrash(_ urls: [URL]) {
        let result = FileOperations.trash(urls: urls)
        reloadBothSides()
        pruneSmartEntries(Set(result.trashed.map(\.original.path)))
        shelf.itemsRemoved(result.trashed.map(\.original))  // trashed: drop from the shelf
        if !result.trashed.isEmpty { registerTrashUndo(result.trashed) }
        if !result.failures.isEmpty { presentFailures(result.failures, title: L("bvc.moveToTrashFailed", "Move to Trash failed")) }
    }

    private func transfer(move: Bool) {
        if blockedByRemote() { return }
        guard !transferInFlight else { NSSound.beep(); return }  // don't prompt for a refused op
        guard let source = activePane, let activeSide else { return }
        let otherSide = (activeSide === leftTabs) ? rightTabs : leftTabs
        guard let destination = otherSide.activePane else { NSSound.beep(); return }
        let urls = source.selectedLocalURLs()  // location-aware: sources may span folders (smart view)
        guard !urls.isEmpty else { NSSound.beep(); return }

        let destinationURL = destination.currentURL

        var resolution = FileOperations.ConflictResolution.skip
        let conflicts = FileOperations.conflicts(urls: urls, into: destinationURL)
        if !conflicts.isEmpty {
            guard let chosen = askConflictResolution(conflictCount: conflicts.count, move: move) else {
                return  // user cancelled
            }
            resolution = chosen
        }

        runTransfer(urls: urls, into: destinationURL, move: move, resolution: resolution) {
            [weak self] outcome in
            guard let self else { return }
            if move { source.reloadIfShowingListing() }
            destination.reloadIfShowingListing()
            if move {  // sources moved away: drop their rows from any smart view
                self.pruneSmartEntries(Set(outcome.performed.map(\.source.path)))
            }
            if !outcome.performed.isEmpty {
                self.registerUndo(outcome.performed, actionName: move ? L("bvc.moveAction", "Move") : L("bvc.copyAction", "Copy"))
            }
            if !outcome.failures.isEmpty {
                self.presentFailures(
                    outcome.failures,
                    title: move ? L("bvc.moveFailed", "Move failed") : L("bvc.copyFailed", "Copy failed"))
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
        let verb = move ? L("bvc.moving", "Moving") : L("bvc.copying", "Copying")
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
        alert.informativeText = String(
            format: L("bvc.conflictHandle", "Choose how to handle the %@."),
            move ? L("bvc.moveNoun", "move") : L("bvc.copyNoun", "copy"))
        alert.addButton(withTitle: L("bvc.replace", "Replace"))
        alert.addButton(withTitle: L("bvc.keepBoth", "Keep Both"))
        alert.addButton(withTitle: L("bvc.skip", "Skip"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
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
            if !result.failures.isEmpty { target.presentFailures(result.failures, title: L("bvc.undoFailed", "Undo failed")) }
            target.registerTransferRedo(performed, actionName: actionName)  // wire up redo
        }
        undoManager.setActionName(actionName)
    }

    private func registerTransferRedo(_ performed: [FileOperations.Performed], actionName: String) {
        guard let undoManager = view.window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            let result = FileOperations.redo(performed)
            target.reloadBothSides()
            if !result.failures.isEmpty { target.presentFailures(result.failures, title: L("bvc.redoFailed", "Redo failed")) }
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
        if blockedByRemoteOrSmart() { return }  // needs a single destination folder
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
                self.registerUndo(outcome.performed, actionName: isMove ? L("bvc.moveAction", "Move") : L("bvc.copyAction", "Copy"))
            }
            if isMove {
                pasteboard.clearContents()  // cut items are gone; don't move them twice
                self.cutPaths = []
                self.applyCutPaths()  // clear the dimming
                self.pruneSmartEntries(Set(outcome.performed.map(\.source.path)))  // drop moved rows
            }
            if !outcome.failures.isEmpty { self.presentFailures(outcome.failures, title: L("bvc.pasteFailed", "Paste failed")) }
        }
    }

    private func writeSelectionToPasteboard(cut: Bool) {
        guard let pane = activePane else { return }
        // Copy/cut only writes URLs (no mutation), so it's safe in smart-result views;
        // selectedLocalURLs resolves each item to its real folder. Remote has no local URL.
        guard !pane.isRemote else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        if cut {
            pasteboard.addTypes([Self.cutPasteboardType], owner: nil)
            pasteboard.setData(Data(), forType: Self.cutPasteboardType)
        }
        cutPaths = cut ? Set(urls.map(\.path)) : []  // dim cut items; a copy clears any prior cut
        applyCutPaths()
    }

    /// Show the current cut-dimming in every pane.
    private func applyCutPaths() {
        for side in [leftTabs, rightTabs] {
            for pane in side.tabs { pane.setCutPaths(cutPaths) }
        }
    }

    private func presentFailures(_ failures: [FileOperations.Failure], title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L("bvc.failuresForItems", "%@ for %d item(s)"), title, failures.count)
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
        guard !pane.isRemote, !pane.isShowingSmartResults, pane.viewMode != .column else {
            NSSound.beep()  // search needs a single local list (not remote/smart/columns)
            return
        }
        pane.searchQuery = query  // remember per pane so the shared field resyncs on focus change
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

    /// Put the search field in the window's unified toolbar (Finder-style), so it
    /// doesn't waste a whole strip at the top of the content.
    private func installToolbarIfNeeded() {
        guard let window = view.window, window.toolbar == nil else { return }
        let toolbar = NSToolbar(identifier: "com.scarcrux.pathem.toolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbarStyle = .unified
        window.toolbar = toolbar
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

extension BrowserViewController: NSToolbarDelegate {
    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if identifier == Self.cleanupItemID {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = L("toolbar.cleanup", "Cleanup")
            item.toolTip = L("toolbar.cleanup.tip", "Find and remove reclaimable files")
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: item.label)
            item.isBordered = true
            item.target = self
            item.action = #selector(cleanupFromToolbar)
            return item
        }
        guard identifier == Self.searchItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = searchField  // the on-device semantic search field
        item.label = L("bvc.searchToolbarLabel", "Search")
        item.visibilityPriority = .high
        return item
    }

    @objc private func cleanupFromToolbar() {
        guard let url = activePane?.currentURL else { NSSound.beep(); return }
        cleanup.present(for: url, over: view.window)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.cleanupItemID, .flexibleSpace, Self.searchItemID]  // cleanup leading, search trailing
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.cleanupItemID, .flexibleSpace, Self.searchItemID]
    }
}
