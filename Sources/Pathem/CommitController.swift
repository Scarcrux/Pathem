import AppKit

/// A small commit dialog: shows the repo, a message field, an optional "Suggest with
/// AI" button (on-device), and Commit/Cancel. The browser stages changes before
/// presenting and performs the commit via the `commit` callback.
@MainActor
final class CommitController: NSObject {
    private let panel: NSPanel
    private let infoLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let suggestButton = NSButton()
    private let commitButton = NSButton()

    private var onCommit: ((String) -> Void)?
    private var onSuggest: (() async -> String?)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        build()
    }

    func present(
        over window: NSWindow, repo: String, canSuggest: Bool,
        suggest: @escaping () async -> String?, commit: @escaping (String) -> Void
    ) {
        onSuggest = suggest
        onCommit = commit
        infoLabel.stringValue = String(format: L("git.commitRepo", "Commit to %@"), repo)
        textView.string = ""
        suggestButton.isHidden = !canSuggest
        panel.growToFitContent()
        panel.centerOverMainWindow()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    private func build() {
        panel.title = L("git.commitTitle", "Commit")
        infoLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        suggestButton.title = L("git.suggestAI", "Suggest with AI")
        suggestButton.bezelStyle = .rounded
        suggestButton.target = self
        suggestButton.action = #selector(suggestTapped)
        let cancel = NSButton(title: L("common.cancel", "Cancel"), target: self, action: #selector(close))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        commitButton.title = L("git.commitButton", "Commit")
        commitButton.bezelStyle = .rounded
        commitButton.keyEquivalent = "\r"
        commitButton.target = self
        commitButton.action = #selector(commitTapped)

        let buttons = NSStackView(views: [suggestButton, NSView(), cancel, commitButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [infoLabel, scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
                buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            ])
        }
    }

    @objc private func suggestTapped() {
        suggestButton.isEnabled = false
        let previous = suggestButton.title
        suggestButton.title = L("git.suggesting", "Thinking…")
        Task { @MainActor in
            defer {
                self.suggestButton.isEnabled = true
                self.suggestButton.title = previous
            }
            if let message = await onSuggest?() ?? nil, !message.isEmpty {
                self.textView.string = message
            }
        }
    }

    @objc private func commitTapped() {
        let message = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { NSSound.beep(); return }
        onCommit?(message)
        close()
    }

    @objc private func close() { panel.orderOut(nil) }
}
