import AppKit
import PathemEngine

/// A small modal progress sheet for remote file transfers (download/upload).
/// Items run sequentially; Cancel aborts the in-flight transfer (curl is
/// terminated via Task cancellation).
@MainActor
final class TransferController {
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private var task: Task<Void, Never>?

    struct Item {
        let name: String
        let run: () async throws -> Void
    }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.titled], backing: .buffered, defer: true)
        build()
    }

    private func build() {
        panel.isReleasedWhenClosed = false
        titleLabel.font = .boldSystemFont(ofSize: 13)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        bar.style = .bar
        bar.isIndeterminate = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"  // Esc

        let column = NSStackView(views: [titleLabel, bar, detailLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [column, cancel])
        row.orientation = .vertical
        row.alignment = .trailing
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            bar.widthAnchor.constraint(equalToConstant: 320),
            titleLabel.widthAnchor.constraint(equalToConstant: 320),
            detailLabel.widthAnchor.constraint(equalToConstant: 320),
        ])
    }

    /// Run `items` sequentially as a modal sheet over `window`. `completion` is
    /// called on the main actor with the failures (name, error) and whether the
    /// user cancelled.
    func run(
        _ items: [Item], title: String, over window: NSWindow,
        completion: @escaping ([(String, Error)], Bool) -> Void
    ) {
        guard !items.isEmpty else {
            completion([], false)
            return
        }
        titleLabel.stringValue = title
        bar.minValue = 0
        bar.maxValue = Double(items.count)
        bar.doubleValue = 0
        detailLabel.stringValue = items[0].name
        window.beginSheet(panel)
        task = Task { @MainActor in
            var failures: [(String, Error)] = []
            for (index, item) in items.enumerated() {
                if Task.isCancelled { break }
                detailLabel.stringValue = "\(item.name)  (\(index + 1) of \(items.count))"
                do {
                    try await item.run()
                } catch {
                    if Task.isCancelled { break }  // terminated by Cancel, not a real failure
                    failures.append((item.name, error))
                }
                bar.doubleValue = Double(index + 1)
            }
            let cancelled = Task.isCancelled
            window.endSheet(panel)
            self.task = nil
            completion(failures, cancelled)
        }
    }

    @objc private func cancelTapped() { task?.cancel() }
}
