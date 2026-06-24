import AppKit

/// Thread-safe shared state for a running transfer: the background op writes
/// `completed` and reads `cancelled`; the main thread polls `completed` for the
/// progress bar and sets `cancelled` from the Cancel button.
final class TransferState: @unchecked Sendable {
    let total: Int
    private let lock = NSLock()
    private var _completed = 0
    private var _cancelled = false

    init(total: Int) { self.total = total }

    var completed: Int {
        lock.lock(); defer { lock.unlock() }
        return _completed
    }
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
    func setCompleted(_ value: Int) {
        lock.lock(); _completed = value; lock.unlock()
    }
    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }
}

/// A progress sheet for copy/move: a determinate bar, a count label, and Cancel.
/// Shown only when a transfer runs long enough to matter (the browser defers it),
/// so quick operations never flash a sheet.
@MainActor
final class TransferProgress: NSObject {
    private let panel: NSPanel
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: L("common.cancel", "Cancel"), target: nil, action: nil)

    private weak var host: NSWindow?
    private var showing = false
    private var verb = ""
    private var total = 0
    private var onCancel: (() -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 130),
            styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        build()
    }

    private func build() {
        panel.title = L("progress.windowTitle", "Transferring")
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        bar.style = .bar
        bar.isIndeterminate = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"  // Esc
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(label)
        content.addSubview(bar)
        content.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            cancelButton.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 14),
            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
        ])
    }

    func begin(verb: String, total: Int, over window: NSWindow?, onCancel: @escaping () -> Void) {
        self.verb = verb
        self.total = total
        self.onCancel = onCancel
        self.host = window
        cancelButton.isEnabled = true
        bar.minValue = 0
        bar.maxValue = Double(max(total, 1))
        bar.doubleValue = 0
        update(completed: 0)
        showing = true
        if let window {
            window.beginSheet(panel)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func update(completed: Int) {
        guard showing else { return }
        bar.doubleValue = Double(completed)
        label.stringValue = String(format: L("progress.countStatus", "%@ %d of %d…"), verb, completed, total)
    }

    func end() {
        guard showing else { return }
        showing = false
        if let host {
            host.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
        onCancel = nil
    }

    @objc private func cancelClicked() {
        cancelButton.isEnabled = false
        label.stringValue = L("progress.cancelling", "Cancelling…")
        onCancel?()
    }
}
