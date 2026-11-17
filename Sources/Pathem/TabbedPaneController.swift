import AppKit
import PathemEngine

/// The pasteboard payload for a dragged tab: which side it came from and its index there. A tab
/// drag never carries file URLs, so a tab can't be dropped into a file list (or vice versa).
enum TabDrag {
    static let type = NSPasteboard.PasteboardType("com.scarcrux.pathem.tab")

    static func item(side: String, index: Int) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setPropertyList(["side": side, "index": index], forType: type)
        return item
    }

    static func payload(_ pasteboard: NSPasteboard) -> (side: String, index: Int)? {
        guard let plist = pasteboard.propertyList(forType: type) as? [String: Any],
            let side = plist["side"] as? String, let index = plist["index"] as? Int
        else { return nil }
        return (side, index)
    }
}

/// One side of the browser as a stack of tabs. Each tab is a full PaneController
/// (its own folder, history, listing, watcher, status), so the per-folder logic
/// is reused unchanged; this controller only owns the tab bar and swaps the
/// active tab's view into the content area. Background tabs keep watching their
/// folders, like browser tabs. Tabs can be dragged: reordered here, moved to the
/// other side, or torn off into their own window.
@MainActor
final class TabbedPaneController: NSObject {
    let containerView = NSView()
    private let tabBar = TabBarStack()
    private let content = NSView()
    private let plusButton = NSButton()
    /// A thin vertical line showing where a dragged tab would land.
    private let dropIndicator = NSView()

    private let start: URL
    private(set) var tabs: [PaneController] = []
    private(set) var activeIndex = 0

    #if DEBUG
    struct ActivationReceipt {
        let sourceIndex: Int
        let previousIndex: Int
        let sourceDisplayed: Bool
    }
    private(set) var debugActivationReceipts: [ActivationReceipt] = []
    #endif

    /// Identifies this side on a tab drag's pasteboard, so a drop can tell "same side" (reorder)
    /// from "other side" (move across) and find the tab's origin.
    let sideID = UUID().uuidString
    /// Resolve a side by its id. The browser owns both sides and wires this.
    var sideForID: ((String) -> TabbedPaneController?)?
    /// A tab was dragged out of every tab bar: tear it off into its own window.
    var onTearOffTab: ((URL) -> Void)?
    /// "Move to Other Pane" on a tab: the browser knows which side is the other one.
    var onMoveTabToOtherSide: ((Int) -> Void)?

    /// Wire a freshly created pane (keymap dispatch, format resolution). Set by
    /// the browser and applied to every tab, existing and new.
    var configurePane: ((PaneController) -> Void)?
    /// A tab here became first responder (this side is now active).
    var onPaneBecameActive: ((PaneController) -> Void)?
    /// A tab's folder changed (navigation or on-disk); the browser rebuilds the
    /// search cache, and the tab title is refreshed here first.
    var onPaneDirectoryDidChange: ((PaneController, URL) -> Void)?
    /// A tab navigated (user moved folders), so the browser can clear the search.
    var onPaneDidNavigate: ((PaneController) -> Void)?
    /// Files were dropped on a tab; the browser copies/moves them into its folder.
    var onPaneDropFiles: ((_ urls: [URL], _ move: Bool, _ destination: URL) -> Void)?
    var onPaneDropOntoFile: ((_ dragged: [URL], _ target: URL) -> Void)?

    var activePane: PaneController? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }
    var tabCount: Int { tabs.count }

    init(start: URL) {
        self.start = start
        super.init()
        build()
        ThemeManager.shared.onChange(owner: self) { [weak self] in self?.refreshTabBar() }
    }

    private func build() {
        tabBar.orientation = .horizontal
        tabBar.spacing = 4
        tabBar.alignment = .centerY
        tabBar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        // Hug the chips' height: without this the stack (pinned top, with content filling
        // below it) wins the pane's spare vertical space and stretches tall, floating its
        // centerY chips mid-pane and squeezing the file list to nothing.
        tabBar.setHuggingPriority(.required, for: .vertical)
        tabBar.setClippingResistancePriority(.required, for: .vertical)

        plusButton.image = NSImage(
            systemSymbolName: "plus", accessibilityDescription: L("tabs.newTab", "New Tab"))
        plusButton.toolTip = L("tabs.newTab", "New Tab")  // icon-only: name on hover like every other control
        plusButton.bezelStyle = .texturedRounded
        plusButton.setButtonType(.momentaryPushIn)
        plusButton.imagePosition = .imageOnly
        plusButton.target = self
        plusButton.action = #selector(addTabClicked)

        content.translatesAutoresizingMaskIntoConstraints = false

        // The tab bar accepts dropped tabs (reorder here, or move one across from the other side).
        // Only the bar registers the type -- the chips don't -- so a drop over a chip resolves to
        // the bar, which is what lets us compute an insertion point from the cursor's x.
        tabBar.registerForDraggedTypes([TabDrag.type])
        tabBar.insertionIndexAt = { [weak self] point in self?.insertionIndex(at: point) ?? 0 }
        tabBar.showInsertion = { [weak self] index in self?.showDropIndicator(at: index) }
        tabBar.dropTab = { [weak self] side, index, insertAt in
            self?.handleTabDrop(side: side, index: index, insertAt: insertAt) ?? false
        }

        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = ThemeManager.shared.accent.cgColor
        dropIndicator.isHidden = true

        containerView.addSubview(tabBar)
        containerView.addSubview(content)
        containerView.addSubview(dropIndicator)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: containerView.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
    }

    /// Create the first tab. Call after the browser has set configurePane and the
    /// callbacks, so the initial pane is fully wired.
    func openInitialTab() {
        if tabs.isEmpty { newTab(at: start, focus: false) }
    }

    /// Each tab's root folder path, and the active tab index, for session capture
    /// (rootURL, not currentURL, so a column-view drill-down isn't what gets saved).
    var tabFolders: [String] { tabs.map { $0.rootURL.path } }
    var activeTabIndex: Int { activeIndex }

    /// Open tabs at the given folders (skipping ones that no longer exist), replacing any
    /// current tabs. Falls back to the start folder if none are valid. Used for session
    /// restore (from empty) and for switching to a saved workspace (replacing a layout).
    /// Tear down every tab (stopping its DirectoryWatcher) and drop them. Called when the window
    /// closes so a closed window doesn't leak a self-retained FSEvents watcher per pane.
    func teardownAllTabs() {
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
    }

    func restoreTabs(_ folders: [String], active: Int) {
        let fm = FileManager.default
        // Tear down any existing tabs so this replaces the layout rather than appending.
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
        activeIndex = 0
        // Keep original indices so the saved active index maps correctly even when
        // some folders were dropped (deleted on disk).
        let survivors = folders.enumerated().filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0.element, isDirectory: &isDir) && isDir.boolValue
        }
        guard !survivors.isEmpty else {
            openInitialTab()
            showActivePane()
            refreshTabBar()
            return
        }
        for survivor in survivors {
            newTab(at: URL(fileURLWithPath: survivor.element), focus: false)
        }
        // Map the saved active index (an original offset) to the surviving tab at
        // or after it, falling back to the last tab.
        let mapped = survivors.firstIndex(where: { $0.offset >= active }) ?? (survivors.count - 1)
        activeIndex = min(max(mapped, 0), tabs.count - 1)
        showActivePane()
        refreshTabBar()
    }

    /// Resolves where a fresh tab opens (the "New tab opens to" preference): nil means the
    /// current folder (browser-style), a URL means Home or a fixed folder.
    var newTabLocation: (() -> URL?)?
    /// New tabs go at the end of the bar (true, the default) or right after the current tab.
    var newTabAtEnd = true

    /// Open a new tab. `duplicatingCurrent` opens it at the active tab's folder
    /// (browser-style) or the user's preferred location; otherwise at this side's start folder.
    func newTab(duplicatingCurrent: Bool) {
        let preferred = duplicatingCurrent ? newTabLocation?() : nil
        let url = preferred ?? (duplicatingCurrent ? activePane?.currentURL : nil) ?? start
        newTab(at: url, focus: true)
    }

    /// Open `url` in a new, focused tab (used by "Open in New Tab" on a folder).
    func openTab(at url: URL) { newTab(at: url, focus: true) }

    @discardableResult
    private func newTab(at url: URL, focus: Bool) -> PaneController {
        let pane = PaneController(start: url)
        configurePane?(pane)
        pane.onBecomeActive = { [weak self, weak pane] in
            guard let self, let pane, let index = self.tabs.firstIndex(where: { $0 === pane })
            else { return }
            #if DEBUG
            self.debugActivationReceipts.append(
                .init(
                    sourceIndex: index, previousIndex: self.activeIndex,
                    sourceDisplayed: pane.containerView.superview === self.content))
            #endif
            // Background Column refreshes emit activation while restoring selection.
            // Ownership follows the displayed tab, not a hidden pane's callback.
            guard pane.containerView.superview === self.content else { return }
            self.activeIndex = index
            self.refreshTabBar()
            self.onPaneBecameActive?(pane)
        }
        pane.onDirectoryDidChange = { [weak self, weak pane] changed in
            guard let self, let pane else { return }
            self.refreshTabBar()
            self.onPaneDirectoryDidChange?(pane, changed)
        }
        pane.onDidNavigate = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.refreshTabBar()  // a smart listing (Network, search results) retitles the tab
            self.onPaneDidNavigate?(pane)
        }
        pane.onDropFiles = { [weak self] urls, move, destination in
            self?.onPaneDropFiles?(urls, move, destination)
        }
        pane.onDropOntoFile = { [weak self] dragged, target in
            self?.onPaneDropOntoFile?(dragged, target)
        }
        // Insert at the end, or right after the current tab (browser-style) when configured.
        if newTabAtEnd || tabs.isEmpty {
            tabs.append(pane)
            activeIndex = tabs.count - 1
        } else {
            let at = min(activeIndex + 1, tabs.count)
            tabs.insert(pane, at: at)
            activeIndex = at
        }
        showActivePane()
        pane.refresh()  // apply formats + fire onDirectoryDidChange now that it is wired
        refreshTabBar()
        if focus { focusActivePane() }
        return pane
    }

    // MARK: - Tab dragging (reorder here, move across, tear off)

    private var chipViews: [TabChipView] {
        tabBar.arrangedSubviews.compactMap { $0 as? TabChipView }
    }

    /// Where a tab dropped at `point` (in tab-bar coordinates) would be inserted: after every chip
    /// whose midpoint the cursor is past.
    private func insertionIndex(at point: NSPoint) -> Int {
        var index = 0
        for (i, chip) in chipViews.enumerated() where point.x > chip.frame.midX { index = i + 1 }
        return index
    }

    /// Show (or hide, with nil) the line marking where a dragged tab would land.
    private func showDropIndicator(at index: Int?) {
        guard let index else {
            dropIndicator.isHidden = true
            return
        }
        let chips = chipViews
        let x: CGFloat =
            chips.isEmpty
            ? tabBar.frame.minX + 6
            : (index >= chips.count
                ? tabBar.convert(chips[chips.count - 1].frame, to: containerView).maxX + 2
                : tabBar.convert(chips[index].frame, to: containerView).minX - 2)
        dropIndicator.layer?.backgroundColor = ThemeManager.shared.accent.cgColor
        dropIndicator.frame = NSRect(
            x: x, y: tabBar.frame.minY + 3, width: 2, height: max(0, tabBar.frame.height - 6))
        dropIndicator.isHidden = false
    }

    /// Reorder within this side, keeping whichever tab was active still active.
    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from) else { return }
        let wasActive = activePane
        let pane = tabs.remove(at: from)
        let destination = min(max(from < to ? to - 1 : to, 0), tabs.count)
        tabs.insert(pane, at: destination)
        activeIndex = wasActive.flatMap { a in tabs.firstIndex(where: { $0 === a }) } ?? destination
        showActivePane()
        refreshTabBar()
    }

    /// This tab's folder, closing the tab if this side has others. The last tab is never closed --
    /// same rule as Move Tab to New Window -- so a side is never left with nothing in it.
    func takeTab(at index: Int) -> URL? {
        guard tabs.indices.contains(index) else { return nil }
        let url = tabs[index].currentURL
        if tabs.count > 1 { closeTab(at: index) }
        return url
    }

    /// Open `url` as a tab here, positioned at `index`.
    func adoptTab(url: URL, at index: Int) {
        let pane = newTab(at: url, focus: true)
        guard let landed = tabs.firstIndex(where: { $0 === pane }) else { return }
        moveTab(from: landed, to: index)
    }

    /// A tab was dropped on this side's bar: reorder it (same side) or move it across (other side).
    private func handleTabDrop(side: String, index: Int, insertAt: Int) -> Bool {
        guard let source = sideForID?(side) else { return false }
        if source === self {
            moveTab(from: index, to: insertAt)
        } else {
            guard let url = source.takeTab(at: index) else { return false }
            adoptTab(url: url, at: insertAt)
        }
        return true
    }

    func closeActiveTab() { closeTab(at: activeIndex) }

    private func closeTab(at index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        guard tabs[index].prepareViewerToClose() else { return }  // unsaved markup: cancelled
        // Only pull focus to this side if it already had it (or we're closing the
        // active tab), so clicking the X on a background side's tab doesn't steal it.
        let hadFocus = activePane.map { $0.keyView.window?.firstResponder === $0.keyView } ?? false
        let closingActive = index == activeIndex
        tabs.remove(at: index).teardown()
        if activeIndex >= tabs.count {
            activeIndex = tabs.count - 1
        } else if index < activeIndex {
            activeIndex -= 1
        }
        showActivePane()
        refreshTabBar()
        if hadFocus || closingActive { focusActivePane() }
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index), index != activeIndex else {
            if tabs.indices.contains(index) { focusActivePane() }
            return
        }
        activeIndex = index
        showActivePane()
        refreshTabBar()
        focusActivePane()
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        selectTab((activeIndex + 1) % tabs.count)
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        selectTab((activeIndex - 1 + tabs.count) % tabs.count)
    }

    private func focusActivePane() {
        guard let keyView = activePane?.keyView else { return }
        keyView.window?.makeFirstResponder(keyView)
    }

    private func showActivePane() {
        content.subviews.forEach { $0.removeFromSuperview() }
        guard let pane = activePane else { return }
        let view = pane.containerView
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func refreshTabBar() {
        for view in tabBar.arrangedSubviews {
            tabBar.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, pane) in tabs.enumerated() {
            tabBar.addArrangedSubview(
                makeChip(
                    title: pane.smartListingTitle ?? Self.title(for: pane.currentURL),
                    index: index,
                    active: index == activeIndex, closable: tabs.count > 1))
        }
        tabBar.addArrangedSubview(plusButton)
    }

    private func makeChip(title: String, index: Int, active: Bool, closable: Bool) -> NSView {
        let chip = TabChipView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 5
        chip.layer?.backgroundColor =
            active
            ? ThemeManager.shared.accent.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        // The whole chip selects the tab, not just the label -- clicking its padding or empty
        // space is what a user expects. Only the close button (below) is carved out.
        chip.onSelect = { [weak self] in self?.selectTab(index) }
        chip.menu = makeTabMenu(index: index, closable: closable)
        chip.index = index
        chip.sideID = sideID
        chip.onDroppedOutside = { [weak self] i in  // no tab bar took it -> tear off into a window
            guard let self, let url = self.takeTab(at: i) else { return }
            self.onTearOffTab?(url)
        }

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12, weight: active ? .semibold : .regular)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(name)

        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            chip.heightAnchor.constraint(equalToConstant: 24),
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])

        if closable {
            let close = NSButton(title: "", target: self, action: #selector(closeClicked(_:)))
            close.tag = index
            close.image = NSImage(
                systemSymbolName: "xmark", accessibilityDescription: L("tabs.closeTab", "Close Tab")
            )
            close.imagePosition = .imageOnly
            close.isBordered = false
            close.translatesAutoresizingMaskIntoConstraints = false
            chip.addSubview(close)
            chip.closeButton = close  // carve it out of the chip's click area
            NSLayoutConstraint.activate([
                close.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
                close.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -4),
                close.widthAnchor.constraint(equalToConstant: 16),
                name.trailingAnchor.constraint(
                    lessThanOrEqualTo: close.leadingAnchor, constant: -2),
            ])
        } else {
            name.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -8).isActive =
                true
        }
        return chip
    }

    @objc private func addTabClicked() { newTab(duplicatingCurrent: true) }
    @objc private func closeClicked(_ sender: NSButton) { closeTab(at: sender.tag) }

    /// Open this tab's folder into a pane (or copy its path); the browser targets either side.
    var onOpenFolderInPane: ((URL, BreadcrumbBar.Action) -> Void)?

    /// The right-click menu for a tab: open its folder elsewhere or copy its path, plus the
    /// usual tab actions.
    private func makeTabMenu(index: Int, closable: Bool) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector) {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            item.target = self
            item.tag = index
        }
        add(L("crumb.copyPath", "Copy Path"), #selector(copyTabPath(_:)))
        menu.addItem(.separator())
        // On a tab, "duplicate" is the right verb (a new tab at the same folder), matching Safari and
        // Chrome; "Open in New Tab" is for links/folders, not a tab itself.
        add(L("tabs.duplicate", "Duplicate Tab"), #selector(duplicateTab(_:)))
        add(L("crumb.leftPane", "Open in Left Pane"), #selector(tabToLeftPane(_:)))
        add(L("crumb.rightPane", "Open in Right Pane"), #selector(tabToRightPane(_:)))
        add(L("tabs.moveToOtherPane", "Move to Other Pane"), #selector(moveTabToOtherPane(_:)))
        menu.addItem(.separator())
        if closable { add(L("tabs.closeTab", "Close Tab"), #selector(closeTabMenu(_:))) }
        if tabs.count > 1 {
            add(L("tabs.closeOthers", "Close Other Tabs"), #selector(closeOtherTabs(_:)))
        }
        return menu
    }

    private func tabURL(_ tag: Int) -> URL? {
        tabs.indices.contains(tag) ? tabs[tag].currentURL : nil
    }

    @objc private func copyTabPath(_ sender: NSMenuItem) {
        guard let url = tabURL(sender.tag) else { return }
        onOpenFolderInPane?(url, .copyPath)
    }
    @objc private func moveTabToOtherPane(_ sender: NSMenuItem) {
        onMoveTabToOtherSide?(sender.tag)
    }
    @objc private func duplicateTab(_ sender: NSMenuItem) {
        if let url = tabURL(sender.tag) { openTab(at: url) }
    }
    @objc private func tabToLeftPane(_ sender: NSMenuItem) {
        if let url = tabURL(sender.tag) { onOpenFolderInPane?(url, .leftPane) }
    }
    @objc private func tabToRightPane(_ sender: NSMenuItem) {
        if let url = tabURL(sender.tag) { onOpenFolderInPane?(url, .rightPane) }
    }
    @objc private func closeTabMenu(_ sender: NSMenuItem) { closeTab(at: sender.tag) }
    @objc private func closeOtherTabs(_ sender: NSMenuItem) {
        // Remove every tab except the target, keeping it as the sole, active tab.
        guard tabs.indices.contains(sender.tag) else { return }
        let keep = tabs[sender.tag]
        // Ask about unsaved markup in every tab that is about to go, before closing any.
        for tab in tabs where tab !== keep {
            guard tab.prepareViewerToClose() else { return }
        }
        for tab in tabs where tab !== keep { tab.teardown() }
        tabs = [keep]
        activeIndex = 0
        showActivePane()
        refreshTabBar()
    }

    static func title(for url: URL) -> String {
        let name = url.lastPathComponent
        return (name.isEmpty || name == "/") ? L("tabs.macintoshHD", "Macintosh HD") : name
    }
}

/// A tab chip whose entire area selects the tab -- clicking the padding, background, or label
/// all count, so you never have to hit the text exactly. The close button (when present) is
/// the only carved-out target; the non-interactive label never swallows the click.
private final class TabChipView: NSView, NSDraggingSource {
    var onSelect: (() -> Void)?
    weak var closeButton: NSButton?
    var index = 0
    var sideID = ""
    /// The drag ended with no tab bar accepting it: tear this tab off into its own window.
    var onDroppedOutside: ((Int) -> Void)?

    private var pressStart: NSPoint?
    private var dragging = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let close = closeButton, !close.isHidden, close.frame.contains(local) { return close }
        return self  // the label and empty space both resolve to the chip, which selects
    }

    // Click vs drag via the standard responder overrides, NOT a hand-rolled nextEvent pump. Pumping
    // the queue races a quick flick (it can start a session when the mouse-up is already queued),
    // which strands an orphaned NSDraggingSession and silently kills every later drag in the
    // process until relaunch. mouseDragged only fires while the button is down, so a session can
    // never begin after release.
    override func mouseDown(with event: NSEvent) {
        pressStart = event.locationInWindow
        dragging = false
        onSelect?()  // clicking a tab still selects it immediately
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressStart, !dragging else { return }
        let point = event.locationInWindow
        guard abs(point.x - start.x) > 6 || abs(point.y - start.y) > 6 else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: TabDrag.item(side: sideID, index: index))
        item.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        pressStart = nil
        dragging = false
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move  // a tab is always moved, never copied -- inside a bar or out into a new window
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        pressStart = nil
        dragging = false
        if operation == [] { onDroppedOutside?(index) }  // nobody took it: tear off
    }

    /// The chip's own pixels, so the thing under the cursor looks like the tab being dragged.
    private func snapshot() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: bounds.size)
        }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// The tab bar itself is the drop target for a dragged tab. Chips deliberately do NOT register the
/// type, so a drop over a chip still resolves here and we can turn the cursor's x into an insertion
/// point. draggingEnded: is NOT overridden on purpose: it is an optional NSDraggingDestination
/// method NSView does not implement, so a plain override is invisible to the ObjC runtime and
/// AppKit's drag completion raises "unrecognized selector", stranding every later drag.
private final class TabBarStack: NSStackView {
    var insertionIndexAt: ((NSPoint) -> Int)?
    var showInsertion: ((Int?) -> Void)?
    var dropTab: ((_ side: String, _ index: Int, _ insertAt: Int) -> Bool)?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        showInsertion?(nil)
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        showInsertion?(nil)
        guard let payload = TabDrag.payload(sender.draggingPasteboard) else { return false }
        let at = insertionIndexAt?(convert(sender.draggingLocation, from: nil)) ?? 0
        return dropTab?(payload.side, payload.index, at) ?? false
    }

    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard TabDrag.payload(sender.draggingPasteboard) != nil else { return [] }
        showInsertion?(insertionIndexAt?(convert(sender.draggingLocation, from: nil)) ?? 0)
        return .move
    }
}
