import AppKit
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
    NSSplitViewDelegate, NSMenuItemValidation
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
        guard !urls.isEmpty, urls.allSatisfy({ $0.pathExtension.lowercased() == "torrent" }) else { return [] }
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
    private var isSyncingPanes = false  // re-entrancy guard for the mirror navigation
    /// Each pane's last-seen local folder, so a navigation's relative delta can be
    /// computed (see `mirrorNavigationIfSyncing`). Keyed by pane identity.
    var syncBrowseAnchors: [ObjectIdentifier: URL] = [:]
    let split = NSSplitView()  // the two sides
    let panesContainer = NSView()  // wraps `split` so the torrent detail can overlay without NSSplitView treating it as a pane
    let outerSplit = NSSplitView()  // sidebar | panes
    let vSplit = NSSplitView()  // browser (top) | terminal (bottom)
    let mainStack = NSStackView()  // vSplit (top) + torrents drawer (bottom dock)
    let shelf = ShelfController()  // stash shelf / drop stack across the bottom
    var shelfHiddenConstraint: NSLayoutConstraint?
    var shelfShownConstraint: NSLayoutConstraint?
    let commanderBar = CommanderBar()  // orthodox F-key bar + command line (Commander mode)
    var commanderShownConstraint: NSLayoutConstraint?
    let previewView = DocumentPreviewView()
    var previewVisible = false
    /// Durably pins the preview pane's width so it (and the panes) can't collapse; see
    /// togglePreviewPane(). Mirrors sidebarWidthConstraint.
    var previewWidthConstraint: NSLayoutConstraint?
    lazy var sizeBrowser = SizeBrowserController()
    lazy var clipboardViewer = ClipboardViewerController()
    lazy var cleanup = CleanupController()
    lazy var xattrController = XattrController()
    lazy var diffViewer = DiffViewerController()
    lazy var bulkAttributes = BulkAttributesController()
    lazy var automationRules = AutomationRulesController()
    lazy var automation: AutomationManager = {
        let manager = AutomationManager(storeURL: Self.automationRulesURL)
        manager.onApplied = { [weak self] _ in self?.reloadBothSides() }
        return manager
    }()
    let sidebar = SidebarController()
    let terminal = TerminalController()
    let torrentDrawer = TorrentDrawerController()  // FileZilla-style transfer drawer at the bottom
    let torrentDetail = TorrentDetailView()  // overlays the panes when a torrent is opened
    /// The toolbar's search-and-command button: looks like a search field, opens the one
    /// overlay (Cmd-F search mode, Cmd-K command mode), and shows the active pane's query.
    let searchButton = NSButton()
    var didSetInitialSplit = false
    /// Opt-in: when true the terminal `cd`s as the active folder changes. Off by
    /// default so navigation never disturbs whatever you're running in the shell.
    var terminalFollows = UserDefaults.standard.bool(forKey: "pathem.terminalFollows")
    /// True while restoring the saved session, so restore activity doesn't trigger
    /// a (partial) save.
    private var isRestoringSession = false
    /// Persists the restore session, saved workspaces, and named view Styles.
    let windowState = WindowStateStore()

    /// Cap on items embedded per search, to bound the cost on huge folders.
    /// The scale path (background incremental indexing and a cached vector
    /// store) is in DESIGN.md section 2.
    let semanticSearch = SemanticSearchController()  // owns the per-folder index cache
    /// Marker on the pasteboard meaning "these files were cut" (paste = move).
    static let cutPasteboardType = NSPasteboard.PasteboardType("com.scarcrux.pathem.cut")
    static let searchItemID = NSToolbarItem.Identifier("com.scarcrux.pathem.search")
    /// A toolbar item that runs a registered command carries the command id in its
    /// identifier (this prefix + the id), so the button is stateless and the id
    /// round-trips through NSToolbar's autosaved customization.
    static let toolbarCmdPrefix = "com.scarcrux.pathem.cmd."

    /// The command bus (DESIGN.md section 10). Every browser action is a named
    /// command; keybindings, the palette, and the AI bar will dispatch by id.
    let commands = CommandRegistry()
    /// Chord -> command id, defaults overlaid with any user keymap.json.
    var keymap = Keymap.standard
    /// Super-drag: direction -> command for a flick, and the swipe-trail overlay.
    var dragGestures = DragGestureMap.standard
    let dragTrail = DragTrailOverlay()
    var dragStartScreen: NSPoint?  // to name the live flick as it changes direction
    /// Stroke -> command id, defaults overlaid with any user gestures.json.
    var gestureMap = GestureMap.standard
    /// Per-folder saved view formats (the exact/subtree cascade), shared by both panes.
    var folderFormats = FolderFormats()
    /// Scoped default-opener rules (by file / folder / type), persisted.
    var openerRules = OpenerRules()
    /// Session-only opener overrides, keyed by lowercased extension (not persisted).
    var sessionOpenersByType: [String: String] = [:]
    /// Saved workspace layouts (pane paths + split position).
    var layouts = Layouts()
    /// Fuzzy command palette over the registry (Cmd-Shift-P).
    private lazy var palette = CommandPalette()
    /// Natural-language command bar (Cmd-Shift-A): Foundation Model when
    /// available, the engine heuristic otherwise.
    private lazy var aiBar = AICommandBar()
    /// Floating quick-action buttons shown over the panes when items are selected.
    let quickBar = QuickActionsBar()
    /// Watches Downloads and floats a one-click "move to" chip; owns its own watcher + queue.
    let downloadSuggestions = DownloadSuggestionsController()
    /// Batch-rename sheet for the active pane's selection.
    private lazy var batchRename = BatchRenameController()
    lazy var settings = SettingsWindowController()
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
    private lazy var aclEditor = ACLEditorController()
    lazy var markupController = MarkupController()
    private lazy var undoHistoryController = UndoHistoryController()
    private lazy var globalSearchController = GlobalSearchController()
    var externalCommands: [ExternalCommand] = []
    /// Dynamic Tools > External Commands submenu (installed once the menu bar is up).
    let externalCommandsMenu = NSMenu(title: "External Commands")
    var didInstallExternalCommandsMenu = false
    var createTemplates: [CreateTemplate] = []
    /// Folders recently used as a Copy To / Move To destination (most recent first).
    private var recentDestinations: [String] = []
    /// The shared Sparkle updater (set by the app), surfaced in Settings > Updates.
    var updater: UpdaterController?
    /// User preferences (density, font, alternating rows, search OCR).
    var prefs = Preferences.default
    /// Runs a local copy/move with a progress sheet; one transfer at a time.
    private let transferRunner = TransferRunner()
    var transferInFlight = false
    /// Whether a copy/move is running (so the app can warn before quitting).
    var isTransferring: Bool { transferInFlight }
    /// File paths currently marked for cut (dimmed until pasted or cleared).
    var cutPaths: Set<String> = []
    var sidebarWidthConstraint: NSLayoutConstraint!
    /// Lays out the two panes at a fixed ratio (and tracks divider drags), so switching a
    /// pane to a content-light view (gallery) can't make the split re-divide and collapse it.
    private let paneSplitDelegate = PaneRatioSplitDelegate()
    var compactSidebar = false
    static let compactSidebarWidth: CGFloat = 60
    /// Guided Full Disk Access walkthrough (first launch, until granted).
    private lazy var fdaGuide = FullDiskAccessGuide()
    private lazy var infoInspector = InfoInspectorController()
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
    private var deviceTimer: Timer?
    let layoutsMenu = NSMenu(title: "Layouts")
    var didInstallLayoutsMenu = false
    let savedViewsMenu = NSMenu(title: "Saved Views")
    var didInstallSavedViewsMenu = false
    let bookmarksMenu = NSMenu(title: "Bookmarks")
    var didInstallBookmarksMenu = false
    /// The most-recently-visited folders (newest first), for the Go > Recent Folders submenu.
    let recentFoldersMenu = NSMenu(title: "Recent Folders")
    var didInstallRecentMenu = false
    var recentFolders: [URL] = []


    /// Set in privacy-safe demo mode (launch flag or the View menu), so session restore is
    /// skipped and the sidebar/panes use the fake workspace instead of the user's real data.
    var demoLayout: DemoWorkspace.Layout?
    /// Real state saved when demo mode is toggled on, to restore when it's toggled off.
    private var savedRealSidebar: Sidebar?
    private var savedPaneFolders: (left: URL?, right: URL?)?

    /// Whether this browser owns the persisted session. The primary window restores and saves
    /// it; additional windows (File ▸ New Window) open fresh at their start folder and never
    /// touch the shared session, so they can't clobber the primary's tabs.
    private(set) var persistsSession: Bool  // cleared by Reset Pathem Data so quit won't re-save

    init(start: URL, demo: DemoWorkspace.Layout? = nil, persistsSession: Bool = true) {
        demoLayout = demo
        self.persistsSession = persistsSession
        leftTabs = TabbedPaneController(start: demo?.leftStart ?? start)
        rightTabs = TabbedPaneController(start: demo?.rightStart ?? start)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        split.isVertical = true
        split.dividerStyle = .thin
        // The two panes use NSSplitView's frame model (TAMIC=true subviews), where width
        // constraints are ignored, so a dedicated delegate lays them out at a fixed ratio.
        // This is what keeps a content-light view (gallery) from collapsing its pane.
        split.delegate = paneSplitDelegate
        split.addArrangedSubview(leftTabs.containerView)
        split.addArrangedSubview(rightTabs.containerView)
        // Wrap the panes split in a plain container so the torrent detail view can overlay it: an
        // NSSplitView treats every direct subview as a pane, so the overlay must go on the container.
        split.translatesAutoresizingMaskIntoConstraints = false
        panesContainer.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: panesContainer.topAnchor),
            split.leadingAnchor.constraint(equalTo: panesContainer.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: panesContainer.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: panesContainer.bottomAnchor),
        ])

        outerSplit.isVertical = true
        outerSplit.dividerStyle = .thin
        outerSplit.delegate = self
        outerSplit.translatesAutoresizingMaskIntoConstraints = false
        outerSplit.addArrangedSubview(sidebar.containerView)
        outerSplit.addArrangedSubview(panesContainer)
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

        // The search-and-command button lives in the window's unified toolbar (Finder-style).
        // It reads like a search field but opens the overlay; the active pane's live query
        // shows as its title so search state stays visible.
        searchButton.bezelStyle = .texturedRounded
        searchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: L("bvc.searchToolbarLabel", "Search"))
        searchButton.imagePosition = .imageLeading
        searchButton.alignment = .left
        searchButton.target = self
        searchButton.action = #selector(searchButtonTapped)
        searchButton.toolTip = L("bvc.searchTip2", "Search this folder or run a command (⌘F / ⌘K)")
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        searchButton.widthAnchor.constraint(equalToConstant: 240).isActive = true
        updateSearchButton(query: "")

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
        mainStack.addArrangedSubview(vSplit)
        mainStack.addArrangedSubview(torrentDrawer.view)
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
        commanderShownConstraint = mainStack.bottomAnchor.constraint(equalTo: commanderBar.topAnchor)
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
        quickBar.onCopiedShowPaste = { [weak self] anchor in self?.showQuickPasteFollowUp(from: anchor) }
        // Ambient download chip, floating at the top-center of the panes.
        let downloadChip = downloadSuggestions.view
        host.addSubview(downloadChip)
        NSLayoutConstraint.activate([
            downloadChip.centerXAnchor.constraint(equalTo: split.centerXAnchor),
            downloadChip.topAnchor.constraint(equalTo: split.topAnchor, constant: 12),
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
        if demoLayout == nil, ProcessInfo.processInfo.environment["PATHEM_SMOKE"] == nil {
            downloadSuggestions.start(feedbackURL: Self.organizeFeedbackURL)
        }
        setupAutomation()
    }

    /// Set the panes' divider to `fraction` (the right pane's share) and lay them out now.
    /// The delegate keeps that ratio across content swaps and window resizes.
    func setRightPaneFraction(_ fraction: Double) {
        paneSplitDelegate.fraction = max(0.15, min(0.85, fraction))
        paneSplitDelegate.layout(split)
        // Also drive the split's own machinery: the delegate layout sets subview frames
        // directly, and without setPosition the split's internal divider layer stays put,
        // leaving a full-height line at the old position.
        if let left = split.arrangedSubviews.first {
            split.setPosition(left.frame.width, ofDividerAt: 0)
        }
        split.needsDisplay = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Self.cleanupRemoteTemp()
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
        loadFolderFormats()
        loadLayouts()
        loadPreferences()
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
                pane.onKeyChordHandler = { [weak self] chord in self?.handleKeyChord(chord) ?? false }
                pane.onMouseGestureHandler = { [weak self] stroke in self?.handleGesture(stroke) ?? false }
                pane.onDragSessionHandler = { [weak self] event in self?.handleDragSession(event) }
                pane.onBrowseArchive = { [weak self, weak pane] archive in
                    guard let self, let pane else { return }
                    self.browseArchive(archive, in: pane, origin: pane.currentURL)
                }
                pane.onArchiveClosed = { [weak self] archive, mountRoot, snapshot in
                    self?.writeBackArchiveIfChanged(archive: archive, mountRoot: mountRoot, original: snapshot)
                }
                pane.onAttachDiskImage = { [weak self, weak pane] image in
                    self?.attachDiskImage(image, in: pane)
                }
                pane.resolveFormat = { [weak self] url in
                    self?.folderFormats.format(for: url.path) ?? self?.prefs.defaultFormat ?? .default
                }
                pane.hasExplicitFormat = { [weak self] url in self?.folderFormats.hasRule(for: url.path) ?? false }
                pane.backgroundFor = { [weak self] url in self?.folderBackgrounds.background(for: url.path) }
                pane.rememberFormat = { [weak self] url, format in self?.rememberFormat(url, format) }
                pane.openFile = { [weak self] url in self?.applyOpen(url) }
                pane.runCommand = { [weak self] id in self?.commands.perform(id) }
                pane.setPathBar(atBottom: self?.prefs.pathBarAtBottom ?? false)
                pane.showHiddenByDefault = self?.prefs.showHiddenByDefault ?? false
                pane.iconZoom = CGFloat(self?.prefs.iconZoom ?? 1)
                pane.onIconZoomChanged = { [weak self] scale in self?.rememberIconZoom(scale) }
                pane.onUploadFiles = { [weak self, weak pane] urls, connection, remotePath, password in
                    guard let self, let pane else { return }
                    self.uploadFiles(urls, to: connection, remotePath: remotePath, password: password, pane: pane)
                }
                pane.onOpenRemoteFile = { [weak self] connection, remotePath, password, name in
                    self?.openRemoteFile(connection, remotePath: remotePath, password: password, name: name)
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
            side.onPaneDirectoryDidChange = { [weak self] pane, url in self?.directoryChanged(pane, url) }
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
            side.onOpenFolderInPane = { [weak self] url, action in self?.handleBreadcrumbAction(url, action) }
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
        sidebar.onSelectSmart = { [weak self] query in self?.openSmart(query) }
        sidebar.onSelectSavedSearch = { [weak self] search in self?.runSavedSearch(search.name, query: search.mdfindQuery()) }
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
        sidebar.onApplyTag = { [weak self] urls, color in self?.applyTag(color, to: urls) }
        sidebar.onAirDrop = { [weak self] in
            let urls = self?.activePane?.selectedLocalURLs() ?? []
            guard !urls.isEmpty else { NSSound.beep(); return }  // nothing selected to send
            self?.airDrop(urls)
        }
        sidebar.onAirDropFiles = { [weak self] urls in self?.airDrop(urls) }
        sidebar.onNetwork = { [weak self] in self?.showNetworkView() }
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
        startDeviceWatch()
        applyPreferences()
    }

    private var deviceNameCache: [String: String] = [:]  // iOS udid -> friendly DeviceName

    /// Poll for USB-attached phones. iOS uses our native usbmux client (always available);
    /// Android uses adb when installed. The sidebar's Devices section updates on change.
    private func startDeviceWatch() {
        refreshDevices()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.refreshDevices()
        }
    }

    /// Stop the repeating device-poll timer (from teardown when the window closes).
    func stopDeviceTimer() {
        deviceTimer?.invalidate()
        deviceTimer = nil
    }

    private func refreshDevices() {
        Task { @MainActor in
            var devices = await DeviceDiscovery.androidDevices()
            for udid in DeviceDiscovery.iosUDIDs() {
                let name: String
                if let cached = self.deviceNameCache[udid] {
                    name = cached
                } else if let resolved = await AFCProvider.friendlyName(udid: udid) {
                    self.deviceNameCache[udid] = resolved  // cache only a real name
                    name = resolved
                } else {
                    name = L("bvc.iphoneFallback", "iPhone")  // not cached, so a later poll retries
                }
                devices.append(RemoteConnection(name: name, proto: .afc, host: udid, path: "/"))
            }
            self.sidebar.setDevices(devices)
        }
    }

    /// Register every browser action as a named command. This is the spine the
    /// keymap, command palette, and AI bar will all bind to (DESIGN.md 10).
    private static var macrosURL: URL? { appSupportDirectory()?.appendingPathComponent("macros.json") }
    static var savedSearchesURL: URL? { appSupportDirectory()?.appendingPathComponent("searches.json") }
    var viewPresets = ViewPresets.default

    static var folderBackgroundsURL: URL? { appSupportDirectory()?.appendingPathComponent("folder-backgrounds.json") }
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
                    id: macroID, title: String(format: L("bvc.macroCmdTitle", "Macro: %@"), macro.name), isEnabled: { true },
                    run: { [weak self] in
                        guard let self, !self.runningMacroIDs.contains(macroID) else { return }  // cycle guard
                        self.runningMacroIDs.insert(macroID)
                        defer { self.runningMacroIDs.remove(macroID) }
                        for id in ids { _ = self.commands.perform(id) }
                    }))
        }
    }


    /// Open the search-and-command overlay over the current window. `prefill` picks the
    /// opening mode: "" is search (Cmd-F), ">" is commands (Cmd-K); either way it's one
    /// widget and the prefix switches modes mid-flight. Chosen commands dispatch through
    /// the registry; search queries rank the active pane live.
    func showPalette(prefill: String = ">") {
        guard let window = view.window else { return }
        let items = commands.all.map { (id: $0.id, title: $0.title) }
        palette.present(
            commands: items,
            prefill: prefill,
            onRun: { [weak self] id in self?.commands.perform(id) },
            onNavigate: { [weak self] url in self?.activePane?.navigate(to: url) },
            onSemantic: { [weak self] query in self?.performSearch(query) },
            over: window)
    }

    /// Open the batch-rename sheet for the active pane's selection.
    func showBatchRename() {
        if blockedByRemoteOrSmart() { return }  // operates within one folder
        guard let window = view.window, let pane = activePane else { return }
        let names = pane.selectedEntries.map(\.name)
        guard !names.isEmpty else { NSSound.beep(); return }
        let existing = Set(pane.entries.map(\.name))
        batchRename.present(names: names, in: pane.currentURL, existing: existing, over: window) {
            [weak self] in self?.activePane?.reloadIfShowingListing()
        }
    }

    /// Select items in the active pane by a name pattern (glob / regex / substring),
    /// replacing, extending, or trimming the current selection.
    func selectByPattern() {
        guard let pane = activePane, let window = view.window else { NSSound.beep(); return }
        SelectByPatternSheet.present(over: window) { query, mode in
            pane.applySelection(query, mode: mode)
        }
    }

    // MARK: - New folder / Trash / Reveal

    /// Remote panes have no local file URLs, so file ops can't act there. Per-file
    /// ops (trash, rename, reveal, info, …) ARE allowed in cross-folder smart views
    /// because they resolve each item by its own folder (selectedLocalURLs). Returns
    /// true (and beeps) if blocked.
    func blockedByRemote() -> Bool {
        if activePane?.isRemote == true {
            activePane?.flashStatus(
                L("flash.notOnRemote", "That action isn’t available on a remote connection"), isError: true)
            return true
        }
        return false
    }

    /// Ops that need one destination folder (paste, new folder) can't run in a
    /// remote pane or a cross-folder smart-result view (there's no single "here").
    func blockedByRemoteOrSmart() -> Bool {
        if activePane?.isRemote == true {
            activePane?.flashStatus(
                L("flash.notOnRemote", "That action isn’t available on a remote connection"), isError: true)
            return true
        }
        if activePane?.isShowingSmartResults == true {
            activePane?.flashStatus(
                L("flash.notInSmartView", "That action needs a single folder, not a search view"), isError: true)
            return true
        }
        return false
    }

    /// Run a remote file operation off-main, refreshing the pane and reporting errors.
    func performRemoteOp(
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

    func renameSelection() {
        guard let pane = activePane, pane.selectedEntries.count == 1,
            let entry = pane.selectedEntries.first
        else { return }
        // Prefer Finder-style in-place editing (list view, local panes). Remote renames and views
        // that can't edit in place fall through to the sheet below.
        if !pane.isRemote, pane.beginInlineRename() { return }
        let alert = NSAlert()
        alert.messageText = String(format: L("bvc.renameTitle", "Rename “%@”"), entry.name)
        alert.addButton(withTitle: L("bvc.renameButton", "Rename"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = entry.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != entry.name else { return }
            if pane.isRemote {
                guard entry.rawName == nil else {
                    self.presentInfo(
                        L("bvc.cantRenameTitle", "Can’t rename this item"),
                        L("bvc.cantRenameBody", "Its name isn’t valid UTF-8, which remote operations don’t support yet."))
                    return
                }
                self.performRemoteOp(pane, verb: L("bvc.renameVerb", "Rename")) { provider, connection, path, password in
                    try await provider.rename(
                        connection, from: PaneController.joinRemote(path, entry.name),
                        to: PaneController.joinRemote(path, newName), password: password)
                }
                return
            }
            self.commitLocalRename(entry, to: newName, pane: pane)
        }
    }

    /// Perform a local rename (+ undo + reselect). Shared by the rename sheet and Finder-style
    /// in-place editing, so both take the same path.
    func commitLocalRename(_ entry: FileEntry, to newName: String, pane: PaneController) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else { return }
        // The file's real folder: its own location in a smart view, else current.
        let directory = entry.location.map { URL(fileURLWithPath: $0) } ?? pane.currentURL
        do {
            try FileOperations.rename(entry.name, to: trimmed, in: directory)
            registerRenameUndo(from: trimmed, to: entry.name, in: directory)
            pane.reloadIfShowingListing()
            pane.select(name: trimmed)
        } catch {
            presentFailures(
                [FileOperations.Failure(name: entry.name, reason: error.localizedDescription)],
                title: L("bvc.renameFailed", "Rename failed"))
        }
    }

    private func registerRenameUndo(from current: String, to original: String, in directory: URL) {
        let paths: Set<String> = [
            directory.appendingPathComponent(current).path, directory.appendingPathComponent(original).path,
        ]
        actionHistory.record(name: L("bvc.renameVerb", "Rename"), footprint: paths, undoFootprint: paths) {
            [weak self] in
            guard let self else { return }
            do {
                try FileOperations.rename(current, to: original, in: directory)
                self.reloadBothSides()
                self.paneShowing(directory)?.select(name: original)
                self.registerRenameUndo(from: original, to: current, in: directory)  // redo
            } catch {
                self.presentFailures(
                    [FileOperations.Failure(name: current, reason: error.localizedDescription)],
                    title: L("bvc.undoFailed", "Undo failed"))
            }
        }
    }

    func trashSelection() {
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
            // Remote delete is permanent (no Trash, no undo) — confirm explicitly, at the pointer.
            let host = pane.remoteContext?.connection.host ?? L("bvc.theServer", "the server")
            let message =
                entries.count == 1
                ? String(format: L("bvc.remoteDeleteOne", "Permanently delete this item on %@?"), host)
                : String(format: L("bvc.remoteDeleteMany", "Permanently delete %d items on %@?"), entries.count, host)
            let names = entries.map { ($0.name, $0.isDirectory) }
            Task { @MainActor in
                let choice = await self.cursorConfirm.ask(
                    message: message, info: L("bvc.cantBeUndone", "This can’t be undone."),
                    buttons: [L("common.delete", "Delete"), L("common.cancel", "Cancel")], over: self.view)
                guard choice == 0 else { return }
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
        guard prefs.confirmBeforeDelete, view.window != nil else {
            performLocalTrash(urls)
            return
        }
        Task { @MainActor in
            let choice = await cursorConfirm.ask(
                message: L("bvc.confirmTrashTitle", "Move the selected items to the Trash?"),
                info: L("bvc.confirmTrashBody", "You can put them back from the Trash."),
                buttons: [L("bvc.moveToTrashAction", "Move to Trash"), L("common.cancel", "Cancel")],
                over: view)
            if choice == 0 { self.performLocalTrash(urls) }
        }
    }

    /// Hand the given files to the system AirDrop sheet. The OS (sharingd) does the
    /// transfer, so this stays a plain UI handoff (no networking in our process).
    private func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else { NSSound.beep(); return }
        let sendable = urls.filter { $0.isFileURL }
        guard service.canPerform(withItems: sendable) else {
            presentInfo(
                L("bvc.airdropUnavailableTitle", "Can’t AirDrop these items"),
                L("bvc.airdropUnavailableBody", "AirDrop may be turned off, or these items can’t be sent."))
            return
        }
        service.perform(withItems: sendable)
    }

    func performLocalTrash(_ urls: [URL]) {
        let result = FileOperations.trash(urls: urls)
        reloadBothSides()  // the trashed files may have lived in either visible folder
        pruneSmartEntries(Set(result.trashed.map(\.original.path)))  // drop stale rows in smart views
        recordTrashOrigins(result.trashed)  // remember where each came from, for Put Back
        if !result.trashed.isEmpty { registerTrashUndo(result.trashed) }
        if !result.failures.isEmpty { presentFailures(result.failures, title: L("bvc.moveToTrashFailed", "Move to Trash failed")) }
    }

    // MARK: - Trash: home Trash location and selection state (ledger + commands in
    // BrowserViewController+TrashLedger.swift)

    /// Where each Pathem-trashed item came from (trashed path -> original path), so Put Back can
    /// restore it. Finder-trashed items aren't here (the OS keeps that info privately).
    var trashOrigins: [String: String] = [:]

    var homeTrashURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    }
    var trashHasItems: Bool {
        !((try? FileManager.default.contentsOfDirectory(atPath: homeTrashURL.path)) ?? []).isEmpty
    }
    /// True when the whole selection lives inside the Trash (so Put Back / Delete Immediately apply).
    var selectionIsInTrash: Bool {
        guard let pane = activePane, !pane.isRemote else { return false }
        let trashPrefix = homeTrashURL.path + "/"
        let selected = pane.selectedLocalURLs()
        return !selected.isEmpty && selected.allSatisfy { $0.path.hasPrefix(trashPrefix) }
    }

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

    /// Suggest a new name for the single selected file with the on-device model, prefilling a
    /// standard rename sheet. The sheet opens immediately (name preselected) and the suggestion
    /// fills in when it lands, so the model's latency never blocks the UI. Applying goes through
    /// the normal rename + undo path.
    func aiRenameSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            pane.selectedEntries.count == 1, let entry = pane.selectedEntries.first, !entry.isDirectory
        else { NSSound.beep(); return }
        guard AIAssistant.isAvailable else {
            presentInfo(L("ai.unavailableTitle", "On-device AI unavailable"), AIAssistant.availability.reason)
            return
        }
        let directory = entry.location.map { URL(fileURLWithPath: $0) } ?? pane.currentURL
        let url = directory.appendingPathComponent(entry.name)
        let ext = (entry.name as NSString).pathExtension

        let alert = NSAlert()
        alert.messageText = String(format: L("ai.renameTitle", "AI Rename “%@”"), entry.name)
        alert.informativeText = L("ai.renameHint", "Suggesting a name… you can edit it or type your own.")
        alert.addButton(withTitle: L("bvc.renameButton", "Rename"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = entry.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        // Fetch the suggestion concurrently and drop it into the field when it arrives.
        Task { @MainActor in
            let preview = await Task.detached { Self.textPreview(of: url) }.value
            guard let base = await AIAssistant.suggestName(currentName: entry.name, content: preview) else { return }
            guard field.window != nil else { return }  // sheet already dismissed
            field.stringValue = ext.isEmpty ? base : "\(base).\(ext)"
            field.selectText(nil)
        }

        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != entry.name else { return }
            do {
                try FileOperations.rename(entry.name, to: newName, in: directory)
                self.registerRenameUndo(from: newName, to: entry.name, in: directory)
                pane.reloadIfShowingListing()
                pane.select(name: newName)
            } catch {
                self.presentFailures(
                    [FileOperations.Failure(name: entry.name, reason: error.localizedDescription)],
                    title: L("bvc.renameFailed", "Rename failed"))
            }
        }
    }

    /// Summarize the current folder's contents with the on-device model, shown in the output panel.
    func aiSummarizeFolder() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        guard AIAssistant.isAvailable else {
            presentInfo(L("ai.unavailableTitle", "On-device AI unavailable"), AIAssistant.availability.reason)
            return
        }
        let folder = pane.currentURL
        let names = pane.entries.map(\.name)
        externalOutput.present(
            title: String(format: L("ai.summaryTitle", "Summary of %@"), folder.lastPathComponent),
            loading: L("ai.summarizing", "Summarizing…")
        ) {
            await AIAssistant.summarizeFolder(folderName: folder.lastPathComponent, itemNames: names)
                ?? L("ai.summaryFailed", "Couldn’t generate a summary.")
        }
    }

    /// A short text preview of a file for AI naming: up to 4 KB of a text-like file, else `nil`.
    /// Kept conservative (by extension) so we never read a huge binary into memory.
    nonisolated static func textPreview(of url: URL) -> String? {
        let textExtensions: Set<String> = [
            "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "log",
            "swift", "py", "js", "ts", "rb", "go", "rs", "c", "h", "cpp", "java", "sh",
            "html", "css", "rtf", "tex", "org", "ini", "toml", "conf",
        ]
        guard textExtensions.contains(url.pathExtension.lowercased()),
            let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return text
    }

    /// The folder a new window should open at: the active pane's folder when it's a local
    /// listing, otherwise Home (a remote/smart pane has no plain local folder to reopen).
    func newWindowStartFolder() -> URL {
        if let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults { return pane.currentURL }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Detach the active tab into its own window: open a new window at that folder and, if the
    /// side still has other tabs, close the one we moved (so nothing is duplicated in place).
    func moveActiveTabToNewWindow() {
        guard let side = activeSide, let pane = side.activePane, !pane.isRemote else { NSSound.beep(); return }
        WindowManager.shared.openWindow(start: pane.currentURL)
        if side.tabCount > 1 { side.closeActiveTab() }
    }

    // The floating quick-actions bar's scroll-follow bookkeeping and the auto-preview-pane
    // "did we show it" flag: physically interleaved stored state for
    // BrowserViewController+QuickActions.swift (extensions can't hold stored properties).
    var quickBarScrollObserver: NSObjectProtocol?
    weak var quickBarObservedClip: NSClipView?
    var previewAutoShown = false

    // MARK: - Organize with AI (typed plan; the model proposes, our code executes)

    func organizeWithAI() {
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
        Task { @MainActor in
            guard let instruction = await self.promptForName(
                title: L("ai.organize.title", "Organize with AI"), default: "group by file type")
            else { return }

            #if canImport(FoundationModels)
                if #available(macOS 26, *) {
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
            #endif
        }
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

    // MARK: - Organize Folder (deterministic rules; no model required)

    private var organizeReview: OrganizeReviewController?

    static var organizeFeedbackURL: URL? {
        appSupportDirectory()?.appendingPathComponent("organize-feedback.json")
    }

    /// Propose a rules-based organization for the active pane's folder and present the
    /// review sheet: every suggestion is a row the user can inspect, skip, or rate, and
    /// only the checked ones are applied (undoable, like every other local file op).
    func organizeFolder() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        guard let window = view.window else { return }
        let folder = pane.currentURL
        let destinations = FilingDestinations.defaults(home: FileManager.default.homeDirectoryForCurrentUser)
        let memory = Self.organizeFeedbackURL.map { OrganizeFeedback.load(from: $0) } ?? OrganizeFeedback()
        Task { @MainActor in
            let suggestions = await Task.detached {
                OrganizePlanner.suggestions(for: folder, destinations: destinations, memory: memory)
            }.value
            guard !suggestions.isEmpty else {
                self.presentInfo(
                    L("organize.none.title", "Nothing to organize"),
                    L("organize.none.body", "No suggestions for this folder (files you touched in the last day, and anything inside a git repo, are left alone)."))
                return
            }
            let review = OrganizeReviewController(
                feedbackURL: Self.organizeFeedbackURL ?? folder.appendingPathComponent(".pathem-feedback.json"))
            self.organizeReview = review  // retain while the sheet is up
            review.present(
                suggestions: suggestions, folderName: folder.lastPathComponent, destinations: destinations,
                over: window
            ) { [weak self] finalized in
                self?.organizeReview = nil
                self?.runOrganize(finalized)
            }
        }
    }

    /// Apply the accepted suggestions (apply filters to the checked ones), reload, and
    /// register undo, then report what happened.
    private func runOrganize(_ suggestions: [OrganizePlanner.Suggestion]) {
        // Record the user's accept/skip decision as behavioral signal (this is what the
        // planner learns from next time), whether or not anything is applied.
        if let url = Self.organizeFeedbackURL {
            OrganizeFeedback.record(
                suggestions.map {
                    .init(
                        ruleID: $0.ruleID, destination: $0.destination?.lastPathComponent,
                        ext: $0.file.pathExtension.lowercased(), verdict: $0.accepted ? .applied : .skipped)
                }, to: url)
        }
        guard suggestions.contains(where: \.accepted) else { return }  // user unchecked everything
        Task { @MainActor in
            let outcome = await Task.detached { OrganizePlanner.apply(suggestions) }.value
            self.reloadBothSides()
            if !outcome.performed.isEmpty {
                self.registerUndo(outcome.performed, actionName: L("organize.action", "Organize"))
            }
            if !outcome.trashedItems.isEmpty { self.registerTrashUndo(outcome.trashedItems) }
            self.presentInfo(
                L("organize.done.title", "Organized"),
                String(
                    format: L("organize.done.body", "Moved %d, trashed %d"), outcome.moved, outcome.trashed)
                    + (outcome.failures.isEmpty
                        ? ""
                        : String(
                            format: L("organize.done.skipped", ", %d skipped"), outcome.failures.count)))
        }
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
        NSWorkspace.shared.open([target], withApplicationAt: editor, configuration: config) { [weak self] _, error in
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

    func revealSelection() {
        if blockedByRemote() { return }
        guard let pane = activePane else { return }
        let urls = pane.selectedLocalURLs()  // location-aware (reveals the real file in smart views)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [pane.currentURL] : urls)
    }

    /// Reveal the selection in place: navigate the active pane to the file's real folder and
    /// select it there, instead of handing off to Finder. Most useful from search and smart
    /// views, where the file lives outside the folder currently on screen.
    func revealSelectionInPathem() {
        if blockedByRemote() { return }
        guard let pane = activePane, let target = pane.selectedLocalURLs().first else { return }
        pane.reveal(target)
    }

    /// Jump to the original of a selected alias or symlink: resolve its target and reveal it
    /// (navigate to the target's folder and select it), like Finder's Show Original.
    func showOriginal() {
        guard let pane = activePane, !pane.isRemote, let url = pane.selectedLocalURLs().first else { NSSound.beep(); return }
        guard let target = Self.resolveOriginal(of: url) else {
            presentInfo(
                L("bvc.showOriginalNoneTitle", "No original to show"),
                L("bvc.showOriginalNoneBody", "This item isn’t an alias or symlink, or its original can’t be found (it may have been moved or deleted)."))
            return
        }
        pane.reveal(target)
    }

    /// Resolve an alias file or symlink to its target URL, or nil if it's neither (or unresolvable).
    static func resolveOriginal(of url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
        if values?.isAliasFile == true {
            return try? URL(resolvingAliasFileAt: url, options: [])
        }
        if values?.isSymbolicLink == true {
            let resolved = url.resolvingSymlinksInPath()
            return resolved.path == url.path ? nil : resolved
        }
        return nil
    }

    /// Get Info on the selection, or on the current folder when nothing is selected.
    func showInfo() {
        if blockedByRemote() { return }
        guard let pane = activePane else { return }
        let selected = pane.selectedLocalURLs()  // location-aware
        let urls = selected.isEmpty ? [pane.currentURL] : selected
        if prefs.useFinderGetInfo {
            Self.openFinderGetInfo(urls)
        } else {
            infoInspector.present(urls: urls, over: view.window)
        }
    }

    /// Open Finder's own Get Info window for each URL (the optional default-app path).
    private static func openFinderGetInfo(_ urls: [URL]) {
        let items = urls.map { "POSIX file \"\($0.path.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            .joined(separator: ", ")
        let script = """
            tell application "Finder"
                activate
                open information window of every item of {\(items)}
            end tell
            """
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
        }
    }

    /// Pull down online-only (dataless) cloud files. The provider materializes
    /// them; the watcher refreshes the badge as they land.
    func downloadSelection() {
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
        // The Edit menu's Undo/Redo reflect the file-op history -- unless a text field is being
        // edited, in which case its own field-editor undo drives them.
        if menuItem.action == Selector(("undo:")) {
            if isEditingText { menuItem.title = L("menu.undo", "Undo"); return view.window?.undoManager?.canUndo ?? false }
            menuItem.title = actionHistory.undoActionName.map { String(format: L("menu.undoNamed", "Undo %@"), $0) } ?? L("menu.undo", "Undo")
            return actionHistory.canUndo
        }
        if menuItem.action == Selector(("redo:")) {
            if isEditingText { menuItem.title = L("menu.redo", "Redo"); return view.window?.undoManager?.canRedo ?? false }
            menuItem.title = actionHistory.redoActionName.map { String(format: L("menu.redoNamed", "Redo %@"), $0) } ?? L("menu.redo", "Redo")
            return actionHistory.canRedo
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
        case "view.asTree": menuItem.state = activePane?.viewMode == .tree ? .on : .off
        case "nav.vimMode": menuItem.state = vimMode ? .on : .off
        case "view.arrangeNone": menuItem.state = (activePane?.groupKey ?? .none) == .none ? .on : .off
        case "view.arrangeKind": menuItem.state = activePane?.groupKey == .kind ? .on : .off
        case "view.arrangeSize": menuItem.state = activePane?.groupKey == .size ? .on : .off
        case "view.arrangeDate": menuItem.state = activePane?.groupKey == .dateModified ? .on : .off
        case "view.arrangeTag": menuItem.state = activePane?.groupKey == .tag ? .on : .off
        case "view.fullPathTitle": menuItem.state = prefs.showFullPathInTitle ? .on : .off
        case "view.pathBarBottom": menuItem.state = prefs.pathBarAtBottom ? .on : .off
        case "view.demoMode": menuItem.state = isDemoMode ? .on : .off
        case "view.calculateSizes": menuItem.state = prefs.calculateFolderSizes ? .on : .off
        case "view.syncBrowsing": menuItem.state = syncBrowsing ? .on : .off
        case "view.compactSidebar": menuItem.state = prefs.compactSidebar ? .on : .off
        case "view.previewPane": menuItem.state = previewVisible ? .on : .off
        case "shelf.toggle":
            menuItem.state = shelf.view.isHidden ? .off : .on
            menuItem.title = shelf.view.isHidden ? L("bvc.showShelf", "Show Shelf") : L("bvc.hideShelf", "Hide Shelf")
        case "connections.newTabToggle": menuItem.state = prefs.openConnectionsInNewTab ? .on : .off
        case "files.newFolderWithSelection":
            menuItem.title = FileContextMenuController.newFolderWithSelectionTitle(
                count: activePane?.selectedEntries.count ?? 0)
        default: break
        }
        return commands.command(id)?.isEnabled() ?? true
    }

    // MARK: - Preferences

    static var preferencesURL: URL? {
        appSupportDirectory()?.appendingPathComponent("prefs.json")
    }

    /// Open the natural-language command bar.
    func showAICommandBar() {
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
            "This removes all Pathem settings, saved connections and their Keychain passwords, sidebar and menu customization, color rules, and layouts, and restores Finder as the default folder app. Your files are not touched. Pathem then quits, so you can drag it to the Trash for a clean uninstall.")
        alert.alertStyle = .warning
        // Off by default = a full clean uninstall. Checked keeps the config/passwords in place
        // so a reinstall picks up where you left off; only the folder default is restored.
        let keepData = NSButton(
            checkboxWithTitle: L("bvc.resetKeepData", "Keep my Pathem settings and data (for a future reinstall)"),
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
                if let dir = Self.appSupportDirectory() { try? FileManager.default.removeItem(at: dir) }
                KeychainStore.removeAll()
                if let bundleID = Bundle.main.bundleIdentifier {
                    UserDefaults.standard.removePersistentDomain(forName: bundleID)
                }
                persistsSession = false  // don't re-save a session into the just-removed folder
            }
            _ = window

            // A closing note on how to finish removing Pathem: the two leftovers Reset can't
            // handle for you (the app bundle itself, and the system Full Disk Access grant).
            let removed = keep
                ? L("bvc.resetKept", "Your settings and data were kept")
                : L("bvc.resetRemoved", "Your settings, saved passwords, and customization were removed")
            let done = NSAlert()
            done.messageText = L("bvc.resetDoneTitle", "Pathem Data Reset")
            done.informativeText = String(
                format: L(
                    "bvc.resetDoneBody",
                    "%@%@.\n\nTo finish uninstalling:\n1. Drag Pathem from Applications to the Trash.\n2. Optionally remove Pathem under System Settings ▸ Privacy & Security ▸ Full Disk Access. macOS keeps that grant until you clear it."),
                removed,
                wasFolderHandler ? L("bvc.resetFinderRestored", ", and Finder is again the default for folders") : "")
            done.addButton(withTitle: L("bvc.resetDoneQuit", "Quit Pathem"))
            _ = await self.presentSheet(done)
            NSApp.terminate(nil)
        }
    }

    /// Decode config from `url`. A missing file returns nil (use defaults). A
    /// present-but-undecodable file (corrupt, hand-edit typo, newer schema) is
    /// moved aside to <name>.corrupt and returns nil, so the next save cannot
    /// silently overwrite and destroy still-recoverable config.
    func loadConfig<T: Decodable>(_ type: T.Type, from url: URL?) -> T? {
        ConfigStore.load(type, from: url)
    }

    func saveConfig<T: Encodable>(_ value: T, to url: URL?) {
        ConfigStore.save(value, to: url)
    }

    // MARK: - Layouts

    private static var layoutsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("layouts.json")
    }

    private func loadLayouts() {
        if let saved = loadConfig(Layouts.self, from: Self.layoutsURL) { layouts = saved }
    }

    func saveLayouts() {
        saveConfig(layouts, to: Self.layoutsURL)
    }

    // MARK: - Customizable sidebar

    private static var sidebarURL: URL? {
        appSupportDirectory()?.appendingPathComponent("sidebar.json")
    }

    /// Add Finder's own sidebar favorites to ours (the folders you already keep there), skipping any
    /// we already have. Reads Finder's LSSharedFileList file; nothing is removed, so running it
    /// twice is harmless.
    func importFinderFavorites() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let found = FinderFavorites.folders()
        guard !found.isEmpty else {
            presentInfo(
                L("sidebar.importNoneTitle", "No Finder favorites found"),
                L(
                    "sidebar.importNoneBody",
                    "Pathem couldn’t read Finder’s sidebar favorites, or none of them point at folders that still exist."
                ))
            return
        }
        var model = sidebar.model
        if model.groups.isEmpty {
            model.groups = [Sidebar.Group(title: L("sidebar.favoritesDefaultName", "Favorites"), items: [])]
        }
        let existing = Set(model.groups.flatMap(\.items).map { ($0.path as NSString).standardizingPath })
        var added = 0
        for url in found {
            let path = (url.path as NSString).standardizingPath
            guard !existing.contains(path) else { continue }  // already in the sidebar: leave it alone
            model.groups[0].items.append(
                Sidebar.Item(
                    name: url.lastPathComponent, icon: Sidebar.suggestedIcon(for: url, home: home),
                    path: url.path))
            added += 1
        }
        guard added > 0 else {
            presentInfo(
                L("sidebar.importAllPresentTitle", "Nothing new to import"),
                L("sidebar.importAllPresentBody", "Every Finder favorite is already in your sidebar."))
            return
        }
        sidebar.model = model  // rebuilds the sidebar; it does not persist on its own
        saveSidebar(model)
        presentInfo(
            String(format: L("sidebar.importedTitle", "Imported %d favorite(s)"), added),
            L("sidebar.importedBody", "They were added to your Favorites. Drag to reorder or rename them."))
    }

    private func loadSidebar() {
        if let demoLayout {  // fake favorites/cloud/volumes; no real accounts, hosts, or paths
            applyDemoSidebar(demoLayout)
            return
        }
        if let saved = loadConfig(Sidebar.self, from: Self.sidebarURL) {
            sidebar.model = saved
        } else {
            sidebar.model = .makeDefault(home: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    private func applyDemoSidebar(_ layout: DemoWorkspace.Layout) {
        sidebar.demoMode = true
        sidebar.demoCloud = layout.cloud
        sidebar.demoVolumes = layout.volumes
        sidebar.model = Sidebar(groups: [
            Sidebar.Group(
                title: L("sidebar.favoritesDefaultName", "Favorites"),
                items: layout.favorites.map { Sidebar.Item(name: $0.name, icon: $0.icon, path: $0.url.path) })
        ])
        BreadcrumbBar.demoRoot = layout.root  // clean "Home ▸ …" path, hiding the temp prefix
    }

    var isDemoMode: Bool { demoLayout != nil }

    /// Toggle privacy-safe demo mode from the View menu, live (no relaunch).
    func toggleDemoMode() {
        if demoLayout == nil {
            savedRealSidebar = sidebar.model
            savedPaneFolders = (leftTabs.activePane?.currentURL, rightTabs.activePane?.currentURL)
            let layout = DemoWorkspace.build()
            demoLayout = layout
            applyDemoSidebar(layout)
            // resetHistory, not navigate: keep the throwaway temp path out of Back, and
            // don't leave the user's real folder reachable via Back during a privacy demo.
            leftTabs.activePane?.resetHistory(to: layout.leftStart)
            rightTabs.activePane?.resetHistory(to: layout.rightStart)
        } else {
            demoLayout = nil
            sidebar.demoMode = false
            sidebar.demoCloud = []
            sidebar.demoVolumes = []
            BreadcrumbBar.demoRoot = nil
            sidebar.model = savedRealSidebar ?? .makeDefault(home: FileManager.default.homeDirectoryForCurrentUser)
            // resetHistory so the (about-to-be-deleted) demo temp path can't be reached
            // via Back after we leave demo mode.
            if let url = savedPaneFolders?.left { leftTabs.activePane?.resetHistory(to: url) }
            if let url = savedPaneFolders?.right { rightTabs.activePane?.resetHistory(to: url) }
        }
    }

    private func saveSidebar(_ model: Sidebar) {
        saveConfig(model, to: Self.sidebarURL)
    }


    // MARK: - Terminal theme

    static var terminalThemeURL: URL? {
        appSupportDirectory()?.appendingPathComponent("terminal.json")
    }

    private func loadTerminalTheme() {
        if let saved = loadConfig(TerminalTheme.self, from: Self.terminalThemeURL) {
            terminal.theme = saved
        }
    }

    // MARK: - Window state (session, workspaces, styles)

    private static var automationRulesURL: URL? {
        appSupportDirectory()?.appendingPathComponent("automation-rules.json")
    }

    /// Reopen the last session's tabs/folders, or open initial tabs if none.
    private func restoreSession() {
        isRestoringSession = true
        defer { isRestoringSession = false }
        if demoLayout != nil {  // demo mode: fresh tabs on the fake workspace, never the real session
            // Open the tabs on the run loop, not synchronously in viewDidLoad (early navigation
            // deadlocks Launch Services); demo sessions are never persisted.
            DispatchQueue.main.async { [self] in
                leftTabs.openInitialTab()
                rightTabs.openInitialTab()
                if let pane = leftTabs.activePane { setActiveSide(leftTabs, pane: pane) }
            }
            return
        }
        if persistsSession, let session = windowState.loadSession(),
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
        guard persistsSession, !isRestoringSession else { return }
        windowState.scheduleSessionSave { [weak self] in self?.captureSession() }
    }

    /// Persist the session immediately (called on quit).
    func saveSessionNow() {
        guard persistsSession else { return }
        guard let state = captureSession() else { return }
        windowState.saveSession(state)
    }

    /// The current dual-pane, multi-tab layout as a Session, or nil in demo mode (which is
    /// never persisted over the real session).
    private func captureSession() -> WindowStateStore.Session? {
        guard demoLayout == nil else { return nil }
        return WindowStateStore.Session(
            left: leftTabs.tabFolders, leftActive: leftTabs.activeTabIndex,
            right: rightTabs.tabFolders, rightActive: rightTabs.activeTabIndex,
            leftIsActive: activeSide === leftTabs)
    }

    /// Edit the selected item's POSIX ACL (add/remove access-control entries).
    func editACLSelection() {
        guard let pane = activePane, !pane.isRemote, let url = pane.selectedLocalURLs().first else { NSSound.beep(); return }
        aclEditor.present(url: url, over: view.window)
    }

    /// Change the owner of the selection. Because giving a file to another user needs root, Pathem
    /// types a ready-to-run `sudo chown` command into the embedded terminal (which prompts for the
    /// password) rather than bundling a privileged helper. Changing only the group is done without
    /// root via Set Attributes ▸ Group.
    func changeOwnerViaTerminal() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let currentOwner = OwnershipEditor.read(urls[0])?.owner ?? ""

        let alert = NSAlert()
        alert.messageText = String(format: L("chown.title", "Change owner of %d item(s)"), urls.count)
        alert.informativeText = L(
            "chown.hint",
            "Changing the owner needs administrator rights, so Pathem will type a sudo command into the terminal. Review it and press Return to run it. (To change only the group, use Set Attributes.)")
        alert.addButton(withTitle: L("chown.prepare", "Prepare in Terminal"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))

        let ownerField = NSTextField(string: currentOwner)
        ownerField.placeholderString = L("chown.owner", "new owner (user)")
        let groupField = NSTextField()
        groupField.placeholderString = L("chown.group", "group (optional)")
        let recursive = NSButton(checkboxWithTitle: L("chown.recursive", "Apply to folder contents (-R)"), target: nil, action: nil)
        let fields = NSStackView(views: [ownerField, groupField, recursive])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 84)
        ownerField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        groupField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        alert.accessoryView = fields
        alert.window.initialFirstResponder = ownerField

        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            let command = OwnershipEditor.sudoChownCommand(
                owner: ownerField.stringValue, group: groupField.stringValue,
                recursive: recursive.state == .on, paths: urls.map(\.path))
            guard !command.isEmpty else { NSSound.beep(); return }
            if self.terminal.view.isHidden { self.toggleTerminal() }  // reveal the terminal
            self.terminal.typeCommand(command, in: self.activePane?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser)
            self.terminal.focus()
        }
    }

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
        applyInitialSplitPositions()
        // Focus the restored active pane, not always the left one.
        let focusPane = activePane ?? activeSide?.activePane ?? leftTabs.activePane
        view.window?.makeFirstResponder(focusPane?.keyView)
        updateWindowTitle()
        maybePromptFullDiskAccess()
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
        updateWindowTitle()
        updateSearchButton(query: pane.searchQuery)  // show the focused pane's own query
        // Note: the query is cleared on navigation (onDidNavigate), not on every
        // focus change, so a live query or visible results survive a pane re-focus.
        if pane.currentURL != semanticSearch.cachedDirectory { preIndex(pane.currentURL) }
        syncAutoPreview()  // follow the newly active pane's view mode + selection
        updateQuickActions()  // the quick-actions bar follows the active pane's selection
        saveSessionSoon()
    }

    /// Copy (or move) the active pane's selection into the other pane's folder.
    /// If names already exist there, ask how to resolve (replace, keep both, or
    /// skip), then register an undo for whatever was performed (DESIGN.md §6.5).
    /// Copy or move files dropped onto a pane into its folder, reusing the same
    /// off-main progress + undo path as the transfer commands.
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

    /// After a drop lands, select and scroll to the items in whichever pane is showing the
    /// destination folder, so you actually see where they landed (a plain reload keeps the old scroll,
    /// leaving a new item stranded off-screen -- the "the drop didn't do anything" bug).
    private func revealDropped(_ performed: [FileOperations.Performed], into destination: URL) {
        let names = performed.map { $0.destination.lastPathComponent }.sorted()
        guard let first = names.first else { return }
        let dest = destination.standardizedFileURL
        for side in [leftTabs, rightTabs] {
            if let pane = side.activePane, pane.currentURL.standardizedFileURL == dest {
                pane.select(name: first)
            }
        }
    }

    /// The dragged items + target file for a file-onto-file drop, held while its menu is open.
    var pendingDropContext: (dragged: [URL], target: URL)?

    func dropFiles(_ allURLs: [URL], move: Bool, into destination: URL) {
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
        resolveThenTransfer(urls: urls, into: destination, move: move, conflictCount: conflicts.count) { [weak self] outcome in
            guard let self else { return }
            self.leftTabs.activePane?.reloadIfShowingListing()
            self.rightTabs.activePane?.reloadIfShowingListing()
            self.revealDropped(outcome.performed, into: destination)  // select + scroll to what landed
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

    /// The single selected local file/folder eligible for Open in Other Pane (a folder to browse
    /// to, or a PDF/image to view in place), when there is an other pane. Nil disables the command.
    func openInOtherPaneTarget() -> URL? {
        guard otherPane != nil, let url = activePane?.singleSelectedURL else { return nil }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return (isDir || DocumentPreviewView.isViewable(url)) ? url : nil
    }

    /// Open the selection in the other pane: navigate there for a folder, or show a document viewer
    /// (PDF/image) so the dual-pane becomes files-on-one-side, live-document-on-the-other.
    func openInOtherPane() {
        guard let other = otherPane, let url = openInOtherPaneTarget() else { NSSound.beep(); return }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDir {
            other.navigate(to: url)
        } else {
            other.presentViewer(url)
        }
    }

    func transfer(move: Bool) {
        if blockedByRemote() { return }
        guard !transferInFlight else { NSSound.beep(); return }  // don't prompt for a refused op
        guard let source = activePane, let activeSide else { return }
        let otherSide = (activeSide === leftTabs) ? rightTabs : leftTabs
        guard let destination = otherSide.activePane else { NSSound.beep(); return }
        let urls = source.selectedLocalURLs()  // location-aware: sources may span folders (smart view)
        guard !urls.isEmpty else { NSSound.beep(); return }

        let destinationURL = destination.currentURL
        let conflicts = FileOperations.conflicts(urls: urls, into: destinationURL)
        resolveThenTransfer(urls: urls, into: destinationURL, move: move, conflictCount: conflicts.count) {
            [weak self] outcome in
            guard let self else { return }
            if move { source.reloadIfShowingListing() }
            destination.reloadIfShowingListing()
            self.revealDropped(outcome.performed, into: destinationURL)  // reveal what landed
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

    // MARK: - Copy To / Move To (arbitrary destination + recents)

    private static var recentDestinationsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("recent-destinations.json")
    }

    private func loadRecentDestinations() {
        recentDestinations = (loadConfig([String].self, from: Self.recentDestinationsURL) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }  // drop folders that went away
        registerRecentDestinationCommands()
    }

    /// One palette command per recent destination, for each of copy and move, so a repeated
    /// "Copy To that place again" is a single palette pick. Rebuilt whenever the list changes.
    private func registerRecentDestinationCommands() {
        for command in commands.all where command.id.hasPrefix("dest.recent.") {
            commands.unregister(command.id)
        }
        for (index, path) in recentDestinations.enumerated() {
            let name = (path as NSString).lastPathComponent
            let hasSel: () -> Bool = { [weak self] in self?.activePane?.selectedEntries.isEmpty == false }
            commands.register(
                .init(id: "dest.recent.copy.\(index)", title: String(format: L("bvc.copyToRecent", "Copy To: %@"), name), isEnabled: hasSel) {
                    [weak self] in self?.transferSelection(to: URL(fileURLWithPath: path), move: false)
                })
            commands.register(
                .init(id: "dest.recent.move.\(index)", title: String(format: L("bvc.moveToRecent", "Move To: %@"), name), isEnabled: hasSel) {
                    [weak self] in self?.transferSelection(to: URL(fileURLWithPath: path), move: true)
                })
        }
    }

    /// Prompt for a folder (starting at the most recent destination) and copy or move the
    /// active selection there.
    func copyOrMoveTo(move: Bool) {
        guard let pane = activePane, !pane.isRemote, let window = view.window else { NSSound.beep(); return }
        guard !pane.selectedLocalURLs().isEmpty else { NSSound.beep(); return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.prompt = move ? L("dest.moveHere", "Move Here") : L("dest.copyHere", "Copy Here")
        picker.message =
            move
            ? L("dest.moveMessage", "Choose a folder to move the selection into")
            : L("dest.copyMessage", "Choose a folder to copy the selection into")
        if let recent = recentDestinations.first { picker.directoryURL = URL(fileURLWithPath: recent) }
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = picker.url, let self else { return }
            self.transferSelection(to: destination, move: move)
        }
    }

    /// Copy or move the active selection into `destination` (off-main, with the standard
    /// conflict prompt, progress sheet, and undo), then remember the destination.
    private func transferSelection(to destination: URL, move: Bool) {
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        // Copying/moving into a folder that's already the parent is a no-op; also refuse
        // moving a folder into itself or its own subtree.
        let destPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        if urls.contains(where: {
            let p = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return destPath == p || destPath.hasPrefix(p + "/")
        }) {
            presentInfo(
                L("dest.invalidTitle", "Can’t put a folder inside itself"),
                L("dest.invalidBody", "Choose a destination that isn’t one of the selected folders or inside them."))
            return
        }

        let conflicts = FileOperations.conflicts(urls: urls, into: destination)
        resolveThenTransfer(urls: urls, into: destination, move: move, conflictCount: conflicts.count) { [weak self] outcome in
            guard let self else { return }
            self.reloadBothSides()
            if move { self.pruneSmartEntries(Set(outcome.performed.map(\.source.path))) }
            if !outcome.performed.isEmpty {
                self.registerUndo(
                    outcome.performed, actionName: move ? L("bvc.moveAction", "Move") : L("bvc.copyAction", "Copy"))
                self.recordDestination(destination)
            }
            if !outcome.failures.isEmpty {
                self.presentFailures(
                    outcome.failures,
                    title: move ? L("bvc.moveFailed", "Move failed") : L("bvc.copyFailed", "Copy failed"))
            }
        }
    }

    private func recordDestination(_ url: URL) {
        recentDestinations = RecentDestinations.recording(url.path, into: recentDestinations)
        saveConfig(recentDestinations, to: Self.recentDestinationsURL)
        registerRecentDestinationCommands()
    }

    /// Run a copy/move off the main thread with a deferred progress sheet (so the
    /// window never freezes and quick ops never flash a sheet), then hand the
    /// outcome back on the main actor. One transfer at a time.
    func runTransfer(
        urls: [URL], into destination: URL, move: Bool,
        resolution: FileOperations.ConflictResolution,
        completion: @escaping (FileOperations.Outcome) -> Void
    ) {
        guard !transferInFlight else { NSSound.beep(); return }  // one transfer at a time
        // Central backstop: never copy/move a folder into itself or its own subtree. Every entry
        // point funnels through here (drop, F5/F6, clipboard paste, shelf), so guarding once
        // covers them all -- a folder dropped into its own descendant would otherwise recurse and
        // duplicate the tree into itself until the path length blows up.
        let urls = Self.dropSelfContaining(urls, destination: destination)
        guard !urls.isEmpty else {
            NSSound.beep()
            presentInfo(
                L("bvc.selfCopyTitle", "Can’t put a folder inside itself"),
                L("bvc.selfCopyBody", "A folder can’t be copied or moved into itself or one of its own subfolders."))
            return
        }
        transferInFlight = true  // so Quit warns mid-transfer
        transferRunner.run(
            urls: urls, into: destination, move: move, resolution: resolution,
            verify: !move && prefs.verifyCopies, over: view.window
        ) { [weak self] outcome in
            self?.transferInFlight = false
            completion(outcome)
        }
    }

    /// Drop any source that is the destination folder itself or an ancestor of it, so a transfer
    /// can never nest a folder inside its own subtree. Symlink-resolved and case-insensitive
    /// (the same comparison dropFiles used, hoisted here to cover every caller).
    static func dropSelfContaining(_ urls: [URL], destination: URL) -> [URL] {
        let destPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        return urls.filter {
            let src = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return destPath.compare(src, options: .caseInsensitive) != .orderedSame
                && !destPath.lowercased().hasPrefix(src.lowercased() + "/")
        }
    }

    func askConflictResolution(conflictCount: Int, move: Bool) async
        -> FileOperations.ConflictResolution?
    {
        let message =
            conflictCount == 1
            ? L("bvc.conflictOne", "1 item already exists at the destination")
            : String(format: L("bvc.conflictMany", "%d items already exist at the destination"), conflictCount)
        let info = String(
            format: L("bvc.conflictHandle", "Choose how to handle the %@."),
            move ? L("bvc.moveNoun", "move") : L("bvc.copyNoun", "copy"))
        // A popover at the pointer, near the drop -- not a sheet at the title bar.
        let choice = await cursorConfirm.ask(
            message: message, info: info,
            buttons: [
                L("bvc.replace", "Replace"), L("bvc.keepBoth", "Keep Both"),
                L("bvc.skip", "Skip"), L("common.cancel", "Cancel"),
            ], over: view)
        switch choice {
        case 0: return .replace
        case 1: return .keepBoth
        case 2: return .skip
        default: return nil
        }
    }

    /// Ask how to resolve the `conflictCount` conflicts (if any), then run the transfer --
    /// centralizing the conflict prompt so the transfer flows don't each repeat the
    /// ask-then-run dance. With no conflicts the resolution is moot, so it runs straight away.
    func resolveThenTransfer(
        urls: [URL], into destination: URL, move: Bool, conflictCount: Int,
        completion: @escaping (FileOperations.Outcome) -> Void
    ) {
        func run(_ resolution: FileOperations.ConflictResolution) {
            runTransfer(
                urls: urls, into: destination, move: move, resolution: resolution, completion: completion)
        }
        guard conflictCount > 0 else { return run(.skip) }
        // A non-Ask default (Settings > General) skips the prompt and resolves automatically.
        if let preset = prefs.conflictDefault.resolution { return run(preset) }
        Task { @MainActor in
            guard let chosen = await askConflictResolution(conflictCount: conflictCount, move: move) else {
                return  // user cancelled
            }
            run(chosen)
        }
    }

    func registerUndo(_ performed: [FileOperations.Performed], actionName: String) {
        let paths = Self.paths(of: performed)
        actionHistory.record(name: actionName, footprint: paths, undoFootprint: paths) { [weak self] in
            guard let self else { return }
            let result = FileOperations.undo(performed)
            self.reloadBothSides()
            if !result.failures.isEmpty { self.presentFailures(result.failures, title: L("bvc.undoFailed", "Undo failed")) }
            self.registerTransferRedo(performed, actionName: actionName)  // wire up redo
        }
    }

    private func registerTransferRedo(_ performed: [FileOperations.Performed], actionName: String) {
        let paths = Self.paths(of: performed)
        actionHistory.record(name: actionName, footprint: paths, undoFootprint: paths) { [weak self] in
            guard let self else { return }
            let result = FileOperations.redo(performed)
            self.reloadBothSides()
            if !result.failures.isEmpty { self.presentFailures(result.failures, title: L("bvc.redoFailed", "Redo failed")) }
            // Re-register undo for exactly what redo re-applied, with the fresh trash locations
            // redo recorded for any Replace. Using the stale original list would trash the wrong
            // file on the next undo when a replace was involved or an op failed.
            if !result.performed.isEmpty { self.registerUndo(result.performed, actionName: actionName) }
        }
    }

    /// A focused text field (inline rename) owns its own undo via the window's field editor;
    /// let it undo text first, else undo a file operation from the history.
    var isEditingText: Bool { view.window?.firstResponder is NSText }

    @objc func undo(_ sender: Any?) {
        if isEditingText, let um = view.window?.undoManager, um.canUndo { um.undo(); return }
        guard actionHistory.canUndo else { NSSound.beep(); return }
        actionHistory.undo()
    }

    @objc func redo(_ sender: Any?) {
        if isEditingText, let um = view.window?.undoManager, um.canRedo { um.redo(); return }
        guard actionHistory.canRedo else { NSSound.beep(); return }
        actionHistory.redo()
    }

    /// Open the recent-actions panel (Undo History) over the file-operation history.
    func showUndoHistory() {
        guard let window = view.window else { return }
        undoHistoryController.present(over: window, history: actionHistory)
    }

    /// Open the "find files everywhere" palette; revealing a result navigates the active pane to
    /// its folder and selects it.
    func showGlobalSearch() {
        guard let window = view.window else { return }
        let folder = activePane.map { !$0.isRemote ? $0.currentURL : nil } ?? nil
        globalSearchController.present(
            over: window, currentFolder: folder ?? FileManager.default.homeDirectoryForCurrentUser
        ) { [weak self] url in
            guard let pane = self?.activePane else { return }
            pane.navigate(to: url.deletingLastPathComponent())
            pane.select(name: url.lastPathComponent)
        }
    }

    // MARK: - Semantic search (on-device, free)

    /// Re-rank the active pane's folder by semantic similarity to the query.
    /// An empty query restores the normal directory listing. All embedding runs
    /// off the main thread, so the UI never blocks. Fed live (debounced) by the
    /// overlay's search mode.
    func performSearch(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pane = activePane else { return }
        guard !pane.isRemote, !pane.isShowingSmartResults, pane.viewMode != .column else {
            if !query.isEmpty { NSSound.beep() }  // search needs a single local list
            return
        }
        pane.searchQuery = query  // remember per pane so the toolbar button resyncs on focus change
        updateSearchButton(query: query)
        guard !query.isEmpty else {
            if pane.isShowingSearchResults { pane.reload() }  // cleared search, restore the listing
            return
        }
        let directory = pane.currentURL
        Task { [weak self] in
            guard let self else { return }
            let ranked = await self.semanticSearch.rank(
                query: query, in: directory,
                isCurrent: { [weak self] in self?.activePane?.currentURL == directory })
            // Only adopt results if the very pane we searched is still active, on that folder,
            // AND still on this query. Without the query check, a debounced search whose text was
            // then cleared or changed would land stale results over the restored listing.
            guard let ranked, self.activePane === pane, pane.currentURL == directory,
                pane.searchQuery == query
            else { return }
            pane.showResults(ranked)
        }
    }

    @objc private func searchButtonTapped() { showPalette(prefill: "") }

    /// Reflect the active pane's query on the toolbar button (its title doubles as the
    /// visible search state, since the overlay itself is transient).
    func updateSearchButton(query: String) {
        searchButton.title = " " + (query.isEmpty ? L("bvc.searchPlaceholder", "Search") : query)
        searchButton.contentTintColor = query.isEmpty ? .secondaryLabelColor : .controlAccentColor
    }

    private var reindexWork: DispatchWorkItem?
    /// Rebuild the semantic index after ~1s of no further disk changes, so a stream of watcher
    /// ticks (a copy or unzip into the folder) collapses into a single rebuild once it settles.
    private func scheduleReindex(_ url: URL) {
        reindexWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.activePane?.currentURL == url else { return }
            self.preIndex(url)
        }
        reindexWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Build the semantic index for `directory` in the background (if not already
    /// cached for it), so the next search there is instant.
    func preIndex(_ directory: URL) {
        semanticSearch.preIndex(
            directory, isCurrent: { [weak self] in self?.activePane?.currentURL == directory })
    }

    /// A pane's folder changed (navigation or on-disk edit): drop a stale cache
    /// for it, and rebuild in the background if it is the active pane.
    private func directoryChanged(_ pane: PaneController, _ url: URL) {
        // A disk edit to the folder we've already indexed (vs a navigation to a new one) means
        // the index is stale. Drop it, but rebuild only after the churn settles: a long copy into
        // this folder fires a watcher tick per file, and re-embedding up to 5000 items on each
        // would thrash the CPU. A navigation to a fresh folder still indexes eagerly.
        let editedIndexedFolder = semanticSearch.cachedDirectory == url
        if editedIndexedFolder { semanticSearch.invalidate() }
        if pane === activePane {
            if editedIndexedFolder { scheduleReindex(url) } else { preIndex(url) }
            updateWindowTitle()
            // The terminal follows the active folder only when the user opted in
            // and the drawer is open (changeDirectory itself ignores TUIs).
            if terminalFollows, !terminal.view.isHidden { terminal.changeDirectory(to: url) }
            mirrorNavigationIfSyncing(to: url)
        }
        saveSessionSoon()
    }

    /// Where a new tab should open per the "New tab opens to" preference: nil = the current
    /// folder (browser-style), else Home or the configured fixed folder (if it exists).
    private func preferredNewTabFolder() -> URL? {
        switch prefs.newTabLocation {
        case .lastFolder: return nil
        case .home: return FileManager.default.homeDirectoryForCurrentUser
        case .fixed:
            let path = prefs.fixedStartFolder
            var isDir: ObjCBool = false
            guard !path.isEmpty,
                FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
            else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    /// A breadcrumb ancestor's right-click action: open that folder into a pane or a new tab,
    /// or copy its path.
    private func handleBreadcrumbAction(_ folder: URL, _ action: BreadcrumbBar.Action) {
        switch action {
        case .newTab: activeSide?.openTab(at: folder)
        case .leftPane: leftTabs.activePane?.navigate(to: folder)
        case .rightPane: rightTabs.activePane?.navigate(to: folder)
        case .leftPaneNewTab: leftTabs.openTab(at: folder)
        case .rightPaneNewTab: rightTabs.openTab(at: folder)
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(folder.path, forType: .string)
        }
    }

    /// Sync browsing: replay the active pane's relative move on the other side's pane,
    /// so two different roots track together. Descending into a subfolder moves the
    /// other pane into its same-named subfolder (if it exists); rising moves both up.
    /// The other pane holds still when the mirrored folder doesn't exist.
    private func mirrorNavigationIfSyncing(to url: URL) {
        guard let active = activePane else { return }
        let here = url.standardizedFileURL
        let key = ObjectIdentifier(active)
        let previous = syncBrowseAnchors[key]
        syncBrowseAnchors[key] = here  // keep the driver's anchor current for the next hop

        guard syncBrowsing, !isSyncingPanes, !active.isRemote, let previous else { return }
        let other = activeSide === leftTabs ? rightTabs : leftTabs
        guard let otherPane = other.activePane, !otherPane.isRemote,
            !otherPane.isShowingSmartResults
        else { return }
        let otherHere = otherPane.currentURL.standardizedFileURL
        guard
            let targetPath = SyncBrowse.mirroredPath(
                driverFrom: previous.path, driverTo: here.path, otherAt: otherHere.path)
        else { return }
        let target = URL(fileURLWithPath: targetPath).standardizedFileURL
        guard target != otherHere else { return }  // already there
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir),
            isDir.boolValue
        else { return }  // no mirror folder over there: hold still
        isSyncingPanes = true
        syncBrowseAnchors[ObjectIdentifier(otherPane)] = target  // so its own callback won't mirror back
        otherPane.navigate(to: target)
        isSyncingPanes = false
    }

    /// The window title: folder name by default (like Finder), full POSIX path
    /// when the preference is on, or the server location for a remote pane. Also
    /// sets representedURL so the title gets a proxy icon and path popup.
    func updateWindowTitle() {
        updateCommanderPrompt()  // keep the commander prompt in sync with the active folder
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

    var terminalFollowsFolder: Bool { terminalFollows }

    /// Open a folder (or reveal a file) handed to Pathem by Finder's "Open With" or the Services
    /// menu, and bring the window forward.
    func openExternalFolder(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            activePane?.navigate(to: url)
        } else if url.pathExtension.lowercased() == "torrent" {
            addTorrentToPanel(url)  // a .torrent opened from Finder goes straight into the Torrents panel
        } else {
            activePane?.reveal(url)  // any other file: show it in its folder
        }
        view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

}
