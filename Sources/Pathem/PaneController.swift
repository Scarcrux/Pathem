import AppKit
import PathemEngine

/// One pane of the dual-pane browser: a directory listing with its own
/// navigation history, an editable path/address bar, and back/forward/up
/// buttons. The pane is intentionally thin. NavigationState owns the history
/// logic and BulkEnumerator does the listing.
@MainActor
final class PaneController: NSObject, NSSearchFieldDelegate, NSMenuDelegate {
    let containerView = NSView()
    /// The active view (list, icon, or gallery), swapped when the folder's view
    /// mode changes. PaneController drives it through PaneContentView.
    private var content: PaneContentView = FileListController()
    private var currentMode: ViewFormat.ViewMode = .list
    /// When set (from Preferences), every folder shows hidden files regardless of its format.
    var showHiddenByDefault = false
    /// Icon/gallery zoom multiplier, persisted by the browser across view switches/launches.
    var iconZoom: CGFloat = 1
    var onIconZoomChanged: ((CGFloat) -> Void)?

    private func makeIconContent(gallery: Bool) -> IconCollectionController {
        let controller = IconCollectionController(gallery: gallery, scale: iconZoom)
        controller.onZoomChanged = { [weak self] scale in
            self?.iconZoom = scale
            self?.onIconZoomChanged?(scale)
        }
        return controller
    }

    /// Zoom the active grid view (Cmd +/-); no-op in list/column.
    func zoomContent(_ delta: CGFloat) { content.adjustZoom(delta) }

    /// Drill the first column's row N (PATHEM_VIEW_SHOT column-drill test).
    func debugColumnDrill(row: Int, column: Int = 0) {
        (content as? ColumnBrowserController)?.debugSelect(row: row, inColumn: column)
    }

    /// PATHEM_SMOKE: the list view's column fill ratio (nil when not in list view).
    func debugColumnFillRatio() -> CGFloat? { (content as? FileListController)?.debugColumnFillRatio() }

    /// Expand named top-level folders of the tree outline (PATHEM_VIEW_SHOT tree render).
    func debugTreeExpand(names: [String]) { (content as? TreeOutlineController)?.debugExpand(names: names) }

    /// Header sort-indicator state (list view only), for the layout smoke check.
    var debugSortIndicator: (column: String, ascending: Bool, drawn: Bool)? { content.debugSortIndicator }

    /// The current selection's bounding rect in window coordinates (for floating the
    /// quick-actions bar next to it), and the pane's scrolling clip view (to reposition
    /// the bar as the list scrolls).
    var selectionRectInWindow: NSRect? { content.selectionRectInWindow() }
    var contentClipView: NSClipView { content.scrollView.contentView }
    func setHiddenContextItems(_ ids: Set<String>) { lastHiddenContextItems = ids; content.setHiddenContextItems(ids) }
    func setContextMenuOrder(_ order: [String]) { lastContextMenuOrder = order; content.setContextMenuOrder(order) }
    func setColorRules(_ rules: ColorRules) { lastColorRules = rules; content.setColorRules(rules) }
    func setFormats(size: Preferences.SizeFormat, date: Preferences.DateDisplay) {
        lastFormats = (size, date)
        content.setFormats(size: size, date: date)
    }
    func setMiddleClickOpensNewTab(_ enabled: Bool) {
        lastMiddleClickNewTab = enabled
        content.setMiddleClickOpensNewTab(enabled)
    }
    /// Fired when a folder should open in a new tab (a middle-click); the browser handles it.
    var onOpenInNewTab: ((URL) -> Void)?
    private var lastMiddleClickNewTab = false
    // Cross-view settings, remembered so they carry across a view-mode swap (the new content
    // starts empty).
    private var lastHiddenContextItems: Set<String> = []
    private var lastContextMenuOrder: [String] = []
    private var lastColorRules = ColorRules()
    private var lastFormats: (size: Preferences.SizeFormat, date: Preferences.DateDisplay)?
    private let contentContainer = NSView()
    /// The full-pane document viewer overlay (Open in Other Pane), when showing a file.
    private var paneViewer: PaneDocumentViewer?
    /// Shown centered below the "Couldn't read this folder" placeholder so a permission failure has
    /// an action, not just an explanation. Hidden the moment any listing lands (see displayEntries).
    private let permissionButton = NSButton(
        title: L("pane.openFDA", "Open Full Disk Access…"), target: nil, action: nil)
    private var lastStyle: (rowHeight: CGFloat, fontSize: CGFloat, alternating: Bool)?
    private var clickBehavior: (singleClick: Bool, underlineHover: Bool) = (false, false)
    private var calculateFolderSizes = false
    private var cutPaths: Set<String> = []
    /// Selection to restore after a view-mode swap repopulates the new content.
    private var pendingSelection: Set<String>?
    /// Runs once, right after the next listing lands and `pendingSelection` is applied. The listing
    /// reload is off-main, so a caller that just created an item cannot select it (or act on that
    /// selection) synchronously -- the row does not exist yet. See `selectWhenListed`.
    private var pendingAfterListing: (() -> Void)?

    /// Select `name` once the (asynchronous) listing lands, then run `then` with it selected.
    /// This is what a "create a new item, then rename it" flow needs: reload() enumerates off the
    /// main thread, so selecting immediately after it would silently miss the brand-new row.
    func selectWhenListed(_ name: String, then: (() -> Void)? = nil) {
        pendingSelection = [name]
        pendingAfterListing = then
    }
    /// Keymap chord handler, re-applied to whichever content is active.
    var onKeyChordHandler: ((KeyChord) -> Bool)? {
        didSet { content.onKeyChord = onKeyChordHandler }
    }
    /// Mouse-gesture handler, re-applied to whichever content is active.
    var onDragSessionHandler: ((DragSessionEvent) -> Void)? {
        didSet { content.onDragSession = onDragSessionHandler }
    }
    var onMouseGestureHandler: ((String) -> Bool)? {
        didSet { content.onMouseGesture = onMouseGestureHandler }
    }
    /// Drag default (move vs copy), re-applied to whichever content is active.
    var dragMovesByDefault = false {
        didSet { content.dragMovesByDefault = dragMovesByDefault }
    }
    /// The focusable view of the active content (for first-responder handoff).
    var keyView: NSView { content.keyView }
    private(set) var nav: NavigationState

    private let breadcrumb = BreadcrumbBar()
    /// Editable address bar (Cmd-L): shows the current path so you can edit or
    /// paste a new one and press Return to jump there. Finder makes this awkward;
    /// here it's first-class.
    private let addressField = NSTextField()
    /// Shown instead of the breadcrumb while browsing a remote server.
    private let remoteLabel = NSTextField(labelWithString: "")

    /// An active remote browsing session (nil = browsing the local disk).
    private struct RemoteSession { let connection: RemoteConnection; var path: String; let password: String }
    private var remote: RemoteSession?
    var isRemote: Bool { remote != nil }

    /// Browsing an archive's contents: the archive was extracted to `mountRoot` (a temp
    /// dir we navigate as a normal folder); going up from the root returns to `origin`.
    private struct ArchiveSession {
        let archive: URL
        let mountRoot: URL
        let origin: URL
        let snapshot: [String: String]  // contents fingerprint at mount, to detect edits
    }
    private var archiveSession: ArchiveSession?
    var isBrowsingArchive: Bool { archiveSession != nil }
    /// Called when the user opens an archive file: the browser extracts it and calls
    /// `mountArchive` to enter it.
    var onBrowseArchive: ((URL) -> Void)?
    var onAttachDiskImage: ((URL) -> Void)?
    /// Opening a discovered-but-unmounted host in the synthetic Network view mounts its share.
    var onMountNetworkHost: ((String) -> Void)?
    /// Called when an archive session ends, so the browser can offer to write changes
    /// back into the archive (compares the mount against the snapshot taken at mount).
    var onArchiveClosed: ((_ archive: URL, _ mountRoot: URL, _ snapshot: [String: String]) -> Void)?
    /// Showing a cross-folder smart-result list (Recents / tag filter).
    private var smartActive = false
    /// Names in the current Network view that are discovered-but-unmounted hosts (as opposed to
    /// real network-volume mounts). Opening one mounts it rather than navigating into a folder.
    private var networkHostNames: Set<String> = []
    /// The synthetic Network view is showing (whether or not it currently has any unmounted hosts).
    private var networkActive = false
    /// Whether this pane is showing the Network view, so the browser can refresh it in place as
    /// discovered hosts come and go.
    var isShowingNetworkView: Bool { networkActive }
    /// This pane's current search query, so the shared search field can resync when
    /// focus moves between panes/tabs.
    var searchQuery = ""
    /// The smart results currently shown, kept so sort / view-mode changes re-apply
    /// in memory (there's no folder to re-read).
    private var smartEntries: [FileEntry] = []
    private var smartTitle = ""
    /// Bumped whenever the pane's shown content changes (navigation, a new smart
    /// request) so a slow async smart load can detect it's stale and not clobber.
    private var contentRequestToken = 0

    /// Reserve a content-request token for an async load; the loader applies its
    /// result only if `isContentRequestCurrent(token)` still holds.
    func beginContentRequest() -> Int {
        contentRequestToken += 1
        return contentRequestToken
    }
    func isContentRequestCurrent(_ token: Int) -> Bool { contentRequestToken == token }

    /// The active remote session as plain values, for the transfer layer. Nil locally.
    var remoteContext: (connection: RemoteConnection, path: String, password: String)? {
        remote.map { ($0.connection, $0.path, $0.password) }
    }
    /// Local files dropped onto a remote pane: upload them to the current folder.
    var onUploadFiles: ((_ urls: [URL], _ connection: RemoteConnection, _ remotePath: String, _ password: String) -> Void)?
    /// Opening a remote file: download it to a temp file and open it locally.
    var onOpenRemoteFile: ((_ connection: RemoteConnection, _ remotePath: String, _ password: String, _ name: String) -> Void)?
    private var backButton = NSButton()
    private var forwardButton = NSButton()
    private var upButton = NSButton()
    /// Point size for the navigation button icons (from the toolbar-icon-size preference).
    var iconPointSize: CGFloat = 13 { didSet { applyIconSize() } }
    private var viewSwitcher = NSSegmentedControl()
    private let sortButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let actionButton = NSPopUpButton(frame: .zero, pullsDown: true)
    /// Run a registered browser command by id (set by the browser). The action
    /// menu uses this so its items reuse the same command spine as the main menu.
    var runCommand: ((String) -> Void)?

    /// The location bar (breadcrumb / edit field / remote label): its own full-width
    /// row, above or below the file list (Directory Opus style), never crammed onto
    /// the button row.
    private let pathBar = NSStackView()
    private var toolbarStack = NSStackView()
    private let bottomStack = NSStackView()
    /// The constraints that position the location bar above or below the list; swapped
    /// when the position toggles.
    private var pathBarPositionConstraints: [NSLayoutConstraint] = []
    private let statusLabel = NSTextField(labelWithString: "")
    /// A small eye button on the status row that shows/hides hidden files for this pane, like Finder's
    /// Cmd-Shift-period but always visible.
    private let hiddenToggle = NSButton()
    /// Whether hidden files are currently shown in this pane (the per-folder view or the global
    /// default), for the eye toggle's icon.
    private var hiddenShown: Bool { format.showHidden || showHiddenByDefault }
    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// Fired when this pane becomes active (its list gains focus).
    var onBecomeActive: (() -> Void)?
    /// Fired when the row selection changes (used by the preview pane).
    var onSelectionChanged: (() -> Void)?
    /// The active view committed an in-place rename; the browser performs it (+ undo).
    var onRenameRequested: ((FileEntry, String) -> Void)?

    /// The single selected file's URL, or nil (for the preview pane). Never a remote
    /// row (currentURL is the local fallback, so it'd be a bogus path) and never an
    /// online-only file (previewing it would fault a download).
    var singleSelectedURL: URL? {
        guard remote == nil else { return nil }
        let selected = content.selectedEntries
        guard selected.count == 1, let entry = selected.first, !entry.isDirectory, !entry.isDataless
        else { return nil }
        if let location = entry.location {
            return URL(fileURLWithPath: location).appendingPathComponent(entry.name)
        }
        return currentURL.appendingPathComponent(entry.name)
    }
    /// Fired when this pane's folder changes, by navigation or on-disk edits.
    /// The browser uses it to invalidate and rebuild the semantic-search cache.
    var onDirectoryDidChange: ((URL) -> Void)?
    /// Fired only on user navigation (not watcher refreshes), so the browser can
    /// clear the stale search query.
    var onDidNavigate: (() -> Void)?
    /// Files were dropped onto this pane: copy/move them into its folder.
    var onDropFiles: ((_ urls: [URL], _ move: Bool, _ destination: URL) -> Void)?
    var onDropOntoFile: ((_ dragged: [URL], _ target: URL) -> Void)?
    /// A right-click action on a breadcrumb ancestor segment (open into a pane/tab, copy path).
    var onBreadcrumbAction: ((_ folder: URL, _ action: BreadcrumbBar.Action) -> Void)?
    /// Opens a (non-folder) file, applying the browser's scoped opener rules.
    /// Falls back to the system default when unset.
    var openFile: ((URL) -> Void)?

    private var watcher: DirectoryWatcher?
    private var pendingRefresh: DispatchWorkItem?
    private var showingSearchResults = false
    /// Whether a search result list (not the plain folder listing) is on screen, so the
    /// browser only restores the listing when a cleared search actually changed it.
    var isShowingSearchResults: Bool { showingSearchResults }

    /// Live filter (find-as-you-type) over the current listing.
    private let filterField = NSSearchField()
    private var filterText = ""
    private var fileFilter = FileFilter("")
    /// The unfiltered display set, kept so changing the filter re-applies instantly.
    private var sourceEntries: [FileEntry] = []

    /// Git overlay state for the status line, and a generation guard so a stale
    /// off-main `git status` can't clobber a newer listing.
    private let gitGen = GenerationBox()
    private var gitSummary: String?

    /// Generation guard for the off-main listing enumeration, so a slow read of a
    /// folder we've since navigated away from (or re-triggered) can't apply its rows
    /// over the current listing.
    private let reloadGen = GenerationBox()

    /// How this pane sorts and filters its listing (resolved per folder).
    var format = ViewFormat.default
    /// Asks the browser for the saved format for a folder (the per-folder cascade).
    var resolveFormat: ((URL) -> ViewFormat)?
    /// Whether a folder has its own remembered format. When it doesn't, navigating into it
    /// keeps the current view mode (so Gallery/Column stays selected as you browse) instead
    /// of snapping back to the default.
    var hasExplicitFormat: ((URL) -> Bool)?
    /// Tells the browser to remember a format for this folder.
    var rememberFormat: ((URL, ViewFormat) -> Void)?

    init(start: URL) {
        nav = NavigationState(current: start.standardizedFileURL)
        super.init()
        build()
        wireContent()
        ThemeManager.shared.onChange(owner: self) { [weak self] in guard let self else { return }; self.setActive(self.isActivePane) }
        enterDirectory()
    }

    // The folder file operations act on. For list/icon/gallery this equals
    // nav.current (the content's directoryURL is kept in sync); for column view it
    // is the active column's folder; for search/smart/remote the content reports
    // nil, so it falls back to nav.current.
    var currentURL: URL { content.directoryURL ?? nav.current }

    /// The tab's navigated root folder (ignores column-view drill-down). Used for
    /// session/layout capture so a restart reopens the tab's folder, not a deep column.
    var rootURL: URL { nav.current }
    var selectedEntries: [FileEntry] { content.selectedEntries }
    var canGoBack: Bool { nav.canGoBack }
    var canGoForward: Bool { nav.canGoForward }
    var canGoUp: Bool { nav.parent != nil }

    /// Entries currently shown (directory listing, or ranked search results).
    var entries: [FileEntry] { content.entries }

    /// Move the single selection by `delta` rows, clamped (used by vim-style j/k navigation).
    func moveSelection(by delta: Int) {
        let all = content.entries
        guard !all.isEmpty else { return }
        let currentName = content.selectedEntries.last?.name
        let currentIndex = currentName.flatMap { name in all.firstIndex { $0.name == name } } ?? (delta > 0 ? -1 : all.count)
        let next = max(0, min(all.count - 1, currentIndex + delta))
        content.select(name: all[next].name)
    }
    func selectFirst() { if let first = content.entries.first { content.select(name: first.name) } }
    func selectLast() { if let last = content.entries.last { content.select(name: last.name) } }

    /// Select the shown entries matching `query`, combining with the current selection per
    /// `mode` (replace / add / subtract). Powers "Select by Pattern…".
    func applySelection(_ query: SelectionQuery, mode: SelectionMode) {
        let isMatch = query.predicate()
        let matching = Set(entries.filter(isMatch).map(\.name))
        let current = Set(selectedEntries.map(\.name))
        let result: Set<String>
        switch mode {
        case .replace: result = matching
        case .add: result = current.union(matching)
        case .subtract: result = current.subtracting(matching)
        }
        content.selectNames(result)
    }

    /// The single funnel every listing passes through, so the live filter applies
    /// uniformly (local, smart, flat, remote). A context change (preserveState ==
    /// false, i.e. navigation or a new smart/remote view) clears the filter; an
    /// in-place refresh keeps it.
    private func displayEntries(_ entries: [FileEntry], preserveState: Bool) {
        permissionButton.isHidden = true  // any successful/empty listing clears the permission prompt
        if !preserveState, !filterText.isEmpty { clearFilterField() }
        sourceEntries = entries
        content.setEntries(filtered(entries), preserveState: preserveState)
    }

    private func filtered(_ entries: [FileEntry]) -> [FileEntry] {
        guard !fileFilter.isEmpty else { return entries }
        return entries.filter { fileFilter.matches($0) }
    }

    /// Apply a live filter over the current display set (called as the user types).
    /// Supports name substrings plus tokens like ext:, kind:, and size:.
    func setFilter(_ text: String) {
        filterText = text
        fileFilter = FileFilter(text)
        let shown = filtered(sourceEntries)
        content.setEntries(shown, preserveState: true)
        content.showPlaceholder(
            shown.isEmpty && !sourceEntries.isEmpty
                ? String(format: L("pane.noMatchesFor", "No matches for “%@”"), text) : nil)
        updateStatus()
    }

    /// Show and focus the filter field.
    func beginFilter() {
        filterField.isHidden = false
        containerView.window?.makeFirstResponder(filterField)
    }

    /// Clear and hide the filter field, restoring the full listing and focus.
    func endFilter() {
        clearFilterField()
        setFilter("")
        containerView.window?.makeFirstResponder(content.keyView)
    }

    private func clearFilterField() {
        filterText = ""
        filterField.stringValue = ""
        filterField.isHidden = true
    }

    /// Replace the listing with an explicit set (e.g. ranked search results).
    func showResults(_ entries: [FileEntry]) {
        showingSearchResults = true
        content.directoryURL = nil  // disable row drag during search
        content.resolutionURL = nav.current  // but results are from this folder, so actions resolve
        displayEntries(entries, preserveState: false)
        content.showPlaceholder(entries.isEmpty ? String(format: L("pane.noMatchesFor", "No matches for “%@”"), self.searchQuery) : nil)
        updateStatus()
    }

    /// True while showing a cross-folder smart-result list (Recents, tag filter).
    var isShowingSmartResults: Bool { smartActive }

    /// Show a cross-folder result list. Entries carry their own location so opening
    /// Flatten this folder's whole subtree into one cross-folder list (Directory
    /// Opus "Flat View"). Walks off the main thread, then renders through the smart-
    /// results path; re-validates the pane hasn't moved before showing.
    func showFlatView() {
        guard remote == nil else { NSSound.beep(); return }
        let root = nav.current
        let token = beginContentRequest()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FlatEnumerator.entries(of: root)
            DispatchQueue.main.async {
                guard let self, self.isContentRequestCurrent(token), self.nav.current == root,
                    self.remote == nil
                else { return }
                let title =
                    String(format: L("pane.flatViewTitle", "Flat View: %@"), root.lastPathComponent)
                    + (result.truncated
                        ? String(format: L("pane.flatViewFirstN", " (first %d)"), result.entries.count) : "")
                self.showSmartResults(result.entries, title: title)
            }
        }
    }

    /// resolves across folders. It's read-only: the browser blocks file ops here
    /// (they assume a single current folder). Back or selecting a folder leaves it.
    func showSmartResults(_ entries: [FileEntry], title: String, preservingState: Bool = false) {
        networkHostNames = []  // a plain smart view carries no mountable hosts (Network sets them after)
        networkActive = false
        remote = nil
        watcher?.stop()
        watcher = nil
        pendingRefresh?.cancel()
        smartActive = true
        smartEntries = entries
        smartTitle = title
        gitSummary = nil
        content.setGitStates([:])  // a cross-folder list isn't one repo folder
        showingSearchResults = true  // keep watcher-driven reloads from fighting it
        // Column view can't show a flat cross-folder list; use list for the smart
        // results (the saved format is untouched, so leaving restores columns).
        applyViewMode(format.viewMode == .column ? .list : format.viewMode)
        pendingSelection = nil
        content.directoryURL = nil  // not a single folder: disable drag
        content.resolutionURL = nil
        // A live refresh (e.g. the Network view re-rendering as Bonjour hosts come and go)
        // keeps the selection and does not grab focus, so it never yanks the cursor or clears
        // the highlight mid-interaction. A fresh open resets state and takes focus as usual.
        displayEntries(format.sorted(entries), preserveState: preservingState)
        content.showSortIndicator(key: format.sortKey, ascending: format.ascending)  // match the header to the sort
        content.showPlaceholder(entries.isEmpty ? L("pane.folderEmpty", "This folder is empty") : nil)
        breadcrumb.isHidden = true
        addressField.isHidden = true
        remoteLabel.isHidden = false
        remoteLabel.stringValue = title
        backButton.isEnabled = nav.canGoBack
        forwardButton.isEnabled = nav.canGoForward
        upButton.isEnabled = false
        updateStatus()
        onDidNavigate?()
        if !preservingState { containerView.window?.makeFirstResponder(content.keyView) }
    }

    /// Show the synthetic "Network" listing: real network-volume mounts (OrbStack, mounted SMB/AFP
    /// shares) that open by navigating into them, plus discovered-but-unmounted hosts named in
    /// `hostNames` that open by mounting (via onMountNetworkHost). Like Finder's Network view.
    func showNetworkResults(_ entries: [FileEntry], hostNames: Set<String>, title: String) {
        // A refresh (already on the Network view) preserves selection and focus so Bonjour churn
        // doesn't yank the cursor; the first open resets and takes focus.
        showSmartResults(entries, title: title, preservingState: networkActive)
        networkHostNames = hostNames
        networkActive = true
    }

    /// Drop the given paths from the smart-result list (after a file op trashed or
    /// moved them), since a smart view has no folder to reload from. No-op unless a
    /// smart view is showing.
    func pruneSmartEntries(paths: Set<String>) {
        guard smartActive, !paths.isEmpty else { return }
        let before = smartEntries.count
        smartEntries.removeAll { paths.contains(Self.path(of: $0)) }
        guard smartEntries.count != before else { return }
        displayEntries(format.sorted(smartEntries), preserveState: true)
        content.showPlaceholder(smartEntries.isEmpty ? L("pane.folderEmpty", "This folder is empty") : nil)
        updateStatus()
    }

    /// The absolute path of a (smart-result) entry, from its own location.
    private static func path(of entry: FileEntry) -> String {
        if let location = entry.location {
            return (location as NSString).appendingPathComponent(entry.name)
        }
        return entry.name
    }

    /// Refresh the listing. In-place refreshes (sort, file op, watcher) preserve
    /// the selection and scroll; navigation passes preserveState: false to reset.
    func reload(preserveState: Bool = true) {
        ReloadDebug.log(
            "reload folder=\(nav.current.lastPathComponent) preserve=\(preserveState) "
                + "remote=\(remote != nil) smart=\(smartActive)")
        if remote != nil { reloadRemote(); return }
        if smartActive { return }  // a smart-result view isn't a folder to refresh
        // Leaving the mounted archive's subtree (sidebar jump, path-bar) drops the session.
        if let session = archiveSession,
            !nav.current.standardizedFileURL.path.hasPrefix(session.mountRoot.standardizedFileURL.path)
        {
            endArchiveSession()  // offer to write changes back
        }
        showingSearchResults = false
        remoteLabel.isHidden = true
        breadcrumb.isHidden = false
        if let resolveFormat {
            var resolved = resolveFormat(nav.current)
            // Unconfigured folders inherit the current view mode (sticky Gallery/Column),
            // rather than reverting to the default each time you open a subfolder.
            if hasExplicitFormat?(nav.current) != true { resolved.viewMode = currentMode }
            format = resolved
        }
        applyViewMode(format.viewMode)  // may swap the content view before we fill it
        // Set the directory synchronously (it's cheap and independent of the async read). It gates
        // row draggability -- the list resolves each row's file URL against it in
        // pasteboardWriterForRow -- so it must be set the instant the content view exists. Leaving
        // it until the async completion broke drag whenever that completion was dropped (superseded
        // reload) or the view was freshly swapped (view-mode change, session restore): the rows
        // showed but nothing was draggable.
        content.directoryURL = nav.current  // rows in this folder are draggable
        content.resolutionURL = nav.current
        content.setSortFormat(format)  // column view re-sorts its drilled columns to match
        content.setGroupKey(format.groupKey)  // list view groups under section headers (else no-op)
        content.showSortIndicator(key: format.sortKey, ascending: format.ascending)

        // Enumerate (and sort) the folder off the main thread: a huge or slow directory must not
        // freeze the UI. Existing rows stay on screen until the fresh ones arrive; a stale read of
        // a folder we've since left is dropped by the generation guard.
        let dir = nav.current
        let includeHidden = format.showHidden || showHiddenByDefault
        let fmt = format
        let generation = reloadGen.bump()
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<[FileEntry], Error>
            do {
                let entries = try BulkEnumerator().entries(of: dir, includingHidden: includeHidden)
                outcome = .success(fmt.sorted(entries))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                // Apply only if still the same listing (see canApplyListing). directoryURL was
                // already set synchronously above, so drag works even if this completion is dropped.
                guard let self, self.canApplyListing(for: dir, generation: generation) else { return }
                switch outcome {
                case .success(let sorted):
                    self.displayEntries(sorted, preserveState: preserveState)
                    // setEntries refreshes only the root column; re-enumerate drilled ones too
                    // so a file op inside a drilled column shows its result (no-op elsewhere).
                    if preserveState { self.content.refreshDrilledColumns() }
                    self.content.showPlaceholder(
                        sorted.isEmpty ? L("pane.folderEmpty", "This folder is empty") : nil)
                case .failure:
                    // A read failure (permission denied, missing) looks identical to an
                    // empty folder unless we say so.
                    self.displayEntries([], preserveState: false)
                    self.content.showPlaceholder(
                        L(
                            "pane.readFolderFailed",
                            "Couldn’t read this folder.\nPathem may need Full Disk Access "
                                + "(System Settings ▸ Privacy & Security ▸ Full Disk Access)."))
                    self.permissionButton.isHidden = false  // give the failure an action
                }
                // After a view-mode swap, carry the selection into the fresh content.
                if let pending = self.pendingSelection {
                    self.content.selectNames(pending)
                    self.pendingSelection = nil
                }
                // A caller waiting on this listing (e.g. "new folder, now rename it") runs now that
                // its row exists and is selected.
                if let after = self.pendingAfterListing {
                    self.pendingAfterListing = nil
                    after()
                }
                self.updateStatus()
                self.refreshGitStatusAsync()
            }
        }
        breadcrumb.setURL(nav.current)
        // Inside an archive, show a friendly "archive ▸ sub ▸ dir" label, not the raw
        // temp path, and make Up always available (it climbs out to the origin).
        if let session = archiveSession {
            let rootPath = session.mountRoot.standardizedFileURL.path
            let rel = String(nav.current.standardizedFileURL.path.dropFirst(rootPath.count))
                .split(separator: "/").joined(separator: " ▸ ")
            remoteLabel.stringValue = "📦 " + session.archive.lastPathComponent + (rel.isEmpty ? "" : " ▸ " + rel)
            remoteLabel.isHidden = false
            breadcrumb.isHidden = true
            addressField.isHidden = true
        }
        backButton.isEnabled = nav.canGoBack
        forwardButton.isEnabled = nav.canGoForward
        upButton.isEnabled = nav.parent != nil || archiveSession != nil
    }

    /// Whether an off-main listing read for `dir` taken at `generation` may still be applied.
    /// The superseding guard: it must be the newest reload (a later reload bumped the counter),
    /// the pane must still be showing a local folder (not switched to a remote or smart-result
    /// view), and it must still be on that same folder. Any of these failing means the read is
    /// stale and dropping it leaves the current listing intact.
    private func canApplyListing(for dir: URL, generation: Int) -> Bool {
        reloadGen.isCurrent(generation) && remote == nil && !smartActive && nav.current == dir
    }

    /// Exercises the superseding guard deterministically (PATHEM_SMOKE): a listing read is applied
    /// only when it is the newest and still on the same folder; a superseded read, or one whose
    /// folder we've since left, is refused. Bumps the reload counter, which is safe here because
    /// the startup listing has already been applied (the smoke harness waits for its rows).
    func debugSupersededListingIsDropped() -> Bool {
        let here = nav.current
        let elsewhere = URL(fileURLWithPath: "/var/empty")
        let genOld = reloadGen.bump()  // as if a reload of `here` started
        let genNew = reloadGen.bump()  // a newer reload superseded it
        let newestApplies = canApplyListing(for: here, generation: genNew)
        let supersededDropped = !canApplyListing(for: here, generation: genOld)
        let movedOnDropped = !canApplyListing(for: elsewhere, generation: genNew)
        return newestApplies && supersededDropped && movedOnDropped
    }

    /// PATHEM_SMOKE: whether the active list view's rows are draggable (nil if not a list). reload
    /// sets directoryURL synchronously, so a fresh list from a view-mode swap is draggable at once,
    /// not only after the async listing lands. Guards the "rows show but nothing drags" regression.
    func debugListRowsDraggable() -> Bool? { (content as? FileListController)?.debugRowsDraggable() }

    /// Whether the list's name cell at `row` exposes the clean filename to VoiceOver (A8 guard).
    func debugListNameAXMatches(row: Int) -> Bool? {
        (content as? FileListController)?.debugNameAXMatchesEntry(row: row)
    }

    /// AX check on the first entry row (skipping group headers), for the accessibility guard.
    func debugFirstEntryNameAXMatches() -> Bool? { (content as? FileListController)?.debugFirstEntryNameAXMatches() }

    /// Whether the background menu for `dir` offers Empty Trash (only in the Trash), for the guard.
    func debugBackgroundMenuHasEmptyTrash(forDir dir: URL) -> Bool {
        (content as? FileListController)?.debugBackgroundMenuHasEmptyTrash(forDir: dir) ?? false
    }

    /// Inline-rename reload-safety guard: is an edit active, and a same-entries reload in place.
    var debugInlineEditActive: Bool { (content as? FileListController)?.debugInlineEditActive ?? false }
    func debugReloadContentInPlace() { content.setEntries(content.entries, preserveState: true) }
    /// Current view mode, for the viewer-overlay-vs-view-switch smoke guard.
    var debugViewMode: ViewFormat.ViewMode { format.viewMode }

    /// Whether the image-only toolbar controls carry accessibility labels (Track A8 guard).
    func debugToolbarAccessibilityLabeled() -> Bool {
        let labeled: [NSControl] = [backButton, forwardButton, upButton, sortButton, actionButton, viewSwitcher]
        return labeled.allSatisfy { !($0.accessibilityLabel()?.isEmpty ?? true) }
    }

    /// Re-key git states from the canonical repo root to the displayed folder path, so
    /// overlays match when the folder is browsed through a symlink.
    private static func remapStates(_ states: [String: GitFileState], to dir: URL)
        -> [String: GitFileState]
    {
        let canonical = dir.resolvingSymlinksInPath().path
        let displayed = dir.path
        guard canonical != displayed else { return states }  // no symlink: nothing to do
        var remapped: [String: GitFileState] = [:]
        for (key, value) in states {
            if key == canonical || key.hasPrefix(canonical + "/") {
                remapped[displayed + key.dropFirst(canonical.count)] = value
            } else {
                remapped[key] = value
            }
        }
        return remapped
    }

    /// Read the git status of the current folder off the main thread and apply the
    /// per-file overlays + branch summary, guarded so a stale result is dropped.
    private func refreshGitStatusAsync() {
        let dir = nav.current
        ReloadDebug.log("git-refresh folder=\(dir.lastPathComponent)")
        let generation = gitGen.bump()
        Task.detached(priority: .utility) { [weak self] in
            let info = await GitStatus.status(for: dir)
            await MainActor.run {
                guard let self, self.gitGen.isCurrent(generation), self.remote == nil, !self.smartActive,
                    self.nav.current == dir
                else { return }
                // git reports the canonical repo root (symlinks resolved), but the list
                // keys rows by the displayed (possibly symlinked) path. Remap so badges
                // match when the folder is reached through a symlink (e.g. /tmp).
                self.content.setGitStates(Self.remapStates(info?.states ?? [:], to: dir))
                self.gitSummary = info.map { gitInfo in
                    var parts = ["\u{2387} \(gitInfo.branch ?? L("pane.gitDetached", "detached"))"]  // ⎇ branch
                    if gitInfo.ahead > 0 { parts.append("\u{2191}\(gitInfo.ahead)") }
                    if gitInfo.behind > 0 { parts.append("\u{2193}\(gitInfo.behind)") }
                    return parts.joined(separator: " ")
                }
                self.updateStatus()
            }
        }
    }

    /// Refresh the listing unless this pane is currently showing search results.
    /// File operations use this so an op elsewhere never wipes a pane's results
    /// (the on-disk change is still picked up by the watcher for index rebuild).
    func reloadIfShowingListing() {
        if !showingSearchResults { reload() }
    }

    // MARK: - Remote browsing

    /// Switch this pane to browse a remote server. The local location is kept so
    /// going up from the remote root returns here.
    func openRemote(_ connection: RemoteConnection, password: String) {
        // Stop watching the local folder while remote, so local disk changes
        // don't trigger spurious remote re-lists or local re-indexing.
        watcher?.stop()
        watcher = nil
        pendingRefresh?.cancel()
        remote = RemoteSession(
            connection: connection, path: connection.path.isEmpty ? "/" : connection.path, password: password)
        gitSummary = nil
        content.setGitStates([:])  // no git overlays on a remote server
        reloadRemote()
        containerView.window?.makeFirstResponder(content.keyView)
    }

    /// Re-list the current remote folder (e.g. after an upload added a file).
    func refreshRemote() {
        if remote != nil { reloadRemote() }
    }

    /// Leave remote browsing and return to the local folder (re-arms the watcher).
    func closeRemote() {
        remote = nil
        enterDirectory()
        containerView.window?.makeFirstResponder(content.keyView)
    }

    /// List the current remote folder off the main thread (via the provider).
    private func reloadRemote() {
        guard let session = remote else { return }
        showingSearchResults = false
        onDidNavigate?()  // clear the (local) search field as the remote folder changes
        // Column view can't render a single remote listing; use list for remote.
        applyViewMode(format.viewMode == .column ? .list : format.viewMode)
        pendingSelection = nil  // clear AFTER the swap (which would set it) so it can't leak forward
        content.directoryURL = nil  // remote items aren't local-draggable yet
        content.resolutionURL = nil
        content.showPlaceholder(String(format: L("pane.loadingHost", "Loading %@…"), session.connection.host))
        breadcrumb.isHidden = true
        addressField.isHidden = true
        remoteLabel.isHidden = false
        remoteLabel.stringValue = "\(session.connection.proto.label)  \(session.connection.host)\(session.path)"
        backButton.isEnabled = false
        forwardButton.isEnabled = false
        upButton.isEnabled = true  // up goes to the parent, or back to local at the root

        let provider = RemoteProviders.make(for: session.connection.proto)
        Task { [weak self] in
            do {
                let entries = try await provider.list(
                    session.connection, path: session.path, password: session.password)
                guard let self, let cur = self.remote, cur.path == session.path,
                    cur.connection.id == session.connection.id
                else { return }
                self.displayEntries(self.format.sorted(entries), preserveState: false)
                self.content.showPlaceholder(entries.isEmpty ? L("pane.folderEmpty", "This folder is empty") : nil)
                self.updateStatus()
            } catch {
                guard let self, let cur = self.remote, cur.path == session.path,
                    cur.connection.id == session.connection.id
                else { return }
                self.displayEntries([], preserveState: false)
                self.content.showPlaceholder(
                    String(
                        format: L("pane.openHostFailed", "Couldn’t open %@%@\n%@"),
                        session.connection.host, session.path, Self.describe(error)))
                self.updateStatus()
            }
        }
    }

    static func joinRemote(_ base: String, _ name: String) -> String {
        (base.hasSuffix("/") ? base : base + "/") + name
    }

    static func parentRemote(_ path: String) -> String {
        var p = path
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        guard let slash = p.lastIndex(of: "/") else { return "/" }
        let parent = String(p[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? RemoteError else { return error.localizedDescription }
        switch error {
        case .unsupported(let message): return message
        case .curl(let code, let message):
            return message.isEmpty ? String(format: L("pane.connectionFailedCode", "The connection failed (code %d)"), code) : message
        case .curlMissing: return L("pane.curlMissing", "curl was not found")
        case .sftp(let code, let message):
            return message.isEmpty ? String(format: L("pane.connectionFailedCode", "The connection failed (code %d)"), code) : message
        case .sftpMissing: return L("pane.sftpMissing", "sftp was not found")
        case .device(let code, let message):
            return message.isEmpty ? String(format: L("pane.deviceFailedCode", "The device connection failed (code %d)"), code) : message
        case .deviceToolMissing(let tool):
            return String(format: L("pane.deviceToolMissing", "%@ is not installed. Install it to browse this device."), tool)
        }
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
        lastStyle = (CGFloat(rowHeight), CGFloat(fontSize), alternatingRows)
        content.applyStyle(
            rowHeight: CGFloat(rowHeight), fontSize: CGFloat(fontSize), alternatingRows: alternatingRows)
    }

    /// Apply click behavior (single-click open, hover underline) to this pane's view.
    func setClickBehavior(singleClick: Bool, underlineHover: Bool) {
        clickBehavior = (singleClick, underlineHover)
        content.setClickBehavior(singleClick: singleClick, underlineHover: underlineHover)
    }

    /// Toggle Finder-style "calculate all sizes" for this pane's list.
    func setCalculateFolderSizes(_ on: Bool) {
        calculateFolderSizes = on
        content.setCalculateFolderSizes(on)
    }

    /// Dim the given paths (items marked for cut), carried across view-mode swaps.
    func setCutPaths(_ paths: Set<String>) {
        cutPaths = paths
        content.setCutPaths(paths)
    }

    func descend(into entry: FileEntry) {
        dismissViewer()  // opening something closes any document viewer overlay
        // In the Network view, an unmounted host has no real folder -- mount it instead of navigating.
        if networkHostNames.contains(entry.name) {
            onMountNetworkHost?(entry.name)
            return
        }
        if let remote {
            if entry.isDirectory {
                self.remote?.path = Self.joinRemote(remote.path, entry.name)
                reloadRemote()
            } else {
                onOpenRemoteFile?(
                    remote.connection, Self.joinRemote(remote.path, entry.name), remote.password, entry.name)
            }
            return
        }
        let url = urlFor(entry)  // smart-result entries carry their own folder
        if entry.isDirectory {
            // App bundles and document packages are directories but should open (launch),
            // like Finder; entering them is via "Show Package Contents" only.
            if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true {
                NSWorkspace.shared.open(url)
            } else {
                nav.go(to: url)
                enterDirectory()  // clears smart mode and watches the real folder
            }
        } else if DiskImage.isDiskImage(url), let onAttachDiskImage {
            onAttachDiskImage(url)  // mount the image and navigate into it
        } else if Archiver.canExtract(url) {
            onBrowseArchive?(url)  // browse the archive as a folder (extract + enter)
        } else if let openFile {
            openFile(url)  // apply scoped opener rules
        } else {
            NSWorkspace.shared.open(url)  // system default
        }
    }

    /// Enter an extracted archive: navigate the pane into `mountRoot`, remembering the
    /// archive and the folder to return to when going up from the root.
    func mountArchive(archive: URL, mountRoot: URL, origin: URL) {
        archiveSession = ArchiveSession(
            archive: archive, mountRoot: mountRoot, origin: origin,
            snapshot: Archiver.snapshot(of: mountRoot))
        nav.go(to: mountRoot)
        enterDirectory()
        containerView.window?.makeFirstResponder(content.keyView)
    }

    /// End the current archive session and let the browser offer to write changes back.
    private func endArchiveSession() {
        guard let session = archiveSession else { return }
        archiveSession = nil
        onArchiveClosed?(session.archive, session.mountRoot, session.snapshot)
    }

    /// Resolve an entry to a URL: smart-result entries carry their own location;
    /// normal entries live in the current folder.
    private func urlFor(_ entry: FileEntry) -> URL {
        if let location = entry.location {
            return URL(fileURLWithPath: location).appendingPathComponent(entry.name)
        }
        // currentURL is the active column's folder in column view (and nav.current
        // for list/icon/gallery), so opening a file resolves to the right folder.
        return currentURL.appendingPathComponent(entry.name)
    }

    /// Select (and scroll to) a row by name, e.g. a just-created folder.
    func select(name: String) { content.select(name: name) }

    @objc func goBack() { guard remote == nil else { return }; if nav.goBack() { enterDirectory() } }
    @objc func goForward() { guard remote == nil else { return }; if nav.goForward() { enterDirectory() } }
    @objc func goUp() {
        if let remote {
            if remote.path == "/" || remote.path.isEmpty {
                closeRemote()  // at the remote root: return to the local folder
            } else {
                self.remote?.path = Self.parentRemote(remote.path)
                reloadRemote()
            }
            return
        }
        // Going up from an archive's root returns to the folder it lives in.
        if let session = archiveSession, nav.current.standardizedFileURL == session.mountRoot.standardizedFileURL {
            endArchiveSession()  // offer to write changes back
            nav.go(to: session.origin)
            enterDirectory()
            return
        }
        if nav.goUp() { enterDirectory() }
    }

    /// Move into nav.current: refresh the listing, watch the new folder for
    /// on-disk changes, and tell the browser the folder changed.
    private func enterDirectory() {
        smartActive = false  // entering a real folder leaves any smart-result view
        networkHostNames = []
        networkActive = false
        contentRequestToken += 1  // invalidate any pending async smart load
        smartEntries = []
        startWatching()  // arm before snapshotting, to narrow the listing/watch gap
        applyFolderBackground()  // show this folder's background (color/picture), if any
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
        ReloadDebug.log("fsevent folder=\(watched.lastPathComponent) active=\(isActivePane)")
        guard remote == nil, watched == nav.current else { return }  // ignore local changes while remote
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyDiskRefresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func applyDiskRefresh() {
        // Refresh the listing only if we're showing it (not search results),
        // but always tell the browser so it can rebuild the search index.
        if !showingSearchResults {
            // Don't blow away the whole tag cache here: reload's refreshTags already reads tags for
            // any newly-added files and reuses cached ones, so a copy streaming into a 100k folder
            // no longer re-issues 100k listxattr calls on every watcher tick. Pathem's own tag
            // edits invalidate explicitly (tagSelection/clearTags); an external Finder tag change
            // to an existing file reflects on the next navigation.
            reload()
        }
        onDirectoryDidChange?(nav.current)
    }

    private var isActivePane = false
    /// The active pane reads as raised: a soft drop shadow lifts it above its neighbor (drawn
    /// over the divider via zPosition) while the border stays a neutral hairline on both panes.
    /// Quieter than the old accent ring, and it reads in both light and dark themes.
    func setActive(_ active: Bool) {
        if active != isActivePane { ReloadDebug.log("setActive \(active) folder=\(nav.current.lastPathComponent)") }
        isActivePane = active
        guard let layer = containerView.layer else { return }
        layer.shadowColor = NSColor.shadowColor.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = 7
        layer.shadowOpacity = active ? 0.38 : 0
        layer.zPosition = active ? 1 : 0  // the raised pane's shadow falls on the flat one
        updateShadowPath()
    }

    /// Give the shadow an explicit rectangular path so Core Animation doesn't re-derive it from
    /// the pane's composited alpha on every content change, which taxed scrolling in the active
    /// pane. Refreshed on resize via the container's frame-change notification.
    private func updateShadowPath() {
        containerView.layer?.shadowPath = CGPath(rect: containerView.bounds, transform: nil)
    }

    @objc private func containerFrameChanged() { if isActivePane { updateShadowPath() } }

    @objc private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Build

    private func build() {
        containerView.wantsLayer = true
        containerView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(containerFrameChanged),
            name: NSView.frameDidChangeNotification, object: containerView)
        containerView.layer?.borderWidth = 1
        containerView.layer?.borderColor = NSColor.separatorColor.cgColor

        backButton = iconButton("chevron.backward", L("pane.back", "Back"), #selector(goBack))
        forwardButton = iconButton("chevron.forward", L("pane.forward", "Forward"), #selector(goForward))
        upButton = iconButton("chevron.up", L("pane.enclosingFolder", "Enclosing Folder"), #selector(goUp))
        buildViewSwitcher()
        buildSortButton()
        buildActionButton()

        breadcrumb.translatesAutoresizingMaskIntoConstraints = false
        breadcrumb.setContentHuggingPriority(.init(1), for: .horizontal)
        breadcrumb.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        breadcrumb.onNavigate = { [weak self] url in
            self?.nav.go(to: url)
            self?.enterDirectory()
        }
        breadcrumb.onClickBackground = { [weak self] in self?.beginEditingPath() }
        breadcrumb.onDropURLs = { [weak self] urls, folder, move in self?.onDropFiles?(urls, move, folder) }
        breadcrumb.onContextAction = { [weak self] folder, action in self?.onBreadcrumbAction?(folder, action) }

        addressField.placeholderString = L("pane.goToPathPlaceholder", "Go to path")
        addressField.font = .systemFont(ofSize: 12)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.isHidden = true  // shown only while editing (Cmd-L)
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(commitPath)
        addressField.setContentHuggingPriority(.init(1), for: .horizontal)
        addressField.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        remoteLabel.font = .systemFont(ofSize: 12)
        remoteLabel.lineBreakMode = .byTruncatingMiddle
        remoteLabel.isHidden = true
        remoteLabel.translatesAutoresizingMaskIntoConstraints = false
        remoteLabel.setContentHuggingPriority(.init(1), for: .horizontal)

        // The path-display group travels between the top toolbar and the bottom
        // strip as one unit.
        pathBar.orientation = .horizontal
        pathBar.spacing = 4
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.setContentHuggingPriority(.init(1), for: .horizontal)
        // A fixed-height row. NSStackView fills its cross-axis space rather than hugging it, so
        // without this the path bar stretches to fill whatever a content view yields (a gallery
        // yields a lot), which pushed the content down.
        pathBar.heightAnchor.constraint(equalToConstant: 26).isActive = true
        pathBar.addArrangedSubview(breadcrumb)
        pathBar.addArrangedSubview(addressField)
        pathBar.addArrangedSubview(remoteLabel)

        toolbarStack = NSStackView(views: [
            backButton, forwardButton, upButton, viewSwitcher, sortButton, actionButton,
        ])
        toolbarStack.orientation = .horizontal
        toolbarStack.spacing = 4
        toolbarStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        // Hug the buttons' height so this row (pinned at the top of the pane, with the file
        // list filling below it) stays its natural height instead of stretching to absorb the
        // pane's spare vertical space, which would squeeze the file list to nothing.
        toolbarStack.setHuggingPriority(.required, for: .vertical)
        toolbarStack.setClippingResistancePriority(.required, for: .vertical)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        hiddenToggle.isBordered = false
        hiddenToggle.imagePosition = .imageOnly
        hiddenToggle.setButtonType(.momentaryChange)
        hiddenToggle.target = self
        hiddenToggle.action = #selector(toggleHiddenFromStatus)
        hiddenToggle.translatesAutoresizingMaskIntoConstraints = false
        hiddenToggle.setContentHuggingPriority(.required, for: .horizontal)
        updateHiddenToggleIcon()

        filterField.placeholderString = L("pane.filterPlaceholder", "Filter (try ext:pdf, kind:image, size:>10mb)")
        filterField.controlSize = .small
        filterField.font = .systemFont(ofSize: 11)
        filterField.isHidden = true  // shown via the Filter command
        filterField.delegate = self
        filterField.sendsWholeSearchString = false
        filterField.sendsSearchStringImmediately = true
        filterField.translatesAutoresizingMaskIntoConstraints = false

        bottomStack.orientation = .vertical
        bottomStack.alignment = .leading
        bottomStack.spacing = 2
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        // Hug the status row's height so it doesn't stretch to absorb space the content view
        // yields (a gallery yields a lot); the content area should claim that space instead.
        bottomStack.setHuggingPriority(.required, for: .vertical)
        bottomStack.setContentHuggingPriority(.required, for: .vertical)
        // The status row: the item-count/size label on the left, the hidden-files eye on the right.
        let statusSpacer = NSView()
        statusSpacer.translatesAutoresizingMaskIntoConstraints = false
        statusSpacer.setContentHuggingPriority(.init(1), for: .horizontal)  // expands to push the eye right
        let statusRow = NSStackView(views: [statusLabel, statusSpacer, hiddenToggle])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .centerY
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        // Hug the row's own (small) height, or it stretches and squeezes the file list to nothing.
        statusRow.setHuggingPriority(.required, for: .vertical)
        statusRow.setContentHuggingPriority(.required, for: .vertical)
        statusRow.setClippingResistancePriority(.required, for: .vertical)
        bottomStack.addArrangedSubview(filterField)
        bottomStack.addArrangedSubview(statusRow)
        filterField.widthAnchor.constraint(equalTo: bottomStack.widthAnchor).isActive = true
        statusRow.widthAnchor.constraint(equalTo: bottomStack.widthAnchor).isActive = true

        containerView.addSubview(toolbarStack)
        containerView.addSubview(pathBar)
        containerView.addSubview(contentContainer)
        containerView.addSubview(bottomStack)

        permissionButton.bezelStyle = .rounded
        permissionButton.target = self
        permissionButton.action = #selector(openFullDiskAccess)
        permissionButton.isHidden = true
        permissionButton.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(permissionButton)
        NSLayoutConstraint.activate([
            permissionButton.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            // Below the centered placeholder text the content view draws.
            permissionButton.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor, constant: 40),
        ])
        NSLayoutConstraint.activate([
            toolbarStack.topAnchor.constraint(equalTo: containerView.topAnchor),
            toolbarStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            toolbarStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            bottomStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
            bottomStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
            bottomStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -5),
            // The location bar always spans the pane's full width on its own row.
            pathBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            pathBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
        ])
        setPathBar(atBottom: false)  // default: location bar directly under the buttons
        embedContent()
    }

    /// Position the full-width location bar below the buttons (top, Directory Opus
    /// style) or above the status line (bottom, Finder style).
    func setPathBar(atBottom: Bool) {
        NSLayoutConstraint.deactivate(pathBarPositionConstraints)
        if atBottom {
            pathBarPositionConstraints = [
                contentContainer.topAnchor.constraint(equalTo: toolbarStack.bottomAnchor),
                contentContainer.bottomAnchor.constraint(equalTo: pathBar.topAnchor, constant: -4),
                pathBar.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -4),
            ]
        } else {
            pathBarPositionConstraints = [
                pathBar.topAnchor.constraint(equalTo: toolbarStack.bottomAnchor, constant: 2),
                contentContainer.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: 2),
                contentContainer.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -4),
            ]
        }
        NSLayoutConstraint.activate(pathBarPositionConstraints)
    }

    /// The laid-out height of the file-list area (PATHEM_SMOKE). A near-zero value means
    /// the pane's chrome stretched and squeezed the list flat, which is the class of layout
    /// regression that renders panes blank.
    func debugContentHeight() -> CGFloat { contentContainer.frame.height }

    /// Put the active content's scroll view into the content container, replacing
    /// any previous one.
    /// A folder's background picture, drawn behind the content view (which goes clear) when the
    /// current folder has one set. Hidden otherwise.
    private let folderBackgroundView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()
    /// Supplies the background configured for a folder (set by the browser from its store).
    var backgroundFor: ((URL) -> FolderBackground?)?

    private func embedContent() {
        for sub in contentContainer.subviews { sub.removeFromSuperview() }
        paneViewer = nil  // any content swap detaches the document-viewer overlay; drop the stale ref
        // The background picture sits behind the content, which is made transparent to reveal it.
        contentContainer.addSubview(folderBackgroundView)
        let view = content.contentView
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)  // on top of the background
        NSLayoutConstraint.activate([
            folderBackgroundView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            folderBackgroundView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            folderBackgroundView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            folderBackgroundView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        applyFolderBackground()  // the new content view must pick up the current folder's background
    }

    /// Apply the current folder's background: a picture (content goes clear over it), a solid color,
    /// or neither (restore the default). Called on navigation and after a view-mode swap.
    func applyFolderBackground() {
        let background = backgroundFor?(nav.current)
        if let path = background?.imagePath, !path.isEmpty, let image = NSImage(contentsOfFile: path) {
            folderBackgroundView.image = image
            folderBackgroundView.isHidden = false
            content.setBackgroundColor(.clear)
        } else if let hex = background?.colorHex, !hex.isEmpty, let color = ThemeManager.color(fromHex: hex) {
            folderBackgroundView.image = nil
            folderBackgroundView.isHidden = true
            content.setBackgroundColor(color)
        } else {
            folderBackgroundView.image = nil
            folderBackgroundView.isHidden = true
            content.setBackgroundColor(nil)
        }
    }

    /// Swap the content view when the folder's view mode changes, carrying over
    /// the callbacks, style, selection, and keyboard focus.
    private func applyViewMode(_ mode: ViewFormat.ViewMode) {
        viewSwitcher.selectedSegment = segmentIndex(mode)  // keep the switcher in sync
        guard mode != currentMode else { return }
        ReloadDebug.log("viewmode-swap folder=\(nav.current.lastPathComponent) mode=\(mode)")
        // Capture before swapping: the new (empty) content can't report these.
        let hadFocus = content.keyView.window?.firstResponder === content.keyView
        pendingSelection = Set(content.selectedEntries.map(\.name))
        currentMode = mode
        switch mode {
        case .list: content = FileListController()
        case .icon: content = makeIconContent(gallery: false)
        case .gallery: content = GalleryController()
        case .column: content = ColumnBrowserController()
        case .tree: content = TreeOutlineController()
        }
        wireContent()
        embedContent()
        if let s = lastStyle {
            content.applyStyle(rowHeight: s.rowHeight, fontSize: s.fontSize, alternatingRows: s.alternating)
        }
        content.setCalculateFolderSizes(calculateFolderSizes)  // carry the option across the swap
        content.setClickBehavior(  // carry single-click / hover across the swap
            singleClick: clickBehavior.singleClick, underlineHover: clickBehavior.underlineHover)
        content.setCutPaths(cutPaths)  // carry cut-dimming across the swap
        content.setHiddenContextItems(lastHiddenContextItems)  // carry menu + color customization
        content.setContextMenuOrder(lastContextMenuOrder)
        content.setColorRules(lastColorRules)
        content.setMiddleClickOpensNewTab(lastMiddleClickNewTab)
        if let f = lastFormats { content.setFormats(size: f.size, date: f.date) }
        if hadFocus { content.keyView.window?.makeFirstResponder(content.keyView) }
    }

    /// Wire the active content's callbacks (run on creation and on every swap).
    private func wireContent() {
        content.onOpen = { [weak self] entry in self?.descend(into: entry) }
        content.onBecomeActive = { [weak self] in self?.onBecomeActive?() }
        content.setOpenInNewTabHandler { [weak self] url in self?.onOpenInNewTab?(url) }
        content.onSortChanged = { [weak self] key, ascending in
            guard let self else { return }
            self.format.sortKey = key
            self.format.ascending = ascending
            self.rememberFormat?(self.nav.current, self.format)
            self.reload()
        }
        content.onSelectionChanged = { [weak self] in
            self?.updateStatus()
            self?.onSelectionChanged?()
        }
        content.onDropFiles = { [weak self] urls, move, destination in
            guard let self else { return }
            if let remote = self.remote {  // dropping onto a remote pane uploads
                let path = destination.map { remote.path + "/" + $0.lastPathComponent } ?? remote.path
                self.onUploadFiles?(urls, remote.connection, path, remote.password)
            } else {
                self.onDropFiles?(urls, move, destination ?? self.nav.current)
            }
        }
        content.onDropOntoFile = { [weak self] dragged, target in
            guard let self, self.remote == nil else { return }  // local only
            self.onDropOntoFile?(dragged, target)
        }
        content.onKeyChord = onKeyChordHandler
        content.onMouseGesture = onMouseGestureHandler
        content.onDragSession = onDragSessionHandler
        content.onInlineRename = { [weak self] entry, newName in self?.onRenameRequested?(entry, newName) }
        content.dragMovesByDefault = dragMovesByDefault
    }

    /// Begin a Finder-style in-place rename in the active view; false if it can't (the browser then
    /// falls back to the rename sheet). The committed name arrives via `onRenameRequested`.
    func beginInlineRename() -> Bool { content.beginInlineRename() }

    /// Switch this folder's view mode (list / icon / gallery), persist it, and
    /// reload (which swaps the content view).
    /// Apply a whole saved view format (a Style): sort, hidden, folders-first, and view
    /// mode, then re-list and update the sort indicator.
    func applyFormat(_ style: ViewFormat) {
        format.sortKey = style.sortKey
        format.ascending = style.ascending
        format.showHidden = style.showHidden
        format.foldersFirst = style.foldersFirst
        setViewMode(style.viewMode)  // swaps the content controller when the mode changes
        reload()  // re-list with the new sort/hidden/folders-first
        content.showSortIndicator(key: style.sortKey, ascending: style.ascending)
    }

    func setViewMode(_ mode: ViewFormat.ViewMode) {
        guard mode != format.viewMode else { return }
        dismissViewer()  // the view switcher sits above the overlay; switching mode closes the viewer
        format.viewMode = mode
        if smartActive {
            // Re-apply in memory; don't persist a format rule onto the underlying
            // folder, and don't reload (there's no folder to read). Column mode needs
            // real folders to drill, so a smart result falls back to list.
            applyViewMode(mode == .column ? .list : mode)
            displayEntries(format.sorted(smartEntries), preserveState: false)
            pendingSelection = nil  // don't leak smart names into the next real listing
            return
        }
        // Changing the view while showing search results drops them (reload re-reads
        // the folder); clear the search field too so it doesn't lie about the listing.
        if showingSearchResults {
            searchQuery = ""
            onDidNavigate?()
        }
        rememberFormat?(nav.current, format)
        reload()
    }

    /// The mode actually on screen (not the persisted format), so the View menu and
    /// the toolbar switcher agree even when a remote/smart pane clamps Column to list.
    var viewMode: ViewFormat.ViewMode { currentMode }

    /// The list view's grouping key (for the Arrange By menu's checkmarks).
    var groupKey: ViewFormat.GroupKey { format.groupKey }
    /// Change the Arrange By grouping key, persist the folder's format, and reload.
    func setGroupKey(_ key: ViewFormat.GroupKey) {
        guard format.groupKey != key else { return }
        format.groupKey = key
        rememberFormat?(nav.current, format)
        reload()
    }

    /// Smoke hook: exercise grouped selection round-trip on the list view (no-op elsewhere).
    func debugGroupedSelectionRoundTrips() -> Bool {
        (content as? FileListController)?.debugGroupedSelectionRoundTrips() ?? true
    }

    func debugCollapseHidesItems() -> Bool {
        (content as? FileListController)?.debugCollapseHidesItems() ?? true
    }

    /// Update the bottom status line: item count, or the selection count and its
    /// total size when something is selected.
    /// Which fields the bottom status bar shows (item count, size, free space).
    var statusOptions: (itemCount: Bool, size: Bool, freeSpace: Bool) = (true, true, false) {
        didSet { if oldValue != statusOptions { updateStatus() } }
    }

    private func updateStatus() {
        let all = content.entries
        let selected = content.selectedEntries
        var parts: [String] = []
        if statusOptions.itemCount {
            if selected.isEmpty {
                parts.append(
                    all.count == 1
                        ? String(format: L("pane.itemCountSingular", "%d item"), all.count)
                        : String(format: L("pane.itemCountPlural", "%d items"), all.count))
            } else {
                parts.append(
                    String(format: L("pane.selectedOf", "%d of %d selected"), selected.count, all.count))
            }
        }
        if statusOptions.size {
            let subset = selected.isEmpty ? all : selected
            let size = subset.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
            if size > 0 { parts.append(byteFormatter.string(fromByteCount: size)) }
        }
        if statusOptions.freeSpace, let free = freeSpaceString() { parts.append(free) }
        var text = parts.joined(separator: " · ")
        // Note when hidden files are on view, so the mode is legible even in a folder with
        // no hidden files (where the dimmed-row cue alone wouldn't show it).
        if format.showHidden || showHiddenByDefault {
            text += (text.isEmpty ? "" : "   ") + L("pane.hiddenShown", "Hidden files shown")
        }
        if let gitSummary, remote == nil, !smartActive { text += "   \(gitSummary)" }
        statusLabel.stringValue = text
        updateHiddenToggleIcon()  // keep the eye in sync with the current folder's hidden state
    }

    private var flashToken = 0

    /// Briefly show a transient message in the status line -- a "Copied 3 paths" confirmation, or a
    /// soft failure reason -- then revert to the normal item-count status. This is the app's toast
    /// channel: it reuses the status label the user is already looking at (bottom of the active
    /// pane), so silent successes and beep-only failures finally say something, with no separate HUD.
    func flashStatus(_ message: String, isError: Bool = false) {
        flashToken += 1
        let token = flashToken
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .labelColor  // pop above the usual secondary status
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, self.flashToken == token else { return }  // a newer flash won: leave it
            self.statusLabel.textColor = .secondaryLabelColor
            self.updateStatus()
        }
    }

    /// PATHEM_SMOKE: the status-line text right now (to check a flash landed).
    func debugStatusText() -> String { statusLabel.stringValue }

    /// Free space on the current folder's volume, e.g. "42 GB free". Local folders only.
    private func freeSpaceString() -> String? {
        guard remote == nil, let url = content.directoryURL,
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let free = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return String(format: L("pane.freeSpace", "%@ free"), byteFormatter.string(fromByteCount: free))
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton()
        let config = NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(config)
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)  // image-only, so VoiceOver needs an explicit label
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Re-render the navigation icons at the current point size (toolbar-icon-size pref).
    private func applyIconSize() {
        let config = NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .regular)
        backButton.image = Self.symbol("chevron.backward").withSymbolConfiguration(config)
        forwardButton.image = Self.symbol("chevron.forward").withSymbolConfiguration(config)
        upButton.image = Self.symbol("chevron.up").withSymbolConfiguration(config)
    }

    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    // MARK: - View switcher + sort dropdown (Finder-style)

    private func segmentIndex(_ mode: ViewFormat.ViewMode) -> Int {
        switch mode {
        case .list: 0
        case .icon: 1
        case .gallery: 2
        case .column: 3
        case .tree: 4
        }
    }

    private func modeForSegment(_ index: Int) -> ViewFormat.ViewMode {
        switch index {
        case 1: .icon
        case 2: .gallery
        case 3: .column
        case 4: .tree
        default: .list
        }
    }

    private func buildViewSwitcher() {
        let segments: [(String, String)] = [
            ("list.bullet", L("pane.viewAsList", "as List")),
            ("square.grid.2x2", L("pane.viewAsIcons", "as Icons")),
            ("square.grid.3x1.below.line.grid.1x2", L("pane.viewAsGallery", "as Gallery")),
            ("rectangle.split.3x1", L("pane.viewAsColumns", "as Columns")),
            ("list.bullet.indent", L("pane.viewAsTree", "as Tree")),
        ]
        viewSwitcher = NSSegmentedControl(
            images: segments.map { Self.symbol($0.0) }, trackingMode: .selectOne,
            target: self, action: #selector(viewSwitcherChanged))
        for (index, segment) in segments.enumerated() {
            viewSwitcher.setToolTip(segment.1, forSegment: index)
        }
        viewSwitcher.setAccessibilityLabel(L("pane.viewAs", "View As"))
        viewSwitcher.segmentStyle = .texturedRounded
        viewSwitcher.selectedSegment = segmentIndex(format.viewMode)
        viewSwitcher.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func viewSwitcherChanged() {
        guard viewSwitcher.selectedSegment >= 0 else { return }
        onBecomeActive?()  // act on this pane, like the action menu
        setViewMode(modeForSegment(viewSwitcher.selectedSegment))
    }

    private func buildSortButton() {
        sortButton.bezelStyle = .texturedRounded
        sortButton.imagePosition = .imageOnly
        sortButton.translatesAutoresizingMaskIntoConstraints = false
        let menu = NSMenu()
        menu.delegate = self
        sortButton.menu = menu
        rebuildSortMenu(menu)
        sortButton.toolTip = L("pane.sortTooltip", "Sort")
        sortButton.setAccessibilityLabel(L("pane.sortTooltip", "Sort"))
    }

    /// Rebuild a pull-down menu each time it opens (fresh checkmarks; the action
    /// menu first makes this pane active so its items target the right pane).
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === sortButton.menu {
            onBecomeActive?()  // sort applies to this pane
            rebuildSortMenu(menu)
        } else if menu === actionButton.menu {
            onBecomeActive?()
            rebuildActionMenu(menu)
        }
    }

    private func buildActionButton() {
        actionButton.bezelStyle = .texturedRounded
        actionButton.imagePosition = .imageOnly
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        let menu = NSMenu()
        menu.delegate = self
        actionButton.menu = menu
        rebuildActionMenu(menu)
        actionButton.toolTip = L("pane.actionsTooltip", "Actions")
        actionButton.setAccessibilityLabel(L("pane.actionsTooltip", "Actions"))
    }

    /// A submenu of apps that can open the single selected file, plus "Other…".
    private func makeOpenWithSubmenu() -> NSMenu? {
        guard !isRemote, selectedEntries.count == 1, let entry = selectedEntries.first, !entry.isDirectory
        else { return nil }
        let url = urlFor(entry)
        let submenu = NSMenu()
        for appURL in NSWorkspace.shared.urlsForApplications(toOpen: url).prefix(15) {
            let item = NSMenuItem(
                title: FileManager.default.displayName(atPath: appURL.path),
                action: #selector(openWithApp(_:)), keyEquivalent: "")
            item.target = self
            // Copy before resizing: icon(forFile:) returns a shared cached NSImage, and
            // mutating its size in place shrinks that app's icon elsewhere in the UI.
            let icon = (NSWorkspace.shared.icon(forFile: appURL.path).copy() as? NSImage)
                ?? NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.representedObject = [url, appURL]
            submenu.addItem(item)
        }
        if submenu.items.count > 0 { submenu.addItem(.separator()) }
        let other = NSMenuItem(
            title: L("pane.openWithOther", "Other…"), action: #selector(openWithOther), keyEquivalent: "")
        other.target = self
        other.representedObject = url
        submenu.addItem(other)
        return submenu
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [URL], pair.count == 2 else { return }
        NSWorkspace.shared.open([pair[0]], withApplicationAt: pair[1], configuration: .init(), completionHandler: nil)
    }

    @objc private func openWithOther(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? URL else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.begin { response in
            guard response == .OK, let app = panel.url else { return }
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: .init(), completionHandler: nil)
        }
    }

    private func rebuildActionMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let face = NSMenuItem()  // pull-down face (item 0 isn't selectable)
        face.image = Self.symbol("ellipsis.circle")
        menu.addItem(face)
        func add(_ label: String, command id: String) {
            let item = NSMenuItem(title: label, action: #selector(runActionCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
        add(L("pane.newFolder", "New Folder"), command: "files.newFolder")
        add(L("bvc.cmd.newFile", "New File"), command: "files.newFile")
        add(L("pane.getInfo", "Get Info"), command: "files.getInfo")
        add("Quick Look", command: "view.quickLook")
        if let openWith = makeOpenWithSubmenu() {
            let item = NSMenuItem(title: L("pane.openWith", "Open With"), action: nil, keyEquivalent: "")
            item.submenu = openWith
            menu.addItem(item)
        }
        add(L("pane.rename", "Rename…"), command: "files.rename")
        add(L("bvc.cmd.duplicate", "Duplicate"), command: "files.duplicate")
        menu.addItem(.separator())
        add(L("pane.revealInFinder", "Reveal in Finder"), command: "files.reveal")
        add(L("pane.revealInPathem", "Reveal in Pathem"), command: "files.revealInPathem")
        let share = NSMenuItem(title: L("pane.share", "Share…"), action: #selector(shareSelection), keyEquivalent: "")
        share.target = self
        menu.addItem(share)
        let airdrop = NSMenuItem(
            title: L("pane.sendViaAirDrop", "Send via AirDrop"), action: #selector(airDropSelection),
            keyEquivalent: "")
        airdrop.target = self
        menu.addItem(airdrop)
        let tagsItem = NSMenuItem(title: L("pane.tags", "Tags"), action: nil, keyEquivalent: "")
        tagsItem.submenu = makeTagsSubmenu()
        menu.addItem(tagsItem)
        if isRemote {
            add(L("pane.downloadFromServer", "Download from Server…"), command: "remote.download")
        }
        menu.addItem(.separator())
        add(L("pane.moveToTrash", "Move to Trash"), command: "files.trash")
    }

    @objc private func runActionCommand(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { runCommand?(id) }
    }

    /// A submenu of the seven Finder colors (checkmarked if the first selected
    /// item has them) plus Clear Tags.
    private func makeTagsSubmenu() -> NSMenu {
        let menu = NSMenu()
        let current: Set<FileTag.Color> = {
            guard remote == nil, !smartActive, let first = content.selectedEntries.first else { return [] }
            let url = currentURL.appendingPathComponent(first.name)  // active column folder in column view
            return Set(FileTags.tags(of: url).map(\.color))
        }()
        for color in FileTag.Color.displayOrder {
            let item = NSMenuItem(title: color.label, action: #selector(tagMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color.rawValue
            item.image = TagColors.dot(color)
            item.state = current.contains(color) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L("pane.clearTags", "Clear Tags"), action: #selector(clearTags), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        return menu
    }

    @objc private func tagMenuItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let color = FileTag.Color(rawValue: raw) else { return }
        tagSelection(toggle: color)
    }

    /// Toggle a color tag across the selection (local only). The decision is made
    /// once for the whole selection: if every file already has the color, remove
    /// it from all; otherwise add it to all (so a mixed selection becomes uniform).
    func tagSelection(toggle color: FileTag.Color) {
        guard remote == nil, !smartActive else {
            NSSound.beep()  // remote / cross-folder smart results don't resolve to one folder
            return
        }
        let urls = selectedLocalURLs()  // active column's folder in column view, else nav.current
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let allHave = urls.allSatisfy { FileTags.tags(of: $0).contains { $0.color == color } }
        var failures = 0
        for url in urls {
            do {
                var tags = FileTags.tags(of: url)
                if allHave {
                    tags.removeAll { $0.color == color }
                } else if !tags.contains(where: { $0.color == color }) {
                    tags.append(FileTag(color: color))
                } else {
                    continue
                }
                try FileTags.setTags(tags, on: url)
            } catch {
                failures += 1
            }
        }
        if failures > 0 { presentTagWriteFailure(failures) }
        content.invalidateTagCache()
        reload()
    }

    /// Toggle a named label (a colored tag) across the selection (local only).
    func applyLabel(_ label: FileLabel) {
        guard remote == nil, !smartActive else {
            NSSound.beep()
            return
        }
        let urls = selectedLocalURLs()
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let allHave = urls.allSatisfy {
            FileTags.tags(of: $0).contains { $0.name.caseInsensitiveCompare(label.name) == .orderedSame }
        }
        var failures = 0
        for url in urls {
            do {
                if allHave {
                    var tags = FileTags.tags(of: url)
                    tags.removeAll { $0.name.caseInsensitiveCompare(label.name) == .orderedSame }
                    try FileTags.setTags(tags, on: url)
                } else if !FileTags.tags(of: url).contains(where: {
                    $0.name.caseInsensitiveCompare(label.name) == .orderedSame
                }) {
                    _ = try FileTags.toggle(label.tag, on: url)
                }
            } catch {
                failures += 1
            }
        }
        if failures > 0 { presentTagWriteFailure(failures) }
        content.invalidateTagCache()
        reload()
    }

    @objc private func clearTags() { clearSelectionTags() }

    /// Remove all tags from every selected file (local only).
    func clearSelectionTags() {
        guard remote == nil, !smartActive else {
            NSSound.beep()
            return
        }
        let urls = selectedLocalURLs()  // active column's folder in column view, else nav.current
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        var failures = 0
        for url in urls {
            do { try FileTags.setTags([], on: url) } catch { failures += 1 }
        }
        if failures > 0 { presentTagWriteFailure(failures) }
        content.invalidateTagCache()
        reload()
    }

    /// Local URLs of the current selection, each resolved against its real folder:
    /// the entry's own location for cross-folder smart results, the active column in
    /// column view, else the current folder.
    func selectedLocalURLs() -> [URL] {
        content.selectedEntries.map(urlFor)
    }

    /// Copy-able path strings for the current selection: server-side paths on a remote pane,
    /// otherwise local filesystem paths (location-aware, so smart-results resolve correctly).
    func selectedPathStrings() -> [String] {
        if let remote {
            return content.selectedEntries.map { Self.joinRemote(remote.path, $0.name) }
        }
        return selectedLocalURLs().map(\.path)
    }

    /// The macOS share sheet for the selection (Finder's Share). Anchored to the pane's action
    /// button. Internal so the context menu / command registry can reach it, not just that button.
    @objc func shareSelection() {
        onBecomeActive?()
        guard remote == nil else {
            NSSound.beep()  // remote files aren't local URLs to share
            return
        }
        let urls = selectedLocalURLs()  // location-aware, so smart results share correctly
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: actionButton.bounds, of: actionButton, preferredEdge: .minY)
    }

    /// Send the selection straight to the AirDrop sheet (a shortcut past the full
    /// share picker). Local files only; macOS has no public API to receive/browse.
    @objc func airDropSelection() {
        onBecomeActive?()
        guard remote == nil else {  // remote files aren't local URLs; smart results resolve by location
            NSSound.beep()
            return
        }
        let urls = selectedLocalURLs()
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else {
            NSSound.beep()
            return
        }
        service.perform(withItems: urls)
    }

    private func rebuildSortMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem()  // pull-down face (item 0 isn't selectable)
        title.image = Self.symbol("arrow.up.arrow.down")
        menu.addItem(title)
        func addKey(_ label: String, _ key: ViewFormat.SortKey) {
            let item = NSMenuItem(title: label, action: #selector(sortByKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = format.sortKey == key ? .on : .off
            menu.addItem(item)
        }
        addKey(L("pane.sortName", "Name"), .name)
        addKey(L("pane.sortSize", "Size"), .size)
        addKey(L("pane.sortDateModified", "Date Modified"), .date)
        menu.addItem(.separator())
        let ascending = NSMenuItem(
            title: L("pane.sortAscending", "Ascending"), action: #selector(sortAscending), keyEquivalent: "")
        ascending.target = self
        ascending.state = format.ascending ? .on : .off
        menu.addItem(ascending)
        let descending = NSMenuItem(
            title: L("pane.sortDescending", "Descending"), action: #selector(sortDescending), keyEquivalent: "")
        descending.target = self
        descending.state = format.ascending ? .off : .on
        menu.addItem(descending)
    }

    @objc private func sortByKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = ViewFormat.SortKey(rawValue: raw)
        else { return }
        applySort(key: key, ascending: format.ascending)
    }

    @objc private func sortAscending() { applySort(key: format.sortKey, ascending: true) }
    @objc private func sortDescending() { applySort(key: format.sortKey, ascending: false) }

    private func applySort(key: ViewFormat.SortKey, ascending: Bool) {
        format.sortKey = key
        format.ascending = ascending
        if smartActive {
            // Re-sort the held results in memory; don't persist onto the folder.
            displayEntries(format.sorted(smartEntries), preserveState: true)
            content.showSortIndicator(key: key, ascending: ascending)
            return
        }
        rememberFormat?(nav.current, format)
        if remote != nil { reloadRemote() } else { reload() }
        content.showSortIndicator(key: key, ascending: ascending)
    }


    func toggleHidden() {
        format.showHidden.toggle()
        rememberFormat?(nav.current, format)
        reload()
    }

    @objc private func toggleHiddenFromStatus() {
        toggleHidden()  // toggles the per-folder view, remembers it, reloads
        updateHiddenToggleIcon()
    }

    /// Sync the status-row eye to whether hidden files are currently shown.
    private func updateHiddenToggleIcon() {
        let symbol = hiddenShown ? "eye" : "eye.slash"
        hiddenToggle.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: L("pane.showHidden", "Show Hidden Files"))
        hiddenToggle.contentTintColor = hiddenShown ? ThemeManager.shared.accent : .tertiaryLabelColor
        hiddenToggle.toolTip =
            hiddenShown ? L("pane.hideHidden", "Hide Hidden Files") : L("pane.showHidden", "Show Hidden Files")
    }

    /// Open the current selection: descend into a folder (files are a no-op for
    /// now). Used by the "files.open" command.
    func openSelection() {
        let selected = selectedEntries
        // A single item navigates (folder) or opens (file); several items open
        // each file (folders can't all be navigated to in one pane).
        if selected.count == 1 {
            descend(into: selected[0])
            return
        }
        for entry in selected {
            // Open files and app/document packages; skip plain folders (can't navigate
            // several at once in one pane).
            let isPackage = (try? urlFor(entry).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
            if !entry.isDirectory || isPackage { descend(into: entry) }
        }
    }

    /// Jump to an arbitrary folder (used when restoring a layout).
    func navigate(to url: URL) {
        dismissViewer()  // browsing away closes any open document viewer
        nav.go(to: url.standardizedFileURL)
        enterDirectory()
    }

    /// Show `url` in a full-pane document viewer (PDF/image), overlaying this pane's browser until
    /// dismissed. Used by "Open in Other Pane" so the dual-pane becomes files-plus-document.
    func presentViewer(_ url: URL) {
        dismissViewer()
        let overlay = PaneDocumentViewer()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onDone = { [weak self] in self?.dismissViewer() }
        contentContainer.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        overlay.show(url)
        paneViewer = overlay
        containerView.window?.makeFirstResponder(overlay)
    }

    /// Close the document viewer overlay if one is open and hand focus back to the file list. Offers
    /// to save unsaved markup first, so browsing away / switching view mode / opening another file
    /// doesn't silently drop annotations. (The Done button already offered; that clears the edited
    /// flag, so this doesn't prompt twice.)
    func dismissViewer() {
        guard let paneViewer else { return }
        paneViewer.prepareToClose()
        paneViewer.removeFromSuperview()
        self.paneViewer = nil
        containerView.window?.makeFirstResponder(content.keyView)
    }

    /// Whether the document viewer overlay is currently showing (for the smoke check).
    var isShowingViewer: Bool { paneViewer != nil }

    /// Present `url` with the markup toolbar on and a tool armed, for the marquee shot.
    func debugPresentMarkup(_ url: URL) {
        presentViewer(url)
        paneViewer?.debugEnableMarkup()
    }

    /// In-app "reveal": navigate to `url`'s enclosing folder and select `url` there. The
    /// pendingSelection is applied by reload() once the (off-main) enumeration completes,
    /// so the file ends up selected and scrolled into view in the fresh folder. Useful from
    /// search and smart-result views, where the file lives outside the folder on screen.
    func reveal(_ url: URL) {
        pendingSelection = [url.lastPathComponent]
        navigate(to: url.deletingLastPathComponent())
    }

    /// Navigate without recording history (clears back/forward). Used by demo-mode
    /// toggling so a throwaway temp path never lingers in the pane's Back stack.
    func resetHistory(to url: URL) {
        nav.reset(to: url.standardizedFileURL)
        enterDirectory()
    }

    // MARK: - Editable address bar (paste a path)

    /// Swap the breadcrumb for an editable field pre-filled with the current path,
    /// selected, so you can type or paste a new path and press Return.
    func beginEditingPath() {
        guard remote == nil else { NSSound.beep(); return }  // remote path editing is a later step
        addressField.stringValue = nav.current.path
        breadcrumb.isHidden = true
        addressField.isHidden = false
        containerView.window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    private func endEditingPath() {
        addressField.isHidden = true
        breadcrumb.isHidden = false
    }

    @objc private func commitPath() {
        let raw = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        endEditingPath()
        containerView.window?.makeFirstResponder(content.keyView)  // restore focus on every path
        guard !raw.isEmpty else { return }
        guard remote == nil else { NSSound.beep(); return }  // path entry is local-only for now

        // Cheap existence check on the main thread (no fuzzy scan): navigate at once
        // if it's a real path (absolute, or relative to this folder).
        let base = nav.current
        let located = PathSuggester.locate(raw, base: base)
        if let existing = located.existing {
            goToResolved(existing)
            return
        }
        // A miss: the fuzzy/semantic "did you mean" (and a possible model load) is
        // heavier, so run it off the main thread, then re-validate the pane hasn't
        // navigated, gone remote, or closed before acting on the suggestion.
        let requested = located.requested
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let suggestion = PathSuggester.suggest(for: requested, embedder: NLEmbedder.shared)
            DispatchQueue.main.async {
                guard let self, self.containerView.window != nil, self.remote == nil,
                    self.nav.current == base
                else { return }
                if let suggestion {
                    self.offerSuggestion(suggestion, for: raw, base: base)
                } else {
                    NSSound.beep()  // no such path, nothing close
                }
            }
        }
    }

    /// Navigate to a resolved path: a folder opens, a file opens its folder and
    /// selects it. Skips a no-op re-navigation to the current folder.
    private func goToResolved(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            NSSound.beep()
            return
        }
        if isDirectory.boolValue {
            guard url != nav.current else { return }
            nav.go(to: url)
            enterDirectory()
        } else {
            nav.go(to: url.deletingLastPathComponent())
            enterDirectory()
            content.select(name: url.lastPathComponent)
        }
    }

    /// Report that some tag writes didn't stick, instead of failing with only a beep. The
    /// usual causes are a read-only volume or a missing Full Disk Access grant.
    private func presentTagWriteFailure(_ count: Int) {
        guard let window = containerView.window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = L("pane.tagFailedTitle", "Couldn’t change tags")
        alert.informativeText = String(
            format: L("pane.tagFailedBody", "%d item(s) couldn’t be updated. They may be on a read-only volume, or Pathem may need Full Disk Access."),
            count)
        alert.addButton(withTitle: L("common.ok", "OK"))
        alert.beginSheetModal(for: window) { _ in }
    }

    /// Offer a "did you mean" correction for a path that doesn't exist.
    private func offerSuggestion(_ suggestion: URL, for raw: String, base: URL) {
        // Need a window, and don't stack a second sheet on one already up.
        guard let window = containerView.window, window.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = L("pane.noSuchPathTitle", "No such path")
        alert.informativeText = String(
            format: L("pane.noSuchPathBody", "“%@” doesn't exist.\n\nDid you mean:\n%@"), raw, suggestion.path)
        alert.addButton(withTitle: L("pane.goButton", "Go"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            // The sheet is async too: re-validate before navigating.
            guard let self, response == .alertFirstButtonReturn, self.remote == nil,
                self.nav.current == base
            else { return }
            self.goToResolved(suggestion)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as AnyObject === filterField { setFilter(filterField.stringValue) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicked away from the address bar without committing: restore the breadcrumb.
        if obj.object as AnyObject === addressField, !addressField.isHidden { endEditingPath() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }  // Esc
        if control === filterField {
            endFilter()
        } else {
            endEditingPath()
            containerView.window?.makeFirstResponder(content.keyView)
        }
        return true
    }
}
