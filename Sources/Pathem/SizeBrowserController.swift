import AppKit
import PathemEngine

/// A "where did my space go" size browser: lists a folder's immediate children sized
/// by their recursive byte totals, as proportional bars; double-click a folder to
/// drill in. Sizes are computed off the main thread and superseded if you navigate.
@MainActor
final class SizeBrowserController: NSObject {
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let upButton = NSButton()
    private let rows = NSStackView()
    private let spinner = NSProgressIndicator()
    private let gen = GenerationBox()
    private var root: URL
    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: true)
        root = URL(fileURLWithPath: NSHomeDirectory())
        super.init()
        panel.title = L("size.windowTitle", "Size Browser")
        build()
    }

    func present(for url: URL, over window: NSWindow?) {
        root = url
        // A normal closable utility window (not a sheet), so its close button works and
        // re-presenting just brings it forward instead of beginSheet-ing twice.
        if !panel.isVisible { panel.centerOverMainWindow() }
        panel.makeKeyAndOrderFront(nil)
        load(url)
    }

    private func build() {
        upButton.title = L("size.enclosingFolder", "Enclosing Folder")
        upButton.bezelStyle = .rounded
        upButton.controlSize = .small
        upButton.target = self
        upButton.action = #selector(goUp)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let header = NSStackView(views: [upButton, titleLabel, spinner])
        header.orientation = .horizontal
        header.spacing = 8

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rows.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = rows

        let root = NSStackView(views: [header, scroll])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(root)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
                rows.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            ])
        }
    }

    @objc private func goUp() {
        let parent = root.deletingLastPathComponent()
        guard parent.path != root.path else { return }
        load(parent)
    }

    private func load(_ url: URL) {
        root = url
        titleLabel.stringValue = url.path
        upButton.isEnabled = url.path != "/"
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        spinner.startAnimation(nil)
        let generation = gen.bump()
        // Main-actor Task so `self` stays on the main actor (the older CI toolchain flags sending
        // it into MainActor.run); the ranked, symlink-safe child sizing runs on a detached task
        // that captures only the Sendable `url`.
        Task { [weak self] in
            let sized = await Task.detached(priority: .utility) {
                DiskUsage.rankedChildren(of: url, includingHidden: false)
                    .map { (name: $0.name, size: $0.bytes, isDir: $0.isDirectory) }
            }.value
            guard let self, self.gen.isCurrent(generation) else { return }
            self.spinner.stopAnimation(nil)
            self.render(sized)
        }
    }

    private func render(_ items: [(name: String, size: Int64, isDir: Bool)]) {
        let maxSize = max(1, items.first?.size ?? 1)
        for item in items.prefix(500) {
            rows.addArrangedSubview(makeRow(item, maxSize: maxSize))
        }
        if items.isEmpty {
            rows.addArrangedSubview(NSTextField(labelWithString: L("pane.folderEmpty", "This folder is empty")))
        }
    }

    private func makeRow(_ item: (name: String, size: Int64, isDir: Bool), maxSize: Int64) -> NSView {
        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(for: item.isDir ? .folder : .data)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let name = NSTextField(labelWithString: item.name)
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 12)
        name.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        track.layer?.cornerRadius = 3
        track.translatesAutoresizingMaskIntoConstraints = false
        track.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = ThemeManager.shared.accent.cgColor
        fill.layer?.cornerRadius = 3
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        let fraction = max(0.02, min(1, Double(item.size) / Double(maxSize)))
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: fraction),
        ])

        let size = NSTextField(labelWithString: byteFormatter.string(fromByteCount: item.size))
        size.font = .systemFont(ofSize: 11)
        size.textColor = .secondaryLabelColor
        size.alignment = .right
        size.widthAnchor.constraint(equalToConstant: 76).isActive = true

        let row = NSStackView(views: [icon, name, track, size])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        track.setContentHuggingPriority(.init(1), for: .horizontal)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        if item.isDir {
            let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
            click.numberOfClicksRequired = 2
            row.addGestureRecognizer(click)
            row.identifier = NSUserInterfaceItemIdentifier(item.name)
        }
        return row
    }

    @objc private func rowClicked(_ sender: NSClickGestureRecognizer) {
        guard let name = sender.view?.identifier?.rawValue else { return }
        load(root.appendingPathComponent(name))
    }
}
