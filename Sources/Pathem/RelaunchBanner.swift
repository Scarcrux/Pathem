import AppKit

/// A prominent in-window banner across the top of the browser when an update is available: a
/// downloaded Sparkle update to install, or a newer build installed under the running app to
/// relaunch into. Unlike the title-bar accessory (easy to miss, and finicky to render next to a
/// unified toolbar), this is unmissable. Hidden by default; an NSStackView collapses it to zero
/// height when hidden, so it costs nothing until there's something to say.
@MainActor
final class RelaunchBanner: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        applyTint()
        ThemeManager.shared.onChange(owner: self) { [weak self] in self?.applyTint() }

        iconView.contentTintColor = ThemeManager.shared.accent
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .regular
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)

        let dismiss = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L("download.dismiss", "Dismiss"))
                ?? NSImage(), target: self, action: #selector(dismissTapped))
        dismiss.isBordered = false
        dismiss.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [iconView, label, NSView(), actionButton, dismiss])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyTint() {
        layer?.backgroundColor = ThemeManager.shared.accent.withAlphaComponent(0.16).cgColor
        iconView.contentTintColor = ThemeManager.shared.accent
    }

    /// Show the banner with a message + action label. Hidden via `isHidden = true`.
    func present(symbol: String, message: String, actionTitle: String) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        label.stringValue = message
        actionButton.title = actionTitle
        isHidden = false
    }

    @objc private func actionTapped() { onAction?() }
    @objc private func dismissTapped() {
        isHidden = true
        onDismiss?()
    }
}
