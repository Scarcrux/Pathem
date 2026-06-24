import AppKit
import PathemEngine

/// The "Stash Shelf" / drop stack: a bottom bar you drag files into from any
/// folder, pane, or tab to gather a working set, then act on them together. The
/// collection logic lives in the engine (`ShelfModel`); this renders it and routes
/// actions back to the browser, which performs them through the existing
/// conflict-aware, undoable file operations.
@MainActor
final class ShelfController: NSObject {
    let view = ShelfBarView()

    private var model = ShelfModel()
    private let titleLabel = NSTextField(labelWithString: L("shelf.title", "Shelf"))
    private let chipsStack = NSStackView()
    private let emptyHint = NSTextField(labelWithString: L("shelf.emptyHint", "Drag files here to stash them"))
    private var actionButtons: [NSButton] = []

    /// Emptiness changed (so the browser can auto-show the bar and update toggles).
    var onChanged: (() -> Void)?
    var onCopyHere: (([URL]) -> Void)?
    var onMoveHere: (([URL]) -> Void)?
    var onTrash: (([URL]) -> Void)?
    var onReveal: (([URL]) -> Void)?
    var onShare: ((_ urls: [URL], _ from: NSView) -> Void)?
    var onHide: (() -> Void)?

    var isEmpty: Bool { model.isEmpty }
    var count: Int { model.count }
    var items: [URL] { model.items }

    override init() {
        super.init()
        build()
        refresh()
    }

    // MARK: Mutations

    func add(_ urls: [URL]) {
        guard model.add(urls) else { return }
        refresh()
        onChanged?()
    }

    func remove(_ url: URL) {
        model.remove(url)
        refresh()
        onChanged?()
    }

    func clear() {
        guard !model.isEmpty else { return }
        model.removeAll()
        refresh()
        onChanged?()
    }

    /// Drop items that were moved away (they no longer exist at their old path).
    func itemsRemoved(_ urls: [URL]) {
        for url in urls { model.remove(url) }
        refresh()
        onChanged?()
    }

    // MARK: Build

    private func build() {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 72).isActive = true
        view.onDropURLs = { [weak self] urls in self?.add(urls) }

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        emptyHint.font = .systemFont(ofSize: 11)
        emptyHint.textColor = .tertiaryLabelColor

        chipsStack.orientation = .horizontal
        chipsStack.spacing = 6
        chipsStack.alignment = .centerY
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        chipsStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        scroll.documentView = chipsStack
        NSLayoutConstraint.activate([
            chipsStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 2),
            chipsStack.trailingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor),
            chipsStack.centerYAnchor.constraint(equalTo: clip.centerYAnchor),
            chipsStack.heightAnchor.constraint(equalTo: clip.heightAnchor),
        ])
        scroll.addSubview(emptyHint)
        emptyHint.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyHint.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 4),
            emptyHint.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        let actions = NSStackView(views: [
            actionButton(L("shelf.copyHere", "Copy Here"), #selector(copyHere)),
            actionButton(L("shelf.moveHere", "Move Here"), #selector(moveHere)),
            actionButton(L("shelf.trash", "Trash"), #selector(trash)),
            actionButton(L("shelf.reveal", "Reveal"), #selector(reveal)),
            actionButton(L("shelf.share", "Share"), #selector(share)),
            actionButton(L("shelf.clear", "Clear"), #selector(clearAll)),
        ])
        actions.orientation = .horizontal
        actions.spacing = 4
        actions.setHuggingPriority(.defaultHigh, for: .horizontal)

        let hide = NSButton()
        hide.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("shelf.hideShelfAX", "Hide Shelf"))
        hide.isBordered = false
        hide.bezelStyle = .inline
        hide.target = self
        hide.action = #selector(hideShelf)
        hide.toolTip = L("shelf.hideShelfTooltip", "Hide the shelf")

        let row = NSStackView(views: [titleLabel, scroll, actions, hide])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)

        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: view.topAnchor),
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func actionButton(_ title: String, _ selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        actionButtons.append(button)
        return button
    }

    private func refresh() {
        for chip in chipsStack.arrangedSubviews {
            chipsStack.removeArrangedSubview(chip)
            chip.removeFromSuperview()
        }
        for (index, url) in model.items.enumerated() {
            chipsStack.addArrangedSubview(makeChip(for: url, index: index))
        }
        titleLabel.stringValue =
            model.isEmpty
            ? L("shelf.title", "Shelf")
            : String(format: L("shelf.titleCount", "Shelf (%d)"), model.count)
        emptyHint.isHidden = !model.isEmpty
        for button in actionButtons {
            // Clear is enabled whenever there are items; the rest too.
            button.isEnabled = !model.isEmpty
        }
    }

    private func makeChip(for url: URL, index: Int) -> NSView {
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        chip.layer?.cornerRadius = 5
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = NSColor.separatorColor.cgColor

        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let label = NSTextField(labelWithString: url.lastPathComponent)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = url.path
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.maximumNumberOfLines = 1

        let remove = NSButton()
        remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("common.remove", "Remove"))
        remove.isBordered = false
        remove.bezelStyle = .inline
        remove.contentTintColor = .tertiaryLabelColor
        remove.tag = index  // valid for this build; refresh() re-tags after any change
        remove.target = self
        remove.action = #selector(removeChip(_:))

        let inner = NSStackView(views: [icon, label, remove])
        inner.orientation = .horizontal
        inner.spacing = 4
        inner.alignment = .centerY
        inner.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 3)
        inner.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: chip.topAnchor),
            inner.bottomAnchor.constraint(equalTo: chip.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: chip.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
        ])
        return chip
    }

    // MARK: Actions

    @objc private func removeChip(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < model.items.count else { return }
        remove(model.items[sender.tag])
    }

    @objc private func copyHere() { guard !model.isEmpty else { return }; onCopyHere?(model.items) }
    @objc private func moveHere() { guard !model.isEmpty else { return }; onMoveHere?(model.items) }
    @objc private func trash() { guard !model.isEmpty else { return }; onTrash?(model.items) }
    @objc private func reveal() { guard !model.isEmpty else { return }; onReveal?(model.items) }
    @objc private func share(_ sender: NSButton) {
        guard !model.isEmpty else { return }
        onShare?(model.items, sender)
    }
    @objc private func clearAll() { clear() }
    @objc private func hideShelf() { onHide?() }
}

/// The shelf's background view, which accepts file-URL drags from the panes, Finder,
/// or anywhere, and highlights while a drag hovers.
final class ShelfBarView: NSView {
    var onDropURLs: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).cgColor
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let urls =
            sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDropURLs?(urls)
        return true
    }
}
