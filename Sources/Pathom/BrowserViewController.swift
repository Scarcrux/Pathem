import AppKit
import PathomEngine

/// The dual-pane browser: two independent panes side by side in a split view,
/// one "active" pane (accent border), and one-key copy/move between them
/// (F5 and F6, the classic dual-pane bindings). A fast, native, two-pane file
/// manager.
@MainActor
final class BrowserViewController: NSViewController {
    private let left: PaneController
    private let right: PaneController
    private weak var activePane: PaneController?
    private let split = NSSplitView()
    private let searchField = NSSearchField()
    private var didSetInitialSplit = false

    /// Cap on items embedded per search, to bound the cost on huge folders.
    /// The scale path (background incremental indexing and a cached vector
    /// store) is in DESIGN.md section 2.
    private static let maxSemanticItems = 5_000

    /// Per-folder semantic index cache: pre-built when a pane enters a folder,
    /// invalidated when that folder changes on disk, so searches are instant.
    private var cachedDir: URL?
    private var cachedIndex: FolderSemanticIndex?
    private var cachedEntries: [FileEntry]?

    init(start: URL) {
        left = PaneController(start: start)
        right = PaneController(start: start)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(left.containerView)
        split.addArrangedSubview(right.containerView)

        searchField.placeholderString = "Semantic search in this folder (on-device)…"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(runSearch)

        let host = NSView()
        host.addSubview(searchField)
        host.addSubview(split)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            split.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        left.onBecomeActive = { [weak self] in self?.setActive(self?.left) }
        right.onBecomeActive = { [weak self] in self?.setActive(self?.right) }
        for pane in [left, right] {
            pane.list.tableView.onCopy = { [weak self] in self?.transfer(move: false) }
            pane.list.tableView.onMove = { [weak self] in self?.transfer(move: true) }
            pane.onDirectoryDidChange = { [weak self] url in self?.directoryChanged(pane, url) }
        }
        setActive(left)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didSetInitialSplit, split.bounds.width > 0 {
            split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
            didSetInitialSplit = true
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(left.list.tableView)
    }

    private func setActive(_ pane: PaneController?) {
        activePane = pane
        left.setActive(pane === left)
        right.setActive(pane === right)
        if let directory = pane?.currentURL, directory != cachedDir { preIndex(directory) }
    }

    /// Copy (or move) the active pane's selection into the other pane's folder.
    /// If names already exist there, ask how to resolve (replace, keep both, or
    /// skip), then register an undo for whatever was performed (DESIGN.md §6.5).
    private func transfer(move: Bool) {
        guard let source = activePane else { return }
        let destination = (source === left) ? right : left
        let names = source.selectedEntries.map(\.name)
        guard !names.isEmpty else { NSSound.beep(); return }

        let sourceURL = source.currentURL
        let destinationURL = destination.currentURL

        var resolution = FileOperations.ConflictResolution.skip
        let conflicts = FileOperations.conflicts(names, from: sourceURL, to: destinationURL)
        if !conflicts.isEmpty {
            guard let chosen = askConflictResolution(conflictCount: conflicts.count, move: move) else {
                return  // user cancelled
            }
            resolution = chosen
        }

        let outcome =
            move
            ? FileOperations.move(names, from: sourceURL, to: destinationURL, onConflict: resolution)
            : FileOperations.copy(names, from: sourceURL, to: destinationURL, onConflict: resolution)

        if move { source.reload() }
        destination.reload()

        if !outcome.performed.isEmpty {
            registerUndo(outcome.performed, actionName: move ? "Move" : "Copy")
        }
        if !outcome.failures.isEmpty {
            presentFailures(outcome.failures, title: "\(move ? "Move" : "Copy") failed")
        }
    }

    private func askConflictResolution(conflictCount: Int, move: Bool)
        -> FileOperations.ConflictResolution?
    {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            "\(conflictCount) item\(conflictCount == 1 ? "" : "s") already exist at the destination"
        alert.informativeText = "Choose how to handle the \(move ? "move" : "copy")."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")
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
            target.left.reload()
            target.right.reload()
            if !result.failures.isEmpty {
                target.presentFailures(result.failures, title: "Undo failed")
            }
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

    private func presentFailures(_ failures: [FileOperations.Failure], title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(title) for \(failures.count) item(s)"
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
            if activePane?.currentURL == directory { pane.showResults(ranked) }
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
        let built = await Task.detached {
            SemanticSearcher.index(dirEntries, in: directory, maxItems: maxItems)
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
        if pane === activePane { preIndex(url) }
    }
}
