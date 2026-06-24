import AppKit
import PathemEngine
import UniformTypeIdentifiers

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
        panel.title = L("info.panelTitle", "Info")
        panel.isReleasedWhenClosed = false  // the controller owns it; closing just hides it
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

    /// The single file currently shown, so an async SHA-256 ignores a stale result.
    private var inspectedURL: URL?

    private func configure(_ urls: [URL]) {
        fields.arrangedSubviews.forEach { $0.removeFromSuperview() }
        inspectedURL = urls.count == 1 ? urls[0] : nil

        if urls.count == 1, let info = FileInfo.gather(for: urls[0]) {
            iconView.image = NSWorkspace.shared.icon(forFile: info.path)
            titleLabel.stringValue = info.name
            addField(L("info.kindLabel", "Kind"), info.isSymbolicLink ? L("info.aliasSymlink", "Alias / Symlink") : info.kind)
            if info.isDataless {
                addField(L("info.sizeLabel", "Size"), L("info.onlineOnly", "Online only (not downloaded)"))
            } else {
                addField(L("info.sizeLabel", "Size"), info.isDirectory ? "--" : byteFormatter.string(fromByteCount: info.size))
            }
            addField(L("info.whereLabel", "Where"), (info.path as NSString).deletingLastPathComponent)
            if let created = info.created { addField(L("info.createdLabel", "Created"), dateFormatter.string(from: created)) }
            if let modified = info.modified { addField(L("info.modifiedLabel", "Modified"), dateFormatter.string(from: modified)) }
            addField(L("info.permissionsLabel", "Permissions"), info.permissions)
            if let owner = info.owner { addField(L("info.ownerLabel", "Owner"), owner) }
            if !info.isDirectory, !info.isDataless {
                let url = urls[0]
                // Image dimensions read off the main thread (ImageIO can touch disk).
                if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
                    let dimField = addField(L("info.dimensionsLabel", "Dimensions"), L("info.reading", "Reading…"))
                    Task { @MainActor in
                        let label = await Task.detached { MediaMetadata.dimensionsLabel(of: url) }.value
                        guard self.inspectedURL == url else { return }
                        dimField.stringValue = label ?? L("info.unknown", "unknown")
                    }
                }
                let hashField = addField("SHA-256", L("info.calculating", "Calculating…"))
                Task { @MainActor in
                    let hash = await Task.detached { try? FileHasher.hash(url) }.value
                    guard self.inspectedURL == url else { return }  // inspector moved on
                    hashField.stringValue = hash ?? L("info.unavailable", "unavailable")
                }
            }
        } else {
            iconView.image = NSWorkspace.shared.icon(for: .item)
            // Derive every number from the items actually read, so the count,
            // folder tally, and total size always agree.
            let infos = urls.compactMap { FileInfo.gather(for: $0) }
            titleLabel.stringValue = String(format: L("info.itemsCount", "%d items"), infos.count)
            let totalSize = infos.filter { !$0.isDirectory && !$0.isDataless }.reduce(Int64(0)) { $0 + $1.size }
            let folders = infos.filter(\.isDirectory).count
            addField(L("info.itemsLabel", "Items"), "\(infos.count) (\(folders) folder\(folders == 1 ? "" : "s"))")
            addField(L("info.totalSizeLabel", "Total Size"), byteFormatter.string(fromByteCount: totalSize))
        }
    }

    @discardableResult
    private func addField(_ label: String, _ value: String) -> NSTextField {
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
        return val
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
