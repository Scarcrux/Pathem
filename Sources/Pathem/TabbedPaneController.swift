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
    }

    private func build() {
        tabBar.orientation = .horizontal
        tabBar.spacing = 4
        tabBar.alignment = .centerY
        tabBar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
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

    /// Reopen tabs at the given folders (skipping ones that no longer exist).
    /// Falls back to the start folder if none are valid.
    func restoreTabs(_ folders: [String], active: Int) {
        let fm = FileManager.default
        // Keep original indices so the saved active index maps correctly even when
        // some folders were dropped (deleted on disk).
        let survivors = folders.enumerated().filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0.element, isDirectory: &isDir) && isDir.boolValue
        }
        guard !survivors.isEmpty else { openInitialTab(); return }
        for survivor in survivors { newTab(at: URL(fileURLWithPath: survivor.element), focus: false) }
        // Map the saved active index (an original offset) to the surviving tab at
        // or after it, falling back to the last tab.
        let mapped = survivors.firstIndex(where: { $0.offset >= active }) ?? (survivors.count - 1)
        activeIndex = min(max(mapped, 0), tabs.count - 1)
        showActivePane()
        refreshTabBar()
    }

    /// Open a new tab. `duplicatingCurrent` opens it at the active tab's folder
    /// (browser-style), otherwise at this side's start folder.
    func newTab(duplicatingCurrent: Bool) {
        let url = (duplicatingCurrent ? activePane?.currentURL : nil) ?? start
        newTab(at: url, focus: true)
    }

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
        tabs.remove(at: index).teardown()
        if activeIndex >= tabs.count {
            activeIndex = tabs.count - 1
        } else if index < activeIndex {
            activeIndex -= 1
        }
        showActivePane()
        refreshTabBar()
        focusActivePane()
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
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 5
        chip.layer?.backgroundColor =
            active ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor

        let name = NSButton(title: title, target: self, action: #selector(tabClicked(_:)))
        name.tag = index
        name.isBordered = false
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
            close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
            close.imagePosition = .imageOnly
            close.isBordered = false
            close.translatesAutoresizingMaskIntoConstraints = false
            chip.addSubview(close)
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
    @objc private func tabClicked(_ sender: NSButton) { selectTab(sender.tag) }
    @objc private func closeClicked(_ sender: NSButton) { closeTab(at: sender.tag) }

    static func title(for url: URL) -> String {
        let name = url.lastPathComponent
        return (name.isEmpty || name == "/") ? "Macintosh HD" : name
    }
}
