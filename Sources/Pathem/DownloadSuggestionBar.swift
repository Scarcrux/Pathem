import AppKit

/// A non-modal chip that slides in when a file lands in Downloads, offering to file it in
/// one click ("Move invoice.pdf to PDFs"). It never blocks: the user can Move, dismiss, or
/// ignore it. Styled like the quick-actions bar (a blurred, shadowed pill).
@MainActor
final class DownloadSuggestionBar: NSView {
    var onMove: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onDismissAll: (() -> Void)?

    private let blur = NSVisualEffectView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let moveButton = NSButton()
    private let closeButton = NSButton()
    private let dismissAllButton = NSButton()

    init() {
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 11
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.separatorColor.cgColor
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        icon.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        moveButton.title = L("download.move", "Move")
        moveButton.bezelStyle = .rounded
        moveButton.controlSize = .small
        moveButton.target = self
        moveButton.action = #selector(moveTapped)

        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: L("download.dismiss", "Dismiss"))
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(dismissTapped)

        dismissAllButton.title = L("download.dismissAll", "Dismiss All")
        dismissAllButton.bezelStyle = .rounded
        dismissAllButton.controlSize = .small
        dismissAllButton.target = self
        dismissAllButton.action = #selector(dismissAllTapped)
        let stack = NSStackView(views: [icon, label, moveButton, dismissAllButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: 11, cornerHeight: 11, transform: nil)
    }

    /// Show the chip for a newly-arrived file and where it would go.
    func show(fileURL: URL, destinationName: String) {
        // Copy the shared workspace icon before resizing it in place.
        let raw = NSWorkspace.shared.icon(forFile: fileURL.path)
        let image = (raw.copy() as? NSImage) ?? raw
        image.size = NSSize(width: 18, height: 18)
        icon.image = image
        label.stringValue = String(
            format: L("download.suggestion", "Move %@ to %@"), fileURL.lastPathComponent,
            destinationName)
        isHidden = false
    }

    func hide() { isHidden = true }

    @objc private func moveTapped() { onMove?() }
    @objc private func dismissTapped() { onDismiss?() }
    @objc private func dismissAllTapped() { onDismissAll?() }

    #if DEBUG
    var debugDismissAllButton: NSButton { dismissAllButton }
    #endif

    /// Test hook: the visible suggestion text, or nil when hidden.
    var debugVisibleText: String? { isHidden ? nil : label.stringValue }
}
