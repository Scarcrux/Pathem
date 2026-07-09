import AppKit
import PathemEngine

/// One side of the browser as a stack of tabs. Each tab is a full PaneController
/// (its own folder, history, listing, watcher, status), so the per-folder logic
/// is reused unchanged; this controller only owns the tab bar and swaps the
/// active tab's view into the content area. Background tabs keep watching their
/// folders, like browser tabs.
@MainActor
final class TabbedPaneController: NSObject {
    let containerView = NSView()
    private let tabBar = NSStackView()
    private let content = NSView()
    private let plusButton = NSButton()

    private let start: URL
    private(set) var tabs: [PaneController] = []
    private(set) var activeIndex = 0

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

        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L("tabs.newTab", "New Tab"))
        plusButton.bezelStyle = .texturedRounded
        plusButton.setButtonType(.momentaryPushIn)
        plusButton.imagePosition = .imageOnly
        plusButton.target = self
        plusButton.action = #selector(addTabClicked)

        content.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(tabBar)
        containerView.addSubview(content)
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
        guard !survivors.isEmpty else { openInitialTab(); showActivePane(); refreshTabBar(); return }
        for survivor in survivors { newTab(at: URL(fileURLWithPath: survivor.element), focus: false) }
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
            guard let self, let pane, let index = self.tabs.firstIndex(where: { $0 === pane }) else { return }
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
            self.onPaneDidNavigate?(pane)
        }
        pane.onDropFiles = { [weak self] urls, move, destination in
            self?.onPaneDropFiles?(urls, move, destination)
        }
        tabs.append(pane)
        activeIndex = tabs.count - 1
        showActivePane()
        pane.refresh()  // apply formats + fire onDirectoryDidChange now that it is wired
        refreshTabBar()
        if focus { focusActivePane() }
        return pane
    }

    func closeActiveTab() { closeTab(at: activeIndex) }

    private func closeTab(at index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
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
                    title: Self.title(for: pane.currentURL), index: index,
                    active: index == activeIndex, closable: tabs.count > 1))
        }
        tabBar.addArrangedSubview(plusButton)
    }

    private func makeChip(title: String, index: Int, active: Bool, closable: Bool) -> NSView {
        let chip = TabChipView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 5
        chip.layer?.backgroundColor =
            active ? ThemeManager.shared.accent.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        // The whole chip selects the tab, not just the label -- clicking its padding or empty
        // space is what a user expects. Only the close button (below) is carved out.
        chip.onSelect = { [weak self] in self?.selectTab(index) }

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
            close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("tabs.closeTab", "Close Tab"))
            close.imagePosition = .imageOnly
            close.isBordered = false
            close.translatesAutoresizingMaskIntoConstraints = false
            chip.addSubview(close)
            chip.closeButton = close  // carve it out of the chip's click area
            NSLayoutConstraint.activate([
                close.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
                close.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -4),
                close.widthAnchor.constraint(equalToConstant: 16),
                name.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -2),
            ])
        } else {
            name.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -8).isActive = true
        }
        return chip
    }

    @objc private func addTabClicked() { newTab(duplicatingCurrent: true) }
    @objc private func closeClicked(_ sender: NSButton) { closeTab(at: sender.tag) }

    static func title(for url: URL) -> String {
        let name = url.lastPathComponent
        return (name.isEmpty || name == "/") ? L("tabs.macintoshHD", "Macintosh HD") : name
    }
}

/// A tab chip whose entire area selects the tab -- clicking the padding, background, or label
/// all count, so you never have to hit the text exactly. The close button (when present) is
/// the only carved-out target; the non-interactive label never swallows the click.
private final class TabChipView: NSView {
    var onSelect: (() -> Void)?
    weak var closeButton: NSButton?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let close = closeButton, !close.isHidden, close.frame.contains(local) { return close }
        return self  // the label and empty space both resolve to the chip, which selects
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }
}
