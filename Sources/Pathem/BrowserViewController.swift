import AppKit
import NetFS
import PathemEngine
import PathemTerminal
import Quartz
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

    /// Set the selected image as the desktop picture on every screen.
    /// Set a chosen image as the selected item's custom icon (folder or file), via NSWorkspace.
    private func setCustomIcon() {
        guard let pane = activePane, !pane.isRemote, let target = pane.selectedLocalURLs().first, let window = view.window else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = L("customicon.choose", "Set Icon")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let iconURL = panel.url, let icon = NSImage(contentsOf: iconURL), let self else { return }
            if NSWorkspace.shared.setIcon(icon, forFile: target.path, options: []) {
                self.activePane?.reloadIfShowingListing()
            } else {
                self.presentInfo(
                    L("customicon.failedTitle", "Couldn’t set the icon"),
                    L("customicon.failedBody", "The custom icon couldn’t be applied. You may not have permission to change this item."))
            }
        }
    }

    /// Remove the custom icon from the selection (restore the default).
    private func removeCustomIcon() {
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        for url in pane.selectedLocalURLs() { NSWorkspace.shared.setIcon(nil, forFile: url.path, options: []) }
        pane.reloadIfShowingListing()
    }

    @objc private func setDesktopPicture() {
        guard let url = singleSelectedImageURL else { NSSound.beep(); return }
        var failed = false
        for screen in NSScreen.screens {
            do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]) } catch { failed = true }
        }
        if failed {
            presentInfo(
                L("bvc.desktopFailedTitle", "Couldn’t set the desktop picture"),
                L("bvc.desktopFailedBody", "The image may be in a format the desktop can’t use."))
        }
    }
    /// When on, navigating one pane replays the same relative move on the other, so two
    /// different roots stay in step (Directory-Opus-style synchronized browsing).
    private var syncBrowsing = false
    private var isSyncingPanes = false  // re-entrancy guard for the mirror navigation
    /// Each pane's last-seen local folder, so a navigation's relative delta can be
    /// computed (see `mirrorNavigationIfSyncing`). Keyed by pane identity.
    private var syncBrowseAnchors: [ObjectIdentifier: URL] = [:]
    private let split = NSSplitView()  // the two sides
    private let outerSplit = NSSplitView()  // sidebar | panes
    private let vSplit = NSSplitView()  // browser (top) | terminal (bottom)
    private let shelf = ShelfController()  // stash shelf / drop stack across the bottom
    private var shelfHiddenConstraint: NSLayoutConstraint?
    private var shelfShownConstraint: NSLayoutConstraint?
    private let commanderBar = CommanderBar()  // orthodox F-key bar + command line (Commander mode)
    private var commanderShownConstraint: NSLayoutConstraint?
    private let previewView = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
    private var previewVisible = false
    /// Durably pins the preview pane's width so it (and the panes) can't collapse; see
    /// togglePreviewPane(). Mirrors sidebarWidthConstraint.
    private var previewWidthConstraint: NSLayoutConstraint?
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
    private let sidebar = SidebarController()
    private let terminal = TerminalController()
    let searchField = NSSearchField()
    private var didSetInitialSplit = false
    /// Opt-in: when true the terminal `cd`s as the active folder changes. Off by
    /// default so navigation never disturbs whatever you're running in the shell.
    private var terminalFollows = UserDefaults.standard.bool(forKey: "pathem.terminalFollows")
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
    private var keymap = Keymap.standard
    /// Super-drag: direction -> command for a flick, and the swipe-trail overlay.
    private var dragGestures = DragGestureMap.standard
    private let dragTrail = DragTrailOverlay()
    private var dragStartScreen: NSPoint?  // to name the live flick as it changes direction
    /// Stroke -> command id, defaults overlaid with any user gestures.json.
    private var gestureMap = GestureMap.standard
    /// Per-folder saved view formats (the exact/subtree cascade), shared by both panes.
    var folderFormats = FolderFormats()
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
    /// Floating quick-action buttons shown over the panes when items are selected.
    private let quickBar = QuickActionsBar()
    /// Watches Downloads and floats a one-click "move to" chip; owns its own watcher + queue.
    let downloadSuggestions = DownloadSuggestionsController()
    /// Batch-rename sheet for the active pane's selection.
    private lazy var batchRename = BatchRenameController()
    private lazy var settings = SettingsWindowController()
    /// Settings embedded over the right pane (so browsing continues in the left pane).
    private var settingsPanel: NSView?
    private lazy var batchCreate = BatchCreateController()
    private lazy var templatesManager = TemplatesController()
    lazy var commitController = CommitController()
    private lazy var archiveContents = ArchiveContentsController()
    private lazy var findInFiles = FindInFilesController()
    private lazy var processViewer = ProcessViewerController()
    private lazy var externalCommandsController = ExternalCommandsController()
    private lazy var externalOutput = ExternalCommandOutputController()
    let slideshow = SlideshowController()
    private lazy var trimController = TrimController()
    private lazy var aclEditor = ACLEditorController()
    private lazy var markupController = MarkupController()
    private lazy var undoHistoryController = UndoHistoryController()
    private lazy var globalSearchController = GlobalSearchController()
    private var externalCommands: [ExternalCommand] = []
    /// Dynamic Tools > External Commands submenu (installed once the menu bar is up).
    private let externalCommandsMenu = NSMenu(title: "External Commands")
    private var didInstallExternalCommandsMenu = false
    private var createTemplates: [CreateTemplate] = []
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
    private var sidebarWidthConstraint: NSLayoutConstraint!
    /// Lays out the two panes at a fixed ratio (and tracks divider drags), so switching a
    /// pane to a content-light view (gallery) can't make the split re-divide and collapse it.
    private let paneSplitDelegate = PaneRatioSplitDelegate()
    private var compactSidebar = false
    private static let compactSidebarWidth: CGFloat = 60
    /// Guided Full Disk Access walkthrough (first launch, until granted).
    private lazy var fdaGuide = FullDiskAccessGuide()
    private lazy var infoInspector = InfoInspectorController()
    private lazy var connectionsController = ConnectionsController()
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
    private let layoutsMenu = NSMenu(title: "Layouts")
    private var didInstallLayoutsMenu = false
    private let savedViewsMenu = NSMenu(title: "Saved Views")
    private var didInstallSavedViewsMenu = false
    private let bookmarksMenu = NSMenu(title: "Bookmarks")
    private var didInstallBookmarksMenu = false
    /// The most-recently-visited folders (newest first), for the Go > Recent Folders submenu.
    private let recentFoldersMenu = NSMenu(title: "Recent Folders")
    private var didInstallRecentMenu = false
    private var recentFolders: [URL] = []


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

    // Constrain the sidebar width (outer split) and the terminal drawer height
    // (vertical split) so neither the sidebar, the panes, nor the terminal can be
    // dragged away to nothing.
    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        // Compact mode lets the sidebar shrink to an icons-only width.
        if splitView === outerSplit, dividerIndex == 0 { return compactSidebar ? 52 : 140 }
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

    /// Set the panes' divider to `fraction` (the right pane's share) and lay them out now.
    /// The delegate keeps that ratio across content swaps and window resizes.
    private func setRightPaneFraction(_ fraction: Double) {
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
    private static var savedSearchesURL: URL? { appSupportDirectory()?.appendingPathComponent("searches.json") }
    private static var viewPresetsURL: URL? { appSupportDirectory()?.appendingPathComponent("view-presets.json") }
    private var viewPresets = ViewPresets.default
    private func loadViewPresets() {
        viewPresets = loadConfig(ViewPresets.self, from: Self.viewPresetsURL) ?? .default
        registerViewPresetCommands()
    }
    /// Register each saved view as a command (so it appears in the palette and is bindable).
    private func registerViewPresetCommands() {
        for command in commands.all where command.id.hasPrefix("viewpreset.") { commands.unregister(command.id) }
        for preset in viewPresets.presets where !preset.name.isEmpty {
            let format = preset.format
            let name = preset.name
            commands.register(
                .init(
                    id: "viewpreset.\(name)", title: String(format: L("bvc.viewPresetCmd", "View: %@"), name),
                    isEnabled: { [weak self] in self?.activePane != nil },
                    run: { [weak self] in self?.applyViewPreset(format) }))
        }
    }
    private func applyViewPreset(_ format: ViewFormat) {
        guard let pane = activePane else { NSSound.beep(); return }
        pane.applyFormat(format)
        pane.setGroupKey(format.groupKey)  // applyFormat doesn't touch grouping
    }
    /// Prompt for a name and save the active pane's current view as a reusable preset.
    @objc private func saveViewPreset() {
        guard let pane = activePane, let window = view.window else { NSSound.beep(); return }
        _ = window
        let format = pane.format
        let alert = NSAlert()
        alert.messageText = L("viewpreset.saveTitle", "Save Current View As")
        alert.informativeText = L("viewpreset.saveHint", "Captures the view mode, sort, grouping, and hidden / folders-first, to apply to any folder.")
        alert.addButton(withTitle: L("common.save", "Save"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = L("viewpreset.name", "preset name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            self.viewPresets.save(.init(name: name, format: format))
            self.saveConfig(self.viewPresets, to: Self.viewPresetsURL)
            self.registerViewPresetCommands()
        }
    }

    private static var folderBackgroundsURL: URL? { appSupportDirectory()?.appendingPathComponent("folder-backgrounds.json") }
    private var folderBackgrounds = FolderBackgrounds.default
    private func loadFolderBackgrounds() {
        folderBackgrounds = loadConfig(FolderBackgrounds.self, from: Self.folderBackgroundsURL) ?? .default
    }
    private func reapplyFolderBackgrounds() {
        for side in [leftTabs, rightTabs] { for pane in side.tabs { pane.applyFolderBackground() } }
    }
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
    private var savedSearches = SavedSearches.default
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

    private func runSavedSearch(_ name: String, query: String) {
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        let token = pane.beginContentRequest()
        pane.showSmartResults([], title: String(format: L("bvc.searchingLoading", "Searching: %@…"), name))
        Task { @MainActor in
            let urls = await SpotlightSearch.matching(query, scope: nil, limit: 1000)
            let entries = await Task.detached { urls.map { FileEntry(contentsOf: $0) } }.value
            guard self.activePane === pane, pane.isContentRequestCurrent(token) else { return }
            let title = String(format: L("bvc.searchCount", "Search: %@ (%d)"), name, entries.count)
            await self.presentSmartResults(entries, title: title, pane: pane, token: token)
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
    /// Present `alert` as a sheet attached to the window -- so it appears on the window
    /// (dropping from its title bar), not centered on the whole screen -- and await its
    /// response. Falls back to a screen-centered app-modal alert when there is no window yet.
    func presentSheet(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = view.window, window.isVisible else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private func promptForName(title: String, default value: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: L("common.ok", "OK"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard await presentSheet(alert) == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The user's default New Folder / New File base name (falling back if they cleared it).
    private var defaultNewFolderName: String {
        let name = prefs.newFolderName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? L("bvc.untitledFolder", "untitled folder") : name
    }
    private var defaultNewFileName: String {
        let name = prefs.newFileName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "untitled file" : name
    }

    private func newFolder() {
        guard let pane = activePane else { return }
        if pane.isShowingSmartResults { NSSound.beep(); return }  // no single destination
        if pane.isRemote {
            Task { @MainActor in
                guard let name = await self.promptForName(title: L("bvc.newFolderPrompt", "New Folder"), default: self.defaultNewFolderName) else { return }
                self.performRemoteOp(pane, verb: L("bvc.newFolderVerb", "New Folder")) { provider, connection, path, password in
                    try await provider.makeDirectory(
                        connection, path: PaneController.joinRemote(path, name), password: password)
                }
            }
            return
        }
        do {
            let name = try FileOperations.makeFolder(in: pane.currentURL, baseName: defaultNewFolderName)
            pane.reloadIfShowingListing()
            pane.select(name: name)
            registerNewItemUndo(name: name, in: pane.currentURL, actionName: L("bvc.newFolderVerb", "New Folder"))
        } catch {
            presentFailures(
                [FileOperations.Failure(name: L("bvc.newFolderVerb", "New Folder"), reason: error.localizedDescription)],
                title: L("bvc.couldntCreateFolder", "Couldn’t create folder"))
        }
    }

    /// Move the current selection into a fresh folder here, in one undoable action (Finder's
    /// Ctrl-Cmd-N "New Folder with Selection"). Falls back to a plain New Folder when nothing
    /// is selected.
    private func newFolderWithSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let names = pane.selectedEntries.map(\.name)
        guard !names.isEmpty else { newFolder(); return }
        let directory = pane.currentURL
        do {
            let folderName = try FileOperations.makeFolder(
                in: directory, baseName: L("bvc.newFolderWithItems", "New Folder With Items"))
            let outcome = FileOperations.move(
                names, from: directory, to: directory.appendingPathComponent(folderName), onConflict: .keepBoth)
            pane.reloadIfShowingListing()
            pane.select(name: folderName)
            registerFolderWithSelectionUndo(folderName: folderName, in: directory, moved: outcome.performed)
            if !outcome.failures.isEmpty {
                presentFailures(outcome.failures, title: L("bvc.moveIntoFolderFailed", "Couldn’t move some items into the folder"))
            }
        } catch {
            presentFailures(
                [FileOperations.Failure(name: L("bvc.newFolderVerb", "New Folder"), reason: error.localizedDescription)],
                title: L("bvc.couldntCreateFolder", "Couldn’t create folder"))
        }
    }

    /// Undo of New Folder with Selection: move the items back out, then trash the emptied folder.
    private func registerFolderWithSelectionUndo(
        folderName: String, in directory: URL, moved: [FileOperations.Performed]
    ) {
        let paths = Self.paths(of: moved).union([directory.appendingPathComponent(folderName).path])
        actionHistory.record(
            name: L("bvc.newFolderWithSelectionAction", "New Folder with Selection"),
            footprint: paths, undoFootprint: paths
        ) { [weak self] in
            guard let self else { return }
            FileOperations.undo(moved)  // items back to their original spot in `directory`
            let trash = FileOperations.trash([folderName], in: directory)  // remove the now-empty folder
            self.reloadBothSides()
            if !trash.failures.isEmpty {
                self.presentFailures(trash.failures, title: L("bvc.undoFailed", "Undo failed"))
            }
            self.registerFolderWithSelectionRedo(folderName: folderName, in: directory, moved: moved)
        }
    }

    private func registerFolderWithSelectionRedo(
        folderName: String, in directory: URL, moved: [FileOperations.Performed]
    ) {
        let paths = Self.paths(of: moved).union([directory.appendingPathComponent(folderName).path])
        actionHistory.record(
            name: L("bvc.newFolderWithSelectionAction", "New Folder with Selection"),
            footprint: paths, undoFootprint: paths
        ) { [weak self] in
            guard let self else { return }
            let folderURL = directory.appendingPathComponent(folderName)
            try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let names = moved.map { $0.source.lastPathComponent }
            let outcome = FileOperations.move(names, from: directory, to: folderURL, onConflict: .keepBoth)
            self.reloadBothSides()
            self.registerFolderWithSelectionUndo(folderName: folderName, in: directory, moved: outcome.performed)
        }
    }

    /// Create a new empty file (local panes only); the Finder pain point this app fixes.
    private func newFile() {
        guard let pane = activePane else { return }
        if pane.isShowingSmartResults || pane.isRemote { NSSound.beep(); return }
        do {
            let name = try FileOperations.makeFile(in: pane.currentURL, baseName: defaultNewFileName)
            pane.reloadIfShowingListing()
            pane.select(name: name)
            registerNewItemUndo(name: name, in: pane.currentURL, actionName: L("bvc.cmd.newFile", "New File"))
        } catch {
            presentFailures(
                [FileOperations.Failure(name: L("bvc.cmd.newFile", "New File"), reason: error.localizedDescription)],
                title: L("bvc.couldntCreateFile", "Couldn’t create file"))
        }
    }

    // MARK: - Batch create + templates

    private static var templatesURL: URL? {
        appSupportDirectory()?.appendingPathComponent("create-templates.json")
    }

    private func loadTemplates() {
        createTemplates = loadConfig([CreateTemplate].self, from: Self.templatesURL) ?? []
        registerTemplateCommands()
    }

    private func saveTemplates() {
        saveConfig(createTemplates, to: Self.templatesURL)
        registerTemplateCommands()
    }

    /// Register one command per template (and drop deleted ones) so each appears in
    /// the command palette and is bindable in Settings > Shortcuts.
    private func registerTemplateCommands() {
        for command in commands.all where command.id.hasPrefix("create.template.") {
            commands.unregister(command.id)
        }
        for template in createTemplates {
            commands.register(
                .init(
                    id: "create.template.\(template.id)",
                    title: String(format: L("templates.commandTitle", "New: %@"), template.name),
                    isEnabled: { [weak self] in
                        guard let pane = self?.activePane else { return false }
                        return !pane.isRemote && !pane.isShowingSmartResults
                    },
                    run: { [weak self] in self?.runTemplate(template) }))
        }
    }

    // MARK: - User-defined external commands

    private static var externalCommandsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("external-commands.json")
    }
    private func loadExternalCommands() {
        externalCommands = loadConfig([ExternalCommand].self, from: Self.externalCommandsURL) ?? []
        registerExternalCommandCommands()
    }
    private func saveExternalCommands() {
        saveConfig(externalCommands, to: Self.externalCommandsURL)
        registerExternalCommandCommands()
    }

    /// Register one command per external command so each shows in the palette and is bindable in
    /// Settings > Shortcuts. Selection-referencing ones require a non-empty local selection.
    private func registerExternalCommandCommands() {
        for command in commands.all where command.id.hasPrefix("external.cmd.") {
            commands.unregister(command.id)
        }
        for command in externalCommands {
            commands.register(
                .init(
                    id: "external.cmd.\(command.id)",
                    title: String(format: L("extcmd.commandTitle", "Command: %@"), command.name),
                    isEnabled: { [weak self] in
                        guard let pane = self?.activePane, !pane.isRemote else { return false }
                        return !command.usesSelection || !pane.selectedEntries.isEmpty
                    },
                    run: { [weak self] in self?.runExternalCommand(command) }))
        }
    }

    private func runExternalCommand(_ command: ExternalCommand) {
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        if command.usesSelection && pane.selectedEntries.isEmpty { NSSound.beep(); return }
        externalOutput.run(command, files: pane.selectedLocalURLs(), directory: pane.currentURL)
    }

    func showExternalCommandsManager() {
        guard let window = view.window else { return }
        externalCommandsController.present(
            over: window, commands: externalCommands,
            onChange: { [weak self] commands in
                self?.externalCommands = commands
                self?.saveExternalCommands()
            },
            onRun: { [weak self] command in self?.runExternalCommand(command) })
    }

    /// Add a "External Commands" submenu to the Tools menu (built in PathemApp before the browser
    /// exists), listing each command plus a Manage entry.
    private func installExternalCommandsMenu() {
        guard !didInstallExternalCommandsMenu, let mainMenu = NSApp.mainMenu,
            let toolsMenu = mainMenu.items.compactMap({ $0.submenu }).first(where: { $0.title == L("menu.tools", "Tools") })
        else { return }
        externalCommandsMenu.delegate = self
        let item = NSMenuItem(title: L("menu.externalCommands", "External Commands"), action: nil, keyEquivalent: "")
        item.submenu = externalCommandsMenu
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(item)
        didInstallExternalCommandsMenu = true
    }

    private func populateExternalCommandsMenu() {
        externalCommandsMenu.removeAllItems()
        for command in externalCommands {
            let item = externalCommandsMenu.addItem(
                withTitle: command.name, action: #selector(runExternalCommandMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.id
        }
        if !externalCommands.isEmpty { externalCommandsMenu.addItem(.separator()) }
        let manage = externalCommandsMenu.addItem(
            withTitle: L("extcmd.manage", "Manage Commands…"), action: #selector(manageExternalCommandsMenu), keyEquivalent: "")
        manage.target = self
    }

    @objc private func runExternalCommandMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let command = externalCommands.first(where: { $0.id == id })
        else { return }
        runExternalCommand(command)
    }
    @objc private func manageExternalCommandsMenu() { showExternalCommandsManager() }

    // MARK: - macOS Shortcuts (run a Shortcut on the selection)

    /// List installed shortcuts (off-main), then pick one and run it on the selection.
    func showShortcutPicker() {
        guard let window = view.window else { return }
        Task { @MainActor in
            let names = await Task.detached { ShortcutsRunner.list() }.value
            guard !names.isEmpty else {
                self.presentInfo(
                    L("shortcut.noneTitle", "No Shortcuts found"),
                    L("shortcut.noneBody", "Create shortcuts in the Shortcuts app first (or the Shortcuts tool is unavailable)."))
                return
            }
            let alert = NSAlert()
            alert.messageText = L("shortcut.pickTitle", "Run Shortcut on Selection")
            alert.informativeText = L("shortcut.pickBody", "The chosen shortcut runs once per selected file.")
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
            popup.addItems(withTitles: names)
            alert.accessoryView = popup
            alert.addButton(withTitle: L("shortcut.run", "Run"))
            alert.addButton(withTitle: L("common.cancel", "Cancel"))
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            self.runShortcut(names[popup.indexOfSelectedItem])
        }
    }

    private func runShortcut(_ name: String) {
        let files = activePane?.selectedLocalURLs() ?? []
        externalOutput.run(title: String(format: L("shortcut.title", "Shortcut: %@"), name)) {
            ShortcutsRunner.runOnFiles(name: name, files: files)
        }
    }

    private func showBatchCreate() {
        guard let window = view.window, let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults
        else { NSSound.beep(); return }
        let folder = pane.currentURL
        batchCreate.present(
            over: window,
            create: { [weak self] names, kind in self?.runBatchCreate(names, kind: kind, in: folder) },
            saveTemplate: { [weak self] names, kind in self?.saveBatchAsTemplate(names, kind: kind) })
    }

    private func runBatchCreate(_ names: [String], kind: BatchCreate.Kind, in folder: URL) {
        let result = BatchCreate.create(names, kind: kind, in: folder)
        reloadBothSides()
        if let first = result.created.first { paneShowing(folder)?.select(name: first) }
        registerCreatedUndo(names: result.created, in: folder, actionName: L("batch.actionName", "Batch Create"))
        if !result.failures.isEmpty {
            presentFailures(result.failures, title: L("batch.someFailed", "Some items couldn’t be created"))
        }
    }

    private func saveBatchAsTemplate(_ names: [String], kind: BatchCreate.Kind) {
        Task { @MainActor in
            guard let name = await self.promptForName(
                title: L("batch.saveTemplateTitle", "Save as Template"),
                default: L("batch.templateDefaultName", "My Template"))
            else { return }
            let entries = names.map { kind == .folders ? "\($0)/" : $0 }
            self.createTemplates.append(CreateTemplate(id: UUID().uuidString, name: name, entries: entries))
            self.saveTemplates()
        }
    }

    private func showTemplatesManager() {
        guard let window = view.window else { return }
        templatesManager.present(
            over: window, templates: createTemplates,
            onChange: { [weak self] templates in
                self?.createTemplates = templates
                self?.saveTemplates()
            },
            onRun: { [weak self] template in self?.runTemplate(template) })
    }

    private func runTemplate(_ template: CreateTemplate) {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let folder = pane.currentURL
        let result = template.instantiate(in: folder)
        reloadBothSides()
        if let first = result.created.first { paneShowing(folder)?.select(name: first) }
        registerCreatedUndo(
            names: result.created, in: folder, actionName: L("templates.actionName", "New from Template"))
        if !result.failures.isEmpty {
            presentFailures(result.failures, title: L("batch.someFailed", "Some items couldn’t be created"))
        }
    }

    /// Undo support for a set of freshly-created items: trashing them reverses it.
    private func registerCreatedUndo(names: [String], in directory: URL, actionName: String) {
        guard !names.isEmpty else { return }
        let paths = Self.paths(names, in: directory)
        actionHistory.record(name: actionName, footprint: paths, undoFootprint: paths) { [weak self] in
            guard let self else { return }
            let result = FileOperations.trash(names, in: directory)
            self.reloadBothSides()
            if !result.failures.isEmpty {
                self.presentFailures(result.failures, title: L("bvc.undoFailed", "Undo failed"))
            }
            if !result.trashed.isEmpty {
                self.registerCreatedRedo(
                    names: names, in: directory, trashed: result.trashed, actionName: actionName)
            }
        }
    }

    private func registerCreatedRedo(
        names: [String], in directory: URL, trashed: [FileOperations.Trashed], actionName: String
    ) {
        let paths = Self.paths(names, in: directory)
        actionHistory.record(name: actionName, footprint: paths, undoFootprint: paths) { [weak self] in
            guard let self else { return }
            let failures = FileOperations.untrash(trashed)
            self.reloadBothSides()
            if !failures.isEmpty { self.presentFailures(failures, title: L("bvc.redoFailed", "Redo failed")) }
            self.registerCreatedUndo(names: names, in: directory, actionName: actionName)
        }
    }

    private func registerNewItemUndo(name: String, in directory: URL, actionName: String) {
        let paths = Self.paths([name], in: directory)
        actionHistory.record(name: actionName, footprint: paths, undoFootprint: paths) { [weak self] in
            guard let self else { return }
            let result = FileOperations.trash([name], in: directory)  // undo = trash the new item
            self.reloadBothSides()
            if !result.failures.isEmpty { self.presentFailures(result.failures, title: L("bvc.undoFailed", "Undo failed")) }
            if !result.trashed.isEmpty {
                self.registerNewItemRedo(name: name, in: directory, trashed: result.trashed, actionName: actionName)
            }
        }
    }

    private func registerNewItemRedo(
        name: String, in directory: URL, trashed: [FileOperations.Trashed], actionName: String
    ) {
        let paths = Self.paths([name], in: directory)
        actionHistory.record(name: actionName, footprint: paths, undoFootprint: paths) { [weak self] in
            guard let self else { return }
            let failures = FileOperations.untrash(trashed)  // redo = restore the item
            self.reloadBothSides()
            self.paneShowing(directory)?.select(name: name)
            if !failures.isEmpty { self.presentFailures(failures, title: L("bvc.redoFailed", "Redo failed")) }
            self.registerNewItemUndo(name: name, in: directory, actionName: actionName)
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

    // MARK: - Trash: origins ledger, Put Back, Delete Immediately, Empty Trash

    private static var trashOriginsURL: URL? {
        appSupportDirectory()?.appendingPathComponent("trash-origins.json")
    }
    /// Where each Pathem-trashed item came from (trashed path -> original path), so Put Back can
    /// restore it. Finder-trashed items aren't here (the OS keeps that info privately).
    private var trashOrigins: [String: String] = [:]
    private func loadTrashOrigins() {
        trashOrigins = loadConfig([String: String].self, from: Self.trashOriginsURL) ?? [:]
    }
    private func recordTrashOrigins(_ trashed: [FileOperations.Trashed]) {
        guard !trashed.isEmpty else { return }
        for item in trashed { trashOrigins[item.trashed.path] = item.original.path }
        saveConfig(trashOrigins, to: Self.trashOriginsURL)
    }

    private var homeTrashURL: URL {
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

    /// Restore the selected trashed items to their original locations (recorded when Pathem
    /// trashed them). Items with no recorded origin (e.g. trashed by Finder) are reported.
    private func putBackSelection() {
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        var failures: [FileOperations.Failure] = []
        for url in urls {
            guard let originalPath = trashOrigins[url.path] else {
                failures.append(
                    .init(
                        name: url.lastPathComponent,
                        reason: L("bvc.putBackUnknown", "Original location unknown (not trashed by Pathem).")))
                continue
            }
            let destination = uniqueLocalURL(URL(fileURLWithPath: originalPath))
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: destination)
                trashOrigins[url.path] = nil
            } catch {
                failures.append(.init(name: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        saveConfig(trashOrigins, to: Self.trashOriginsURL)
        reloadBothSides()
        if !failures.isEmpty { presentFailures(failures, title: L("bvc.putBackFailed", "Couldn’t put back")) }
    }

    /// Permanently delete the selection, bypassing the Trash (Finder's Delete Immediately).
    private func deleteImmediatelySelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty, view.window != nil else { NSSound.beep(); return }
        Task { @MainActor in
            let message =
                urls.count == 1
                ? L("bvc.deleteNowOne", "Permanently delete this item?")
                : String(format: L("bvc.deleteNowMany", "Permanently delete %d items?"), urls.count)
            let choice = await self.cursorConfirm.ask(
                message: message, info: L("bvc.cantBeUndone", "This can’t be undone."),
                buttons: [L("common.delete", "Delete"), L("common.cancel", "Cancel")], over: self.view)
            guard choice == 0 else { return }
            var failures: [FileOperations.Failure] = []
            for url in urls {
                do { try FileManager.default.removeItem(at: url) } catch {
                    failures.append(.init(name: url.lastPathComponent, reason: error.localizedDescription))
                }
                self.trashOrigins[url.path] = nil
            }
            saveConfig(self.trashOrigins, to: Self.trashOriginsURL)
            self.reloadBothSides()
            if !failures.isEmpty { self.presentFailures(failures, title: L("bvc.deleteFailed", "Delete failed")) }
        }
    }

    /// Permanently erase everything in the (home) Trash, after a confirmation at the pointer.
    private func emptyTrash() {
        let items =
            (try? FileManager.default.contentsOfDirectory(
                at: homeTrashURL, includingPropertiesForKeys: nil)) ?? []
        guard !items.isEmpty, view.window != nil else { NSSound.beep(); return }
        Task { @MainActor in
            let choice = await self.cursorConfirm.ask(
                message: String(
                    format: L("bvc.emptyTrashTitle", "Permanently erase %d item(s) in the Trash?"), items.count),
                info: L("bvc.cantBeUndone", "This can’t be undone."),
                buttons: [L("bvc.emptyTrashAction", "Empty Trash"), L("common.cancel", "Cancel")], over: self.view)
            guard choice == 0 else { return }
            var failed = 0
            for item in items {
                do { try FileManager.default.removeItem(at: item) } catch { failed += 1 }
                self.trashOrigins[item.path] = nil
            }
            saveConfig(self.trashOrigins, to: Self.trashOriginsURL)
            self.reloadBothSides()
            if failed > 0 {
                self.presentInfo(
                    L("bvc.emptyTrashPartialTitle", "Some items couldn’t be erased"),
                    L("bvc.emptyTrashPartialBody", "They may be locked or in use."))
            }
        }
    }

    func registerTrashUndo(_ trashed: [FileOperations.Trashed]) {
        let paths = Set(trashed.flatMap { [$0.original.path, $0.trashed.path] })
        actionHistory.record(
            name: L("bvc.moveToTrashAction", "Move to Trash"), footprint: paths, undoFootprint: paths
        ) { [weak self] in
            guard let self else { return }
            let failures = FileOperations.untrash(trashed)
            self.reloadBothSides()
            if !failures.isEmpty { self.presentFailures(failures, title: L("bvc.undoFailed", "Undo failed")) }
            self.registerTrashRedo(trashed)  // redo = move them back to the Trash
        }
    }

    private func registerTrashRedo(_ trashed: [FileOperations.Trashed]) {
        let paths = Set(trashed.flatMap { [$0.original.path, $0.trashed.path] })
        actionHistory.record(
            name: L("bvc.moveToTrashAction", "Move to Trash"), footprint: paths, undoFootprint: paths
        ) { [weak self] in
            guard let self else { return }
            // Trash by original URL so cross-folder selections redo correctly.
            let result = FileOperations.trash(urls: trashed.map(\.original))
            self.reloadBothSides()
            if !result.failures.isEmpty { self.presentFailures(result.failures, title: L("bvc.redoFailed", "Redo failed")) }
            if !result.trashed.isEmpty { self.registerTrashUndo(result.trashed) }
        }
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

    private func compress7zSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs()
        guard !urls.isEmpty else { NSSound.beep(); return }
        let folder = pane.currentURL
        let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let dest = uniqueLocalURL(folder.appendingPathComponent("\(base).7z"))
        Task { @MainActor [weak self] in
            do {
                try await Archiver.compress7z(urls, to: dest)
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

    /// Extract each selected archive's contents directly into the current directory
    /// (no per-archive subfolder), matching a manager's "Extract Here".
    private func extractHereSelection() {
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        let archives = pane.selectedLocalURLs().filter { Archiver.canExtract($0) }
        guard !archives.isEmpty else { NSSound.beep(); return }
        let folder = pane.currentURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failed = false
            for archive in archives {
                do { try await Archiver.extract(archive, to: folder) } catch { failed = true }
            }
            self.reloadBothSides()
            if failed { self.reportArchiveError(L("bvc.couldntExtract", "Couldn’t extract one or more archives"), nil) }
        }
    }

    /// Choose a destination folder, then extract each selected archive into its own
    /// subfolder there ("Extract to Folder…").
    private func extractToSelection() {
        guard let pane = activePane, !pane.isRemote else { NSSound.beep(); return }
        let archives = pane.selectedLocalURLs().filter { Archiver.canExtract($0) }
        guard !archives.isEmpty, let window = view.window else { NSSound.beep(); return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.prompt = L("extract.choose", "Extract Here")
        picker.message = L("extract.message", "Choose a folder to extract into")
        picker.directoryURL = pane.currentURL
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = picker.url, let self else { return }
            Task { @MainActor in
                var failed = false
                for archive in archives {
                    let name = (archive.lastPathComponent as NSString).deletingPathExtension
                    let out = self.uniqueLocalURL(destination.appendingPathComponent(name))
                    do { try await Archiver.extract(archive, to: out) } catch { failed = true }
                }
                self.reloadBothSides()
                if failed { self.reportArchiveError(L("bvc.couldntExtract", "Couldn’t extract one or more archives"), nil) }
            }
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

    /// Full-screen slideshow: 2+ selected images play as-is; otherwise every image in the folder
    /// plays, starting at the one selected (if any). Non-image selections are ignored.
    private func startSlideshow() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let selected = pane.selectedLocalURLs().filter { Self.isImageName($0.lastPathComponent) }
        if selected.count >= 2 {
            slideshow.start(urls: selected)
            return
        }
        let folderImages = pane.entries
            .filter { !$0.isDirectory && Self.isImageName($0.name) }
            .map { pane.currentURL.appendingPathComponent($0.name) }
        guard !folderImages.isEmpty else { NSSound.beep(); return }
        let start = selected.first.flatMap { folderImages.firstIndex(of: $0) } ?? 0
        slideshow.start(urls: folderImages, startAt: start)
    }

    /// Rotate the selected images in place (270 = left, 90 = right) via sips. Not undoable (sips
    /// re-encodes); rotating the other way restores the orientation.
    private func rotateSelection(clockwiseDegrees: Int) {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs().filter { Self.isImageName($0.lastPathComponent) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        Task { @MainActor in
            let result = await ImageConverter.rotate(urls, clockwiseDegrees: clockwiseDegrees)
            self.activePane?.reloadIfShowingListing()
            self.invalidateThumbnails(urls)  // the on-disk pixels changed; drop stale thumbnails
            if !result.failures.isEmpty {
                self.presentFailures(result.failures, title: L("bvc.rotateFailed", "Couldn’t rotate"))
            }
        }
    }

    /// Combine the selected images and PDFs into one new PDF in the folder, then select it.
    private func createPDFFromSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs().filter {
            Self.isImageName($0.lastPathComponent) || $0.pathExtension.lowercased() == "pdf"
        }
        guard !urls.isEmpty else { NSSound.beep(); return }
        let folder = pane.currentURL
        Task { @MainActor in
            let out = await Task.detached { Self.buildPDF(from: urls, in: folder) }.value
            self.activePane?.reloadIfShowingListing()
            if let out {
                self.activePane?.select(name: out.lastPathComponent)
            } else {
                self.presentInfo(
                    L("bvc.createPDFFailedTitle", "Couldn’t create PDF"),
                    L("bvc.createPDFFailedBody", "None of the selected files could be added to a PDF."))
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

    /// Drop cached thumbnails for files whose pixels changed on disk, so the grids regenerate them.
    private func invalidateThumbnails(_ urls: [URL]) {
        for url in urls { ThumbnailProvider.shared.evict(url) }
    }

    /// Mark up the selected image (freehand annotations), saving a flattened copy.
    private func markupSelection() {
        guard let pane = activePane, !pane.isRemote, let url = pane.selectedLocalURLs().first,
            Self.isImageName(url.lastPathComponent)
        else { NSSound.beep(); return }
        markupController.onSaved = { [weak self] output in
            self?.activePane?.reloadIfShowingListing()
            self?.activePane?.select(name: output.lastPathComponent)
        }
        markupController.onFailed = { [weak self] message in
            self?.presentInfo(L("markup.failedTitle", "Couldn’t mark up"), message)
        }
        markupController.markup(url)
    }

    /// Trim the selected audio/video file: show the native trim UI, then export the range to a
    /// new "<name> trimmed" file and select it.
    private func trimSelection() {
        guard let pane = activePane, !pane.isRemote, let url = pane.selectedLocalURLs().first,
            TrimController.trimmableExtensions.contains(url.pathExtension.lowercased())
        else { NSSound.beep(); return }
        trimController.onExported = { [weak self] output in
            self?.activePane?.reloadIfShowingListing()
            self?.activePane?.select(name: output.lastPathComponent)
        }
        trimController.onFailed = { [weak self] message in
            self?.presentInfo(L("trim.failedTitle", "Couldn’t trim"), message)
        }
        trimController.trim(url)
    }

    /// Convert/resize the selected images via sips (out-of-process), after a small dialog
    /// for the target format and maximum pixel size.
    private func convertImagesSelection() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { NSSound.beep(); return }
        let urls = pane.selectedLocalURLs().filter { Self.isImageName($0.lastPathComponent) }
        guard !urls.isEmpty, let window = view.window else { NSSound.beep(); return }

        let formatPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 25))
        formatPopup.addItem(withTitle: L("convert.keepFormat", "Keep format"))
        for format in ImageConverter.Format.allCases { formatPopup.addItem(withTitle: format.rawValue.uppercased()) }
        let sizeField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        sizeField.placeholderString = L("convert.maxPixels", "Max pixels (optional)")
        func row(_ label: String, _ control: NSView) -> NSStackView {
            let name = NSTextField(labelWithString: label)
            name.font = .systemFont(ofSize: 12)
            name.alignment = .right
            name.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let stack = NSStackView(views: [name, control])
            stack.orientation = .horizontal
            stack.spacing = 8
            return stack
        }
        let stripCheck = NSButton(
            checkboxWithTitle: L("convert.strip", "Strip metadata (EXIF, GPS)"), target: nil, action: nil)
        let accessory = NSStackView(views: [
            row(L("convert.formatLabel", "Format"), formatPopup),
            row(L("convert.sizeLabel", "Max size"), sizeField),
            stripCheck,
        ])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 320, height: 92)

        let alert = NSAlert()
        alert.messageText = String(format: L("bvc.convertImagesQ", "Convert %d image(s)"), urls.count)
        alert.accessoryView = accessory
        alert.addButton(withTitle: L("common.convert", "Convert"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let index = formatPopup.indexOfSelectedItem
            let format = index > 0 ? ImageConverter.Format.allCases[index - 1] : nil
            let maxDim = Int(sizeField.stringValue.trimmingCharacters(in: .whitespaces))
            let options = ImageConverter.Options(
                format: format, maxDimension: maxDim.flatMap { $0 > 0 ? $0 : nil },
                stripMetadata: stripCheck.state == .on)
            guard !options.isNoOp else { return }
            Task { @MainActor in
                let result = await ImageConverter.process(urls, options: options)
                self.activePane?.reloadIfShowingListing()
                if !result.failures.isEmpty {
                    self.presentFailures(result.failures, title: L("bvc.convertFailed", "Couldn’t convert"))
                }
            }
        }
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

    /// Peek inside an archive (read-only listing), with Extract All from the panel.
    private func peekArchive() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults,
            pane.selectedEntries.count == 1, let window = view.window
        else { NSSound.beep(); return }
        guard let archive = pane.selectedLocalURLs().first, Archiver.canExtract(archive) else {
            NSSound.beep(); return
        }
        let folder = pane.currentURL
        Task { @MainActor in
            do {
                let paths = try await Archiver.list(archive)
                self.archiveContents.present(
                    over: window, archiveName: archive.lastPathComponent, entries: paths,
                    onExtractAll: { [weak self] in self?.extractArchive(archive, in: folder) })
            } catch {
                self.reportArchiveError(L("archive.cantRead", "Couldn’t read the archive"), error)
            }
        }
    }

    /// On leaving a browsed archive, if its extracted contents changed, offer to repack
    /// them back into the original archive.
    private func writeBackArchiveIfChanged(archive: URL, mountRoot: URL, original: [String: String]) {
        // RAR and other read-only formats can't be repacked; browse them without prompting.
        guard Archiver.canRepack(archive) else { return }
        Task { @MainActor in
            let changed = await Task.detached { Archiver.snapshot(of: mountRoot) != original }.value
            guard changed, let window = self.view.window else { return }
            let alert = NSAlert()
            alert.messageText = String(
                format: L("archive.saveBackTitle", "Save changes to %@?"), archive.lastPathComponent)
            alert.informativeText = L(
                "archive.saveBackBody", "You changed files inside this archive. Repack them into it?")
            alert.addButton(withTitle: L("archive.saveBackSave", "Save to Archive"))
            alert.addButton(withTitle: L("archive.saveBackDiscard", "Discard"))
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                Task { @MainActor in
                    do {
                        try await Archiver.repack(from: mountRoot, into: archive)
                        self.reloadBothSides()
                    } catch {
                        self.reportArchiveError(
                            L("archive.saveBackFailed", "Couldn’t save changes to the archive"), error)
                    }
                }
            }
        }
    }

    private func extractArchive(_ archive: URL, in folder: URL) {
        Task { @MainActor in
            let name = (archive.lastPathComponent as NSString).deletingPathExtension
            let out = self.uniqueLocalURL(folder.appendingPathComponent(name))
            do {
                try await Archiver.extract(archive, to: out)
                self.reloadBothSides()
            } catch {
                self.reportArchiveError(L("bvc.couldntExtract", "Couldn’t extract one or more archives"), error)
            }
        }
    }

    func reportArchiveError(_ title: String, _ error: Error?) {
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
        let deleteExtras = NSButton(checkboxWithTitle: L("bvc.alsoDeleteMissing", "Also delete files missing from the source (mirror only)"), target: nil, action: nil)
        alert.accessoryView = deleteExtras
        alert.addButton(withTitle: L("bvc.syncTwoWay", "Sync Both Ways (newer wins)"))
        alert.addButton(withTitle: L("bvc.mirrorLeftToRight", "Mirror Left → Right"))
        alert.addButton(withTitle: L("bvc.mirrorRightToLeft", "Mirror Right → Left"))
        alert.addButton(withTitle: L("common.close", "Close"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            let delete = deleteExtras.state == .on
            switch response {
            case .alertFirstButtonReturn: self?.runSync(left: leftURL, right: rightURL)
            case .alertSecondButtonReturn: self?.runMirror(source: leftURL, target: rightURL, deleteExtras: delete)
            case .alertThirdButtonReturn: self?.runMirror(source: rightURL, target: leftURL, deleteExtras: delete)
            default: break
            }
        }
    }

    /// Two-way additive sync (recompute fresh, apply off-main): copy each side's unique
    /// and newer files to the other; never deletes.
    private func runSync(left: URL, right: URL) {
        Task { @MainActor [weak self] in
            let actions = await Task.detached {
                FolderSync.plan(left: left, right: right, conflict: .newerWins)
            }.value
            guard let self else { return }
            let toRight = actions.filter { $0.direction == .toRight }
            let toLeft = actions.filter { $0.direction == .toLeft }
            let conflicts = actions.filter { $0.direction == nil && $0.wasConflict }
            if toRight.isEmpty && toLeft.isEmpty {
                self.presentInfo(
                    L("sync.upToDateTitle", "Already in sync"),
                    conflicts.isEmpty
                        ? L("sync.upToDateBody", "Both folders already match.")
                        : String(
                            format: L("sync.upToDateConflicts", "Both folders match except %d file(s) that changed on both sides at the same time; those are left untouched."),
                            conflicts.count))
                return
            }
            // Two-way sync copies files across; show exactly what will move before doing it.
            guard await self.confirmSync(toRight: toRight, toLeft: toLeft, conflicts: conflicts, left: left, right: right)
            else { return }
            let result = await Task.detached { FolderSync.execute(actions, left: left, right: right) }.value
            self.reloadBothSides()
            self.presentSyncResult(result)
        }
    }

    /// Preview what a two-way sync will copy in each direction (with a sample of file names)
    /// and how many conflicts it will leave alone, and return whether the user confirmed.
    private func confirmSync(
        toRight: [FolderSync.Action], toLeft: [FolderSync.Action], conflicts: [FolderSync.Action],
        left: URL, right: URL
    ) async -> Bool {
        guard let window = view.window else { return false }
        func sample(_ actions: [FolderSync.Action], _ arrow: String) -> String {
            var lines = actions.prefix(6).map { "  \(arrow) \($0.relativePath)" }
            if actions.count > 6 {
                lines.append("  " + String(format: L("sync.more", "…and %d more"), actions.count - 6))
            }
            return lines.joined(separator: "\n")
        }
        var body = ""
        if !toRight.isEmpty {
            body += String(format: L("sync.toRightHeader", "Copy %d into %@:"), toRight.count, right.lastPathComponent)
            body += "\n" + sample(toRight, "→") + "\n\n"
        }
        if !toLeft.isEmpty {
            body += String(format: L("sync.toLeftHeader", "Copy %d into %@:"), toLeft.count, left.lastPathComponent)
            body += "\n" + sample(toLeft, "←") + "\n\n"
        }
        if !conflicts.isEmpty {
            body += String(
                format: L("sync.conflictsNote", "%d file(s) changed on both sides at the same time; those are left untouched.\n\n"),
                conflicts.count)
        }
        body += L("sync.nothingDeleted", "Nothing is deleted — only newer and missing files are copied.")

        let alert = NSAlert()
        alert.messageText = String(
            format: L("sync.confirmTitle", "Sync %@ ↔ %@"), left.lastPathComponent, right.lastPathComponent)
        alert.informativeText = body
        alert.addButton(withTitle: L("sync.confirmGo", "Sync"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    private func presentSyncResult(_ result: FolderSync.Result) {
        let alert = NSAlert()
        alert.messageText = L("bvc.syncComplete", "Sync complete")
        var info = String(
            format: L("bvc.syncCopied", "Copied %d to the right, %d to the left"),
            result.copiedToRight, result.copiedToLeft)
        if result.conflictsSkipped > 0 {
            info += String(
                format: L("bvc.syncConflicts", "\n%d conflicts skipped (same time on both sides)"),
                result.conflictsSkipped)
        }
        if !result.failures.isEmpty {
            info += String(format: L("bvc.mirrorFailedSuffix", ", %d failed"), result.failures.count)
        }
        alert.informativeText = info
        alert.addButton(withTitle: L("common.ok", "OK"))
        if let window = view.window { alert.beginSheetModal(for: window) { _ in } }
    }

    /// Mirror `source` onto `target`. Recompute the diff fresh, and when the mirror would
    /// DELETE files from the target (deleteExtras), show exactly which ones and require
    /// explicit confirmation before touching anything. Then apply off-main.
    private func runMirror(source: URL, target: URL, deleteExtras: Bool) {
        Task { @MainActor [weak self] in
            let diffs = await Task.detached { FolderCompare.compare(left: source, right: target) }.value
            guard let self else { return }
            let plan = FolderCompare.mirrorPlan(diffs, deleteExtras: deleteExtras)
            if plan.copies.isEmpty && plan.deletes.isEmpty {
                self.presentInfo(
                    L("bvc.mirrorNothing", "Already mirrored"),
                    String(format: L("bvc.mirrorNothingBody", "%@ already matches the source."), target.lastPathComponent))
                return
            }
            // Deletions are destructive: preview them and require a second confirmation.
            if !plan.deletes.isEmpty {
                guard await self.confirmMirrorDeletions(plan, target: target) else { return }
            }
            let result = await Task.detached {
                FolderCompare.mirror(from: source, to: target, differences: diffs, deleteExtras: deleteExtras)
            }.value
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

    /// Show the itemized deletions a mirror will perform (the files trashed on the target),
    /// plus the copy count, and return whether the user confirmed.
    private func confirmMirrorDeletions(
        _ plan: (copies: [String], deletes: [String]), target: URL
    ) async -> Bool {
        guard let window = view.window else { return false }
        let shown = plan.deletes.prefix(12).map { "• \($0)" }.joined(separator: "\n")
        let more =
            plan.deletes.count > 12
            ? "\n" + String(format: L("bvc.mirrorMore", "…and %d more."), plan.deletes.count - 12) : ""
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: L("bvc.mirrorConfirmTitle", "Mirror will delete %d item(s) from %@"),
            plan.deletes.count, target.lastPathComponent)
        alert.informativeText =
            String(
                format: L("bvc.mirrorConfirmBody", "These files exist in %@ but not in the source, so mirroring moves them to the Trash. %d file(s) will also be copied.\n\n%@%@"),
                target.lastPathComponent, plan.copies.count, shown, more)
        alert.addButton(withTitle: L("bvc.mirrorConfirmGo", "Mirror and Delete"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
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

    /// Show/hide the QuickLook preview pane docked at the right of the window.
    private func togglePreviewPane() {
        previewVisible.toggle()
        if previewVisible {
            // Auto-layout, like the sidebar and panes -- a TAMIC arranged subview in an
            // auto-layout NSSplitView breaks the split's width distribution and collapses
            // the panes to zero (blanking both panes).
            previewView.translatesAutoresizingMaskIntoConstraints = false
            outerSplit.addArrangedSubview(previewView)  // [sidebar | panes | preview]
            outerSplit.setHoldingPriority(NSLayoutConstraint.Priority(255), forSubviewAt: 2)
            // Durably pin the preview to a sane width so the panes always keep the rest. A
            // bare setPosition() is transient in an auto-layout split and lets the preview
            // (and the panes with it) collapse to zero; this constraint stays put and is
            // still draggable (its priority is below the divider-drag priority).
            let width = previewWidthConstraint ?? previewView.widthAnchor.constraint(equalToConstant: 300)
            width.priority = NSLayoutConstraint.Priority(255)
            width.isActive = true
            previewWidthConstraint = width
            // Seed the divider once so the split gives the preview its width now; the
            // constraint then holds it durably across resizes and view swaps.
            outerSplit.layoutSubtreeIfNeeded()
            outerSplit.setPosition(
                outerSplit.bounds.width - 300, ofDividerAt: outerSplit.arrangedSubviews.count - 2)
            updatePreview()
        } else {
            previewView.previewItem = nil
            previewWidthConstraint?.isActive = false
            outerSplit.removeArrangedSubview(previewView)
            previewView.removeFromSuperview()
            // Hand the freed width back to the panes now: pin the sidebar|panes divider at the
            // sidebar width so the panes fill the rest (removeArrangedSubview leaves a stale
            // divider position otherwise, stranding the freed strip as dead space).
            outerSplit.layoutSubtreeIfNeeded()
            outerSplit.setPosition(sidebarWidthConstraint?.constant ?? 200, ofDividerAt: 0)
            outerSplit.layoutSubtreeIfNeeded()
        }
    }

    /// Point the preview at the active pane's single selected file (when visible).
    private func updatePreview() {
        guard previewVisible else { return }
        previewView.previewItem = activePane?.singleSelectedURL as NSURL?
    }

    private var quickBarScrollObserver: NSObjectProtocol?
    private weak var quickBarObservedClip: NSClipView?

    /// Show/hide the floating quick-actions bar for the active pane's selection, and place
    /// it next to the selected rows.
    private func updateQuickActions() {
        quickBar.update(selectionCount: activePane?.selectedEntries.count ?? 0)
        observeActivePaneScroll()
        positionQuickBar()
    }

    /// Reposition the bar while the active pane scrolls, so it stays next to the selection.
    private func observeActivePaneScroll() {
        guard let clip = activePane?.contentClipView else { return }
        if quickBarObservedClip === clip { return }
        if let token = quickBarScrollObserver { NotificationCenter.default.removeObserver(token) }
        clip.postsBoundsChangedNotifications = true
        quickBarScrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionQuickBar() }
        }
        quickBarObservedClip = clip
    }

    /// Float the bar next to the selection (all rects in host coordinates), clamped inside
    /// the pane; falls back to the pane's top-center when the selection is scrolled out.
    private func positionQuickBar() {
        guard !quickBar.isHidden else { return }
        let host = view
        quickBar.layoutSubtreeIfNeeded()
        let size = quickBar.fittingSize
        let pane =
            activePane.map { host.convert($0.contentClipView.bounds, from: $0.contentClipView) }
            ?? host.convert(split.bounds, from: split)
        // Column view drills into columns to the right, so a bar floating next to the
        // selection covers the very columns you're browsing. Pin it to the pane's
        // bottom-center there (out of the browsing area) instead of tracking the selection.
        let selection =
            activePane?.viewMode == .column
            ? nil : activePane?.selectionRectInWindow.map { host.convert($0, from: nil) }
        let origin = Self.quickBarOrigin(
            barSize: size, selection: selection, pane: pane, margin: 8,
            noSelectionAtBottom: activePane?.viewMode == .column)
        quickBar.frame = NSRect(origin: origin, size: size)
    }

    /// Pure geometry (so it is testable without a laid-out window): the bar sits just below
    /// the selection, or above it when there is no room, centered on the selection and
    /// clamped inside the pane. In a non-flipped host, lower on screen is a smaller y.
    static func quickBarOrigin(
        barSize size: NSSize, selection: NSRect?, pane: NSRect, margin: CGFloat,
        noSelectionAtBottom: Bool = false
    ) -> NSPoint {
        var x: CGFloat
        var y: CGFloat
        if let r = selection {
            x = r.midX - size.width / 2
            y = r.minY - margin - size.height  // just below the selection
            if y < pane.minY + margin { y = r.maxY + margin }  // no room below, place above
        } else {
            x = pane.midX - size.width / 2
            // Bottom-center (column view, to clear the drilled columns) or top-center.
            y = noSelectionAtBottom ? (pane.minY + margin) : (pane.maxY - size.height - 16)
        }
        x = min(max(x, pane.minX + margin), pane.maxX - size.width - margin)
        y = min(max(y, pane.minY + margin), pane.maxY - size.height - margin)
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    /// Pop up an "Open With" apps menu for the active selection, anchored to the quick-bar button.
    private func showQuickOpenWith(from anchor: NSView) {
        guard let urls = activePane?.selectedLocalURLs(), let first = urls.first else { NSSound.beep(); return }
        let menu = NSMenu()
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: first), let index = apps.firstIndex(of: preferred) {
            apps.remove(at: index)
            apps.insert(preferred, at: 0)  // default app first
        }
        if apps.isEmpty {
            let none = NSMenuItem(title: L("list.noApplications", "No applications"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for app in apps {
                let item = NSMenuItem(
                    title: FileManager.default.displayName(atPath: app.path),
                    action: #selector(quickOpenSelection(with:)), keyEquivalent: "")
                item.target = self
                item.representedObject = app
                let icon = (NSWorkspace.shared.icon(forFile: app.path).copy() as? NSImage) ?? NSImage()
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let other = NSMenuItem(title: L("list.other", "Other…"), action: #selector(quickOpenSelectionWithOther), keyEquivalent: "")
            other.target = self
            menu.addItem(other)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func quickOpenSelection(with sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL,
            let urls = activePane?.selectedLocalURLs(), !urls.isEmpty
        else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quickOpenSelectionWithOther() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let app = panel.url,
            let urls = activePane?.selectedLocalURLs(), !urls.isEmpty
        else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Right after a quick-bar Copy/Cut, offer where to drop it: this pane's folder or the
    /// other pane's. Only shown if the clipboard actually holds files, and the other-pane item
    /// only when a valid other pane exists (so a single-pane layout just shows "Paste Here").
    private func showQuickPasteFollowUp(from anchor: NSView) {
        let pasteboard = NSPasteboard.general
        let items =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
        guard !items.isEmpty else { return }  // copy beeped (remote / nothing selected)
        let menu = NSMenu()
        let here = NSMenuItem(
            title: L("quick.pasteHere", "Paste in This Pane"), action: #selector(quickPasteHere), keyEquivalent: "")
        here.target = self
        here.image = MenuIcons.image("doc.on.clipboard")
        menu.addItem(here)
        if let other = otherPane, !other.isRemote, !other.isShowingSmartResults {
            let there = NSMenuItem(
                title: String(
                    format: L("quick.pasteOther", "Paste in Other Pane (%@)"),
                    other.currentURL.lastPathComponent),
                action: #selector(quickPasteOtherPane), keyEquivalent: "")
            there.target = self
            there.image = MenuIcons.image("rectangle.righthalf.inset.filled")
            menu.addItem(there)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func quickPasteHere() { paste(nil) }
    @objc private func quickPasteOtherPane() { pasteInto(otherPane) }

    /// Set the active pane's view mode, then sync the auto-preview pane.
    private func setActiveViewMode(_ mode: ViewFormat.ViewMode) {
        activePane?.setViewMode(mode)
        syncAutoPreview()
    }

    private var previewAutoShown = false

    /// With the "preview in gallery/column" preference on, auto-open the preview pane while
    /// the active pane is in gallery or column view (and close it again when leaving).
    private func syncAutoPreview() {
        guard prefs.previewInGalleryView else { return }
        let mode = activePane?.viewMode
        let wantsPreview = (mode == .gallery || mode == .column)
        if wantsPreview, !previewVisible {
            togglePreviewPane()
            previewAutoShown = true
        } else if !wantsPreview, previewVisible, previewAutoShown {
            togglePreviewPane()
            previewAutoShown = false
        }
        updatePreview()
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

    func presentInfo(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: L("common.ok", "OK"))
        if let window = view.window { alert.beginSheetModal(for: window) { _ in } }
    }

    // MARK: - Organize Folder (deterministic rules; no model required)

    private var organizeReview: OrganizeReviewController?

    private static var organizeFeedbackURL: URL? {
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

    private static var preferencesURL: URL? {
        appSupportDirectory()?.appendingPathComponent("prefs.json")
    }

    private func loadPreferences() {
        if let saved = loadConfig(Preferences.self, from: Self.preferencesURL) { prefs = saved }
    }

    private func showPreferences() {
        if settingsPanel != nil {  // Cmd-, toggles the embedded panel
            closeSettingsPanel()
            return
        }
        // Host Settings over the right pane; reveal it if it's collapsed.
        if rightTabs.containerView.frame.width < 120 {
            setRightPaneFraction(0.5)
            view.layoutSubtreeIfNeeded()
        }
        let content = settings.makeEmbedded(
            prefs: prefs,
            commands: commands.all.map { (id: $0.id, title: $0.title) },
            effective: keymap.bindings,
            gestures: gestureMap.bindings,
            updater: updater,
            terminal: .init(
                themes: TerminalTheme.presets.map(\.name),
                current: terminal.theme.name,
                follows: terminalFollows,
                onSelectTheme: { [weak self] name in
                    guard let self, let preset = TerminalTheme.presets.first(where: { $0.name == name })
                    else { return }
                    self.terminal.theme = preset
                    self.saveConfig(preset, to: Self.terminalThemeURL)
                },
                onToggleFollows: { [weak self] on in
                    guard let self else { return }
                    self.terminalFollows = on
                    UserDefaults.standard.set(on, forKey: "pathem.terminalFollows")
                    if on, !self.terminal.view.isHidden, let url = self.activePane?.currentURL {
                        self.terminal.changeDirectory(to: url)
                    }
                }),
            onChange: { [weak self] updated in
                guard let self else { return }
                self.prefs = updated
                self.applyPreferences()
            },
            onKeymapChange: { [weak self] overlay in
                guard let self else { return }
                self.saveConfig(overlay, to: Self.keymapURL)  // persist the user overlay
                self.keymap = Keymap.standard.merging(userBindings: overlay)  // apply live
            },
            onGestureChange: { [weak self] overlay in
                guard let self else { return }
                self.saveConfig(overlay, to: Self.gesturesURL)
                self.gestureMap = GestureMap.standard.merging(userBindings: overlay)  // apply live
            })
        let panel = makeSettingsPanel(content: content)
        rightTabs.containerView.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: rightTabs.containerView.topAnchor),
            panel.bottomAnchor.constraint(equalTo: rightTabs.containerView.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: rightTabs.containerView.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: rightTabs.containerView.trailingAnchor),
        ])
        settingsPanel = panel
    }

    /// Wrap the embedded settings content in an opaque panel with a header (title + Done),
    /// since it no longer has a window title bar.
    private func makeSettingsPanel(content: NSView) -> NSView {
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: L("settings.title", "Settings"))
        title.font = .boldSystemFont(ofSize: 13)
        title.translatesAutoresizingMaskIntoConstraints = false
        let done = NSButton(
            title: L("common.done", "Done"), target: self, action: #selector(closeSettingsPanel))
        done.bezelStyle = .rounded
        done.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(title)
        panel.addSubview(done)
        panel.addSubview(divider)
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            done.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            done.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            divider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            content.topAnchor.constraint(equalTo: divider.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        return panel
    }

    @objc private func closeSettingsPanel() {
        settingsPanel?.removeFromSuperview()
        settingsPanel = nil
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
    /// Force the app's appearance (System/Light/Dark) per the preference.
    private func applyAppearance() {
        switch prefs.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Push the skin's colors into the theme manager (which notifies the themed chrome) and tint
    /// the window/pane background. The accent is honored by Pathem-drawn elements via ThemeManager.
    private func applyTheme() {
        ThemeManager.shared.apply(accentHex: prefs.accentColorHex, windowTintHex: prefs.windowTintHex)
        let tint = ThemeManager.shared.windowTint
        view.window?.backgroundColor = tint ?? .windowBackgroundColor
    }

    /// Adopt the selected icon set; reload every listing so the new icons appear.
    private func applyIconSet() {
        guard IconSetManager.shared.setCurrent(named: prefs.iconSetName) else { return }
        for side in [leftTabs, rightTabs] { for pane in side.tabs { pane.reloadIfShowingListing() } }
    }

    private func applyCompactSidebar() {
        compactSidebar = prefs.compactSidebar
        sidebar.setShowsLabels(!compactSidebar)
        let width: CGFloat = compactSidebar ? Self.compactSidebarWidth : 200
        sidebarWidthConstraint?.constant = width
        if didSetInitialSplit { outerSplit.setPosition(width, ofDividerAt: 0) }  // resize live
        // In icons-only mode the labels are hidden, so tooltips are how you identify an icon --
        // make them instant. Otherwise honor the preference.
        if compactSidebar {
            UserDefaults.standard.set(1, forKey: "NSInitialToolTipDelay")
        } else {
            applyTooltipDelay()
        }
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
    /// Persist a new icon/gallery zoom and keep both panes' base zoom in sync.
    private func rememberIconZoom(_ scale: CGFloat) {
        prefs.iconZoom = Double(scale)
        saveConfig(prefs, to: Self.preferencesURL)
        for side in [leftTabs, rightTabs] {
            for pane in side.tabs { pane.iconZoom = scale }
        }
    }

    private func applyPreferences() {
        for side in [leftTabs, rightTabs] {
            for pane in side.tabs {
                pane.applyStyle(
                    rowHeight: prefs.rowHeight, fontSize: prefs.fontSize,
                    alternatingRows: prefs.alternatingRows)
                pane.setPathBar(atBottom: prefs.pathBarAtBottom)
                pane.setCalculateFolderSizes(prefs.calculateFolderSizes)
                pane.dragMovesByDefault = prefs.dragMovesByDefault
                pane.setClickBehavior(
                    singleClick: prefs.singleClickToOpen, underlineHover: prefs.underlineOnHover)
                let wasHidden = pane.showHiddenByDefault
                pane.showHiddenByDefault = prefs.showHiddenByDefault
                if wasHidden != prefs.showHiddenByDefault { pane.reloadIfShowingListing() }
                pane.iconZoom = CGFloat(prefs.iconZoom)
                pane.iconPointSize = CGFloat(prefs.toolbarIconSize.pointSize)
                pane.setHiddenContextItems(Set(prefs.hiddenContextItems))
                pane.setContextMenuOrder(prefs.contextMenuOrder)
                pane.setColorRules(prefs.colorRules)
                pane.setFormats(size: prefs.sizeFormat, date: prefs.dateDisplay)
                pane.setMiddleClickOpensNewTab(prefs.middleClickOpensNewTab)
                pane.statusOptions = (
                    prefs.statusShowItemCount, prefs.statusShowSize, prefs.statusShowFreeSpace)
            }
        }
        for side in [leftTabs, rightTabs] { side.newTabAtEnd = prefs.newTabAtEnd }
        applyCompactSidebar()
        applyCommanderCommands()
        applyAppearance()
        applyTheme()
        applyIconSet()
        applyTooltipDelay()
        applyToolbarIconSize()
        RemoteLimits.bandwidthKBps = prefs.bandwidthLimitKBps  // honored by the transfer backends
        saveConfig(prefs, to: Self.preferencesURL)
        semanticSearch.includeOCR = prefs.searchOCR
        semanticSearch.invalidate()  // a pref (e.g. OCR) may change how folders index
        if let directory = activePane?.currentURL { preIndex(directory) }
    }

    /// AppKit shows a tooltip after `NSInitialToolTipDelay` milliseconds (a long system
    /// default). Register a near-zero delay for instant tooltips, or clear our override to
    /// restore the default. A live toggle applies to tooltips shown after this point;
    /// AppKit may cache the value, so a relaunch guarantees it.
    private func applyTooltipDelay() {
        let key = "NSInitialToolTipDelay"
        if prefs.instantTooltips {
            UserDefaults.standard.set(1, forKey: key)  // 1 ms, effectively instant
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
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

    /// Resolve a key chord against the keymap and dispatch via the registry.
    /// Returns true if a binding existed (so the key is consumed even when the
    /// command is currently disabled).
    /// Vim-style, keyboard-driven navigation (View ▸ Vim Navigation). Off by default.
    private var vimMode = false
    private var vimPendingG = false

    private func handleKeyChord(_ chord: KeyChord) -> Bool {
        if vimMode, handleVimKey(chord) { return true }  // vim keys take precedence when enabled
        // Don't consume a chord whose command is currently disabled, so the event
        // falls through (e.g. Cmd-W with one tab should reach Close Window).
        guard let id = keymap.commandID(for: chord), commands.command(id)?.isEnabled() == true else {
            return false
        }
        commands.perform(id)
        return true
    }

    /// Map a plain (unmodified) key to a navigation action in vim mode: h/j/k/l move, gg/G jump to
    /// the top/bottom, / focuses the filter. Returns true when it consumed the key.
    private func handleVimKey(_ chord: KeyChord) -> Bool {
        guard !chord.cmd, !chord.ctrl, !chord.opt, !isEditingText else { vimPendingG = false; return false }
        let hadPendingG = vimPendingG
        vimPendingG = false
        switch (chord.key, chord.shift) {
        case ("j", false): activePane?.moveSelection(by: 1)
        case ("k", false): activePane?.moveSelection(by: -1)
        case ("h", false): if commands.command("nav.up")?.isEnabled() == true { commands.perform("nav.up") }
        case ("l", false), ("l", true): if commands.command("files.open")?.isEnabled() == true { commands.perform("files.open") }
        case ("g", false):
            if hadPendingG { activePane?.selectFirst() } else { vimPendingG = true }
        case ("g", true): activePane?.selectLast()  // Shift-G
        case ("/", _): if commands.command("view.filter")?.isEnabled() == true { commands.perform("view.filter") }
        default: return false
        }
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

    /// Resolve a mouse-gesture stroke against the gesture map and dispatch it.
    private func handleGesture(_ stroke: String) -> Bool {
        guard let id = gestureMap.commandID(for: stroke), commands.command(id)?.isEnabled() == true
        else { return false }
        commands.perform(id)
        return true
    }

    /// Super-drag: draw the swipe trail as a row drag moves, and on a flick release (the drag
    /// ended past the threshold without a drop target) run its mapped command on the selection.
    /// Gated on the preference; when off, drags behave exactly as before.
    private func handleDragSession(_ event: DragSessionEvent) {
        guard prefs.dragFlickActions else { return }
        switch event {
        case .began(let screen):
            dragStartScreen = screen
            dragTrail.color = NSColor(hex: prefs.dragTrailColor) ?? .systemBlue
            dragTrail.trailWidth = max(1, CGFloat(prefs.dragTrailWidth))
            dragTrail.decaySeconds = max(0.1, prefs.dragTrailDecay)
            dragTrail.hint = ""
            dragTrail.begin()
        case .moved(let screen):
            guard let window = view.window else { return }
            // Name the flick this direction would trigger (same threshold as the release),
            // so the trail shows what it's shortcutting; blank until it's a clear flick.
            if let start = dragStartScreen {
                let direction = MouseGesture.reduce([start, screen], minSegment: 44)
                dragTrail.hint = direction.isEmpty ? "" : flickHint(for: direction)
            }
            let windowPoint = window.convertPoint(fromScreen: screen)
            dragTrail.add(dragTrail.convert(windowPoint, from: nil))
        case .ended(let flick):
            dragStartScreen = nil
            dragTrail.end()
            guard let flick, let id = dragGestures.commandID(for: flick),
                commands.command(id)?.isEnabled() == true
            else { return }
            commands.perform(id)
        }
    }

    /// The command a flick `direction` maps to, as "Title  ⌘K" (its keyboard equivalent), for
    /// the trail's live hint. The shortcut is the simplest keymap chord bound to that command.
    private func flickHint(for direction: String) -> String {
        guard let id = dragGestures.commandID(for: direction), let title = commands.command(id)?.title
        else { return "" }
        let chord = keymap.bindings.filter { $0.value == id }.keys.sorted().first
        let shortcut = chord.map { ChordFormat.display($0) } ?? ""
        return shortcut.isEmpty ? title : "\(title)   \(shortcut)"
    }

    private static var gesturesURL: URL? {
        appSupportDirectory()?.appendingPathComponent("gestures.json")
    }

    private func loadGestures() {
        if let user = loadConfig([String: String].self, from: Self.gesturesURL) {
            gestureMap = GestureMap.standard.merging(userBindings: user)
        } else {
            gestureMap = .standard
        }
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

    private func saveLayouts() {
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

    private static var terminalThemeURL: URL? {
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
            await self.presentSmartResults(entries, title: title, pane: pane, token: token)
        }
    }

    /// Show smart-search results. When they're empty because Spotlight indexing is off (not
    /// because there are no matches), show a clear message instead of a silent empty pane --
    /// smart folders and search all rely on `mdfind`.
    private func presentSmartResults(
        _ entries: [FileEntry], title: String, pane: PaneController, token: Int
    ) async {
        if entries.isEmpty {
            let indexed = await SpotlightSearch.indexingEnabled()
            guard activePane === pane, pane.isContentRequestCurrent(token) else { return }
            if !indexed {
                pane.showSmartResults(
                    [],
                    title: L(
                        "bvc.spotlightOff",
                        "Spotlight indexing is off — smart folders and search need it. Enable it in Terminal: sudo mdutil -i on /"))
                return
            }
        }
        pane.showSmartResults(entries, title: title)
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

    /// Set the current folder's background to a solid color (a color well in a sheet), applied
    /// immediately and persisted; a color replaces any picture.
    private func setFolderBackgroundColor() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults, let window = view.window else { NSSound.beep(); return }
        _ = window
        let folder = pane.currentURL
        let alert = NSAlert()
        alert.messageText = String(format: L("folderbg.colorTitle", "Background color for “%@”"), folder.lastPathComponent)
        alert.addButton(withTitle: L("common.apply", "Apply"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 44))
        if let hex = folderBackgrounds.background(for: folder.path)?.colorHex, let color = ThemeManager.color(fromHex: hex) {
            well.color = color
        }
        alert.accessoryView = well
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            var background = self.folderBackgrounds.background(for: folder.path) ?? FolderBackground()
            background.colorHex = ThemeManager.hex(from: well.color)
            background.imagePath = ""  // a color replaces a picture
            self.folderBackgrounds.set(background, for: folder.path)
            self.saveConfig(self.folderBackgrounds, to: Self.folderBackgroundsURL)
            self.reapplyFolderBackgrounds()
        }
    }

    /// Set the current folder's background to a picture chosen from disk; a picture replaces any color.
    private func setFolderBackgroundPicture() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults, let window = view.window else { NSSound.beep(); return }
        let folder = pane.currentURL
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = L("folderbg.choose", "Choose")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            var background = self.folderBackgrounds.background(for: folder.path) ?? FolderBackground()
            background.imagePath = url.path
            background.colorHex = ""
            self.folderBackgrounds.set(background, for: folder.path)
            self.saveConfig(self.folderBackgrounds, to: Self.folderBackgroundsURL)
            self.reapplyFolderBackgrounds()
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

    /// Remove the current folder's background (restore the default).
    private func clearFolderBackground() {
        guard let pane = activePane, !pane.isShowingSmartResults else { NSSound.beep(); return }
        folderBackgrounds.set(nil, for: pane.currentURL.path)
        saveConfig(folderBackgrounds, to: Self.folderBackgroundsURL)
        reapplyFolderBackgrounds()
    }

    /// Finder-style "Connect to Server": prompt for an smb/afp/nfs address, mount it via NetFS
    /// (the OS handles auth), and navigate the active pane to the mount point.
    private func connectToServer() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = L("connect.title", "Connect to Server")
        alert.informativeText = L("connect.hint", "Enter a server address, for example smb://host/share or afp://host.")
        alert.addButton(withTitle: L("connect.connect", "Connect"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "smb://host/share"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            var text = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            if !text.contains("://") { text = "smb://" + text }  // bare host defaults to SMB
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                ["smb", "afp", "nfs"].contains(scheme)
            else {
                self.presentInfo(
                    L("connect.badTitle", "Unsupported address"),
                    L("connect.badBody", "Use an smb://, afp://, or nfs:// address."))
                return
            }
            let result = await Self.mountShare(url)
            if let mount = result.mount {
                self.activePane?.navigate(to: mount)
            } else if result.status != ECANCELED {  // ECANCELED = user dismissed the OS prompt
                self.presentInfo(
                    L("smb.failedTitle", "Couldn’t connect"),
                    String(format: L("connect.failedBody", "Couldn’t mount “%@”. Check the address and your credentials."), text))
            }
        }
    }

    // MARK: - Remote bookmarks

    /// Save the active remote pane's current path as a named bookmark on its
    /// connection, so it can be jumped back to from the Bookmarks menu.
    private func addBookmark() {
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
    private func jumpToBookmark(_ bookmark: RemoteBookmark) {
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
            let result = await Self.mountShare(url)
            guard let self else { return }
            if let mount = result.mount {
                self.activePane?.navigate(to: mount)
            } else if result.status != ECANCELED {
                // nil with ECANCELED means the user dismissed the OS credential prompt;
                // only a real failure (unreachable host, wrong password, share gone) warrants
                // an alert.
                self.presentInfo(
                    L("smb.failedTitle", "Couldn’t connect"),
                    String(
                        format: L("smb.failedBody", "Couldn’t mount “%@”. Check that the share is available and your credentials are correct."),
                        host))
            }
        }
    }

    /// Off-main NetFS mount. Returns the mount point (nil on failure/cancel) plus the
    /// NetFS status, so the caller can tell a user cancel (ECANCELED) from a real failure.
    nonisolated private static func mountShare(_ url: URL) async -> (mount: URL?, status: Int32) {
        await withCheckedContinuation { (cont: CheckedContinuation<(URL?, Int32), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let openOptions = NSMutableDictionary()
                openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI  // let the OS prompt for credentials
                var mountpoints: Unmanaged<CFArray>?
                let status = NetFSMountURLSync(
                    url as CFURL, nil, nil, nil, openOptions as CFMutableDictionary, nil, &mountpoints)
                let paths = (mountpoints?.takeRetainedValue() as? [String]) ?? []
                cont.resume(
                    returning: (status == 0 ? paths.first.map { URL(fileURLWithPath: $0) } : nil, status))
            }
        }
    }

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

    /// Add a "Layouts" menu to the main menu, rebuilt on demand from the saved set.
    private func installLayoutsMenu() {
        guard !didInstallLayoutsMenu, let mainMenu = NSApp.mainMenu else { return }
        let item = NSMenuItem()
        item.title = L("bvc.layoutsMenu", "Layouts")
        item.submenu = layoutsMenu
        layoutsMenu.delegate = self
        mainMenu.addItem(item)
        didInstallLayoutsMenu = true
        installSavedViewsMenu()
    }

    private func installSavedViewsMenu() {
        guard !didInstallSavedViewsMenu, let mainMenu = NSApp.mainMenu else { return }
        let item = NSMenuItem()
        item.title = L("bvc.savedViewsMenu", "Saved Views")
        item.submenu = savedViewsMenu
        savedViewsMenu.delegate = self
        mainMenu.addItem(item)
        didInstallSavedViewsMenu = true
        installBookmarksMenu()
    }

    private func installBookmarksMenu() {
        guard !didInstallBookmarksMenu, let mainMenu = NSApp.mainMenu else { return }
        let item = NSMenuItem()
        item.title = L("bvc.bookmarksMenu", "Bookmarks")
        item.submenu = bookmarksMenu
        bookmarksMenu.delegate = self
        mainMenu.addItem(item)
        didInstallBookmarksMenu = true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === recentFoldersMenu { populateRecentFoldersMenu(); return }
        if menu === externalCommandsMenu { populateExternalCommandsMenu(); return }
        if menu === bookmarksMenu { populateBookmarksMenu(); return }
        if menu === savedViewsMenu {
            menu.removeAllItems()
            let save = menu.addItem(withTitle: L("bvc.saveViewMenuItem", "Save Current View As…"), action: #selector(saveViewPreset), keyEquivalent: "")
            save.target = self
            guard !viewPresets.presets.isEmpty else { return }
            menu.addItem(.separator())
            for preset in viewPresets.presets {
                let item = menu.addItem(withTitle: preset.name, action: #selector(applyViewPresetMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.name
            }
            return
        }
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

    @objc private func applyViewPresetMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
            let preset = viewPresets.presets.first(where: { $0.name == name })
        else { return }
        applyViewPreset(preset.format)
    }

    /// The Bookmarks menu lists the current remote site's saved paths, plus a
    /// "Bookmark This Folder…" item. Off a remote pane it shows a single hint.
    private func populateBookmarksMenu() {
        bookmarksMenu.removeAllItems()
        let add = bookmarksMenu.addItem(
            withTitle: L("bvc.bookmarkThisFolder", "Bookmark This Folder…"),
            action: #selector(addBookmarkMenu), keyEquivalent: "")
        add.target = self
        guard let ctx = activePane?.remoteContext else {
            add.action = nil  // greyed out: nothing to bookmark off a local pane
            let hint = bookmarksMenu.addItem(
                withTitle: L("bvc.bookmarksHint", "Connect to a server to add bookmarks."),
                action: nil, keyEquivalent: "")
            hint.isEnabled = false
            return
        }
        // Read the live connection so a just-added bookmark shows immediately.
        let bookmarks =
            connectionsController.connections.first { $0.id == ctx.connection.id }?.bookmarks
            ?? ctx.connection.bookmarks
        guard !bookmarks.isEmpty else { return }
        bookmarksMenu.addItem(.separator())
        for bookmark in bookmarks {
            let item = bookmarksMenu.addItem(
                withTitle: bookmark.name, action: #selector(jumpBookmarkMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bookmark.remotePath
            item.toolTip = bookmark.remotePath
        }
    }

    @objc private func addBookmarkMenu() { addBookmark() }

    @objc private func jumpBookmarkMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        jumpToBookmark(RemoteBookmark(name: sender.title, remotePath: path))
    }

    // MARK: - Recent folders (Go menu)

    private static var recentFoldersURL: URL? {
        appSupportDirectory()?.appendingPathComponent("recent-folders.json")
    }
    private func loadRecentFolders() {
        let paths = loadConfig([String].self, from: Self.recentFoldersURL) ?? []
        recentFolders = paths.map { URL(fileURLWithPath: $0) }
    }
    private func saveRecentFolders() {
        saveConfig(recentFolders.map(\.path), to: Self.recentFoldersURL)
    }
    /// Push a folder to the front of the recents (deduped, capped at 20).
    private func recordRecentFolder(_ url: URL) {
        guard url.isFileURL else { return }
        let standardized = url.standardizedFileURL
        recentFolders.removeAll { $0.standardizedFileURL == standardized }
        recentFolders.insert(standardized, at: 0)
        if recentFolders.count > 20 { recentFolders = Array(recentFolders.prefix(20)) }
        saveRecentFolders()
    }

    /// Add "Recent Folders" to the existing Go menu (built in PathemApp before the browser
    /// exists, so it's wired here once the menu bar is up).
    private func installRecentFoldersMenu() {
        guard !didInstallRecentMenu, let mainMenu = NSApp.mainMenu,
            let goMenu = mainMenu.items.compactMap({ $0.submenu }).first(where: { $0.title == L("menu.go", "Go") })
        else { return }
        recentFoldersMenu.delegate = self
        let item = NSMenuItem(title: L("menu.recentFolders", "Recent Folders"), action: nil, keyEquivalent: "")
        item.submenu = recentFoldersMenu
        goMenu.addItem(.separator())
        goMenu.addItem(item)
        didInstallRecentMenu = true
    }

    private func populateRecentFoldersMenu() {
        recentFoldersMenu.removeAllItems()
        guard !recentFolders.isEmpty else {
            let none = recentFoldersMenu.addItem(
                withTitle: L("menu.noRecentFolders", "No Recent Folders"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            return
        }
        for url in recentFolders {
            let item = recentFoldersMenu.addItem(
                withTitle: url.lastPathComponent, action: #selector(openRecentFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        recentFoldersMenu.addItem(.separator())
        let clear = recentFoldersMenu.addItem(
            withTitle: L("menu.clearMenu", "Clear Menu"), action: #selector(clearRecentFolders), keyEquivalent: "")
        clear.target = self
    }

    @objc private func openRecentFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        activePane?.navigate(to: url)
    }
    @objc private func clearRecentFolders() {
        recentFolders = []
        saveRecentFolders()
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
        Task { @MainActor in
            guard await self.presentSheet(alert) == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            self.layouts.save(self.captureLayout(name: name))
            self.saveLayouts()
        }
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
        setRightPaneFraction(1 - layout.dividerFraction)  // saved fraction is the left pane's share
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
        setRightPaneFraction(0.5)  // even panes
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

        let conflicts = FileOperations.conflicts(urls: sources, into: destinationURL)
        resolveThenTransfer(urls: sources, into: destinationURL, move: move, conflictCount: conflicts.count) {
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
    private var isEditingText: Bool { view.window?.firstResponder is NSText }

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

    func presentFailures(_ failures: [FileOperations.Failure], title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L("bvc.failuresForItems", "%@ for %d item(s)"), title, failures.count)
        alert.informativeText =
            failures.prefix(8).map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
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
    private func preIndex(_ directory: URL) {
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
    private func updateWindowTitle() {
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
    private func applyCommanderCommands() {
        commanderBar.commandIDs =
            prefs.commanderCommands.count == 6 ? prefs.commanderCommands : CommanderBar.defaultCommandIDs
    }

    private func toggleCommander() {
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
        } else {
            activePane?.reveal(url)  // a file: show it in its folder
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
        // The file list must actually have vertical room. A near-zero height with the pane at
        // full width is the "blank panes" regression: the tab bar / toolbar stacks stretched and
        // squeezed the list flat. Rows exist (data is fine) but nothing is visible.
        let leftContentH = leftTabs.activePane?.debugContentHeight() ?? 0
        let rightContentH = rightTabs.activePane?.debugContentHeight() ?? 0
        check("pane-content-not-squished", leftContentH > 150 && rightContentH > 150,
            "left=\(Int(leftContentH)) right=\(Int(rightContentH))")
        check("left-pane-has-rows", leftTabs.activePane?.entries.isEmpty == false, "\(leftTabs.activePane?.entries.count ?? -1) entries")
        lines.append("info left-folder (\(leftTabs.activePane?.currentURL.path ?? "?"))")
        // The sorted column must show its indicator on load, not only after a header
        // click (setting sortDescriptors programmatically doesn't draw the triangle).
        if let sort = leftTabs.activePane?.debugSortIndicator {
            check(
                "sort-indicator-drawn", sort.drawn,
                "column=\(sort.column) \(sort.ascending ? "ascending" : "descending")")
        } else {
            lines.append("info sort-indicator (active pane is not a list view)")
        }
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
        // Gallery (preview + filmstrip): exercise setEntries so a crash/hang there is caught.
        let galleryView = GalleryController()
        galleryView.directoryURL = leftTabs.activePane?.currentURL
        galleryView.setEntries(leftTabs.activePane?.entries ?? [], preserveState: false)
        check("gallery-view-renders", galleryView.entries.count > 0, "\(galleryView.entries.count) entries")
        // Preview pane must not collapse the panes to zero (the auto-preview layout bug):
        // toggling it on keeps the panes wide, and toggling it off restores their width.
        check("preview-pane-keeps-panes", debugPreviewToggleKeepsPanes(), "panes survive preview toggle")
        // Every context-menu command resolves to an icon (a mistyped SF Symbol name would
        // silently drop the glyph, leaving the item icon-less).
        let iconlessCommands = FileListController.contextCommands.filter { MenuIcons.image(forCommand: $0.id) == nil }
        check(
            "context-menu-icons", iconlessCommands.isEmpty,
            iconlessCommands.isEmpty ? "all present" : "missing: \(iconlessCommands.map(\.id))")
        // Copy Path / Copy Name are offered in the right-click menu everywhere (all views share it).
        let ctxIDs = Set(FileListController.contextCommands.map(\.id))
        check("copy-path-in-context-menu", ctxIDs.isSuperset(of: ["files.copyPath", "files.copyName"]),
            "copyPath=\(ctxIDs.contains("files.copyPath")) copyName=\(ctxIDs.contains("files.copyName"))")
        // Every default hotkey resolves to a registered command -- catches a binding that
        // points at a renamed or removed command id (a silently dead key). The wiring check
        // between the keymap and the command registry.
        let deadHotkeys = Keymap.standard.bindings.filter { commands.command($0.value) == nil }
        check(
            "keymap-bindings-resolve", deadHotkeys.isEmpty,
            deadHotkeys.isEmpty
                ? "\(Keymap.standard.bindings.count) hotkeys -> commands"
                : "dead: \(deadHotkeys.map { "\($0.key)=\($0.value)" }.sorted())")
        // The whole hotkey dispatch path works end to end: a Delete chord resolves through the
        // keymap to files.trash and would fire (routed the same way KeyTableView.keyDown does).
        let deleteCmd = keymap.commandID(for: KeyChord(key: "delete"))
        check(
            "keymap-dispatch", deleteCmd == "files.trash" && commands.command("files.trash") != nil,
            "delete -> \(deleteCmd ?? "nil")")
        // Every super-drag flick direction maps to a registered command (same wiring check).
        let deadFlicks = DragGestureMap.standard.bindings.filter { commands.command($0.value) == nil }
        check(
            "drag-gestures-resolve", deadFlicks.isEmpty,
            deadFlicks.isEmpty
                ? "\(DragGestureMap.standard.bindings.count) flicks -> commands"
                : "dead: \(deadFlicks.map { "\($0.key)=\($0.value)" }.sorted())")
        // The super-drag handler drives the trail: a synthetic drag shows it on begin and
        // hides it on end (the drawing itself is only visible during a live drag).
        let savedFlick = prefs.dragFlickActions
        prefs.dragFlickActions = true
        handleDragSession(.began(screen: .zero))
        handleDragSession(.moved(screen: NSPoint(x: 90, y: 8)))  // a clear rightward flick
        let trailShown = !dragTrail.isHidden
        let hint = dragTrail.hint  // names the mapped command + its shortcut
        handleDragSession(.ended(flick: nil))
        prefs.dragFlickActions = savedFlick
        check("super-drag-trail", trailShown && dragTrail.isHidden, "shown=\(trailShown)")
        check("super-drag-hint", !hint.isEmpty, "hint=\"\(hint)\"")
        // Shrinking a listing must clamp the scroll back to the top, not strand the view
        // scrolled into empty space below the few remaining rows (the "panels scroll down
        // after a change" bug). Load a tall synthetic list, scroll to the bottom, shrink it
        // to two rows, and assert the offset returns to zero.
        let tallList = (0..<40).map {
            FileEntry(
                name: String(format: "row-%02d.txt", $0), isDirectory: false, size: 0, modificationDate: nil)
        }
        let shrink = FileListController()
        shrink.debugLayout(width: 300, height: 100)  // small viewport so the list overflows
        shrink.setEntries(tallList, preserveState: false)
        shrink.debugLayout(width: 300, height: 100)
        shrink.debugScrollToBottom()
        let scrolled = shrink.debugScrollOriginY()
        shrink.setEntries(Array(tallList.prefix(2)), preserveState: true)  // shrink to 2 rows
        let after = shrink.debugScrollOriginY()
        check(
            "scroll-clamps-on-shrink", scrolled > 0 && after == 0,
            "scrolled=\(Int(scrolled)) after=\(Int(after)) (want after=0)")
        // Embedded Settings: build the in-pane settings view (catches a crash in that path).
        let settingsView = settings.makeEmbedded(
            prefs: prefs, commands: commands.all.map { (id: $0.id, title: $0.title) },
            effective: keymap.bindings, gestures: gestureMap.bindings, updater: updater,
            terminal: .init(
                themes: TerminalTheme.presets.map(\.name), current: terminal.theme.name,
                follows: terminalFollows, onSelectTheme: { _ in }, onToggleFollows: { _ in }),
            onChange: { _ in }, onKeymapChange: { _ in }, onGestureChange: { _ in })
        check("settings-embeds", !settingsView.subviews.isEmpty, "\(settingsView.subviews.count) subviews")
        // Organize review sheet: build it with synthetic suggestions (a move and a trash)
        // so a crash in the row/detail layout is caught headlessly.
        let review = OrganizeReviewController(
            feedbackURL: FileManager.default.temporaryDirectory.appendingPathComponent("pathem-fb-smoke.json"))
        review.debugLoad([
            .init(file: URL(fileURLWithPath: "/tmp/a.png"), kind: .move(to: URL(fileURLWithPath: "/tmp/Images")),
                ruleID: "by-kind", rationale: "Image to Images", confidence: 0.8, size: 1234, accepted: true),
            .init(file: URL(fileURLWithPath: "/tmp/.DS_Store"), kind: .trash, ruleID: "junk",
                rationale: "System junk file", confidence: 0.9, size: 6, accepted: true),
        ])
        check("organize-review-builds", review.debugRowCount == 2, "\(review.debugRowCount) rows")
        // Cleanup panel (with its new detail pane) must construct without a layout crash.
        check("cleanup-builds", CleanupController().debugContentReady, "content ready")
        // The ambient download chip must render its suggestion text without crashing.
        let chip = DownloadSuggestionBar()
        chip.show(fileURL: URL(fileURLWithPath: "/tmp/invoice.pdf"), destinationName: "PDFs")
        check("download-chip-builds", chip.debugVisibleText?.contains("PDFs") == true, chip.debugVisibleText ?? "nil")
        // The transfer queue holds when paused and re-queues a failed job on retry.
        check("transfer-queue-pause-retry", TransferQueueController().debugPauseRetry(), "")
        // New Folder with Selection: create a folder, move items in, and undo back to the start.
        let nfwsDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-nfws-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: nfwsDir, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt"] { try? "x".write(to: nfwsDir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let nfwsFolder = (try? FileOperations.makeFolder(in: nfwsDir, baseName: "New Folder With Items")) ?? ""
        let nfwsOutcome = FileOperations.move(
            ["a.txt", "b.txt"], from: nfwsDir, to: nfwsDir.appendingPathComponent(nfwsFolder), onConflict: .keepBoth)
        let movedIn = FileManager.default.fileExists(
            atPath: nfwsDir.appendingPathComponent(nfwsFolder).appendingPathComponent("a.txt").path)
        FileOperations.undo(nfwsOutcome.performed)  // move back out
        _ = FileOperations.trash([nfwsFolder], in: nfwsDir)  // and remove the emptied folder
        let backOut = FileManager.default.fileExists(atPath: nfwsDir.appendingPathComponent("a.txt").path)
        check("new-folder-with-selection", !nfwsFolder.isEmpty && movedIn && backOut,
            "folder=\(nfwsFolder) movedIn=\(movedIn) undone=\(backOut)")
        try? FileManager.default.removeItem(at: nfwsDir)
        // The cursor-anchored confirmation popover builds its content without a layout crash, and
        // a non-Ask conflict default resolves without prompting.
        check("cursor-confirm-builds",
            cursorConfirm.debugBuildsController(buttons: ["Replace", "Keep Both", "Skip", "Cancel"]), "")
        check("conflict-default-maps",
            ConflictDefault.keepBoth.resolution == .keepBoth && ConflictDefault.ask.resolution == nil, "")
        // Verified copy: copying a file with verify on succeeds (SHA-256 matches) and lands.
        let vDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-verify-\(UUID().uuidString)")
        let vSrcDir = vDir.appendingPathComponent("src")
        let vDstDir = vDir.appendingPathComponent("dst")
        try? FileManager.default.createDirectory(at: vSrcDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: vDstDir, withIntermediateDirectories: true)
        let vSrc = vSrcDir.appendingPathComponent("v.txt")
        try? String(repeating: "payload ", count: 2000).write(to: vSrc, atomically: true, encoding: .utf8)
        let vOutcome = FileOperations.copy(urls: [vSrc], into: vDstDir, verify: true)
        let vOK = vOutcome.failures.isEmpty
            && FileManager.default.fileExists(atPath: vDstDir.appendingPathComponent("v.txt").path)
        check("verified-copy", vOK, "performed=\(vOutcome.performed.count) failures=\(vOutcome.failures.count)")
        try? FileManager.default.removeItem(at: vDir)
        // Arrange By: ungrouped is 1:1 items; grouping by kind adds section headers and keeps
        // every item, mapping each display row back to an entry.
        let gEntries = [
            FileEntry(name: "b.txt", isDirectory: false, size: 10, modificationDate: nil, location: nil),
            FileEntry(name: "afolder", isDirectory: true, size: 0, modificationDate: nil, location: nil),
            FileEntry(name: "c.txt", isDirectory: false, size: 10, modificationDate: nil, location: nil),
        ]
        let flat = FileGrouping.rows(gEntries, by: .none, now: Date())
        let grouped = FileGrouping.rows(gEntries, by: .kind, now: Date())
        func headers(_ r: [FileGrouping.Row]) -> Int { r.filter { if case .header = $0 { return true }; return false }.count }
        func items(_ r: [FileGrouping.Row]) -> Int { r.filter { if case .item = $0 { return true }; return false }.count }
        check("arrange-by-grouping",
            flat.count == 3 && headers(flat) == 0 && items(grouped) == 3 && headers(grouped) >= 2,
            "flat=\(flat.count) groupedHeaders=\(headers(grouped)) groupedItems=\(items(grouped))")
        // And against the real list view: grouping + selection maps back to the right entry.
        check("arrange-by-selection", leftTabs.activePane?.debugGroupedSelectionRoundTrips() ?? true, "")
        // Collapsible sections: collapsing a group hides its items but keeps the header, and
        // re-expanding restores the rows.
        check("collapsible-sections", leftTabs.activePane?.debugCollapseHidesItems() ?? true, "")
        // External commands: the manager + output panel construct, and a command runs via the engine.
        _ = ExternalCommandsController()
        _ = ExternalCommandOutputController()
        let ecOut = ExternalCommandRunner.run(
            ExternalCommand(id: "smoke", name: "echo", command: "echo ok"),
            files: [], directory: FileManager.default.temporaryDirectory)
        check("external-command-runs", ecOut.succeeded && ecOut.text.contains("ok"), "exit=\(ecOut.exitCode)")
        // Undo history: two path-disjoint actions; the older is independently undoable, and a
        // selective undo runs just its reverse and enables redo.
        let history = ActionHistory()
        var undoLog: [String] = []
        history.record(name: "A", footprint: ["/a"], undoFootprint: ["/a"]) {
            undoLog.append("undoA")
            history.record(name: "A'", footprint: ["/a"], undoFootprint: ["/a"], perform: {})
        }
        history.record(name: "B", footprint: ["/b"], undoFootprint: ["/b"]) {
            undoLog.append("undoB")
            history.record(name: "B'", footprint: ["/b"], undoFootprint: ["/b"], perform: {})
        }
        let indepA = history.isIndependentlyUndoable(at: 0)
        let didUndoA = history.undo(at: 0)
        check("undo-history-selective", indepA && didUndoA && undoLog == ["undoA"] && history.canRedo,
            "indep=\(indepA) undid=\(didUndoA) log=\(undoLog) canRedo=\(history.canRedo)")
        // The real file-op undo path: move a file, register it in the live history, then undo it.
        let uDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-undo-\(UUID().uuidString)")
        let uSrc = uDir.appendingPathComponent("src")
        let uDst = uDir.appendingPathComponent("dst")
        try? FileManager.default.createDirectory(at: uSrc, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: uDst, withIntermediateDirectories: true)
        try? "x".write(to: uSrc.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let uOutcome = FileOperations.move(["f.txt"], from: uSrc, to: uDst, onConflict: .keepBoth)
        registerUndo(uOutcome.performed, actionName: "Move")
        let movedOK = FileManager.default.fileExists(atPath: uDst.appendingPathComponent("f.txt").path)
        actionHistory.undo()  // reverses the move
        let undoneOK = FileManager.default.fileExists(atPath: uSrc.appendingPathComponent("f.txt").path)
            && !FileManager.default.fileExists(atPath: uDst.appendingPathComponent("f.txt").path)
        check("undo-file-move", movedOK && undoneOK, "moved=\(movedOK) undone=\(undoneOK)")
        try? FileManager.default.removeItem(at: uDir)
        // The new superuser/developer panels must construct without a layout crash.
        _ = DiffViewerController()
        let panelsOK =
            XattrController().debugRowCount == 0 && BulkAttributesController().debugContentReady
            && AutomationRulesController().debugContentReady
        check("aux-panels-build", panelsOK, "diff/xattr/attrs/automation")
        // End-to-end ambient path: point Downloads at a temp dir, drop a file, run one change
        // pass, and confirm the chip offers to move it (catches wiring bugs the unit tests can't).
        let dlDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-dl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: dlDir.appendingPathComponent("receipt.pdf"))
        downloadSuggestions.debugRunCheck(  // empty seed => receipt.pdf reads as newly arrived
            folder: dlDir, seedKnown: [], feedbackURL: Self.organizeFeedbackURL)
        check(
            "download-suggestion-fires", downloadSuggestions.debugChipText?.contains("receipt.pdf") == true,
            downloadSuggestions.debugChipText ?? "no chip")
        downloadSuggestions.debugReset()
        try? FileManager.default.removeItem(at: dlDir)
        // The quick-actions bar geometry must place the bar next to the selection, not at a
        // fixed spot (verified as pure math; the live layout is confirmed visually).
        let qbPane = NSRect(x: 0, y: 0, width: 500, height: 700)
        let qbSel = NSRect(x: 100, y: 400, width: 200, height: 24)
        let qbOrigin = Self.quickBarOrigin(
            barSize: NSSize(width: 240, height: 38), selection: qbSel, pane: qbPane, margin: 8)
        let qbMidY = qbOrigin.y + 19
        check(
            "quickbar-near-selection", abs(qbMidY - qbSel.midY) < 80,
            "bar midY \(Int(qbMidY)) vs selection \(Int(qbSel.midY))")
        // Column view instead pins the bar to the pane's bottom (clear of the drilled
        // columns), so a no-selection bottom placement sits lower than the top-center one.
        let qbBottom = Self.quickBarOrigin(
            barSize: NSSize(width: 240, height: 38), selection: nil, pane: qbPane, margin: 8,
            noSelectionAtBottom: true)
        let qbTop = Self.quickBarOrigin(
            barSize: NSSize(width: 240, height: 38), selection: nil, pane: qbPane, margin: 8,
            noSelectionAtBottom: false)
        check(
            "quickbar-column-bottom", qbBottom.y < qbTop.y,
            "bottom.y=\(Int(qbBottom.y)) top.y=\(Int(qbTop.y))")
        // Switching a pane's view mode must not move the split divider (durable ratio constraint).
        let beforeRight = rightTabs.containerView.frame.width
        let originalMode = rightTabs.activePane?.viewMode ?? .list
        rightTabs.activePane?.setViewMode(.gallery)
        view.layoutSubtreeIfNeeded()
        let afterRight = rightTabs.containerView.frame.width
        rightTabs.activePane?.setViewMode(originalMode)  // restore
        check(
            "split-stable-on-view-switch", abs(beforeRight - afterRight) < 5,
            "right pane \(Int(beforeRight)) -> \(Int(afterRight))")
        // Dragging out must advertise both file URLs (modern apps) and legacy filenames (VMware
        // etc.) on the same pasteboard; adding the legacy type must not drop the file URLs.
        let scratch = NSPasteboard(name: NSPasteboard.Name("com.scarcrux.pathem.dragcheck"))
        scratch.clearContents()
        let dragURLs = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]
        scratch.writeObjects(dragURLs.map { $0 as NSURL })
        FileDrag.addLegacyFilenames(dragURLs, to: scratch)
        let keepsFileURL = scratch.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let filenames = scratch.propertyList(forType: FileDrag.filenamesType) as? [String]
        check(
            "drag-has-legacy-filenames", keepsFileURL && filenames == dragURLs.map(\.path),
            "fileURL=\(keepsFileURL) names=\(filenames ?? [])")
        // A dragged file must also advertise a file PROMISE (alongside its file URL), or
        // browser upload zones and sandboxed apps -- which materialize the promise into
        // DataTransfer.files -- silently reject the drop.
        let promiseScratch = NSPasteboard(name: NSPasteboard.Name("com.scarcrux.pathem.promisecheck"))
        promiseScratch.clearContents()
        promiseScratch.writeObjects([FileDrag.item(for: URL(fileURLWithPath: "/tmp/a.txt"))])
        let promiseType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
        let hasPromise = promiseScratch.types?.contains(promiseType) ?? false
        let promiseFileURL = promiseScratch.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        check(
            "drag-has-file-promise", hasPromise && promiseFileURL,
            "promise=\(hasPromise) fileURL=\(promiseFileURL)")
        // The promise delegate is pulled OFF the main thread by other apps (Messages fetches it
        // via file-provider XPC on a FileCoordination queue). Exercise it off-main: if the
        // delegate methods were main-actor-isolated the Swift concurrency check would trap the
        // whole process, so this also fails to compile if the `nonisolated` markers regress.
        let promiseSrc = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-promise-\(UUID().uuidString).txt")
        try? "promise payload".write(to: promiseSrc, atomically: true, encoding: .utf8)
        // Reproduce the Messages path: Foundation hands the delegate a fresh, plain provider
        // (not our FileDragItem) carrying the source only in userInfo. If the delegate can't
        // resolve the source from userInfo it writes nothing and the drop silently does nothing.
        let promiseItem = NSFilePromiseProvider(
            fileType: "public.plain-text", delegate: FilePromiseFulfiller.shared)
        promiseItem.userInfo = promiseSrc
        let fulfiller = FilePromiseFulfiller.shared
        let promiseDest = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-promise-dst-\(UUID().uuidString)")
            .appendingPathComponent(promiseSrc.lastPathComponent)
        try? FileManager.default.createDirectory(
            at: promiseDest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let promiseBox = SmokePromiseResult()
        let promiseSem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = fulfiller.operationQueue(for: promiseItem)  // the exact call that trapped
            promiseBox.name = fulfiller.filePromiseProvider(promiseItem, fileNameForType: "public.plain-text")
            // Actually fulfill the promise, exactly as a receiver (Messages) triggers it.
            fulfiller.filePromiseProvider(promiseItem, writePromiseTo: promiseDest) { err in
                promiseBox.error = err
                promiseSem.signal()
            }
        }
        promiseSem.wait()
        let wrote = promiseBox.error == nil && FileManager.default.fileExists(atPath: promiseDest.path)
        check("promise-fulfills-offmain", promiseBox.name == promiseSrc.lastPathComponent && wrote,
            "name=\(promiseBox.name) wrote=\(wrote) err=\(promiseBox.error.map { "\($0)" } ?? "nil")")
        try? FileManager.default.removeItem(at: promiseSrc)
        try? FileManager.default.removeItem(at: promiseDest.deletingLastPathComponent())
        // Get Info: presenting the inspector builds every field (metadata reads, open-with,
        // toggles) without crashing, and populates a reasonable number of them.
        let inspector = InfoInspectorController()
        let infoTmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-info-\(UUID().uuidString).txt")
        try? "hi".write(to: infoTmp, atomically: true, encoding: .utf8)
        inspector.present(urls: [infoTmp], over: nil)
        check("get-info-populates", inspector.debugFieldCount >= 5, "\(inspector.debugFieldCount) fields")
        inspector.debugClose()
        try? FileManager.default.removeItem(at: infoTmp)
        // Semantic dedup + AI: the new commands are registered, clustering is crash-safe on empty
        // input, and the AI availability probe returns a defined value (whatever this Mac reports).
        let cmdIDs = Set(commands.all.map(\.id))
        check("ai-commands-registered",
            cmdIDs.isSuperset(of: ["files.findSimilarNames", "ai.renameSelection", "ai.summarizeFolder"]),
            "have=\(["files.findSimilarNames", "ai.renameSelection", "ai.summarizeFolder"].filter(cmdIDs.contains).count)/3")
        check("semantic-dedup-empty-safe", SemanticDedup.similarGroups([]).isEmpty, "no groups for no files")
        check("ai-availability-defined", AIAssistant.availability.reason.isEmpty == AIAssistant.isAvailable,
            "availability=\(AIAssistant.availability) reason=\"\(AIAssistant.availability.reason)\"")
        // Multi-window: the primary is registered, the window commands exist, and a second browser
        // constructs as an independent (non-persisting) session so it can't clobber the primary's.
        check("window-commands-registered", cmdIDs.isSuperset(of: ["window.new", "window.moveTabToNew"]),
            "have=\(["window.new", "window.moveTabToNew"].filter(cmdIDs.contains).count)/2")
        let secondary = BrowserViewController(start: FileManager.default.homeDirectoryForCurrentUser, persistsSession: false)
        check("new-window-independent-session",
            !secondary.persistsSession && self.persistsSession && WindowManager.shared.windowCount >= 1,
            "secondaryPersists=\(secondary.persistsSession) primaryPersists=\(self.persistsSession) windows=\(WindowManager.shared.windowCount)")
        // Slideshow: the command is registered and the controller starts inactive (a headless
        // smoke must not pop a full-screen window, so we don't call start()).
        check("slideshow-ready", cmdIDs.contains("view.slideshow") && !slideshow.isActive,
            "registered=\(cmdIDs.contains("view.slideshow")) active=\(slideshow.isActive)")
        // Create PDF: two images combine into a real 2-page PDF.
        let pdfDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-pdf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: pdfDir, withIntermediateDirectories: true)
        var pdfImages: [URL] = []
        for i in 0..<2 {
            let image = NSImage(size: NSSize(width: 60, height: 40))
            image.lockFocus()
            NSColor.systemGreen.setFill()
            NSRect(x: 0, y: 0, width: 60, height: 40).fill()
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:]) {
                let url = pdfDir.appendingPathComponent("p\(i).png")
                try? png.write(to: url)
                pdfImages.append(url)
            }
        }
        let pdfOut = BrowserViewController.buildPDF(from: pdfImages, in: pdfDir)
        let pdfPages = pdfOut.flatMap { PDFDocument(url: $0)?.pageCount } ?? 0
        check("create-pdf-builds", pdfPages == 2, "pages=\(pdfPages)")
        // Markup: draw a stroke over an image and flatten to a valid same-size PNG.
        let mkFile = pdfDir.appendingPathComponent("markup-src.png")
        let mkImage = NSImage(size: NSSize(width: 80, height: 60))
        mkImage.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 80, height: 60).fill(); mkImage.unlockFocus()
        if let tiff = mkImage.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: mkFile)
        }
        let mkOut = markupController.debugMarkupAndSave(mkFile)
        let mkSize = mkOut.flatMap { NSImage(contentsOf: $0)?.size.width } ?? 0
        check("markup-flattens", cmdIDs.contains("image.markup") && mkOut != nil && mkSize >= 80,
            "registered=\(cmdIDs.contains("image.markup")) out=\(mkOut != nil) width=\(Int(mkSize))")
        try? FileManager.default.removeItem(at: pdfDir)
        // Show Original: a symlink resolves to its target; a plain file resolves to nil.
        let soDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-showorig-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: soDir, withIntermediateDirectories: true)
        let soTarget = soDir.appendingPathComponent("target.txt")
        let soLink = soDir.appendingPathComponent("link.txt")
        try? "x".write(to: soTarget, atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(at: soLink, withDestinationURL: soTarget)
        let resolvedLink = BrowserViewController.resolveOriginal(of: soLink)
        let resolvedPlain = BrowserViewController.resolveOriginal(of: soTarget)
        check("show-original-resolves", resolvedLink?.lastPathComponent == "target.txt" && resolvedPlain == nil,
            "link=\(resolvedLink?.lastPathComponent ?? "nil") plain=\(resolvedPlain?.lastPathComponent ?? "nil")")
        try? FileManager.default.removeItem(at: soDir)
        // Batch metadata + server: the new commands are registered, and the Finder-comment writer
        // round-trips (set, read back, clear) through the engine.
        check("batch-commands-registered",
            cmdIDs.isSuperset(of: ["files.setFinderComment", "files.connectToServer"]),
            "have=\(["files.setFinderComment", "files.connectToServer"].filter(cmdIDs.contains).count)/2")
        // Remote bookmarks: the command is registered and a bookmark survives a save/jump
        // round-trip on a connection (mirrors what addBookmark writes into the store).
        var bmConn = RemoteConnection(name: "Site", proto: .sftp, host: "h.example.com")
        bmConn.bookmarks.append(RemoteBookmark(name: "Logs", remotePath: "/var/log"))
        let bmData = (try? JSONEncoder().encode(bmConn)).flatMap {
            try? JSONDecoder().decode(RemoteConnection.self, from: $0)
        }
        check("remote-bookmarks",
            cmdIDs.contains("files.addBookmark") && bmData?.bookmarks.first?.remotePath == "/var/log",
            "cmd=\(cmdIDs.contains("files.addBookmark")) path=\(bmData?.bookmarks.first?.remotePath ?? "nil")")
        // Sync browsing: the command is registered and a relative descend on one pane
        // maps onto the other pane's parallel tree (delta mirroring, not same-path lock).
        let syncDescend = SyncBrowse.mirroredPath(
            driverFrom: "/a/projA", driverTo: "/a/projA/src", otherAt: "/a/projB")
        let syncAscend = SyncBrowse.mirroredPath(
            driverFrom: "/a/projA/src", driverTo: "/a/projA", otherAt: "/a/projB/src")
        check("sync-browse-delta",
            cmdIDs.contains("view.syncBrowsing") && syncDescend == "/a/projB/src"
                && syncAscend == "/a/projB",
            "cmd=\(cmdIDs.contains("view.syncBrowsing")) descend=\(syncDescend ?? "nil") ascend=\(syncAscend ?? "nil")")
        // Azure Blob: the protocol dispatches to its provider and the Shared Key signer
        // produces a signature (correctness is unit-tested against an HMAC vector).
        let azureProvider = RemoteProviders.make(for: .azure) is AzureBlobProvider
        let azureSig = AzureSharedKey.signature(
            key: Data("Jefe".utf8).base64EncodedString(), stringToSign: "what do ya want for nothing?")
        check("azure-blob-backend",
            azureProvider && RemoteConnection.Proto.allCases.contains(.azure) && azureSig != nil,
            "provider=\(azureProvider) signer=\(azureSig != nil)")
        // Cloud folder badges: a cloud folder's icon is decorated with a service glyph; a
        // plain folder's is returned untouched (same instance).
        let homeDir = NSHomeDirectory()
        let cloudDir = URL(fileURLWithPath: homeDir).appendingPathComponent("Library/CloudStorage")
        let baseIcon = NSWorkspace.shared.icon(forFile: "/")
        let cloudFolder = FileEntry(name: "GoogleDrive-x@y.com", isDirectory: true, size: 0, modificationDate: nil)
        let plainFolder = FileEntry(name: "Documents", isDirectory: true, size: 0, modificationDate: nil)
        let badged = CloudBadge.decorate(baseIcon, for: cloudFolder, in: cloudDir)
        let plain = CloudBadge.decorate(baseIcon, for: plainFolder, in: URL(fileURLWithPath: homeDir).appendingPathComponent("Code"))
        check("cloud-folder-badge",
            badged !== baseIcon && plain === baseIcon
                && CloudLocation.service(forFolderAt: cloudDir.appendingPathComponent("GoogleDrive-x@y.com").path, home: homeDir) == .googleDrive,
            "badged=\(badged !== baseIcon) plainUntouched=\(plain === baseIcon)")
        // Context menu editor: a custom order reorders the right-click menu, and hiding drops
        // an item. Build a menu with copy first and Rename hidden, then read it back.
        let cmenu = FileContextMenuController()
        cmenu.hiddenItems = ["files.rename"]
        cmenu.menuOrder = ["files.copy", "files.open"]
        let cmenuCommands = cmenu.menu.items.compactMap { $0.representedObject as? String }
        check("context-menu-reorder",
            Array(cmenuCommands.prefix(2)) == ["files.copy", "files.open"]
                && !cmenuCommands.contains("files.rename"),
            "first=\(Array(cmenuCommands.prefix(2))) hidRename=\(!cmenuCommands.contains("files.rename"))")
        // Color rules (labels): a matching rule yields a color/font; a non-match yields nil.
        let ruleSet = ColorRules(rules: [
            ColorRule(field: .ext, op: .isAnyOf, value: "log", colorHex: "#FF0000", bold: true)
        ])
        let logStyle = FileColorStyle.style(
            for: FileEntry(name: "a.log", isDirectory: false, size: 1, modificationDate: nil),
            rules: ruleSet, baseFont: .systemFont(ofSize: 13))
        let txtStyle = FileColorStyle.style(
            for: FileEntry(name: "a.txt", isDirectory: false, size: 1, modificationDate: nil),
            rules: ruleSet, baseFont: .systemFont(ofSize: 13))
        check("color-rules", logStyle?.color != nil && txtStyle == nil,
            "matched=\(logStyle?.color != nil) unmatched=\(txtStyle == nil)")
        // Custom toolbar buttons: the customize palette exposes every registry command (not
        // just the curated catalog), so any command can be dragged onto the toolbar.
        let paletteIDs = Set(toolbarAllowedItemIdentifiers(NSToolbar(identifier: "smoke")).map(\.rawValue))
        check("toolbar-any-command",
            paletteIDs.contains(Self.toolbarCmdPrefix + "view.syncBrowsing")
                && paletteIDs.count > Self.toolbarCatalog.count + 3,
            "palette=\(paletteIDs.count) catalog=\(Self.toolbarCatalog.count)")
        // Clean-uninstall + folder handler: the reset command is registered (never invoked
        // here -- it would wipe data), and the folder-default query answers without crashing.
        check("uninstall-hooks",
            cmdIDs.contains("app.resetData") && (FolderHandler.isPathem || !FolderHandler.isPathem),
            "reset=\(cmdIDs.contains("app.resetData"))")
        let fcFile = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-fc-\(UUID().uuidString).txt")
        try? "x".write(to: fcFile, atomically: true, encoding: .utf8)
        try? FileMetadata.setFinderComment("smoke note", on: fcFile)
        let fcRead = FileMetadata.finderComment(of: fcFile)
        try? FileMetadata.setFinderComment("", on: fcFile)
        let fcCleared = FileMetadata.finderComment(of: fcFile) == nil
        check("finder-comment-roundtrips", fcRead == "smoke note" && fcCleared, "read=\(fcRead ?? "nil") cleared=\(fcCleared)")
        try? FileManager.default.removeItem(at: fcFile)
        // ACL editor: the command is registered, the panel constructs, and the engine adds then
        // removes an entry on a real file (no privileges needed for your own file).
        _ = ACLEditorController()
        let aclFile = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-acl-\(UUID().uuidString).txt")
        try? "x".write(to: aclFile, atomically: true, encoding: .utf8)
        let added = ACLEditor.add(principal: NSUserName(), allow: true, permissions: ["read"], to: aclFile) == nil
        let listed = FileMetadata.aclEntries(of: aclFile)?.contains { $0.contains(NSUserName()) } ?? false
        let removed = ACLEditor.removeEntry(at: 0, from: aclFile) == nil && FileMetadata.aclEntries(of: aclFile) == nil
        check("acl-edit-roundtrips", cmdIDs.contains("files.editACL") && added && listed && removed,
            "registered=\(cmdIDs.contains("files.editACL")) added=\(added) listed=\(listed) removed=\(removed)")
        try? FileManager.default.removeItem(at: aclFile)
        // Ownership: change-owner command registered, the sudo command builds correctly, and a
        // change-group applies without root (setting the file's own group is a valid no-op).
        let ownFile = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-own-\(UUID().uuidString).txt")
        try? "x".write(to: ownFile, atomically: true, encoding: .utf8)
        let chownCmd = OwnershipEditor.sudoChownCommand(owner: "bob", group: "staff", recursive: false, paths: ["/tmp/a b"])
        let group = OwnershipEditor.read(ownFile)?.group ?? ""
        let grpOK = BulkAttributes.apply(.init(groupOwnerName: group), to: [ownFile]).failures.isEmpty && !group.isEmpty
        check("ownership-tools",
            cmdIDs.contains("files.changeOwner") && chownCmd == "sudo chown 'bob:staff' '/tmp/a b'" && grpOK,
            "registered=\(cmdIDs.contains("files.changeOwner")) cmd=\(chownCmd == "sudo chown 'bob:staff' '/tmp/a b'") group=\(grpOK)")
        try? FileManager.default.removeItem(at: ownFile)
        // Custom icon: the commands register and NSWorkspace applies then clears a custom icon.
        let iconDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-icon-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: iconDir, withIntermediateDirectories: true)
        let customImage = NSImage(size: NSSize(width: 32, height: 32))
        customImage.lockFocus(); NSColor.systemPink.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill(); customImage.unlockFocus()
        let iconSet = NSWorkspace.shared.setIcon(customImage, forFile: iconDir.path, options: [])
        NSWorkspace.shared.setIcon(nil, forFile: iconDir.path, options: [])
        check("custom-icon",
            cmdIDs.isSuperset(of: ["files.setCustomIcon", "files.removeCustomIcon"]) && iconSet,
            "registered=\(cmdIDs.isSuperset(of: ["files.setCustomIcon", "files.removeCustomIcon"])) set=\(iconSet)")
        try? FileManager.default.removeItem(at: iconDir)
        // Skinning: hex parsing, preset lookup, and an accent apply (restored afterward so the
        // running window keeps its configured skin).
        let parsedAccent = ThemeManager.color(fromHex: "#BD93F9")
        let emptyParse = ThemeManager.color(fromHex: "")
        let presetName = ThemePreset.matching(accentHex: "#BD93F9", backgroundHex: "#282A36", appearance: .dark)?.name
        ThemeManager.shared.apply(accentHex: "#FF0000", windowTintHex: "")
        let accentApplied = ThemeManager.shared.customAccent != nil
        ThemeManager.shared.apply(accentHex: prefs.accentColorHex, windowTintHex: prefs.windowTintHex)  // restore
        check("skinning-applies",
            parsedAccent != nil && emptyParse == nil && presetName == "Dracula" && accentApplied,
            "parsed=\(parsedAccent != nil) empty=\(emptyParse == nil) preset=\(presetName ?? "nil") applied=\(accentApplied)")
        // Folder backgrounds: the per-folder store round-trips (set, read, clear).
        check("folder-background-roundtrips", debugFolderBackgroundRoundTrips(), "")
        // Icon sets: a themed set renders an icon; "System" returns nil (use the OS icon).
        let sampleFolder = FileEntry(name: "docs", isDirectory: true, size: 0, modificationDate: nil)
        IconSetManager.shared.setCurrent(named: "Vivid")
        let themedIcon = IconSetManager.shared.icon(for: sampleFolder)
        IconSetManager.shared.setCurrent(named: "System")
        let systemIcon = IconSetManager.shared.icon(for: sampleFolder)
        IconSetManager.shared.setCurrent(named: prefs.iconSetName)  // restore
        check("icon-set-renders", themedIcon != nil && (themedIcon?.size.width ?? 0) > 0 && systemIcon == nil,
            "themed=\(themedIcon != nil) system=\(systemIcon == nil)")
        // Icon-view grouping: sections cover every entry and a selection maps back through the
        // section<->entry mapping.
        let gridGroup = IconCollectionController(gallery: false)
        gridGroup.directoryURL = URL(fileURLWithPath: "/tmp")
        gridGroup.setEntries([
            FileEntry(name: "b.txt", isDirectory: false, size: 10, modificationDate: nil),
            FileEntry(name: "afolder", isDirectory: true, size: 0, modificationDate: nil),
            FileEntry(name: "c.txt", isDirectory: false, size: 10, modificationDate: nil),
        ], preserveState: false)
        check("icon-view-grouping", gridGroup.debugGroupRoundTrips(), "")
        // Flat / recursive view: the command is registered and the enumerator flattens a subtree
        // (a nested file appears with its own subfolder location).
        let flatDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-flat-\(UUID().uuidString)")
        let flatSub = flatDir.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: flatSub, withIntermediateDirectories: true)
        try? "x".write(to: flatDir.appendingPathComponent("top.txt"), atomically: true, encoding: .utf8)
        try? "y".write(to: flatSub.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)
        let flatResult = FlatEnumerator.entries(of: flatDir, includeFolders: true)
        let hasDeep = flatResult.entries.contains { $0.name == "deep.txt" && ($0.location?.contains("sub") ?? false) }
        let hasTop = flatResult.entries.contains { $0.name == "top.txt" }
        check("flatten-folder", cmdIDs.contains("view.flattenFolder") && hasDeep && hasTop,
            "registered=\(cmdIDs.contains("view.flattenFolder")) deep=\(hasDeep) top=\(hasTop)")
        try? FileManager.default.removeItem(at: flatDir)
        // Tree view: the mode is registered, and the outline controller exposes its entries and a
        // location-aware selection (so file ops resolve to the real path).
        let tree = TreeOutlineController()
        tree.directoryURL = URL(fileURLWithPath: "/tmp")
        tree.setEntries([
            FileEntry(name: "afolder", isDirectory: true, size: 0, modificationDate: nil),
            FileEntry(name: "b.txt", isDirectory: false, size: 10, modificationDate: nil),
        ], preserveState: false)
        tree.select(name: "b.txt")
        let selected = tree.selectedEntries.first
        check("tree-view",
            cmdIDs.contains("view.asTree") && tree.entries.count == 2
                && selected?.name == "b.txt" && selected?.location == "/tmp",
            "registered=\(cmdIDs.contains("view.asTree")) entries=\(tree.entries.count) sel=\(selected?.name ?? "nil") loc=\(selected?.location ?? "nil")")
        // Commander mode: registered, and toggling shows then hides the bar.
        let commanderShown = debugToggleCommander()
        let commanderHidden = !debugToggleCommander()
        check("commander-mode", cmdIDs.contains("commander.toggle") && commanderShown && commanderHidden,
            "registered=\(cmdIDs.contains("commander.toggle")) shown=\(commanderShown) hidden=\(commanderHidden)")
        // Saved view presets: the store saves/replaces by name and round-trips the captured format,
        // and the save command is registered.
        var presetStore = ViewPresets.default
        presetStore.save(.init(name: "Photos", format: .init(viewMode: .icon, groupKey: .kind)))
        presetStore.save(.init(name: "Photos", format: .init(viewMode: .gallery, groupKey: .none)))  // replace by name
        let savedPreset = presetStore.presets.first { $0.name == "Photos" }
        check("view-presets",
            cmdIDs.contains("view.saveViewPreset") && presetStore.presets.count == 1
                && savedPreset?.format.viewMode == .gallery,
            "registered=\(cmdIDs.contains("view.saveViewPreset")) count=\(presetStore.presets.count) mode=\(savedPreset?.format.viewMode.rawValue ?? "nil")")
        // Vim navigation: the command is registered and j/k selection movement steps the selection.
        leftTabs.activePane?.selectFirst()
        let vimFirst = leftTabs.activePane?.selectedEntries.first?.name
        leftTabs.activePane?.moveSelection(by: 1)
        let vimSecond = leftTabs.activePane?.selectedEntries.first?.name
        check("vim-navigation",
            cmdIDs.contains("nav.vimMode") && vimFirst != nil && vimSecond != nil && vimFirst != vimSecond,
            "registered=\(cmdIDs.contains("nav.vimMode")) first=\(vimFirst ?? "nil") second=\(vimSecond ?? "nil")")
        // Open with Pathem / Services: openExternalFolder navigates the active pane. (Last check,
        // since it changes the active folder.)
        let openDir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-open-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: openDir, withIntermediateDirectories: true)
        openExternalFolder(openDir)
        let navigated = activePane?.currentURL.standardizedFileURL == openDir.standardizedFileURL
        check("open-external-folder", navigated, "at=\(activePane?.currentURL.lastPathComponent ?? "nil")")
        try? FileManager.default.removeItem(at: openDir)
        return (ok, lines)
    }
}

/// Cross-thread result box for the smoke promise check (the fulfillment completion runs on a
/// background OperationQueue). Reference type so the closures mutate one shared instance.
private final class SmokePromiseResult: @unchecked Sendable {
    var name = ""
    var error: Error?
}
