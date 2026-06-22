import AppKit
import PathemEngine

/// A Finder-style Get Info panel: icon, name, and a labeled field list for the
/// selected item, or a summary when several are selected. A single reusable
/// floating panel, refreshed each time it is shown.
@MainActor
final class InfoInspectorController: NSObject {
    private let panel: NSPanel
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let fields = NSStackView()

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        build()
    }

    private func build() {
        panel.title = "Info"
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 2

        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 6

        let stack = NSStackView(views: [iconView, titleLabel, NSBox.horizontalLine(), fields])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fields.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    func present(urls: [URL], over window: NSWindow?) {
        guard !urls.isEmpty else { return }
        configure(urls)
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
    }

    private func configure(_ urls: [URL]) {
        fields.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if urls.count == 1, let info = FileInfo.gather(for: urls[0]) {
            iconView.image = NSWorkspace.shared.icon(forFile: info.path)
            titleLabel.stringValue = info.name
            addField("Kind", info.isSymbolicLink ? "Alias / Symlink" : info.kind)
            addField("Size", info.isDirectory ? "--" : byteFormatter.string(fromByteCount: info.size))
            addField("Where", (info.path as NSString).deletingLastPathComponent)
            if let created = info.created { addField("Created", dateFormatter.string(from: created)) }
            if let modified = info.modified { addField("Modified", dateFormatter.string(from: modified)) }
            addField("Permissions", info.permissions)
            if let owner = info.owner { addField("Owner", owner) }
        } else {
            iconView.image = NSWorkspace.shared.icon(for: .item)
            titleLabel.stringValue = "\(urls.count) items"
            let infos = urls.compactMap { FileInfo.gather(for: $0) }
            let totalSize = infos.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
            let folders = infos.filter(\.isDirectory).count
            addField("Items", "\(urls.count) (\(folders) folder\(folders == 1 ? "" : "s"))")
            addField("Total Size", byteFormatter.string(fromByteCount: totalSize))
        }
    }

    private func addField(_ label: String, _ value: String) {
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = .secondaryLabelColor
        name.alignment = .right
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 92).isActive = true
        name.setContentHuggingPriority(.required, for: .horizontal)

        let val = NSTextField(wrappingLabelWithString: value)
        val.font = .systemFont(ofSize: 12)
        val.isSelectable = true

        let row = NSStackView(views: [name, val])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        fields.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
    }
}

extension NSBox {
    /// A thin horizontal separator line.
    static func horizontalLine() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
