import AppKit
import PathomEngine

/// The dual-pane browser: two independent panes side by side in a split view,
/// one "active" pane (accent border), and one-key copy/move between them
/// (F5 / F6 — the classic dual-pane bindings). This is the Launch-1 hero: a
/// fast, native, two-pane file manager.
@MainActor
final class BrowserViewController: NSViewController {
    private let left: PaneController
    private let right: PaneController
    private weak var activePane: PaneController?
    private let split = NSSplitView()
    private let searchField = NSSearchField()
    private var didSetInitialSplit = false

    /// Cap on items embedded per search (bounds the cost on huge folders). The
    /// scale path — background incremental indexing + a cached vector store —
    /// is in DESIGN.md §2.
    private static let maxSemanticItems = 5_000

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
    }

    /// Copy (or move) the active pane's selection into the *other* pane's
    /// directory. Refuses to overwrite and reports any failures (DESIGN.md §6.5).
    private func transfer(move: Bool) {
        guard let source = activePane else { return }
        let destination = (source === left) ? right : left
        let names = source.selectedEntries.map(\.name)
        guard !names.isEmpty else { NSSound.beep(); return }

        let failures =
            move
            ? FileOperations.move(names, from: source.currentURL, to: destination.currentURL)
            : FileOperations.copy(names, from: source.currentURL, to: destination.currentURL)

        if move { source.reload() }
        destination.reload()
        if !failures.isEmpty { presentFailures(failures, move: move) }
    }

    private func presentFailures(_ failures: [FileOperations.Failure], move: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(move ? "Move" : "Copy") failed for \(failures.count) item(s)"
        alert.informativeText =
            failures.prefix(8).map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
        alert.runModal()
    }

    // MARK: - Semantic search (on-device, free)

    /// Re-rank the active pane's folder by semantic similarity to the query.
    /// Empty query restores the normal directory listing. Embedding runs off the
    /// main thread so the UI never blocks.
    @objc private func runSearch(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pane = activePane else { return }
        guard !query.isEmpty else {
            pane.reload()
            return
        }
        let entries = Array(pane.entries.prefix(Self.maxSemanticItems))
        let names = entries.map(\.name)
        Task {
            let order = await Self.semanticRank(query: query, names: names)
            let ranked = order.compactMap { $0 < entries.count ? entries[$0] : nil }
            pane.showResults(ranked)
        }
    }

    /// Off-main: embed the names and the query, return item indices ranked by
    /// similarity. Builds the embedder here so nothing non-Sendable crosses the
    /// actor boundary. If the OS model asset isn't ready, keeps original order.
    nonisolated private static func semanticRank(query: String, names: [String]) async -> [Int] {
        let embedder = NLEmbedder()
        guard embedder.dimension > 0 else { return Array(names.indices) }
        var index = SemanticIndex<Int>(embedder: embedder)
        for (i, name) in names.enumerated() { index.add(i, text: name) }
        return index.search(query, topK: names.count).map(\.id)
    }
}
