import AppKit
import AppRelaunch
import NetFS
import PathemEngine
import PathemTerminal
import Quartz
import TorrentKit
import UniformTypeIdentifiers

/// The dual-pane browser: two independent panes side by side in a split view,
/// one "active" pane (accent border), and one-key copy/move between them
/// (F5 and F6, the classic dual-pane bindings). A fast, native, two-pane file
/// manager.
@MainActor
final class BrowserViewController: NSViewController, NSMenuDelegate, QLPreviewPanelDataSource,
    NSMenuItemValidation
{
    let leftTabs: TabbedPaneController
    let rightTabs: TabbedPaneController
    weak var activePane: PaneController?
    weak var activeSide: TabbedPaneController?
    /// The app's file-operation undo/redo history (replaces the window's NSUndoManager for file
    /// ops; text-field editing keeps its own). Drives Cmd-Z, the Edit menu, and a recent-actions
    /// panel with selective undo.
    let actionHistory = ActionHistory()
    /// Absolute paths a set of performed ops touched, used as an action's footprint.
    static func paths(of performed: [FileOperations.Performed]) -> Set<String> {
        Set(performed.flatMap { [$0.source.path, $0.destination.path] })
    }
    static func paths(_ names: [String], in directory: URL) -> Set<String> {
        Set(names.map { directory.appendingPathComponent($0).path })
    }
    /// The active pane's counterpart on the opposite side (for "paste in other pane", etc.).
    var otherPane: PaneController? {
        guard let activeSide else { return nil }
        return (activeSide === leftTabs ? rightTabs : leftTabs).activePane
    }
    /// The one selected folder's URL when exactly one local folder is selected (for "Open in
    /// New Tab"); nil otherwise.
    var singleSelectedFolder: URL? {
        guard let pane = activePane, !pane.isRemote else { return nil }
        let entries = pane.selectedEntries
        guard entries.count == 1, entries[0].isDirectory else { return nil }
        return pane.selectedLocalURLs().first
    }
    /// The selected local .torrent files (empty unless every selected item is a .torrent).
    var selectedTorrentURLs: [URL] {
        guard let pane = activePane, !pane.isRemote else { return [] }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty, urls.allSatisfy({ $0.pathExtension.lowercased() == "torrent" }) else {
            return []
        }
        return urls
    }

    /// The single selected local file or folder (for "Create Torrent"), or nil.
    var selectedSingleLocalURL: URL? {
        guard let pane = activePane, !pane.isRemote else { return nil }
        let urls = pane.selectedLocalURLs()
        return urls.count == 1 ? urls[0] : nil
    }

    /// The one selected image's URL when exactly one local image file is selected (for "Set
    /// Desktop Picture"); nil otherwise.
    var singleSelectedImageURL: URL? {
        guard let pane = activePane, !pane.isRemote else { return nil }
        let entries = pane.selectedEntries
        guard entries.count == 1, !entries[0].isDirectory, let url = pane.selectedLocalURLs().first
        else { return nil }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return type?.conforms(to: .image) == true ? url : nil
    }

    /// When on, navigating one pane replays the same relative move on the other, so two
    /// different roots stay in step (Directory-Opus-style synchronized browsing).
    var syncBrowsing = false
    var isSyncingPanes = false  // re-entrancy guard for the mirror navigation (used in +Navigation)
    /// Each pane's last-seen local folder, so a navigation's relative delta can be
    /// computed (see `mirrorNavigationIfSyncing`). Keyed by pane identity.
    var syncBrowseAnchors: [ObjectIdentifier: URL] = [:]
    let splitLayout = BrowserSplitLayoutController()
    var split: NSSplitView { splitLayout.split }
    var panesContainer: NSView { splitLayout.panesContainer }
    var outerSplit: NSSplitView { splitLayout.outerSplit }
    var vSplit: NSSplitView { splitLayout.vSplit }
    var mainStack: NSStackView { splitLayout.mainStack }
    let shelf = ShelfController()  // stash shelf / drop stack across the bottom
    var shelfHiddenConstraint: NSLayoutConstraint?
    var shelfShownConstraint: NSLayoutConstraint?
    let commanderBar = CommanderBar()  // orthodox F-key bar + command line (Commander mode)
    var commanderShownConstraint: NSLayoutConstraint?
    /// The docked far-right Quick Look preview pane -- view, visibility, width pin, and the
    /// auto-shown flag all live here now (god-object slice 5.6). Lazy so outerSplit and the
    /// sidebar constraint exist by first use; its selection/width closures defer back to self.
    lazy var previewPane = PreviewPaneController(
        outerSplit: outerSplit,
        selectedURL: { [weak self] in self?.activePane?.singleSelectedURL },
        sidebarWidth: { [weak self] in self?.sidebarWidthConstraint?.constant ?? 200 })
    lazy var sizeBrowser = SizeBrowserController()
    lazy var clipboardViewer = ClipboardViewerController()
    lazy var cleanup = CleanupController()
    lazy var xattrController = XattrController()
    lazy var diffViewer = DiffViewerController()
    lazy var bulkAttributes = BulkAttributesController()
    lazy var automationRules = AutomationRulesController()
    /// Optional-backed (not `lazy var`) so teardown can stop its watchers only when it was actually
    /// created -- touching a `lazy var` in teardown would force-instantiate a manager just to tear
    /// it down.
    var _automation: AutomationManager?  // internal: BVC+QuickActions.teardown() stops it
    var automation: AutomationManager {
        if let automation = _automation { return automation }
        let manager = AutomationManager(storeURL: Self.automationRulesURL)
        manager.onApplied = { [weak self] _ in self?.reloadBothSides() }
        _automation = manager
        return manager
    }
    let sidebar = SidebarController()
    let terminal = TerminalController()
    let torrentDrawer = TorrentDrawerController()  // FileZilla-style transfer drawer at the bottom
    let torrentDetail = TorrentDetailView()  // overlays the panes when a torrent is opened
    /// The toolbar's search-and-command button: looks like a search field, opens the one
    /// overlay (Cmd-F search mode, Cmd-K command mode), and shows the active pane's query.
    let searchButton = NSButton()
    var didSetInitialSplit: Bool {
        get { splitLayout.didSetInitialSplit }
        set { splitLayout.didSetInitialSplit = newValue }
    }
    /// Opt-in: when true the terminal `cd`s as the active folder changes. Off by
    /// default so navigation never disturbs whatever you're running in the shell.
    var terminalFollows = UserDefaults.standard.bool(forKey: "pathem.terminalFollows")
    /// True while restoring the saved session, so restore activity doesn't trigger
    /// a (partial) save.
    var isRestoringSession = false
    /// Persists the restore session, saved workspaces, and named view Styles.
    let windowState = WindowStateStore()

    /// Cap on items embedded per search, to bound the cost on huge folders.
    /// The scale path (background incremental indexing and a cached vector
    /// store) is in DESIGN.md section 2.
    let semanticSearch = SemanticSearchController()  // owns the per-folder index cache
    /// Marker on the pasteboard meaning "these files were cut" (paste = move).
    static let cutPasteboardType = NSPasteboard.PasteboardType("com.scarcrux.pathem.cut")
    static let searchItemID = NSToolbarItem.Identifier("com.scarcrux.pathem.search")
    /// The "…" overflow toolbar button: a pull-down menu of quick options (theme, view, settings).
    static let overflowItemID = NSToolbarItem.Identifier("com.scarcrux.pathem.overflow")
    /// Retained delegate that repopulates the overflow menu each time it opens (fresh checkmarks).
    lazy var overflowMenuDelegate = OverflowMenuDelegate(browser: self)
    /// A toolbar item that runs a registered command carries the command id in its
    /// identifier (this prefix + the id), so the button is stateless and the id
    /// round-trips through NSToolbar's autosaved customization.
    static let toolbarCmdPrefix = "com.scarcrux.pathem.cmd."

    /// The command bus (DESIGN.md section 10). Every browser action is a named
    /// command; keybindings, the palette, and the AI bar will dispatch by id.
    let commands = CommandRegistry()
    var savedSearchCommandIDs: Set<String> = []
    /// Chord -> command id, defaults overlaid with any user keymap.json.
    var keymap = Keymap.standard
    /// Super-drag: direction -> command for a flick, and the swipe-trail overlay.
    var dragGestures = DragGestureMap.standard
    let dragTrail = DragTrailOverlay()
    var dragStartScreen: NSPoint?  // to name the live flick as it changes direction
    var dragShowsHint = false  // only a row super-drag shows the flick label; an empty-space stroke doesn't
    /// Stroke -> command id, defaults overlaid with any user gestures.json.
    var gestureMap = GestureMap.standard
    /// Per-folder saved view formats (the exact/subtree cascade), shared by both panes.
    var folderFormats = FolderFormats()
    let trashRetention = TrashRetentionController.shared
    /// Scoped default-opener rules (by file / folder / type), persisted.
    var openerRules = OpenerRules()
    /// Session-only opener overrides, keyed by lowercased extension (not persisted).
    var sessionOpenersByKind: [String: String] = [:]  // OpenerRules.kindKey -> app path
    /// Saved workspace layouts (pane paths + split position).
    var layouts = Layouts()
    /// Fuzzy command palette over the registry (Cmd-Shift-P).
    lazy var palette = CommandPalette()  // used in +CommandSurfaces
    /// Natural-language command bar (Cmd-Shift-A): Foundation Model when
    /// available, the engine heuristic otherwise.
    lazy var aiBar = AICommandBar()  // natural-language command bar (driven from +AICommands)
    /// Floating quick-action buttons shown over the panes when items are selected.
    let quickBar = QuickActionsBar()
    /// Watches Downloads and floats a one-click "move to" chip; owns its own watcher + queue.
    let downloadSuggestions = DownloadSuggestionsController()
    /// Batch-rename sheet for the active pane's selection.
    lazy var batchRename = BatchRenameController()  // used in +CommandSurfaces
    /// The review sheet for a deterministic "Organize Folder" plan (its methods live in
    /// BrowserViewController+OrganizeWithAI.swift; a stored property can't sit in an extension).
    var organizeReview: OrganizeReviewController?
    lazy var settings = SettingsWindowController()
    /// The Photos-library browser (PhotoKit), opened from the sidebar's Photos item.
    lazy var photosBrowser = PhotosBrowserController()
    /// The interactive image cropper (Image ▸ Crop).
    lazy var cropController = CropController()
    /// Bulk metadata editor (EXIF/IPTC + Finder tags/comment).
    lazy var metadataEditor = MetadataEditorController()
    /// Grouped duplicate resolver (keep one per set, trash the rest).
    lazy var duplicatesController = DuplicatesController()
    /// Settings embedded over the right pane (so browsing continues in the left pane).
    var settingsPanel: NSView?
    lazy var batchCreate = BatchCreateController()
    lazy var templatesManager = TemplatesController()
    lazy var commitController = CommitController()
    lazy var archiveContents = ArchiveContentsController()
    lazy var findInFiles = FindInFilesController()
    lazy var processViewer = ProcessViewerController()
    lazy var torrents = TorrentsWindowController()
    lazy var externalCommandsController = ExternalCommandsController()
    lazy var externalOutput = ExternalCommandOutputController()
    let slideshow = SlideshowController()
    lazy var trimController = TrimController()
    lazy var aclEditor = ACLEditorController()  // used by BrowserViewController+Permissions
    lazy var markupController = MarkupController()
    lazy var undoHistoryController = UndoHistoryController()  // used by showUndoHistory (BrowserViewController+Transfers)
    lazy var globalSearchController = GlobalSearchController(semantic: semanticSearch)  // used in +Navigation
    var externalCommands: [ExternalCommand] = []
    let menuInstaller = BrowserMenuInstaller()
    var externalCommandsMenu: NSMenu { menuInstaller.externalCommandsMenu }
    var createTemplates: [CreateTemplate] = []
    /// Folders recently used as a Copy To / Move To destination (most recent first).
    var recentDestinations: [String] = []  // Copy To / Move To history (see +CopyMoveTo)
    /// The shared Sparkle updater (set by the app), surfaced in Settings > Updates.
    var updater: UpdaterController?
    /// Prominent in-window banner shown when an update is ready to install or a newer build is
    /// installed under the running app. This is the reliable affordance (the title-bar accessory
    /// renders inconsistently next to the unified toolbar and was easy to miss).
    let updateBanner = RelaunchBanner()
    /// User preferences (density, font, alternating rows, search OCR).
    var prefs = Preferences.default
    /// Runs a local copy/move with a progress sheet; one transfer at a time.
    let transferRunner = TransferRunner()  // driven by runTransfer (BrowserViewController+Transfers)
    var transferInFlight = false
    /// Acquire synchronously before scheduling a file-operation confirmation.
    /// Pending decisions are not replaceable or implicitly queued approvals.
    var fileConfirmationPending = false
    var fileOperationBusy: Bool { transferInFlight || fileConfirmationPending }
    /// Whether a copy/move is running (so the app can warn before quitting).
    var isTransferring: Bool { transferInFlight }
    /// File paths currently marked for cut (dimmed until pasted or cleared).
    var cutPaths: Set<String> = []
    #if DEBUG
    /// UI regression scenarios must not replace the owner's system clipboard.
    var debugFilePasteboard: NSPasteboard?
    /// Observe real confirmation dispatch without touching the owner's Trash.
    var debugTrashHandler: (([URL]) -> Void)?
    #endif
    var sidebarWidthConstraint: NSLayoutConstraint? { splitLayout.sidebarWidthConstraint }
    var compactSidebar: Bool {
        get { splitLayout.compactSidebar }
        set { splitLayout.compactSidebar = newValue }
    }
    var expandedSidebarWidth: CGFloat {
        get { splitLayout.expandedSidebarWidth }
        set { splitLayout.expandedSidebarWidth = newValue }
    }
    static let compactSidebarWidth = BrowserSplitLayoutController.compactSidebarWidth
    /// Guided Full Disk Access walkthrough (first launch, until granted).
    private lazy var fdaGuide = FullDiskAccessGuide()
    lazy var infoInspector = InfoInspectorController()
    lazy var connectionsController = ConnectionsController()
    lazy var transferController: TransferQueueController = {
        let controller = TransferQueueController()
        // A retried transfer finishes outside its original batch, so reload the panes and
        // surface any failure the way the first attempt did.
        controller.onRetryComplete = { [weak self] failures, cancelled in
            guard let self else { return }
            self.leftTabs.activePane?.reloadIfShowingListing()  // handles remote + local re-list
            self.rightTabs.activePane?.reloadIfShowingListing()
            self.reportTransfer(failures, cancelled: cancelled, verb: "transfer")
        }
        return controller
    }()
    let sharedDiscovery = SharedDiscovery()
    /// Bonjour-discovered SMB computers on the LAN (display names), kept so the Network view can
    /// list them and re-render live as they come and go.
    var discoveredHosts: [String] = []
    /// Confirmations shown as a popover at the pointer (move/copy conflicts, Trash) rather than
    /// a sheet pinned to the title bar.
    let cursorConfirm = CursorConfirm()
    let deviceWatcher = DeviceWatcher()  // owns the USB-phone poll timer + name cache (feeds the sidebar)
    var layoutsMenu: NSMenu { menuInstaller.layoutsMenu }
    var savedViewsMenu: NSMenu { menuInstaller.savedViewsMenu }
    var bookmarksMenu: NSMenu { menuInstaller.bookmarksMenu }
    var recentFoldersMenu: NSMenu { menuInstaller.recentFoldersMenu }
    /// The most-recently-visited folders (newest first), for the Go > Recent Folders submenu.
    var recentFolders: [URL] {
        get { menuInstaller.recentFolders }
        set { menuInstaller.recentFolders = newValue }
    }

    /// Set in privacy-safe demo mode (launch flag or the View menu), so session restore is
    /// skipped and the sidebar/panes use the fake workspace instead of the user's real data.
    var demoLayout: DemoWorkspace.Layout?
    /// Real state saved when demo mode is toggled on, to restore when it's toggled off.
    var savedRealSidebar: Sidebar?
    var savedPaneFolders: (left: URL?, right: URL?)?

    /// Whether this browser owns the persisted session. The primary window restores and saves
    /// it; additional windows (File ▸ New Window) open fresh at their start folder and never
    /// touch the shared session, so they can't clobber the primary's tabs.
    private(set) var persistsSession: Bool  // cleared by Reset Pathem Data so quit won't re-save

    init(start: URL, demo: DemoWorkspace.Layout? = nil, persistsSession: Bool = true) {
        demoLayout = demo
        if let demo { FolderSizeSkipSettings.demoRoot = demo.root.path }
        self.persistsSession = persistsSession
        leftTabs = TabbedPaneController(start: demo?.leftStart ?? start)
        rightTabs = TabbedPaneController(start: demo?.rightStart ?? start)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        splitLayout.configure(
            left: leftTabs.containerView, right: rightTabs.containerView,
            sidebar: sidebar.containerView, terminal: terminal.view)

        // The search-and-command button lives in the window's unified toolbar (Finder-style).
        // It reads like a search field but opens the overlay; the active pane's live query
        // shows as its title so search state stays visible.
        searchButton.bezelStyle = .texturedRounded
        searchButton.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: L("bvc.searchToolbarLabel", "Search"))
        searchButton.imagePosition = .imageLeading
        searchButton.alignment = .left
        searchButton.target = self
        searchButton.action = #selector(searchButtonTapped)
        searchButton.toolTip = L("filesearch.toolbarTip", "Search file names or contents (⌘F)")
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        searchButton.widthAnchor.constraint(equalToConstant: 240).isActive = true
        updateSearchButton(query: "")

        // The torrents drawer docks below the whole split via a stack view rather than as a third
        // split pane: two independently-toggled drawers in one NSSplitView can't both size reliably
        // (a hidden middle pane collapses the divider index, leaving the other at 0 height -- the
        // "full black single pane" bug). A stack view collapses a hidden arranged view cleanly and
        // honors the drawer's fixed-height constraint.
        torrentDrawer.view.translatesAutoresizingMaskIntoConstraints = false
        torrentDrawer.view.heightAnchor.constraint(equalToConstant: 220).isActive = true
        torrentDrawer.view.isHidden = true
        mainStack.orientation = .vertical
        mainStack.spacing = 0
        mainStack.distribution = .fill
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        updateBanner.isHidden = true  // collapses to zero height until there's an update
        updateBanner.onAction = { [weak self] in self?.performUpdateBannerAction() }
        mainStack.addArrangedSubview(updateBanner)  // unmissable update bar across the very top
        mainStack.addArrangedSubview(vSplit)
        mainStack.addArrangedSubview(torrentDrawer.view)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshUpdateBanner), name: .pathemUpdateStateChanged,
            object: nil)
        refreshUpdateBanner()
        // The browser split absorbs resize; the drawer holds its constrained height.
        vSplit.setContentHuggingPriority(.init(1), for: .vertical)
        torrentDrawer.view.setContentHuggingPriority(.required, for: .vertical)
        torrentDrawer.onSelect = { [weak self] status in self?.torrentSelectionChanged(status) }
        torrentDrawer.onOpen = { [weak self] status in self?.showTorrentDetail(status) }

        // The torrent detail view overlays the pane area (sidebar stays visible), hidden until a
        // torrent is opened from the drawer.
        torrentDetail.translatesAutoresizingMaskIntoConstraints = false
        torrentDetail.isHidden = true
        torrentDetail.onClose = { [weak self] in self?.hideTorrentDetail() }
        panesContainer.addSubview(torrentDetail)
        NSLayoutConstraint.activate([
            torrentDetail.topAnchor.constraint(equalTo: panesContainer.topAnchor),
            torrentDetail.leadingAnchor.constraint(equalTo: panesContainer.leadingAnchor),
            torrentDetail.trailingAnchor.constraint(equalTo: panesContainer.trailingAnchor),
            torrentDetail.bottomAnchor.constraint(equalTo: panesContainer.bottomAnchor),
        ])

        let host = NSView()
        host.addSubview(mainStack)  // browser split + torrents drawer dock
        host.addSubview(shelf.view)  // the stash shelf docks across the bottom
        shelf.view.isHidden = true
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: host.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            shelf.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            shelf.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            shelf.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        // The browser fills the window; when the shelf shows, it gives up the bottom.
        shelfHiddenConstraint = mainStack.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        shelfShownConstraint = mainStack.bottomAnchor.constraint(equalTo: shelf.view.topAnchor)
        shelfHiddenConstraint?.isActive = true
        // Commander bar docks across the very bottom; when shown, the browser ends above it.
        commanderBar.translatesAutoresizingMaskIntoConstraints = false
        commanderBar.isHidden = true
        host.addSubview(commanderBar)
        NSLayoutConstraint.activate([
            commanderBar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            commanderBar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            commanderBar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            commanderBar.heightAnchor.constraint(equalToConstant: 38),  // a single compact strip
        ])
        commanderShownConstraint = mainStack.bottomAnchor.constraint(
            equalTo: commanderBar.topAnchor)
        commanderBar.onCommand = { [weak self] id in self?.commands.perform(id) }
        commanderBar.onRunCommand = { [weak self] command in self?.runCommanderCommand(command) }
        commanderBar.titleForCommand = { [weak self] id in self?.commands.command(id)?.title ?? id }
        applyCommanderCommands()
        // Super-drag swipe trail, filling the window overlay above the panes (non-interactive).
        dragTrail.frame = host.bounds
        dragTrail.autoresizingMask = [.width, .height]
        host.addSubview(dragTrail)
        // Floating quick-actions bar, positioned next to the selection (see positionQuickBar).
        host.addSubview(quickBar)
        quickBar.translatesAutoresizingMaskIntoConstraints = true
        quickBar.onAction = { [weak self] id in self?.commands.perform(id) }
        quickBar.onOpenWith = { [weak self] anchor in self?.showQuickOpenWith(from: anchor) }
        quickBar.onCopiedShowPaste = { [weak self] anchor in
            self?.showQuickPasteFollowUp(from: anchor)
        }
        // Ambient download chip, floating at the top-center of the panes.
        let downloadChip = downloadSuggestions.view
        host.addSubview(downloadChip)
        NSLayoutConstraint.activate([
            downloadChip.centerXAnchor.constraint(equalTo: split.centerXAnchor),
            downloadChip.topAnchor.constraint(equalTo: split.topAnchor, constant: 12),
            downloadChip.widthAnchor.constraint(
                lessThanOrEqualTo: split.widthAnchor, constant: -24),
        ])
        downloadSuggestions.onApplied = { [weak self] performed in
            if !performed.isEmpty {
                self?.registerUndo(performed, actionName: L("organize.action", "Organize"))
            }
            self?.reloadBothSides()
        }
        view = host
        configureShelf()
        // Watch Downloads for one-click filing, except in demo mode and under the smoke
        // harness (which must stay deterministic).
        updateDownloadSuggestions()
        setupAutomation()
    }

    /// Set the panes' divider to `fraction` (the right pane's share) and lay them out now.
    /// The delegate keeps that ratio across content swaps and window resizes.
    func setRightPaneFraction(_ fraction: Double) {
        splitLayout.setRightPaneFraction(fraction)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Self.prepareRemoteTemp()
        registerCommands()
        loadSavedSearches()  // register before macros so a macro can run a search
        loadFolderBackgrounds()
        loadViewPresets()
        loadCollections()
        loadMacros()  // after base commands, so macros can chain them
        loadTemplates()  // register template commands so they appear in the shortcut editor
        loadRecentDestinations()  // register Copy/Move To <recent> commands for the palette
        loadKeymap()
        loadGestures()
        loadPreferences()
        loadFolderFormats()
        loadLayouts()
        loadSidebar()
        loadTerminalTheme()
        loadOpenerRules()
        loadTrashOrigins()
        loadExternalCommands()
        installExternalCommandsMenu()
        loadConnections()
        installLayoutsMenu()
        loadRecentFolders()
        installRecentFoldersMenu()
        for side in [leftTabs, rightTabs] {
            side.configurePane = { [weak self] pane in
                pane.onKeyChordHandler = { [weak self] chord in self?.handleKeyChord(chord) ?? false
                }
                pane.onMouseGestureHandler = { [weak self] stroke in
                    self?.handleGesture(stroke) ?? false
                }
                pane.onDragSessionHandler = { [weak self] event in self?.handleDragSession(event) }
                pane.onBrowseArchive = { [weak self, weak pane] archive in
                    guard let self, let pane else { return }
                    self.browseArchive(archive, in: pane, origin: pane.currentURL)
                }
                pane.onArchiveClosed = { [weak self] archive, mountRoot, snapshot in
                    self?.writeBackArchiveIfChanged(
                        archive: archive, mountRoot: mountRoot, original: snapshot)
                }
                pane.onAttachDiskImage = { [weak self, weak pane] image in
                    self?.attachDiskImage(image, in: pane)
                }
                pane.resolveFormat = { [weak self] url in
                    self?.folderFormats.format(for: url.path) ?? self?.prefs.defaultFormat
                        ?? .default
                }
                pane.hasExplicitFormat = { [weak self] url in
                    self?.folderFormats.hasRule(for: url.path) ?? false
                }
                pane.backgroundFor = { [weak self] url in
                    self?.folderBackgrounds.background(for: url.path)
                }
                pane.rememberFormat = { [weak self] url, format in self?.rememberFormat(url, format)
                }
                pane.openFile = { [weak self] url in self?.applyOpen(url) }
                pane.runCommand = { [weak self] id in self?.commands.perform(id) }
                pane.setPathBar(atBottom: self?.prefs.pathBarAtBottom ?? false)
                pane.showHiddenByDefault = self?.prefs.showHiddenByDefault ?? false
                pane.iconZoom = CGFloat(self?.prefs.iconZoom ?? 1)
                pane.onIconZoomChanged = { [weak self] scale in self?.rememberIconZoom(scale) }
                pane.onHeaderButtonsChanged = { [weak self] ids in
                    self?.rememberHiddenHeaderButtons(ids)
                }
                pane.onHeaderOrderChanged = { [weak self] ids in
                    self?.rememberHeaderButtonOrder(ids)
                }
                // New tabs honor the customized header too.
                pane.setHeaderButtonOrder(self?.prefs.paneHeaderButtonOrder ?? [])
                pane.setHiddenHeaderButtons(Set(self?.prefs.hiddenPaneHeaderButtons ?? []))
                // A tab created after a settings change must not reset content preferences.
                if let self { self.applyContentPreferences(to: pane) }
                pane.onUploadFiles = {
                    [weak self, weak pane] urls, connection, remotePath, password in
                    guard let self, let pane else { return }
                    self.uploadFiles(
                        urls, to: connection, remotePath: remotePath, password: password, pane: pane
                    )
                }
                pane.onOpenRemoteFile = { [weak self] connection, remotePath, password, name in
                    self?.openRemoteFile(
                        connection, remotePath: remotePath, password: password, name: name)
                }
                pane.onSelectionChanged = { [weak self] in
                    self?.updatePreview()
                    self?.updateQuickActions()
                }
                pane.onBreadcrumbAction = { [weak self] folder, action in
                    self?.handleBreadcrumbAction(folder, action)
                }
                pane.onOpenInNewTab = { [weak self] url in self?.activeSide?.openTab(at: url) }
                pane.onMountNetworkHost = { [weak self] host in self?.connectToShared(host) }
                pane.onRenameRequested = { [weak self, weak pane] entry, newName in
                    guard let self, let pane else { return }
                    self.commitLocalRename(entry, to: newName, pane: pane)
                }
            }
            side.onPaneBecameActive = { [weak self, weak side] pane in
                guard let self, let side else { return }
                self.setActiveSide(side, pane: pane)
            }
            side.onPaneDirectoryDidChange = { [weak self] pane, url in
                self?.directoryChanged(pane, url)
            }
            side.onPaneDidNavigate = { [weak self] pane in
                pane.searchQuery = ""  // navigating clears that pane's query
                guard pane === self?.activePane else { return }
                self?.updateSearchButton(query: "")
                self?.updateWindowTitle()  // covers remote nav too
                if !pane.isRemote { self?.recordRecentFolder(pane.currentURL) }
            }
            side.onPaneDropFiles = { [weak self] urls, move, destination in
                self?.dropFiles(urls, move: move, into: destination)
            }
            side.onPaneDropOntoFile = { [weak self] dragged, target in
                self?.showDropOntoFileMenu(dragged: dragged, target: target)
            }
            side.newTabLocation = { [weak self] in self?.preferredNewTabFolder() }
            side.onOpenFolderInPane = { [weak self] url, action in
                self?.handleBreadcrumbAction(url, action)
            }
            // Tab dragging: only the browser knows both sides, so it resolves a drag's origin, and
            // handles the two drops a single side can't do by itself (tear off, move across).
            side.sideForID = { [weak self] id in
                guard let self else { return nil }
                if self.leftTabs.sideID == id { return self.leftTabs }
                if self.rightTabs.sideID == id { return self.rightTabs }
                return nil
            }
            side.onTearOffTab = { url in WindowManager.shared.openWindow(start: url) }
            side.onMoveTabToOtherSide = { [weak self, weak side] index in
                guard let self, let side else { return }
                let other = side === self.leftTabs ? self.rightTabs : self.leftTabs
                guard let url = side.takeTab(at: index) else { return }
                other.adoptTab(url: url, at: other.tabCount)
            }
        }
        // Restore the last session's tabs/folders (or open initial tabs) now that
        // configurePane + callbacks are set, so each pane is fully wired.
        restoreSession()
        sidebar.onSelect = { [weak self] url in self?.activePane?.navigate(to: url) }
        sidebar.onOpenInNewTab = { [weak self] url in self?.activeSide?.openTab(at: url) }
        sidebar.onOpenInOtherPane = { [weak self] url in
            (self?.otherPane ?? self?.activePane)?.navigate(to: url)
        }
        sidebar.onEmptyTrash = { [weak self] in self?.emptyTrash() }
        sidebar.onSelectSmart = { [weak self] query in self?.openSmart(query) }
        sidebar.onSelectSavedSearch = { [weak self] search in
            self?.runSavedSearch(search.name, query: search.mdfindQuery())
        }
        sidebar.savedSearches = savedSearches.searches  // show saved smart folders in the sidebar
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
        sidebar.onEjectVolume = { [weak self] volume in self?.ejectVolume(volume) }
        sidebar.onDropFilesIntoFolder = { [weak self] urls, folder, move in
            self?.dropFiles(urls, move: move, into: folder)
        }
        sidebar.onPasteIntoFolder = { [weak self] folder in self?.pasteFiles(into: folder) }
        sidebar.canPasteIntoFolder = { [weak self] folder in
            self?.canPasteFiles(into: folder) == true
        }
        sidebar.onApplyTag = { [weak self] urls, color in self?.applyTag(color, to: urls) }
        sidebar.onAirDrop = { [weak self] in
            let urls = self?.activePane?.selectedLocalURLs() ?? []
            guard !urls.isEmpty else {
                NSSound.beep()
                return
            }  // nothing selected to send
            self?.airDrop(urls)
        }
        sidebar.onAirDropFiles = { [weak self] urls in self?.airDrop(urls) }
        sidebar.onNetwork = { [weak self] in self?.showNetworkView() }
        sidebar.onOpenPhotos = { [weak self] in self?.openPhotosBrowser() }
        sidebar.onTrashFiles = { [weak self] urls in self?.performLocalTrash(urls) }
        sidebar.onOpenSettings = { [weak self] in self?.showPreferences() }
        sidebar.onToggleCompact = { [weak self] in
            guard let self else { return }
            self.prefs.compactSidebar.toggle()
            self.applyCompactSidebar()
            saveConfig(self.prefs, to: Self.preferencesURL)
        }
        sidebar.onModelChange = { [weak self] model in self?.saveSidebar(model) }
        sidebar.currentFolder = { [weak self] in self?.activePane?.currentURL }
        sharedDiscovery.onChange = { [weak self] hosts in
            self?.discoveredHosts = hosts
            self?.sidebar.setSharedHosts(hosts)
            self?.refreshNetworkViewIfShowing()
        }
        sharedDiscovery.start()
        deviceWatcher.onDevices = { [weak self] devices in self?.sidebar.setDevices(devices) }
        deviceWatcher.start()
        applyPreferences()
    }

    /// Register every browser action as a named command. This is the spine the
    /// keymap, command palette, and AI bar will all bind to (DESIGN.md 10).
    private static var macrosURL: URL? {
        appSupportDirectory()?.appendingPathComponent("macros.json")
    }
    static var savedSearchesURL: URL? {
        appSupportDirectory()?.appendingPathComponent("searches.json")
    }
    var viewPresets = ViewPresets.default

    static var folderBackgroundsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("folder-backgrounds.json")
    }
    var folderBackgrounds = FolderBackgrounds.default
    static var collectionsConfigURL: URL? {
        appSupportDirectory()?.appendingPathComponent("collections.json")
    }
    var collectionsStore = Collections()
    /// Macros currently executing, to break a self/mutually-referential macro cycle.
    private var runningMacroIDs: Set<String> = []

    /// The saved smart-folder searches (searches.json); each is a command that runs its mdfind
    /// query and shows the results as a cross-folder smart list.
    var savedSearches = SavedSearches.default

    /// Register each user macro (macros.json) as a command that runs its command IDs
    /// in order; it then appears in the palette and is bindable like any command.
    private func loadMacros() {
        let set = loadConfig(Macros.self, from: Self.macrosURL) ?? Macros.default
        for macro in set.macros where !macro.name.isEmpty && !macro.commands.isEmpty {
            let ids = macro.commands
            let macroID = "macro.\(macro.name)"
            commands.register(
                .init(
                    id: macroID,
                    title: String(format: L("bvc.macroCmdTitle", "Macro: %@"), macro.name),
                    isEnabled: { true },
                    run: { [weak self] in
                        guard let self, !self.runningMacroIDs.contains(macroID) else { return }  // cycle guard
                        self.runningMacroIDs.insert(macroID)
                        defer { self.runningMacroIDs.remove(macroID) }
                        for id in ids { _ = self.commands.perform(id) }
                    }))
        }
    }

    // Palette / batch-rename / select-by-pattern surfaces live in BrowserViewController+CommandSurfaces.

    // MARK: - New folder / Trash / Reveal

    /// Remote panes have no local file URLs, so file ops can't act there. Per-file
    /// ops (trash, rename, reveal, info, …) ARE allowed in cross-folder smart views
    /// because they resolve each item by its own folder (selectedLocalURLs). Returns
    /// true (and beeps) if blocked.
    func blockedByRemote() -> Bool {
        if activePane?.isRemote == true {
            activePane?.flashStatus(
                L("flash.notOnRemote", "That action isn’t available on a remote connection"),
                isError: true)
            return true
        }
        return false
    }

    /// Ops that need one destination folder (paste, new folder) can't run in a
    /// remote pane or a cross-folder smart-result view (there's no single "here").
    func blockedByRemoteOrSmart() -> Bool {
        if activePane?.isRemote == true {
            activePane?.flashStatus(
                L("flash.notOnRemote", "That action isn’t available on a remote connection"),
                isError: true)
            return true
        }
        if activePane?.isShowingSmartResults == true {
            activePane?.flashStatus(
                L("flash.notInSmartView", "That action needs a single folder, not a search view"),
                isError: true)
            return true
        }
        return false
    }

    /// Run a remote file operation off-main, refreshing the pane and reporting errors.
    func performRemoteOp(
        _ pane: PaneController, verb: String,
        _ op:
            @escaping @Sendable (RemoteProvider, RemoteConnection, String, String) async throws ->
            Void
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

    // (Rename lives in BrowserViewController+Rename.swift.)

    // (trashSelection / performLocalTrash / trash-location state live in
    // BrowserViewController+TrashLedger.swift.)

    /// Hand the given files to the system AirDrop sheet. The OS (sharingd) does the
    /// transfer, so this stays a plain UI handoff (no networking in our process).
    private func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            NSSound.beep()
            return
        }
        let sendable = urls.filter { $0.isFileURL }
        guard service.canPerform(withItems: sendable) else {
            presentInfo(
                L("bvc.airdropUnavailableTitle", "Can’t AirDrop these items"),
                L(
                    "bvc.airdropUnavailableBody",
                    "AirDrop may be turned off, or these items can’t be sent."))
            return
        }
        service.perform(withItems: sendable)
    }

    /// Where each Pathem-trashed item came from (trashed path -> original path), so Put Back can
    /// restore it. Finder-trashed items aren't here (the OS keeps that info privately). A stored
    /// property, so it stays here; the ledger and trash commands that use it are in
    /// BrowserViewController+TrashLedger.swift.
    var trashOrigins: [String: String] = [:]

    /// Refresh the active pane on each side (used by undo/redo handlers).
    func reloadBothSides() {
        leftTabs.activePane?.reloadIfShowingListing()
        rightTabs.activePane?.reloadIfShowingListing()
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp",
    ]
    static func isImageName(_ name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// The folder a new window should open at: the active pane's folder when it's a local
    /// listing, otherwise Home (a remote/smart pane has no plain local folder to reopen).
    func newWindowStartFolder() -> URL {
        if let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults {
            return pane.currentURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Detach the active tab into its own window: open a new window at that folder and, if the
    /// side still has other tabs, close the one we moved (so nothing is duplicated in place).
    func moveActiveTabToNewWindow() {
        guard let side = activeSide, let pane = side.activePane, !pane.isRemote else {
            NSSound.beep()
            return
        }
        WindowManager.shared.openWindow(start: pane.currentURL)
        if side.tabCount > 1 { side.closeActiveTab() }
    }

    // The floating quick-actions bar's scroll-follow bookkeeping and the auto-preview-pane
    // "did we show it" flag: physically interleaved stored state for
    // BrowserViewController+QuickActions.swift (extensions can't hold stored properties).
    var quickBarScrollObserver: NSObjectProtocol?
    weak var quickBarObservedClip: NSClipView?

    /// Apply (toggle) the named label carried by a "Label" menu item to the selection.
    @objc func applyLabelFromMenu(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? FileLabel else {
            NSSound.beep()
            return
        }
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
        NSWorkspace.shared.open([target], withApplicationAt: editor, configuration: config) {
            [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.presentInfo(
                    String(
                        format: L("editor.failedTitle", "Couldn’t open in %@"),
                        editor.deletingPathExtension().lastPathComponent),
                    error.localizedDescription)
            }
        }
    }

    /// Prune the given paths from every pane's smart-result list (after a file op
    /// removed/moved them), so smart views don't keep stale rows.
    func pruneSmartEntries(_ paths: Set<String>) {
        for side in [leftTabs, rightTabs] {
            for pane in side.tabs { pane.pruneSmartEntries(paths: paths) }
        }
    }

    /// The pane (on either side) currently showing `directory`, if any.
    func paneShowing(_ directory: URL) -> PaneController? {
        for side in [leftTabs, rightTabs] {
            for pane in side.tabs where pane.currentURL == directory { return pane }
        }
        return nil
    }

    /// Vim-style, keyboard-driven navigation (View ▸ Vim Navigation). Off by default.
    var vimMode = false
    var vimPendingG = false

    static var keymapURL: URL? {
        appSupportDirectory()?.appendingPathComponent("keymap.json")
    }

    static var gesturesURL: URL? {
        appSupportDirectory()?.appendingPathComponent("gestures.json")
    }

    static func appSupportDirectory() -> URL? {
        ConfigStore.directory()
    }

    /// Clean-uninstall helper: restore Finder as the default folder app, and (unless the user
    /// opts to keep it) remove everything Pathem persisted -- its Application Support config,
    /// its user defaults, and its Keychain passwords -- then quit, so dragging Pathem to the
    /// Trash leaves nothing behind. Files are never touched.
    func resetPathemData() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = L("bvc.resetDataTitle", "Reset Pathem Data?")
        alert.informativeText = L(
            "bvc.resetDataBody",
            "This removes all Pathem settings, saved connections and their Keychain passwords, sidebar and menu customization, color rules, and layouts, and restores Finder as the default folder app. Your files are not touched. Pathem then quits, so you can drag it to the Trash for a clean uninstall."
        )
        alert.alertStyle = .warning
        // Off by default = a full clean uninstall. Checked keeps the config/passwords in place
        // so a reinstall picks up where you left off; only the folder default is restored.
        let keepData = NSButton(
            checkboxWithTitle: L(
                "bvc.resetKeepData", "Keep my Pathem settings and data (for a future reinstall)"),
            target: nil, action: nil)
        keepData.state = .off
        alert.accessoryView = keepData
        alert.addButton(withTitle: L("bvc.resetDataConfirm", "Continue and Quit"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            let keep = keepData.state == .on
            let wasFolderHandler = FolderHandler.isPathem
            if wasFolderHandler { try? await FolderHandler.setDefault(toPathem: false) }  // always restore Finder
            if !keep {
                if let dir = Self.appSupportDirectory() {
                    try? FileManager.default.removeItem(at: dir)
                }
                KeychainStore.removeAll()
                if let bundleID = Bundle.main.bundleIdentifier {
                    UserDefaults.standard.removePersistentDomain(forName: bundleID)
                }
                persistsSession = false  // don't re-save a session into the just-removed folder
            }
            _ = window

            // A closing note on how to finish removing Pathem: the two leftovers Reset can't
            // handle for you (the app bundle itself, and the system Full Disk Access grant).
            let removed =
                keep
                ? L("bvc.resetKept", "Your settings and data were kept")
                : L(
                    "bvc.resetRemoved",
                    "Your settings, saved passwords, and customization were removed")
            let done = NSAlert()
            done.messageText = L("bvc.resetDoneTitle", "Pathem Data Reset")
            done.informativeText = String(
                format: L(
                    "bvc.resetDoneBody",
                    "%@%@.\n\nTo finish uninstalling:\n1. Drag Pathem from Applications to the Trash.\n2. Optionally remove Pathem under System Settings ▸ Privacy & Security ▸ Full Disk Access. macOS keeps that grant until you clear it."
                ),
                removed,
                wasFolderHandler
                    ? L("bvc.resetFinderRestored", ", and Finder is again the default for folders")
                    : "")
            done.addButton(withTitle: L("bvc.resetDoneQuit", "Quit Pathem"))
            _ = await self.presentSheet(done)
            NSApp.terminate(nil)
        }
    }

    // ACL + ownership actions live in BrowserViewController+Permissions.

    /// Finder-style "Connect to Server": prompt for an smb/afp/nfs address, mount it via NetFS
    /// (the OS handles auth), and navigate the active pane to the mount point.

    /// Mount smb://host via NetFS (the OS handles auth/Keychain and shows its own
    /// prompt when needed), then navigate the active pane to the mount point.
    // MARK: - Scoped openers

    static var openersURL: URL? {
        appSupportDirectory()?.appendingPathComponent("openers.json")
    }

    /// Apply a built-in terminal theme by name (from the View > Terminal Theme menu).
    @objc func selectTerminalTheme(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
            let preset = TerminalTheme.presets.first(where: { $0.name == name })
        else { return }
        terminal.theme = preset
        saveConfig(preset, to: Self.terminalThemeURL)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialSplitPositions()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installToolbarIfNeeded()
        installUpdateButtonIfNeeded()
        applyInitialSplitPositions()
        // Focus the restored active pane, not always the left one.
        let focusPane = activePane ?? activeSide?.activePane ?? leftTabs.activePane
        view.window?.makeFirstResponder(focusPane?.keyView)
        updateWindowTitle()
        maybePromptFullDiskAccess()
        maybeOfferDemoWorkspace()  // first-run tour, once FDA is granted (never stacks on the FDA guide)
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
    func setActiveSide(_ side: TabbedPaneController, pane: PaneController) {
        if activePane !== pane { activePane?.setActive(false) }
        activePane = pane
        activeSide = side
        pane.setActive(true)
        sidebar.highlightFolder(pane.currentURL)  // the sidebar tracks the newly active pane's folder
        updateWindowTitle()
        updateSearchButton(query: pane.searchQuery)  // show the focused pane's own query
        // Note: the query is cleared on navigation (onDidNavigate), not on every
        // focus change, so a live query or visible results survive a pane re-focus.
        // The semantic index is built lazily on first search (not on focus/navigation),
        // so re-focusing a pane costs nothing here.
        syncAutoPreview()  // follow the newly active pane's view mode + selection
        updateQuickActions()  // the quick-actions bar follows the active pane's selection
        saveSessionSoon()
    }

    /// Apply a color tag to dropped files (drop onto a sidebar Tag).
    private func applyTag(_ color: FileTag.Color, to urls: [URL]) {
        for url in urls {
            var tags = FileTags.tags(of: url)
            guard !tags.contains(where: { $0.color == color }) else { continue }
            tags.append(FileTag(color: color))
            try? FileTags.setTags(tags, on: url)
        }
        reloadBothSides()
    }

    /// The dragged items + target file for a file-onto-file drop, held while its menu is open.
    var pendingDropContext: (dragged: [URL], target: URL)?

    // Navigation, sync-browsing, and window-title methods live in BrowserViewController+Navigation.

    // MARK: - Terminal

    var terminalFollowsFolder: Bool { terminalFollows }

    // External-open / reveal / Photos-browser methods live in BrowserViewController+ExternalOpen.
}
