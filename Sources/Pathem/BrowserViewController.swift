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
    private weak var activeSide: TabbedPaneController?
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
    private var syncBrowsing = false
    private var isSyncingPanes = false  // re-entrancy guard for the mirror navigation
    /// Each pane's last-seen local folder, so a navigation's relative delta can be
    /// computed (see `mirrorNavigationIfSyncing`). Keyed by pane identity.
    private var syncBrowseAnchors: [ObjectIdentifier: URL] = [:]
    let split = NSSplitView()  // the two sides
    let outerSplit = NSSplitView()  // sidebar | panes
    let vSplit = NSSplitView()  // browser (top) | terminal (bottom)
    let shelf = ShelfController()  // stash shelf / drop stack across the bottom
    var shelfHiddenConstraint: NSLayoutConstraint?
    var shelfShownConstraint: NSLayoutConstraint?
    let commanderBar = CommanderBar()  // orthodox F-key bar + command line (Commander mode)
    private var commanderShownConstraint: NSLayoutConstraint?
    let previewView = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
    var previewVisible = false
    /// Durably pins the preview pane's width so it (and the panes) can't collapse; see
    /// togglePreviewPane(). Mirrors sidebarWidthConstraint.
    var previewWidthConstraint: NSLayoutConstraint?
    private lazy var sizeBrowser = SizeBrowserController()
    lazy var clipboardViewer = ClipboardViewerController()
    private lazy var cleanup = CleanupController()
    private lazy var xattrController = XattrController()
    private lazy var diffViewer = DiffViewerController()
    private lazy var bulkAttributes = BulkAttributesController()
    private lazy var automationRules = AutomationRulesController()
    private lazy var automation: AutomationManager = {
        let manager = AutomationManager(storeURL: Self.automationRulesURL)
        manager.onApplied = { [weak self] _ in self?.reloadBothSides() }
        return manager
    }()
    let sidebar = SidebarController()
    let terminal = TerminalController()
    let searchField = NSSearchField()
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
    private var openerRules = OpenerRules()
    /// Session-only opener overrides, keyed by lowercased extension (not persisted).
    private var sessionOpenersByType: [String: String] = [:]
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
    private lazy var findInFiles = FindInFilesController()
    private lazy var processViewer = ProcessViewerController()
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
    private let sharedDiscovery = SharedDiscovery()
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
    private var demoLayout: DemoWorkspace.Layout?
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
        commanderShownConstraint = vSplit.bottomAnchor.constraint(equalTo: commanderBar.topAnchor)
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
                if !pane.isRemote { self?.recordRecentFolder(pane.currentURL) }
            }
            side.onPaneDropFiles = { [weak self] urls, move, destination in
                self?.dropFiles(urls, move: move, into: destination)
            }
            side.newTabLocation = { [weak self] in self?.preferredNewTabFolder() }
            side.onOpenFolderInPane = { [weak self] url, action in self?.handleBreadcrumbAction(url, action) }
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
        sharedDiscovery.onChange = { [weak self] hosts in self?.sidebar.setSharedHosts(hosts) }
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
        Task { @MainActor in
            guard let name = await self.promptForName(title: L("bvc.addToCollectionPrompt", "Add to Collection"), default: L("bvc.collectionDefaultName", "Collection")) else { return }
            let isNew = self.collectionsStore.collection(named: name) == nil
            self.collectionsStore.add(urls.map(\.path), to: name)
            self.saveConfig(self.collectionsStore, to: Self.collectionsConfigURL)
            if isNew { self.registerCollectionCommand(name) }
        }
    }

    /// The saved smart-folder searches (searches.json); each is a command that runs its mdfind
    /// query and shows the results as a cross-folder smart list.
    var savedSearches = SavedSearches.default
    private func loadSavedSearches() {
        savedSearches = loadConfig(SavedSearches.self, from: Self.savedSearchesURL) ?? SavedSearches.default
        registerSavedSearchCommands()
    }
    private func registerSavedSearchCommands() {
        for command in commands.all where command.id.hasPrefix("search.") { commands.unregister(command.id) }
        for search in savedSearches.searches where !search.name.isEmpty {
            let query = search.mdfindQuery()
            guard !query.isEmpty else { continue }
            let name = search.name
            commands.register(
                .init(
                    id: "search.\(name)", title: String(format: L("bvc.searchCmdTitle", "Search: %@"), name), isEnabled: { true },
                    run: { [weak self] in self?.runSavedSearch(name, query: query) }))
        }
    }
    /// Persist a smart folder (replacing any with the same name) and re-register the commands.
    private func saveSmartFolder(_ search: SavedSearch) {
        savedSearches.searches.removeAll { $0.name == search.name }
        savedSearches.searches.append(search)
        saveConfig(savedSearches, to: Self.savedSearchesURL)
        registerSavedSearchCommands()
        sidebar.savedSearches = savedSearches.searches  // reflect it in the sidebar section
    }

    /// Advanced Find: a builder over Spotlight (name / extension / kind / content / tag / size /
    /// date). Search shows results in the active pane; Save persists a reusable smart folder.
    func showAdvancedFind() {
        guard let window = view.window, let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        func field(_ placeholder: String) -> NSTextField {
            let f = NSTextField()
            f.placeholderString = placeholder
            f.widthAnchor.constraint(equalToConstant: 240).isActive = true
            return f
        }
        func labeled(_ title: String, _ control: NSView) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let row = NSStackView(views: [label, control])
            row.orientation = .horizontal
            row.spacing = 8
            return row
        }
        let name = field(L("find.namePh", "contains…"))
        let ext = field(L("find.extPh", "e.g. pdf"))
        let content = field(L("find.contentPh", "text inside the file"))
        let tag = field(L("find.tagPh", "Finder tag"))
        let minSize = field(L("find.sizePh", "MB"))
        let days = field(L("find.daysPh", "days"))
        let kind = NSPopUpButton()
        kind.addItems(withTitles: [
            L("find.kindAny", "Any"), L("find.kindImages", "Images"), L("find.kindPDF", "PDF"),
            L("find.kindDocs", "Documents"), L("find.kindAudio", "Audio"), L("find.kindVideo", "Video"),
            L("find.kindFolders", "Folders"),
        ])
        let kindUTIs: [String?] = [nil, "public.image", "com.adobe.pdf", "public.content", "public.audio", "public.movie", "public.folder"]
        let rows = NSStackView(views: [
            labeled(L("find.nameLabel", "Name"), name), labeled(L("find.extLabel", "Extension"), ext),
            labeled(L("find.kindLabel", "Kind"), kind), labeled(L("find.contentLabel", "Content"), content),
            labeled(L("find.tagLabel", "Tag"), tag), labeled(L("find.sizeLabel", "Min size (MB)"), minSize),
            labeled(L("find.daysLabel", "Modified within"), days),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.frame = NSRect(x: 0, y: 0, width: 380, height: 250)

        func criteria(named: String) -> SavedSearch {
            func nz(_ f: NSTextField) -> String? {
                let v = f.stringValue.trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            return SavedSearch(
                name: named, nameContains: nz(name), fileExtension: nz(ext),
                minSizeBytes: nz(minSize).flatMap { Double($0) }.map { Int64($0 * 1_000_000) },
                modifiedWithinDays: nz(days).flatMap { Int($0) },
                contentType: kindUTIs[kind.indexOfSelectedItem],
                contentContains: nz(content), tag: nz(tag))
        }

        let alert = NSAlert()
        alert.messageText = L("find.title", "Advanced Find")
        alert.informativeText = L("find.info", "Find files across your Mac by any combination of criteria (Spotlight).")
        alert.accessoryView = rows
        alert.addButton(withTitle: L("find.search", "Search"))
        alert.addButton(withTitle: L("find.save", "Save as Smart Folder…"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                let search = criteria(named: L("find.resultsName", "Find Results"))
                guard !search.mdfindQuery().isEmpty else { NSSound.beep(); return }
                self.runSavedSearch(search.name, query: search.mdfindQuery())
            case .alertSecondButtonReturn:
                Task { @MainActor in
                    guard let chosen = await self.promptForName(
                        title: L("find.saveTitle", "Save Smart Folder"), default: L("find.saveDefault", "My Search"))
                    else { return }
                    let search = criteria(named: chosen)
                    guard !search.mdfindQuery().isEmpty else { NSSound.beep(); return }
                    self.saveSmartFolder(search)
                    self.runSavedSearch(search.name, query: search.mdfindQuery())
                }
            default:
                break
            }
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
        add("files.copyTo", L("bvc.cmd.copyTo", "Copy To…"), enabled: hasSelection) {
            [weak self] in self?.copyOrMoveTo(move: false)
        }
        add("files.moveTo", L("bvc.cmd.moveTo", "Move To…"), enabled: hasSelection) {
            [weak self] in self?.copyOrMoveTo(move: true)
        }
        add("files.copy", L("bvc.cmd.copy", "Copy"), enabled: hasSelection) {
            [weak self] in self?.writeSelectionToPasteboard(cut: false)
        }
        add("files.cut", L("bvc.cmd.cut", "Cut"), enabled: hasSelection) {
            [weak self] in self?.writeSelectionToPasteboard(cut: true)
        }
        add("view.clipboard", L("bvc.cmd.showClipboard", "Show Clipboard…")) { [weak self] in self?.showClipboard() }
        add("view.asList", L("bvc.cmd.asList", "as List")) { [weak self] in self?.setActiveViewMode(.list) }
        add("view.asIcons", L("bvc.cmd.asIcons", "as Icons")) { [weak self] in self?.setActiveViewMode(.icon) }
        add("view.asGallery", L("bvc.cmd.asGallery", "as Gallery")) { [weak self] in self?.setActiveViewMode(.gallery) }
        add("view.asColumn", L("bvc.cmd.asColumns", "as Columns")) { [weak self] in self?.setActiveViewMode(.column) }
        add("view.asTree", L("bvc.cmd.asTree", "as Tree")) { [weak self] in self?.setActiveViewMode(.tree) }
        add("view.saveViewPreset", L("bvc.cmd.saveViewPreset", "Save Current View As…"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.saveViewPreset()
        }
        add("view.arrangeNone", L("bvc.cmd.arrangeNone", "None")) { [weak self] in self?.activePane?.setGroupKey(.none) }
        add("view.arrangeKind", L("bvc.cmd.arrangeKind", "Kind")) { [weak self] in self?.activePane?.setGroupKey(.kind) }
        add("view.arrangeSize", L("bvc.cmd.arrangeSize", "Size")) { [weak self] in self?.activePane?.setGroupKey(.size) }
        add("view.arrangeDate", L("bvc.cmd.arrangeDate", "Date Modified")) { [weak self] in self?.activePane?.setGroupKey(.dateModified) }
        add("view.arrangeTag", L("bvc.cmd.arrangeTag", "Tag")) { [weak self] in self?.activePane?.setGroupKey(.tag) }
        add("view.zoomIn", L("bvc.cmd.zoomIn", "Zoom In")) { [weak self] in self?.activePane?.zoomContent(0.15) }
        add("view.zoomOut", L("bvc.cmd.zoomOut", "Zoom Out")) { [weak self] in self?.activePane?.zoomContent(-0.15) }
        add("terminal.toggle", L("bvc.cmd.toggleTerminal", "Toggle Terminal")) { [weak self] in self?.toggleTerminal() }
        add("commander.toggle", L("bvc.cmd.commanderMode", "Commander Mode")) { [weak self] in self?.toggleCommander() }
        add("nav.vimMode", L("bvc.cmd.vimMode", "Vim Navigation")) { [weak self] in
            self?.vimMode.toggle()
            self?.vimPendingG = false
        }
        add("terminal.here", L("bvc.cmd.openTerminalHere", "Open Terminal Here")) { [weak self] in self?.openTerminalHere() }
        add("terminal.toggleFollow", L("bvc.cmd.terminalFollowsFolder", "Terminal Follows Folder")) {
            [weak self] in self?.toggleTerminalFollows()
        }
        add("files.paste", L("bvc.cmd.paste", "Paste")) { [weak self] in self?.paste(nil) }
        add(
            "files.pasteOtherPane", L("bvc.cmd.pasteOtherPane", "Paste in Other Pane"),
            enabled: { [weak self] in self?.otherPane != nil }
        ) { [weak self] in self?.pasteInto(self?.otherPane) }
        add("files.open", L("bvc.cmd.open", "Open"), enabled: hasSelection) { [weak self] in self?.activePane?.openSelection() }
        add("files.batchRename", L("bvc.cmd.batchRename", "Batch Rename…"), enabled: hasSelection) { [weak self] in self?.showBatchRename() }
        add("files.selectByPattern", L("bvc.cmd.selectByPattern", "Select by Pattern…"), enabled: { [weak self] in
            self?.activePane != nil
        }) { [weak self] in self?.selectByPattern() }
        add("files.newFolder", L("bvc.cmd.newFolder", "New Folder")) { [weak self] in self?.newFolder() }
        add(
            "files.newFolderWithSelection", L("bvc.newFolderWithSelectionAction", "New Folder with Selection"),
            enabled: { [weak self] in
                guard let pane = self?.activePane else { return false }
                return !pane.isRemote && !pane.isShowingSmartResults && !pane.selectedEntries.isEmpty
            }
        ) { [weak self] in self?.newFolderWithSelection() }
        add("files.newFile", L("bvc.cmd.newFile", "New File")) { [weak self] in self?.newFile() }
        add("files.batchCreate", L("bvc.cmd.batchCreate", "Batch Create…")) { [weak self] in self?.showBatchCreate() }
        add("templates.manage", L("bvc.cmd.manageTemplates", "Manage Templates…")) { [weak self] in self?.showTemplatesManager() }
        let inLocalFolder: () -> Bool = { [weak self] in
            guard let pane = self?.activePane else { return false }
            return !pane.isRemote && !pane.isShowingSmartResults
        }
        add("files.findInFiles", L("bvc.cmd.findInFiles", "Find in Files…"), enabled: inLocalFolder) { [weak self] in self?.showFindInFiles() }
        add("view.advancedFind", L("bvc.cmd.advancedFind", "Advanced Find…"), enabled: { [weak self] in self?.activePane?.isRemote == false }) { [weak self] in self?.showAdvancedFind() }
        add("nav.findFiles", L("bvc.cmd.findFiles", "Find Files Everywhere…")) { [weak self] in self?.showGlobalSearch() }
        add("tools.processViewer", L("bvc.cmd.processViewer", "Process Viewer")) { [weak self] in self?.processViewer.present() }
        add("tools.torrents", L("bvc.cmd.torrents", "Torrents")) { [weak self] in self?.torrents.present() }
        add("files.addToTorrents", L("bvc.cmd.addToTorrents", "Add to Torrents"),
            enabled: { [weak self] in !(self?.selectedTorrentURLs.isEmpty ?? true) }) {
            [weak self] in self?.addSelectedTorrents()
        }
        add("files.copyMagnetLink", L("bvc.cmd.copyMagnetLink", "Copy Magnet Link"),
            enabled: { [weak self] in !(self?.selectedTorrentURLs.isEmpty ?? true) }) {
            [weak self] in self?.copySelectedMagnetLinks()
        }
        add("files.createTorrent", L("bvc.cmd.createTorrent", "Create Torrent…"),
            enabled: { [weak self] in self?.selectedSingleLocalURL != nil }) {
            [weak self] in self?.createTorrentFromSelection()
        }
        add("tools.transfers", L("bvc.cmd.transfers", "Transfers")) { [weak self] in self?.transferController.showWindow() }
        add("tools.externalCommands", L("bvc.cmd.externalCommands", "External Commands…")) { [weak self] in self?.showExternalCommandsManager() }
        add("tools.runShortcut", L("bvc.cmd.runShortcut", "Run Shortcut on Selection…")) { [weak self] in self?.showShortcutPicker() }
        add("files.ejectVolume", L("bvc.cmd.ejectVolume", "Eject Volume"), enabled: { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote else { return false }
            let volume = (try? pane.currentURL.resourceValues(forKeys: [.volumeURLKey]))?.volume
            return volume != nil && volume?.path != "/"
        }) { [weak self] in self?.ejectActiveVolume() }
        add("files.duplicate", L("bvc.cmd.duplicate", "Duplicate"), enabled: { [weak self] in
            guard let pane = self?.activePane else { return false }
            return !pane.isRemote && !pane.isShowingSmartResults && !pane.selectedEntries.isEmpty
        }) { [weak self] in self?.duplicateSelection() }
        let hasLocalSelection: () -> Bool = { [weak self] in
            guard let pane = self?.activePane else { return false }
            return !pane.isRemote && !pane.isShowingSmartResults && !pane.selectedEntries.isEmpty
        }
        add("files.makeSymlink", L("bvc.cmd.makeSymlink", "Make Symlink"), enabled: hasLocalSelection) {
            [weak self] in self?.makeLinks(kind: .symlink)
        }
        add("files.makeAlias", L("bvc.cmd.makeAlias", "Make Alias"), enabled: hasLocalSelection) {
            [weak self] in self?.makeLinks(kind: .alias)
        }
        add(
            "files.showOriginal", L("bvc.cmd.showOriginal", "Show Original"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, pane.selectedEntries.count == 1 else { return false }
                return true
            }
        ) { [weak self] in self?.showOriginal() }
        add("files.makeHardlink", L("bvc.cmd.makeHardlink", "Make Hard Link"), enabled: hasLocalSelection) {
            [weak self] in self?.makeLinks(kind: .hardlink)
        }
        add("files.secureDelete", L("bvc.cmd.secureDelete", "Secure Delete…"), enabled: hasLocalSelection) {
            [weak self] in self?.secureDeleteSelection()
        }
        add("files.encryptDMG", L("bvc.cmd.encryptDMG", "New Encrypted Disk Image…"), enabled: hasLocalSelection) {
            [weak self] in self?.encryptToDiskImage()
        }
        add("files.offload", L("bvc.cmd.offload", "Offload to iCloud"), enabled: { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults else { return false }
            return pane.selectedLocalURLs().contains { Backup.isOffloadable($0) }
        }) { [weak self] in self?.offloadSelection() }
        add("files.backupTo", L("bvc.cmd.backupTo", "Back Up To…"), enabled: hasLocalSelection) {
            [weak self] in self?.backupSelection()
        }
        add("files.repoReclaim", L("bvc.cmd.repoReclaim", "Reclaim in Repo…"), enabled: { [weak self] in
            guard let pane = self?.activePane else { return false }
            return !pane.isRemote && !pane.isShowingSmartResults
        }) { [weak self] in self?.repoReclaim() }
        add("files.split", L("bvc.cmd.split", "Split File…"), enabled: { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults,
                pane.selectedEntries.count == 1, let entry = pane.selectedEntries.first
            else { return false }
            return !entry.isDirectory
        }) { [weak self] in self?.splitSelection() }
        add("files.merge", L("bvc.cmd.mergeParts", "Merge Parts"), enabled: { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults,
                let entry = pane.selectedEntries.first
            else { return false }
            let ext = (entry.name as NSString).pathExtension
            return !ext.isEmpty && ext.allSatisfy(\.isNumber)  // a ".001"-style part
        }) { [weak self] in self?.mergeSelection() }
        add("files.convertImages", L("bvc.cmd.convertImages", "Convert Images…"), enabled: { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults else { return false }
            return pane.selectedEntries.contains { Self.isImageName($0.name) }
        }) { [weak self] in self?.convertImagesSelection() }
        let hasSelectedImage: () -> Bool = { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults else { return false }
            return pane.selectedEntries.contains { Self.isImageName($0.name) }
        }
        add("image.rotateLeft", L("bvc.cmd.rotateLeft", "Rotate Left"), enabled: hasSelectedImage) {
            [weak self] in self?.rotateSelection(clockwiseDegrees: 270)
        }
        add("image.rotateRight", L("bvc.cmd.rotateRight", "Rotate Right"), enabled: hasSelectedImage) {
            [weak self] in self?.rotateSelection(clockwiseDegrees: 90)
        }
        add("image.createPDF", L("bvc.cmd.createPDF", "Create PDF"), enabled: { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults else { return false }
            return pane.selectedEntries.contains { Self.isImageName($0.name) || ($0.name as NSString).pathExtension.lowercased() == "pdf" }
        }) { [weak self] in self?.createPDFFromSelection() }
        add("files.trimMedia", L("bvc.cmd.trimMedia", "Trim…"), enabled: { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults,
                pane.selectedEntries.count == 1, let entry = pane.selectedEntries.first, !entry.isDirectory
            else { return false }
            return TrimController.trimmableExtensions.contains((entry.name as NSString).pathExtension.lowercased())
        }) { [weak self] in self?.trimSelection() }
        add("image.markup", L("bvc.cmd.markup", "Markup…"), enabled: { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults,
                pane.selectedEntries.count == 1, let entry = pane.selectedEntries.first
            else { return false }
            return Self.isImageName(entry.name)
        }) { [weak self] in self?.markupSelection() }
        add("files.xattrs", L("bvc.cmd.xattrs", "Extended Attributes…"), enabled: { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults else { return false }
            return pane.selectedEntries.count == 1
        }) { [weak self] in self?.showXattrs() }
        add("files.removeQuarantine", L("bvc.cmd.removeQuarantine", "Remove Quarantine"), enabled: hasLocalSelection) {
            [weak self] in self?.removeQuarantineFromSelection()
        }
        add("files.diff", L("bvc.cmd.diff", "Compare Files"), enabled: { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults else { return false }
            let entries = pane.selectedEntries
            return entries.count == 2 && entries.allSatisfy { !$0.isDirectory }
        }) { [weak self] in self?.compareSelection() }
        add("files.setAttributes", L("bvc.cmd.setAttributes", "Set Attributes…"), enabled: hasLocalSelection) {
            [weak self] in self?.setAttributesSelection()
        }
        add("files.setFinderComment", L("bvc.cmd.setFinderComment", "Set Finder Comment…"), enabled: hasLocalSelection) {
            [weak self] in self?.setFinderCommentSelection()
        }
        add("files.editACL", L("bvc.cmd.editACL", "Permissions…"), enabled: { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults else { return false }
            return pane.selectedEntries.count == 1
        }) { [weak self] in self?.editACLSelection() }
        add("files.changeOwner", L("bvc.cmd.changeOwner", "Change Owner (Admin)…"), enabled: hasLocalSelection) {
            [weak self] in self?.changeOwnerViaTerminal()
        }
        add("files.connectToServer", L("bvc.cmd.connectToServer", "Connect to Server…")) {
            [weak self] in self?.connectToServer()
        }
        add(
            "files.addBookmark", L("bvc.cmd.addBookmark", "Bookmark This Remote Folder…"),
            enabled: { [weak self] in self?.activePane?.remoteContext != nil }
        ) {
            [weak self] in self?.addBookmark()
        }
        let localFolder: () -> Bool = { [weak self] in
            guard let pane = self?.activePane else { return false }
            return !pane.isRemote && !pane.isShowingSmartResults
        }
        add("files.setFolderBgColor", L("bvc.cmd.setFolderBgColor", "Background Color…"), enabled: localFolder) {
            [weak self] in self?.setFolderBackgroundColor()
        }
        add("files.setFolderBgPicture", L("bvc.cmd.setFolderBgPicture", "Background Picture…"), enabled: localFolder) {
            [weak self] in self?.setFolderBackgroundPicture()
        }
        add("files.clearFolderBg", L("bvc.cmd.clearFolderBg", "Remove Background"), enabled: localFolder) {
            [weak self] in self?.clearFolderBackground()
        }
        add("files.peekArchive", L("bvc.cmd.peekArchive", "Show Archive Contents"), enabled: { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote, pane.selectedEntries.count == 1 else { return false }
            return pane.selectedLocalURLs().first.map(Archiver.canExtract) ?? false
        }) { [weak self] in self?.peekArchive() }
        add("files.deleteApp", L("bvc.cmd.deleteApp", "Uninstall App…"), enabled: { [weak self] in
            guard let entry = self?.activePane?.selectedEntries, entry.count == 1 else { return false }
            return entry.first?.name.hasSuffix(".app") == true
        }) { [weak self] in self?.deleteAppWithLeftovers() }
        add("app.resetData", L("bvc.cmd.resetData", "Reset Pathem Data…")) { [weak self] in self?.resetPathemData() }
        add("git.commit", L("bvc.cmd.gitCommit", "Commit…"), enabled: inLocalFolder) { [weak self] in self?.gitCommit() }
        add("git.push", L("bvc.cmd.gitPush", "Push"), enabled: inLocalFolder) { [weak self] in self?.gitPushPull(push: true) }
        add("git.pull", L("bvc.cmd.gitPull", "Pull"), enabled: inLocalFolder) { [weak self] in self?.gitPushPull(push: false) }
        add("files.rename", L("bvc.cmd.rename", "Rename…"), enabled: { [weak self] in self?.activePane?.selectedEntries.count == 1 }) {
            [weak self] in self?.renameSelection()
        }
        add("files.trash", L("bvc.cmd.moveToTrash", "Move to Trash"), enabled: hasSelection) { [weak self] in self?.trashSelection() }
        add(
            "files.putBack", L("bvc.cmd.putBack", "Put Back"),
            enabled: { [weak self] in self?.selectionIsInTrash ?? false }
        ) { [weak self] in self?.putBackSelection() }
        add(
            "files.deleteImmediately", L("bvc.cmd.deleteImmediately", "Delete Immediately"), enabled: hasSelection
        ) { [weak self] in self?.deleteImmediatelySelection() }
        add(
            "files.emptyTrash", L("bvc.cmd.emptyTrash", "Empty Trash"),
            enabled: { [weak self] in self?.trashHasItems ?? false }
        ) { [weak self] in self?.emptyTrash() }
        add(
            "files.setDesktopPicture", L("bvc.cmd.setDesktopPicture", "Set Desktop Picture"),
            enabled: { [weak self] in self?.singleSelectedImageURL != nil }
        ) { [weak self] in self?.setDesktopPicture() }
        add("files.setCustomIcon", L("bvc.cmd.setCustomIcon", "Set Custom Icon…"), enabled: { [weak self] in
            guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults else { return false }
            return pane.selectedEntries.count == 1
        }) { [weak self] in self?.setCustomIcon() }
        add("files.removeCustomIcon", L("bvc.cmd.removeCustomIcon", "Remove Custom Icon"), enabled: hasLocalSelection) {
            [weak self] in self?.removeCustomIcon()
        }
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
        add("files.organize", L("bvc.cmd.organize", "Organize Folder…"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.organizeFolder()
        }
        add("files.copySHA256", L("bvc.cmd.copySHA256", "Copy SHA-256"), enabled: hasSelection) { [weak self] in self?.copyChecksums() }
        add("files.verifyChecksum", L("bvc.cmd.verifyChecksum", "Verify Checksum…"), enabled: hasSelection) {
            [weak self] in self?.verifyChecksum()
        }
        add("files.reveal", L("bvc.cmd.revealInFinder", "Reveal in Finder"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.revealSelection()
        }
        add(
            "files.revealInPathem", L("bvc.cmd.revealInPathem", "Reveal in Pathem"),
            enabled: { [weak self] in self?.activePane?.selectedLocalURLs().isEmpty == false }
        ) { [weak self] in self?.revealSelectionInPathem() }
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
        add("view.syncBrowsing", L("bvc.cmd.syncBrowsing", "Sync Browsing")) { [weak self] in
            guard let self else { return }
            self.syncBrowsing.toggle()
            // Seed both panes' anchors so the first move of either one mirrors relative
            // to where they sit right now.
            if self.syncBrowsing {
                for side in [self.leftTabs, self.rightTabs] {
                    if let pane = side.activePane, !pane.isRemote {
                        self.syncBrowseAnchors[ObjectIdentifier(pane)] = pane.currentURL.standardizedFileURL
                    }
                }
            }
        }
        add("workspace.save", L("bvc.cmd.saveWorkspace", "Save Workspace…")) { [weak self] in self?.saveWorkspace() }
        add("workspace.open", L("bvc.cmd.openWorkspace", "Open Workspace…")) { [weak self] in self?.openWorkspace() }
        add("view.saveStyle", L("bvc.cmd.saveStyle", "Save Style…"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.saveStyle()
        }
        add("view.applyStyle", L("bvc.cmd.applyStyle", "Apply Style…"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.applyStyle()
        }
        add("tools.automation", L("bvc.cmd.automation", "Automation Rules…")) { [weak self] in self?.showAutomationRules() }
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
        add(
            "view.slideshow", L("bvc.cmd.slideshow", "Slideshow"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults else { return false }
                return pane.entries.contains { !$0.isDirectory && BrowserViewController.isImageName($0.name) }
            }
        ) { [weak self] in self?.startSlideshow() }
        add("tab.new", L("bvc.cmd.newTab", "New Tab")) { [weak self] in self?.activeSide?.newTab(duplicatingCurrent: true) }
        add("window.new", L("bvc.cmd.newWindow", "New Window")) { [weak self] in
            WindowManager.shared.openWindow(start: self?.newWindowStartFolder() ?? FileManager.default.homeDirectoryForCurrentUser)
        }
        add(
            "window.moveTabToNew", L("bvc.cmd.moveTabToNewWindow", "Move Tab to New Window"),
            enabled: { [weak self] in
                guard let side = self?.activeSide, let pane = side.activePane else { return false }
                return !pane.isRemote  // a remote session can't be re-hosted in a fresh window
            }
        ) { [weak self] in self?.moveActiveTabToNewWindow() }
        add(
            "files.openInNewTab", L("bvc.cmd.openInNewTab", "Open in New Tab"),
            enabled: { [weak self] in self?.singleSelectedFolder != nil }
        ) { [weak self] in
            guard let self, let folder = self.singleSelectedFolder else { NSSound.beep(); return }
            self.activeSide?.openTab(at: folder)
        }
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
        add("nav.selectFirst", L("bvc.cmd.selectFirst", "Select First Item"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.activePane?.selectFirst()
        }
        add("nav.selectLast", L("bvc.cmd.selectLast", "Select Last Item"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.activePane?.selectLast()
        }
        add("view.flatView", L("bvc.cmd.flatView", "Flat View"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.activePane?.showFlatView()
        }
        add("view.filter", L("bvc.cmd.filter", "Filter…"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.activePane?.beginFilter()
        }
        add("view.previewPane", L("bvc.cmd.previewPane", "Preview Pane"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.togglePreviewPane()
        }
        add("view.demoMode", L("bvc.cmd.demoMode", "Demo Mode (fake data for screenshots)")) {
            [weak self] in self?.toggleDemoMode()
        }
        add("files.findDuplicates", L("bvc.cmd.findDuplicates", "Find Duplicates"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.findDuplicates()
        }
        add("files.findSimilarNames", L("bvc.cmd.findSimilarNames", "Find Similar Names"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.findSimilarNames()
        }
        add(
            "view.flattenFolder", L("bvc.cmd.flattenFolder", "Flatten Folder (Show All Items)"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults else { return false }
                return true
            }
        ) { [weak self] in self?.flattenFolder() }
        add(
            "ai.renameSelection", L("bvc.cmd.aiRename", "AI Rename…"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults else { return false }
                return pane.selectedEntries.count == 1 && !(pane.selectedEntries.first?.isDirectory ?? true)
            }
        ) { [weak self] in self?.aiRenameSelection() }
        add(
            "ai.summarizeFolder", L("bvc.cmd.aiSummarize", "Summarize Folder"),
            enabled: { [weak self] in
                guard let pane = self?.activePane, !pane.isRemote, !pane.isShowingSmartResults else { return false }
                return true
            }
        ) { [weak self] in self?.aiSummarizeFolder() }
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
        add("view.customizeToolbar", L("bvc.cmd.customizeToolbar", "Customize Toolbar…"), enabled: { [weak self] in
            self?.view.window?.toolbar != nil
        }) { [weak self] in self?.view.window?.toolbar?.runCustomizationPalette(nil) }
        add("files.comparePanes", L("bvc.cmd.comparePanes", "Compare Panes…"), enabled: { [weak self] in self?.activePane != nil }) {
            [weak self] in self?.comparePanes()
        }
        add("files.compress", L("bvc.cmd.compress", "Compress"), enabled: hasSelection) { [weak self] in self?.compressSelection() }
        add("files.compress7z", L("bvc.cmd.compress7z", "Compress to 7-Zip"), enabled: hasSelection) { [weak self] in self?.compress7zSelection() }
        let hasArchive: () -> Bool = { [weak self] in
            (self?.activePane?.selectedLocalURLs() ?? []).contains { Archiver.canExtract($0) }
        }
        add(
            "files.extract", L("bvc.cmd.extract", "Extract"), enabled: hasArchive
        ) { [weak self] in self?.extractSelection() }
        add(
            "files.extractHere", L("bvc.cmd.extractHere", "Extract Here"), enabled: hasArchive
        ) { [weak self] in self?.extractHereSelection() }
        add(
            "files.extractTo", L("bvc.cmd.extractTo", "Extract to Folder…"), enabled: hasArchive
        ) { [weak self] in self?.extractToSelection() }
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
        add("edit.undo", L("bvc.cmd.undo", "Undo"), enabled: { [weak self] in self?.actionHistory.canUndo ?? false }) {
            [weak self] in self?.undo(nil)
        }
        add("edit.redo", L("bvc.cmd.redo", "Redo"), enabled: { [weak self] in self?.actionHistory.canRedo ?? false }) {
            [weak self] in self?.redo(nil)
        }
        add("edit.showHistory", L("bvc.cmd.showHistory", "Undo History…")) { [weak self] in self?.showUndoHistory() }
        loadExtensionsIfEnabled()
    }

    // MARK: - Extensions (out-of-process, off by default)

    /// Load out-of-process Swift extensions and register their contributed commands on the
    /// same command bus as everything else. This is the demand-gated seam (DESIGN.md Phase 6),
    /// deliberately OFF unless `PATHEM_ENABLE_EXTENSIONS=1`: the FDA host never loads foreign
    /// code in-process, and a shipping build exposes no extension surface until this is
    /// intentionally turned on. Signatures are required unless `PATHEM_EXTENSIONS_UNSIGNED=1`
    /// (local development only).
    private func loadExtensionsIfEnabled() {
        let env = ProcessInfo.processInfo.environment
        guard env["PATHEM_ENABLE_EXTENSIONS"] == "1" else { return }
        guard
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("Pathem/Extensions"),
            FileManager.default.fileExists(atPath: dir.path)
        else { return }
        let hostVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let policy: ExtensionHost.Policy =
            env["PATHEM_EXTENSIONS_UNSIGNED"] == "1" ? .development : .production
        for ext in ExtensionHost.discover(in: dir, hostVersion: hostVersion, policy: policy) {
            for cmd in ext.manifest.contributes.commands {
                let title = String(format: L("ext.cmdTitle", "%@: %@"), ext.manifest.name, cmd.title)
                commands.register(
                    .init(id: "ext.\(ext.manifest.id).\(cmd.id)", title: title) { [weak self] in
                        self?.runExtensionCommand(ext, handler: cmd.handler, title: title, policy: policy)
                    })
            }
        }
    }

    /// Invoke an extension handler out-of-process with the active pane's context, then show
    /// its result (or error) in a simple alert. A crash, hang, or error in the helper is
    /// isolated by `ExtensionHost` and never touches the host process.
    private func runExtensionCommand(
        _ ext: LoadedExtension, handler: String, title: String, policy: ExtensionHost.Policy
    ) {
        let context = ExtensionProtocol.Context(
            folder: activePane?.currentURL.path,
            selection: activePane?.selectedLocalURLs().map(\.path) ?? [])
        Task { @MainActor in
            do {
                let result = try await ExtensionHost.invoke(
                    ext, handler: handler, context: context, policy: policy)
                self.presentInfo(title, Self.describe(result))
            } catch {
                self.presentInfo(L("ext.failed", "Extension error"), "\(error)")
            }
        }
    }

    /// Render an extension result as readable text for the info alert.
    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: return L("ext.noResult", "Done.")
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
        }
    }

    /// Open the command palette over the current window, dispatching the chosen
    /// command through the registry.
    private func showPalette() {
        guard let window = view.window else { return }
        let items = commands.all.map { (id: $0.id, title: $0.title) }
        palette.present(
            commands: items,
            onRun: { [weak self] id in self?.commands.perform(id) },
            onNavigate: { [weak self] url in self?.activePane?.navigate(to: url) },
            onSemantic: { [weak self] query in self?.runSemanticSearch(query) },
            over: window)
    }

    /// Run the on-device semantic search in the active pane for `query` (routes the command
    /// bar's "?" mode through the same path as the toolbar search field).
    private func runSemanticSearch(_ query: String) {
        searchField.stringValue = query
        runSearch(searchField)
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

    /// Select items in the active pane by a name pattern (glob / regex / substring),
    /// replacing, extending, or trimming the current selection.
    private func selectByPattern() {
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
    private func blockedByRemote() -> Bool {
        if activePane?.isRemote == true {
            NSSound.beep()
            return true
        }
        return false
    }

    /// Ops that need one destination folder (paste, new folder) can't run in a
    /// remote pane or a cross-folder smart-result view (there's no single "here").
    func blockedByRemoteOrSmart() -> Bool {
        if activePane?.isRemote == true || activePane?.isShowingSmartResults == true {
            NSSound.beep()
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
            // The file's real folder: its own location in a smart view, else current.
            let directory = entry.location.map { URL(fileURLWithPath: $0) } ?? pane.currentURL
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

    private func performLocalTrash(_ urls: [URL]) {
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

    /// Copy the selection's paths (POSIX or file://) to the clipboard, one per line.
    private func copyPaths(asURL: Bool) {
        guard let pane = activePane else { NSSound.beep(); return }
        let lines: [String]
        if pane.isRemote {
            lines = pane.selectedPathStrings()  // server-side paths; a file:// URL doesn't apply
        } else {
            lines = pane.selectedLocalURLs().map { asURL ? $0.absoluteString : $0.path }
        }
        guard !lines.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
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
            guard !lines.isEmpty else {
                self.presentInfo(
                    L("checksum.failedTitle", "Couldn’t hash the selection"),
                    L("checksum.failedBody", "None of the selected files could be read. They may be unreadable without Full Disk Access, or they may have been removed."))
                return
            }
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

    /// Duplicate the selected items in place ("<name> copy"), undoable.
    private func duplicateSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let folder = pane.currentURL
        let names = pane.selectedEntries.map(\.name)
        guard !names.isEmpty else { NSSound.beep(); return }
        var created: [String] = []
        var failures: [FileOperations.Failure] = []
        for name in names {
            do { created.append(try FileOperations.duplicate(name, in: folder)) } catch {
                failures.append(.init(name: name, reason: error.localizedDescription))
            }
        }
        pane.reloadIfShowingListing()
        if let first = created.first { pane.select(name: first) }
        registerCreatedUndo(names: created, in: folder, actionName: L("bvc.duplicateAction", "Duplicate"))
        if !failures.isEmpty { presentFailures(failures, title: L("bvc.duplicateFailed", "Couldn’t duplicate")) }
    }

    /// Set metadata (dates, permissions, tags) across the whole selection at once.
    private func setAttributesSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty, let window = view.window else { NSSound.beep(); return }
        bulkAttributes.present(count: urls.count, over: window) { [weak self] changes in
            guard !changes.isEmpty else { return }
            Task { @MainActor in
                let result = await Task.detached { BulkAttributes.apply(changes, to: urls) }.value
                self?.activePane?.reloadIfShowingListing()
                if !result.failures.isEmpty {
                    self?.presentFailures(result.failures, title: L("bvc.setAttrsFailed", "Couldn’t set attributes"))
                }
            }
        }
    }

    /// Compare the two selected files side by side.
    private func compareSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let entries = pane.selectedEntries
        guard entries.count == 2, entries.allSatisfy({ !$0.isDirectory }) else { NSSound.beep(); return }
        diffViewer.present(
            left: pane.currentURL.appendingPathComponent(entries[0].name),
            right: pane.currentURL.appendingPathComponent(entries[1].name), over: view.window)
    }

    /// Show the extended-attributes panel for the single selected item.
    private func showXattrs() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            let entry = pane.selectedEntries.first
        else { NSSound.beep(); return }
        xattrController.present(for: pane.currentURL.appendingPathComponent(entry.name), over: view.window)
    }

    /// Strip com.apple.quarantine from the selection (recursively for folders/bundles).
    private func removeQuarantineFromSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let total = urls.reduce(0) { $0 + ExtendedAttributes.removeQuarantine(from: $1) }
        pane.reloadIfShowingListing()
        presentInfo(
            L("bvc.quarantineDone", "Quarantine"),
            total > 0
                ? String(format: L("bvc.quarantineRemoved", "Cleared the download flag from %d item(s)."), total)
                : L("bvc.quarantineNone", "No quarantine flags were set."))
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp",
    ]
    static func isImageName(_ name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Set (or clear) the Finder comment on every selected item, prefilled with the shared comment
    /// when they all match. Applied off-main through the engine writer.
    private func setFinderCommentSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty, let window = view.window else { NSSound.beep(); return }
        let existing = Set(urls.map { FileMetadata.finderComment(of: $0) ?? "" })
        let prefill = existing.count == 1 ? (existing.first ?? "") : ""

        let alert = NSAlert()
        alert.messageText =
            urls.count == 1
            ? String(format: L("comment.titleOne", "Finder comment for “%@”"), urls[0].lastPathComponent)
            : String(format: L("comment.titleMany", "Finder comment for %d items"), urls.count)
        alert.informativeText = L("comment.hint", "Leave empty to remove the comment.")
        alert.addButton(withTitle: L("common.apply", "Apply"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = prefill
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            let comment = field.stringValue
            let failures = await Task.detached { () -> [FileOperations.Failure] in
                var failures: [FileOperations.Failure] = []
                for url in urls {
                    do { try FileMetadata.setFinderComment(comment, on: url) } catch {
                        failures.append(.init(name: url.lastPathComponent, reason: error.localizedDescription))
                    }
                }
                return failures
            }.value
            self.activePane?.reloadIfShowingListing()
            if !failures.isEmpty {
                self.presentFailures(failures, title: L("comment.failed", "Couldn’t set the comment"))
            }
        }
    }

    /// Build a single PDF from images (one page each) and PDFs (all their pages), in selection
    /// order, written to a uniquely-named file in `folder`. Returns the URL, or nil on failure.
    nonisolated static func buildPDF(from urls: [URL], in folder: URL) -> URL? {
        let document = PDFDocument()
        var pageIndex = 0
        for url in urls {
            if url.pathExtension.lowercased() == "pdf", let source = PDFDocument(url: url) {
                for i in 0..<source.pageCount where source.page(at: i) != nil {
                    document.insert(source.page(at: i)!, at: pageIndex)
                    pageIndex += 1
                }
            } else if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                document.insert(page, at: pageIndex)
                pageIndex += 1
            }
        }
        guard document.pageCount > 0 else { return nil }
        let fm = FileManager.default
        var out = folder.appendingPathComponent("Combined.pdf")
        var n = 2
        while fm.fileExists(atPath: out.path) {
            out = folder.appendingPathComponent("Combined \(n).pdf")
            n += 1
        }
        return document.write(to: out) ? out : nil
    }

    /// Split the selected file into fixed-size parts (asks for a size in MB), off-main.
    private func splitSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            pane.selectedEntries.count == 1, let entry = pane.selectedEntries.first, !entry.isDirectory
        else { NSSound.beep(); return }
        let file = pane.currentURL.appendingPathComponent(entry.name)
        Task { @MainActor in
            guard
                let input = await self.promptForName(
                    title: L("bvc.splitTitle", "Split into parts of how many MB?"), default: "100"),
                let mb = Double(input.trimmingCharacters(in: .whitespaces)), mb > 0
            else { return }
            let partSize = Int64(mb * 1_000_000)
            do {
                _ = try await Task.detached { try FileSplitter.split(file, partSize: partSize) }.value
                self.activePane?.reloadIfShowingListing()
            } catch {
                self.presentInfo(L("bvc.splitFailed", "Couldn’t split the file"), error.localizedDescription)
            }
        }
    }

    /// Merge the ".001/.002/…" parts starting at the selected part back into the whole.
    private func mergeSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            let entry = pane.selectedEntries.first
        else { NSSound.beep(); return }
        let part = pane.currentURL.appendingPathComponent(entry.name)
        Task { @MainActor in
            do {
                let merged = try await Task.detached { try FileSplitter.merge(firstPart: part) }.value
                self.activePane?.reloadIfShowingListing()
                self.activePane?.select(name: merged.lastPathComponent)
            } catch {
                self.presentInfo(L("bvc.mergeFailed", "Couldn’t merge the parts"), error.localizedDescription)
            }
        }
    }

    /// Offload the selected downloaded iCloud files (evict the local copy; the cloud copy
    /// stays and the file becomes online-only).
    private func offloadSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs().filter { Backup.isOffloadable($0) }
        guard !urls.isEmpty else {
            presentInfo(
                L("offload.none", "Nothing to offload"),
                L("offload.noneBody", "Select downloaded iCloud files to free their local space."))
            return
        }
        let result = Backup.offload(urls)
        pane.reloadIfShowingListing()
        if !result.failures.isEmpty {
            presentFailures(result.failures, title: L("offload.failed", "Couldn’t offload"))
        }
    }

    /// Copy the selection to a chosen destination as a backup (originals kept).
    private func backupSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty, let window = view.window else { NSSound.beep(); return }
        backup(urls, over: window)
    }

    /// Inside a git repository, split the current folder's contents into what git already
    /// protects (tracked), what's safe to reclaim (regenerable build output/caches), and what
    /// git ISN'T protecting and is worth backing up (precious untracked data). Then offer to
    /// clean the first and back up the second.
    private func repoReclaim() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let folder = pane.currentURL
        guard let window = view.window else { return }
        Task { @MainActor in
            let items = await RepoScan.classify(folder)
            guard !items.isEmpty else {
                self.presentInfo(
                    L("repo.notRepo", "Not a git repository"),
                    L("repo.notRepoBody", "Reclaim only runs inside a git repository, where it can tell tracked files from regenerable junk and precious untracked data."))
                return
            }
            let regenerable = items.filter { $0.disposition == .regenerable }
            let precious = items.filter { $0.disposition == .precious }
            let tracked = items.filter { $0.disposition == .tracked }
            let bytes = ByteCountFormatter()
            func size(_ list: [RepoScan.Item]) -> String {
                bytes.string(fromByteCount: list.reduce(0) { $0 + $1.size })
            }
            func urls(_ list: [RepoScan.Item]) -> [URL] {
                list.map { folder.appendingPathComponent($0.name) }
            }

            let alert = NSAlert()
            alert.messageText = String(
                format: L("repo.title", "Reclaim in %@"), folder.lastPathComponent)
            alert.informativeText = String(
                format: L(
                    "repo.summary",
                    "Regenerable (safe to clean): %d, %@\nPrecious (untracked, worth backing up): %d, %@\nTracked (git already has these): %d"),
                regenerable.count, size(regenerable), precious.count, size(precious), tracked.count)

            // Offer only the actions that apply, mapped by button order.
            var actions: [() -> Void] = []
            if !regenerable.isEmpty {
                alert.addButton(
                    withTitle: String(format: L("repo.clean", "Clean Regenerable (%d)"), regenerable.count))
                let toTrash = urls(regenerable)
                actions.append { [weak self] in self?.performLocalTrash(toTrash) }
            }
            if !precious.isEmpty {
                alert.addButton(
                    withTitle: String(format: L("repo.backup", "Back Up Precious… (%d)"), precious.count))
                let toBackUp = urls(precious)
                actions.append { [weak self] in self?.backup(toBackUp, over: window) }
            }
            if actions.isEmpty {
                self.presentInfo(
                    L("repo.nothing", "Nothing to reclaim"),
                    L("repo.nothingBody", "Everything here is tracked by git. There's no regenerable junk to clean and no untracked data to back up."))
                return
            }
            alert.addButton(withTitle: L("common.close", "Close"))
            alert.beginSheetModal(for: window) { response in
                let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                if index >= 0 && index < actions.count { actions[index]() }
            }
        }
    }

    /// Copy the given files to a chosen destination as a backup (originals kept). Shared by
    /// the selection backup and the repo-reclaim precious-data backup.
    private func backup(_ urls: [URL], over window: NSWindow) {
        guard !urls.isEmpty else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.prompt = L("backup.choose", "Back Up Here")
        picker.message = L("backup.message", "Choose a destination for the backup copy")
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = picker.url, let self else { return }
            Task { @MainActor in
                let result = await Task.detached { Backup.backup(urls, to: destination) }.value
                if !result.failures.isEmpty {
                    self.presentFailures(result.failures, title: L("backup.failed", "Couldn’t back up"))
                } else {
                    self.presentInfo(
                        L("backup.done", "Backed up"),
                        String(
                            format: L("backup.doneBody", "Copied %d item(s) to %@."),
                            result.succeeded.count, destination.lastPathComponent))
                }
            }
        }
    }

    /// Create an AES-256 encrypted disk image containing the selection, after prompting for
    /// a volume name and password.
    private func encryptToDiskImage() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty, let window = view.window else { NSSound.beep(); return }
        let folder = pane.currentURL

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        nameField.stringValue = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Encrypted"
        let passField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        passField.placeholderString = L("dmg.password", "Password")
        func labeledRow(_ label: String, _ control: NSView) -> NSStackView {
            let name = NSTextField(labelWithString: label)
            name.alignment = .right
            name.widthAnchor.constraint(equalToConstant: 80).isActive = true
            let row = NSStackView(views: [name, control])
            row.orientation = .horizontal
            row.spacing = 8
            return row
        }
        let accessory = NSStackView(views: [
            labeledRow(L("dmg.name", "Name"), nameField), labeledRow(L("dmg.passwordLabel", "Password"), passField),
        ])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 340, height: 66)

        let alert = NSAlert()
        alert.messageText = String(
            format: L("dmg.title", "New Encrypted Disk Image (%d item(s))"), urls.count)
        alert.accessoryView = accessory
        alert.addButton(withTitle: L("dmg.create", "Create"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = nameField.stringValue.isEmpty ? "Encrypted" : nameField.stringValue
            let password = passField.stringValue
            guard !password.isEmpty else { NSSound.beep(); return }
            Task { @MainActor in
                do {
                    let dmg = try await Task.detached {
                        try await DiskImage.createEncrypted(
                            from: urls, volumeName: name, password: password, in: folder)
                    }.value
                    self.activePane?.reloadIfShowingListing()
                    self.activePane?.select(name: dmg.lastPathComponent)
                } catch {
                    self.presentInfo(
                        L("dmg.failed", "Couldn’t create the disk image"), error.localizedDescription)
                }
            }
        }
    }

    /// Overwrite the selected files with random data and delete them, after a strong
    /// confirmation. Irreversible, and there is no Trash.
    private func secureDeleteSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty, let window = view.window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            format: L("bvc.secureDeleteQ", "Securely erase %d item(s)?"), urls.count)
        alert.informativeText = L(
            "bvc.secureDeleteBody",
            "The files are overwritten with random data and deleted. This cannot be undone and does not use the Trash. On SSD or APFS storage, secure erasure is best-effort.")
        alert.addButton(withTitle: L("bvc.secureDeleteConfirm", "Erase"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                let result = await Task.detached { SecureDelete.shred(urls) }.value
                self.activePane?.reloadIfShowingListing()
                if !result.failures.isEmpty {
                    self.presentFailures(result.failures, title: L("bvc.secureDeleteFailed", "Couldn’t erase"))
                }
            }
        }
    }

    /// Create a symlink, alias, or hard link next to each selected item (undoable).
    private func makeLinks(kind: FileOperations.LinkKind) {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let outcome = FileOperations.makeLinks(urls, kind: kind)
        pane.reloadIfShowingListing()
        let createdNames = outcome.performed.map { $0.destination.lastPathComponent }
        if let first = createdNames.first { pane.select(name: first) }
        if !createdNames.isEmpty {
            registerCreatedUndo(
                names: createdNames, in: pane.currentURL, actionName: L("bvc.makeLinkAction", "Make Link"))
        }
        if !outcome.failures.isEmpty {
            presentFailures(outcome.failures, title: L("bvc.makeLinkFailed", "Couldn’t create the link"))
        }
    }

    /// Attach a disk image (.dmg etc.) out-of-process and navigate the pane into it.
    private func attachDiskImage(_ image: URL, in pane: PaneController?) {
        Task { @MainActor [weak self] in
            do {
                let mountPoint = try await DiskImage.attach(image)
                (pane ?? self?.activePane)?.navigate(to: mountPoint)
            } catch {
                self?.reportArchiveError(L("bvc.couldntMount", "Couldn’t mount the disk image"), error)
            }
        }
    }

    /// Eject the volume that contains the active folder (disk image, USB, network share).
    private func ejectActiveVolume() {
        guard let pane = activePane, !pane.isRemote,
            let volume = (try? pane.currentURL.resourceValues(forKeys: [.volumeURLKey]))?.volume
        else { NSSound.beep(); return }
        ejectVolume(volume)
    }

    /// Eject a specific mounted volume, moving any pane that was inside it back home.
    private func ejectVolume(_ volume: URL) {
        if volume.path == "/" { NSSound.beep(); return }  // never the boot volume
        let home = FileManager.default.homeDirectoryForCurrentUser
        for side in [leftTabs, rightTabs] {
            if let pane = side.activePane, !pane.isRemote,
                pane.currentURL.path.hasPrefix(volume.path) {
                pane.navigate(to: home)
            }
        }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
        } catch {
            reportArchiveError(L("bvc.couldntEject", "Couldn’t eject the volume"), error)
        }
    }

    /// Search file contents under the active folder (grep/ripgrep), open a match.
    private func showFindInFiles() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults, let window = view.window
        else { NSSound.beep(); return }
        let folder = pane.currentURL
        findInFiles.present(
            over: window, folderName: folder.lastPathComponent,
            search: { query, regex, caseSensitive in
                await ContentSearch.search(query, in: folder, regex: regex, caseSensitive: caseSensitive)
            },
            open: { [weak self] match in self?.applyOpen(URL(fileURLWithPath: match.path)) },
            replace: { query, replacement, regex, caseSensitive in
                await ContentSearch.replaceAll(
                    query, with: replacement, in: folder, regex: regex, caseSensitive: caseSensitive)
            })
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

    /// Group files in the folder whose names are semantically similar (via the on-device
    /// embedder) and show them as smart results — the near-duplicate complement to Find
    /// Duplicates (which matches byte-identical content). Runs off the main thread.
    private func findSimilarNames() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let root = pane.currentURL
        let entries = pane.entries
        let token = pane.beginContentRequest()
        pane.showSmartResults([], title: String(format: L("bvc.findingSimilar", "Finding similar names in %@…"), root.lastPathComponent))
        Task { @MainActor [weak self] in
            let groups = await Task.detached { SemanticDedup.similarGroups(entries) }.value
            guard let self, self.activePane === pane, pane.isContentRequestCurrent(token) else { return }
            let files = groups.flatMap { $0.files }
            let title =
                groups.isEmpty
                ? String(format: L("bvc.noSimilar", "No similar names in %@"), root.lastPathComponent)
                : "Similar names: \(groups.count) group\(groups.count == 1 ? "" : "s"), \(files.count) files"
            pane.showSmartResults(files, title: title)
        }
    }

    /// Flat / recursive view: list every item under the current folder, flattened into one
    /// location-aware smart-result view (each row carries its own subfolder). Runs off the main
    /// thread; navigating away discards it, like the other smart views.
    private func flattenFolder() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let root = pane.currentURL
        let includingHidden = pane.showHiddenByDefault
        let token = pane.beginContentRequest()
        pane.showSmartResults([], title: String(format: L("bvc.flatteningLoading", "Listing everything in %@…"), root.lastPathComponent))
        Task { @MainActor [weak self] in
            let result = await Task.detached {
                FlatEnumerator.entries(of: root, includingHidden: includingHidden, includeFolders: true)
            }.value
            guard let self, self.activePane === pane, pane.isContentRequestCurrent(token) else { return }
            let count = result.entries.count
            let title =
                result.truncated
                ? String(format: L("bvc.flatCountTruncated", "All items in %@: %d+ (truncated)"), root.lastPathComponent, count)
                : String(format: L("bvc.flatCount", "All items in %@: %d"), root.lastPathComponent, count)
            pane.showSmartResults(result.entries, title: title)
        }
    }

    /// Suggest a new name for the single selected file with the on-device model, prefilling a
    /// standard rename sheet. The sheet opens immediately (name preselected) and the suggestion
    /// fills in when it lands, so the model's latency never blocks the UI. Applying goes through
    /// the normal rename + undo path.
    private func aiRenameSelection() {
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
    private func aiSummarizeFolder() {
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
    private func newWindowStartFolder() -> URL {
        if let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults { return pane.currentURL }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Detach the active tab into its own window: open a new window at that folder and, if the
    /// side still has other tabs, close the one we moved (so nothing is duplicated in place).
    private func moveActiveTabToNewWindow() {
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
    private func organizeFolder() {
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

    /// Copy the selection's file names to the clipboard, one per line. Uses the entries' own
    /// names so it works everywhere — local, remote, and smart results.
    private func copyNames() {
        let names = activePane?.selectedEntries.map(\.name) ?? []
        guard !names.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
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

    private func revealSelection() {
        if blockedByRemote() { return }
        guard let pane = activePane else { return }
        let urls = pane.selectedLocalURLs()  // location-aware (reveals the real file in smart views)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [pane.currentURL] : urls)
    }

    /// Reveal the selection in place: navigate the active pane to the file's real folder and
    /// select it there, instead of handing off to Finder. Most useful from search and smart
    /// views, where the file lives outside the folder currently on screen.
    private func revealSelectionInPathem() {
        if blockedByRemote() { return }
        guard let pane = activePane, let target = pane.selectedLocalURLs().first else { return }
        pane.reveal(target)
    }

    /// Jump to the original of a selected alias or symlink: resolve its target and reveal it
    /// (navigate to the target's folder and select it), like Finder's Show Original.
    private func showOriginal() {
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
    private func showInfo() {
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
    private func resetPathemData() {
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
                    "%@%@.\n\nTo finish uninstalling:\n1. Drag Pathem from Applications to the Trash.\n2. Optionally remove Pathem under System Settings ▸ Privacy & Security ▸ Full Disk Access — macOS keeps that grant until you clear it."),
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

    /// Save the active pane's current view format (mode, sort, hidden, folders-first) as a
    /// named Style.
    private func saveStyle() {
        guard let pane = activePane else { NSSound.beep(); return }
        Task { @MainActor in
            guard
                let name = await self.promptForName(title: L("bvc.saveStyleTitle", "Save style as:"), default: ""),
                !name.trimmingCharacters(in: .whitespaces).isEmpty
            else { return }
            self.windowState.saveStyle(WindowStateStore.Style(name: name, format: pane.format))
        }
    }

    /// Pick a saved Style and apply it to the active pane.
    private func applyStyle() {
        let all = windowState.styles()
        guard let window = view.window else { return }
        guard !all.isEmpty else {
            presentInfo(
                L("bvc.noStyles", "No styles"), L("bvc.noStylesBody", "Save one first with Save Style."))
            return
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 25))
        for style in all { popup.addItem(withTitle: style.name) }
        let alert = NSAlert()
        alert.messageText = L("bvc.applyStyleTitle", "Apply Style")
        alert.accessoryView = popup
        alert.addButton(withTitle: L("bvc.apply", "Apply"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                all.indices.contains(popup.indexOfSelectedItem)
            else { return }
            self.activePane?.applyFormat(all[popup.indexOfSelectedItem].format)
        }
    }

    private static var automationRulesURL: URL? {
        appSupportDirectory()?.appendingPathComponent("automation-rules.json")
    }

    /// Start the automation folder watchers (off in demo mode and under the smoke harness).
    private func setupAutomation() {
        guard demoLayout == nil, ProcessInfo.processInfo.environment["PATHEM_SMOKE"] == nil else { return }
        _ = automation  // lazy init loads the rules and starts the watchers
    }

    private func showAutomationRules() {
        automationRules.present(manager: automation, over: view.window)
    }

    /// Capture the current dual-pane, multi-tab layout under a name.
    private func saveWorkspace() {
        Task { @MainActor in
            guard
                let name = await self.promptForName(title: L("bvc.saveWorkspaceTitle", "Save workspace as:"), default: ""),
                !name.trimmingCharacters(in: .whitespaces).isEmpty
            else { return }
            self.windowState.saveWorkspace(
                WindowStateStore.Workspace(
                    name: name, left: self.leftTabs.tabFolders, leftActive: self.leftTabs.activeTabIndex,
                    right: self.rightTabs.tabFolders, rightActive: self.rightTabs.activeTabIndex))
        }
    }

    /// Pick a saved workspace and switch both panes to its layout.
    private func openWorkspace() {
        let all = windowState.workspaces()
        guard let window = view.window else { return }
        guard !all.isEmpty else {
            presentInfo(
                L("bvc.noWorkspaces", "No workspaces"),
                L("bvc.noWorkspacesBody", "Save one first with Save Workspace."))
            return
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 25))
        for workspace in all { popup.addItem(withTitle: workspace.name) }
        let alert = NSAlert()
        alert.messageText = L("bvc.openWorkspaceTitle", "Open Workspace")
        alert.accessoryView = popup
        alert.addButton(withTitle: L("common.open", "Open"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                all.indices.contains(popup.indexOfSelectedItem)
            else { return }
            let workspace = all[popup.indexOfSelectedItem]
            self.leftTabs.restoreTabs(workspace.left, active: workspace.leftActive)
            self.rightTabs.restoreTabs(workspace.right, active: workspace.rightActive)
            if let pane = self.leftTabs.activePane { self.setActiveSide(self.leftTabs, pane: pane) }
        }
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
    /// If the site has a default local directory, point the other (local) pane at it, pairing the
    /// local and remote sides on connect.
    private func openLocalPairing(_ connection: RemoteConnection) {
        guard !connection.localPath.isEmpty else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: connection.localPath, isDirectory: &isDir), isDir.boolValue else { return }
        let otherSide = (activeSide === leftTabs) ? rightTabs : leftTabs
        otherSide.activePane?.navigate(to: URL(fileURLWithPath: connection.localPath))
    }

    private func connectToRemote(_ connection: RemoteConnection, forceNewTab: Bool = false) {
        guard let pane = activePane else { return }
        openLocalPairing(connection)  // point the other pane at the site's default local dir
        // USB devices (adb / iOS) have no password; connect straight through.
        if connection.proto.isDevice {
            openRemoteConnection(connection, password: "", forceNewTab: forceNewTab, fallback: pane)
            return
        }
        // A remembered password connects straight away, no prompt.
        if let saved = KeychainStore.password(for: connection.id) {
            openRemoteConnection(connection, password: saved, forceNewTab: forceNewTab, fallback: pane)
            return
        }
        guard let window = view.window else { return }
        let who = connection.user.isEmpty ? L("bvc.anonymous", "anonymous") : connection.user
        let usingKey = connection.proto == .sftp && !connection.keyFile.isEmpty
        let alert = NSAlert()
        alert.messageText = String(format: L("bvc.connectTo", "Connect to %@"), connection.host)
        alert.informativeText =
            usingKey
            ? L("bvc.enterPassphrase", "Enter the private key’s passphrase (leave blank if it has none).")
            : String(format: L("bvc.enterPasswordFor", "Enter the password for %@@%@."), who, connection.host)
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let remember = NSButton(
            checkboxWithTitle: usingKey
                ? L("bvc.rememberPassphraseInKeychain", "Remember passphrase in Keychain")
                : L("bvc.rememberPasswordInKeychain", "Remember password in Keychain"),
            target: nil, action: nil)
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

    // MARK: - Shared (SMB) computers

    /// Resolve a discovered Bonjour host and mount its SMB share, then browse it.
    private func connectToShared(_ name: String) {
        sharedDiscovery.resolveHost(named: name) { [weak self] host in
            guard let self, let host else {
                self?.presentInfo(
                    L("smb.unreachableTitle", "Can’t reach that computer"),
                    String(
                        format: L("smb.unreachableBody", "Couldn’t resolve “%@” on the network. It may have gone offline."),
                        name))
                return
            }
            self.mountSMB(host: host)
        }
    }

    /// Edit the selected item's POSIX ACL (add/remove access-control entries).
    private func editACLSelection() {
        guard let pane = activePane, !pane.isRemote, let url = pane.selectedLocalURLs().first else { NSSound.beep(); return }
        aclEditor.present(url: url, over: view.window)
    }

    /// Change the owner of the selection. Because giving a file to another user needs root, Pathem
    /// types a ready-to-run `sudo chown` command into the embedded terminal (which prompts for the
    /// password) rather than bundling a privileged helper. Changing only the group is done without
    /// root via Set Attributes ▸ Group.
    private func changeOwnerViaTerminal() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let currentOwner = OwnershipEditor.read(urls[0])?.owner ?? ""

        let alert = NSAlert()
        alert.messageText = String(format: L("chown.title", "Change owner of %d item(s)"), urls.count)
        alert.informativeText = L(
            "chown.hint",
            "Changing the owner needs administrator rights, so Pathem will type a sudo command into the terminal — review it and press Return to run it. (To change only the group, use Set Attributes.)")
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

    // MARK: - Remote bookmarks

    /// Save the active remote pane's current path as a named bookmark on its
    /// connection, so it can be jumped back to from the Bookmarks menu.
    func addBookmark() {
        guard let ctx = activePane?.remoteContext else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = L("bookmark.title", "Bookmark This Folder")
        alert.informativeText = String(
            format: L("bookmark.hint", "Save “%@” on %@ so you can jump back to it later."),
            ctx.path, ctx.connection.name)
        alert.addButton(withTitle: L("common.save", "Save"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        let leaf = (ctx.path as NSString).lastPathComponent
        field.stringValue = leaf.isEmpty || leaf == "/" ? ctx.connection.name : leaf
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            guard
                let idx = self.connectionsController.connections.firstIndex(where: {
                    $0.id == ctx.connection.id
                })
            else {
                NSSound.beep()
                return
            }
            self.connectionsController.connections[idx].bookmarks.removeAll { $0.name == name }
            self.connectionsController.connections[idx].bookmarks.append(
                RemoteBookmark(name: name, remotePath: ctx.path))
            self.connectionsController.onChange?(self.connectionsController.connections)
        }
    }

    /// Reconnect the active remote pane at a saved bookmark's path, reusing the
    /// live session password so there's no re-prompt.
    func jumpToBookmark(_ bookmark: RemoteBookmark) {
        guard let pane = activePane, let ctx = pane.remoteContext else {
            NSSound.beep()
            return
        }
        var target = ctx.connection
        target.path = bookmark.remotePath
        openRemoteConnection(target, password: ctx.password, forceNewTab: false, fallback: pane)
    }

    /// Mount smb://host via NetFS (the OS handles auth/Keychain and shows its own
    /// prompt when needed), then navigate the active pane to the mount point.
    // MARK: - Scoped openers

    private static var openersURL: URL? {
        appSupportDirectory()?.appendingPathComponent("openers.json")
    }

    private func loadOpenerRules() {
        guard var saved = loadConfig(OpenerRules.self, from: Self.openersURL) else { return }
        // One-time migration: per-kind defaults now live in the system (LaunchServices), so drop
        // any legacy Pathem per-extension rules -- those kinds then defer to the system default,
        // like Finder. Per-file and per-folder overlays are kept (the OS can't express them).
        if !saved.byType.isEmpty {
            saved.byType.removeAll()
            saveConfig(saved, to: Self.openersURL)
        }
        openerRules = saved
    }

    /// Open a file with its resolved app: session override (by type) first, then
    /// the persisted file/folder/type rules, else the system default.
    private func applyOpen(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        // A .torrent opens in Pathem's own Torrents panel rather than handing off to another app.
        if ext == "torrent" {
            addTorrentToPanel(url)
            return
        }
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
        scopePopup.addItem(
            withTitle: ext.isEmpty
                ? L("bvc.scopeThisKind", "Files of this kind (system-wide)")
                : String(format: L("bvc.scopeAllExt", "All .%@ files (system-wide)"), ext))
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
        case .type:
            // "Files of this kind" is Finder's "Change All": set the real system default
            // (LaunchServices) so Pathem, Finder, and every other app agree, and drop any local
            // per-type rule so the system stays authoritative even if the default changes later.
            let type = (try? fileURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: ext) ?? .data
            NSWorkspace.shared.setDefaultApplication(at: URL(fileURLWithPath: appPath), toOpen: type) { _ in }
            openerRules.clearType(ext)
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
        resolveThenTransfer(urls: urls, into: destination, move: move, conflictCount: conflicts.count) { [weak self] outcome in
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

    private func transfer(move: Bool) {
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
    private func copyOrMoveTo(move: Bool) {
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
        transferInFlight = true  // so Quit warns mid-transfer
        transferRunner.run(
            urls: urls, into: destination, move: move, resolution: resolution,
            verify: !move && prefs.verifyCopies, over: view.window
        ) { [weak self] outcome in
            self?.transferInFlight = false
            completion(outcome)
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
            self.registerUndo(performed, actionName: actionName)  // back to undo
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
        Task { [weak self] in
            guard let self else { return }
            let ranked = await self.semanticSearch.rank(
                query: query, in: directory,
                isCurrent: { [weak self] in self?.activePane?.currentURL == directory })
            // Only adopt results if the very pane we searched is still active and
            // on that folder (not merely some pane that shares the path).
            guard let ranked, self.activePane === pane, pane.currentURL == directory else { return }
            pane.showResults(ranked)
        }
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
        if semanticSearch.cachedDirectory == url { semanticSearch.invalidate() }  // this folder changed on disk
        if pane === activePane {
            preIndex(url)
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

    /// Show or hide the embedded terminal drawer. On first show it starts a login
    /// shell in the active folder and gives the drawer a reasonable height.
    /// Show/hide the commander bar (orthodox F-key bar + command line) across the window bottom.
    /// Bind the Commander F3–F8 buttons to the user's chosen commands (or the defaults).
    func applyCommanderCommands() {
        commanderBar.commandIDs =
            prefs.commanderCommands.count == 6 ? prefs.commanderCommands : CommanderBar.defaultCommandIDs
    }

    func toggleCommander() {
        let show = commanderBar.isHidden
        commanderBar.isHidden = !show
        if show {
            shelf.view.isHidden = true  // the commander bar takes the bottom slot
            shelfHiddenConstraint?.isActive = false
            shelfShownConstraint?.isActive = false
            commanderShownConstraint?.isActive = true
            commanderBar.setPrompt(activePane?.currentURL.lastPathComponent ?? "")
            commanderBar.focusCommandLine()
        } else {
            commanderShownConstraint?.isActive = false
            shelfHiddenConstraint?.isActive = true
        }
        view.layoutSubtreeIfNeeded()
    }

    /// Run a commander command line in the embedded terminal (revealed if hidden), in the folder.
    private func runCommanderCommand(_ command: String) {
        let folder = activePane?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        if terminal.view.isHidden { toggleTerminal() }
        terminal.runInline(command, in: folder)
    }

    /// Keep the commander prompt in sync with the active folder (when the bar is showing).
    private func updateCommanderPrompt() {
        guard !commanderBar.isHidden else { return }
        commanderBar.setPrompt(activePane?.currentURL.lastPathComponent ?? "")
    }

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

    /// Set the active pane's view mode (PATHEM_VIEW_SHOT diagnostics).
    func debugSetActiveViewMode(_ mode: ViewFormat.ViewMode) { activePane?.setViewMode(mode) }

    /// Navigate the active pane (PATHEM_VIEW_SHOT diagnostics, bypassing session restore).
    func debugNavigateActive(to url: URL) { activePane?.navigate(to: url) }

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

    /// Toggle the preview pane and report whether both panes kept a real width (the
    /// regression guard for the auto-preview layout collapse). Used by the smoke self-check.
    func debugPreviewToggleKeepsPanes() -> Bool {
        let before = split.frame.width
        togglePreviewPane()  // show
        view.layoutSubtreeIfNeeded()
        let shown = split.frame.width
        togglePreviewPane()  // hide
        view.layoutSubtreeIfNeeded()
        let hidden = split.frame.width
        // With the preview open the panes must keep most of their width (not collapse to
        // zero), and closing it must restore them.
        return shown > 200 && hidden > before - 20
    }

    /// Drill the first column's row N (PATHEM_VIEW_SHOT column-drill test).
    func debugDrillActive(row: Int) { activePane?.debugColumnDrill(row: row) }

    /// Render the whole browser to a PNG (PATHEM_VIEW_SHOT diagnostics).
    func debugRender(to path: String) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 10, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("VIEW SHOT: \(path) \(Int(bounds.width))x\(Int(bounds.height))")
        }
    }

    /// Apply a skin and select the first row so a render shows the accent (PATHEM_THEME_SHOT).
    func debugApplyTheme(accentHex: String, tintHex: String) {
        prefs.accentColorHex = accentHex
        prefs.windowTintHex = tintHex
        applyTheme()
        if let first = activePane?.entries.first { activePane?.select(name: first.name) }
        view.layoutSubtreeIfNeeded()
    }

    /// Toggle commander mode (PATHEM_COMMANDER_SHOT); returns whether it's now visible.
    @discardableResult
    func debugToggleCommander() -> Bool {
        toggleCommander()
        view.layoutSubtreeIfNeeded()
        return !commanderBar.isHidden
    }

    /// Set the active pane's arrange-by key (PATHEM_ICONGROUP_SHOT).
    func debugSetActiveGroupKey(_ key: ViewFormat.GroupKey) {
        activePane?.setGroupKey(key)
        view.layoutSubtreeIfNeeded()
    }

    /// Switch the active icon set and reload (PATHEM_ICONSET_SHOT).
    func debugSetIconSet(_ name: String) {
        prefs.iconSetName = name
        applyIconSet()
        view.layoutSubtreeIfNeeded()
    }

    /// Set a folder background on the active folder and apply it (PATHEM_FOLDERBG_SHOT).
    func debugSetFolderBackground(colorHex: String, imagePath: String) {
        guard let pane = activePane else { return }
        folderBackgrounds.set(FolderBackground(colorHex: colorHex, imagePath: imagePath), for: pane.currentURL.path)
        pane.applyFolderBackground()
        view.layoutSubtreeIfNeeded()
    }

    /// Round-trip a folder background through the store (PATHEM_SMOKE): set, read, clear.
    func debugFolderBackgroundRoundTrips() -> Bool {
        let path = "/tmp/pathem-bg-\(UUID().uuidString)"
        folderBackgrounds.set(FolderBackground(colorHex: "#112233"), for: path)
        let got = folderBackgrounds.background(for: path)?.colorHex == "#112233"
        folderBackgrounds.set(nil, for: path)
        let cleared = folderBackgrounds.background(for: path) == nil
        return got && cleared
    }

    /// Force compact (icons-only) sidebar for a render check (PATHEM_SIDEBAR_COMPACT).
    func debugSetCompactSidebar(_ on: Bool) {
        prefs.compactSidebar = on
        applyCompactSidebar()
        view.layoutSubtreeIfNeeded()
    }

    /// Reorder sidebar sections for a render, without persisting (PATHEM_SIDEBAR_ORDER).
    func debugReorderSidebar(_ order: [String]) {
        sidebar.debugSetSectionOrder(order)
        view.layoutSubtreeIfNeeded()
    }

    /// Seed grouped connections for a render, without persisting (PATHEM_SITE_GROUPS).
    func debugSeedGroupedConnections() {
        let conns = [
            RemoteConnection(name: "Web 1", proto: .sftp, host: "web1.example.com", group: "Production"),
            RemoteConnection(name: "Web 2", proto: .sftp, host: "web2.example.com", group: "Production"),
            RemoteConnection(name: "Backups", proto: .s3, host: "s3.example.com", group: "Storage"),
            RemoteConnection(name: "Scratch", proto: .ftp, host: "ftp.example.com"),
        ]
        connectionsController.connections = conns  // reloads the manager table (no persistence)
        sidebar.setConnections(conns)  // group them in the sidebar
    }

    /// Seed sample color rules for a render, without persisting (PATHEM_COLOR_RULES).
    func debugSeedColorRules() {
        let rules = ColorRules(rules: [
            ColorRule(name: "Folders", field: .kind, op: .isAnyOf, value: "folder", colorHex: "#95D5B2", bold: true),
            ColorRule(name: "Images", field: .ext, op: .isAnyOf, value: "png, jpg, jpeg, gif, heic", colorHex: "#8ECAE6"),
            ColorRule(name: "Docs", field: .ext, op: .isAnyOf, value: "pdf, doc, docx, txt, md", colorHex: "#FFB4A2"),
            ColorRule(name: "Drafts", field: .name, op: .contains, value: "draft", colorHex: "#FFB703", italic: true),
            ColorRule(name: "Big files", field: .size, op: .greaterThan, value: "50", colorHex: "#E76F51", bold: true),
        ])
        leftTabs.activePane?.setColorRules(rules)
        rightTabs.activePane?.setColorRules(rules)
    }

    /// Apply binary sizes + relative dates for a render, without persisting (PATHEM_FORMATS).
    func debugSetBinaryRelativeFormats() {
        leftTabs.activePane?.setFormats(size: .binary, date: .relative)
        rightTabs.activePane?.setFormats(size: .binary, date: .relative)
    }

    /// Render the sidebar to a PNG for headless layout inspection (PATHEM_SIDEBAR_SHOT).
    func debugRenderSidebar(to path: String) {
        let view = sidebar.containerView
        let bounds = view.bounds
        guard bounds.width > 10, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SIDEBAR SHOT: \(Int(bounds.width))x\(Int(bounds.height))")
        }
    }
}
