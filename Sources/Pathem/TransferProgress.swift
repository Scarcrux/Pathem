import AppKit
import PathemEngine

/// Thread-safe shared state for a running transfer: the background op writes the
/// latest `progress`, the main thread reads it for the bar/labels and sets
/// `cancelled` from the Cancel button.
final class TransferState: @unchecked Sendable {
    private let lock = NSLock()
    private var _progress = FileOperations.Progress()
    private var _cancelled = false

    var progress: FileOperations.Progress {
        lock.lock(); defer { lock.unlock() }
        return _progress
    }
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
    func setProgress(_ value: FileOperations.Progress) {
        lock.lock(); _progress = value; lock.unlock()
    }
    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }
}

/// A progress sheet for copy/move: a determinate byte bar, the current file, a
/// "42 MB of 380 MB", the live transfer speed, and an ETA, plus Cancel. Shown only
/// when a transfer runs long enough to matter (the browser defers it), so quick
/// operations never flash a sheet.
@MainActor
final class TransferProgress: NSObject {
    private let panel: NSPanel
    private let bar = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: L("common.cancel", "Cancel"), target: nil, action: nil)

    private weak var host: NSWindow?
    private var showing = false
    private var verb = ""

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    private static let etaFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = [.hour, .minute, .second]
        f.maximumUnitCount = 2
        f.includesApproximationPhrase = false
        return f
    }()

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 148),
            styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        build()
    }

    private func build() {
        panel.title = L("progress.windowTitle", "Transferring")
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.style = .bar
        bar.isIndeterminate = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"  // Esc
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        [titleLabel, bar, detailLabel, cancelButton].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            bar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            detailLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            detailLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            detailLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            cancelButton.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 12),
            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
        ])
    }

    func begin(verb: String, over window: NSWindow?, onCancel: @escaping () -> Void) {
        self.verb = verb
        self.host = window
        self.onCancel = onCancel
        cancelButton.isEnabled = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        titleLabel.stringValue = verb
        detailLabel.stringValue = ""
        showing = true
        if let window {
            window.beginSheet(panel)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private var onCancel: (() -> Void)?

    /// Update from the latest snapshot. `bytesPerSecond` is the smoothed transfer rate
    /// (0 if not yet known), used for the speed readout and ETA.
    func update(_ progress: FileOperations.Progress, bytesPerSecond: Double) {
        guard showing else { return }
        let total = max(progress.totalBytes, 1)
        bar.doubleValue = min(1, Double(progress.completedBytes) / Double(total))

        let file = progress.currentFile.isEmpty ? "" : " " + progress.currentFile
        titleLabel.stringValue = verb + file

        let done = Self.byteFormatter.string(fromByteCount: progress.completedBytes)
        let all = Self.byteFormatter.string(fromByteCount: progress.totalBytes)
        var parts = [String(format: L("progress.ofBytes", "%@ of %@"), done, all)]
        if bytesPerSecond > 1 {
            parts.append(Self.byteFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s")
            let remaining = Double(progress.totalBytes - progress.completedBytes)
            if remaining > 0, let eta = Self.etaFormatter.string(from: remaining / bytesPerSecond) {
                parts.append(String(format: L("progress.timeLeft", "%@ left"), eta))
            }
        }
        detailLabel.stringValue = parts.joined(separator: "  ·  ")
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
        titleLabel.stringValue = L("progress.cancelling", "Cancelling…")
        onCancel?()
    }
}
