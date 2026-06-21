import AppKit
import PathomEngine

/// One pane of the dual-pane browser: a directory listing with its own
/// navigation history, an editable path/address bar, and back/forward/up
/// buttons. The pane is intentionally thin — `NavigationState` owns the history
/// logic and `BulkEnumerator` does the listing.
@MainActor
final class PaneController: NSObject {
    let containerView = NSView()
    let list = FileListController()
    private(set) var nav: NavigationState

    private let pathControl = NSPathControl()
    private var backButton = NSButton()
    private var forwardButton = NSButton()
    private var upButton = NSButton()

    /// Fired when this pane becomes active (its list gains focus).
    var onBecomeActive: (() -> Void)?

    init(start: URL) {
        nav = NavigationState(current: start.standardizedFileURL)
        super.init()
        build()
        wire()
        reload()
    }

    var currentURL: URL { nav.current }
    var selectedEntries: [FileEntry] { list.selectedEntries }

    /// Entries currently shown (directory listing, or ranked search results).
    var entries: [FileEntry] { list.entries }

    /// Replace the listing with an explicit set (e.g. ranked search results).
    func showResults(_ entries: [FileEntry]) { list.setEntries(entries) }

    func reload() {
        let entries = (try? BulkEnumerator().entries(of: nav.current, includingHidden: false)) ?? []
        list.setEntries(entries.sorted(by: Self.dirsFirst))
        pathControl.url = nav.current
        backButton.isEnabled = nav.canGoBack
        forwardButton.isEnabled = nav.canGoForward
        upButton.isEnabled = nav.parent != nil
    }

    func descend(into entry: FileEntry) {
        guard entry.isDirectory else { return }
        nav.go(to: nav.current.appendingPathComponent(entry.name))
        reload()
    }

    @objc func goBack() { if nav.goBack() { reload() } }
    @objc func goForward() { if nav.goForward() { reload() } }
    @objc func goUp() { if nav.goUp() { reload() } }

    func setActive(_ active: Bool) {
        containerView.layer?.borderColor =
            (active ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    // MARK: - Build

    private func build() {
        containerView.wantsLayer = true
        containerView.layer?.borderWidth = 1
        containerView.layer?.borderColor = NSColor.separatorColor.cgColor

        backButton = iconButton("chevron.backward", #selector(goBack))
        forwardButton = iconButton("chevron.forward", #selector(goForward))
        upButton = iconButton("chevron.up", #selector(goUp))

        pathControl.pathStyle = .standard
        pathControl.target = self
        pathControl.action = #selector(pathClicked)
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.setContentHuggingPriority(.init(1), for: .horizontal)
        pathControl.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let toolbar = NSStackView(views: [backButton, forwardButton, upButton, pathControl])
        toolbar.orientation = .horizontal
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let scroll = list.scrollView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(toolbar)
        containerView.addSubview(scroll)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: containerView.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
    }

    private func iconButton(_ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func wire() {
        list.onOpen = { [weak self] entry in self?.descend(into: entry) }
        list.onBecomeActive = { [weak self] in self?.onBecomeActive?() }
        let table = list.tableView
        table.onGoUp = { [weak self] in self?.goUp() }
        table.onGoBack = { [weak self] in self?.goBack() }
        table.onGoForward = { [weak self] in self?.goForward() }
    }

    @objc private func pathClicked() {
        guard let url = pathControl.clickedPathItem?.url else { return }
        nav.go(to: url)
        reload()
    }

    private static func dirsFirst(_ a: FileEntry, _ b: FileEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
