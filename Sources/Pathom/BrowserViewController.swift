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
    private var didSetInitialSplit = false

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

        let host = NSView()
        host.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: host.topAnchor),
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
}
