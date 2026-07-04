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
    private let stack = NSStackView()

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
    private let groupedNumber: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    /// "1.2 MB (1,234,567 bytes), 1.3 MB on disk" — Finder-style with exact + allocated size.
    private func sizeDescription(_ info: FileInfo) -> String {
        let human = byteFormatter.string(fromByteCount: info.size)
        let exact = groupedNumber.string(from: NSNumber(value: info.size)) ?? "\(info.size)"
        var text = String(format: L("info.sizeExact", "%@ (%@ bytes)"), human, exact)
        if info.allocatedSize > 0 {
            text += String(format: L("info.sizeOnDisk", ", %@ on disk"), byteFormatter.string(fromByteCount: info.allocatedSize))
        }
        return text
    }

    @objc private func toggleLocked(_ sender: NSButton) {
        guard let url = inspectedURL else { return }
        do {
            try FileInfo.setLocked(sender.state == .on, on: url)
        } catch {
            sender.state = sender.state == .on ? .off : .on  // revert on failure
            NSSound.beep()
        }
    }

    @objc private func toggleHideExtension(_ sender: NSButton) {
        guard let url = inspectedURL else { return }
        do {
            try FileMetadata.setHidesExtension(sender.state == .on, on: url)
        } catch {
            sender.state = sender.state == .on ? .off : .on
            NSSound.beep()
        }
    }

    /// Replace the file icon with a real QuickLook preview when it renders (guarded against
    /// the inspector having moved on to another item).
    private func loadThumbnail(for url: URL) {
        let size = CGSize(width: 128, height: 128)
        if let cached = ThumbnailProvider.shared.cached(url, size: size) {
            iconView.image = cached
            return
        }
        let scale = iconView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        ThumbnailProvider.shared.generate(url, size: size, scale: scale) { [weak self] image in
            guard let self, self.inspectedURL == url else { return }
            self.iconView.image = image
        }
    }

    /// A popup of the apps that can open this file (the default first) plus "Other…"; picking
    /// one sets it as the default application for this specific file.
    private var openWithApps: [URL] = []
    private func openWithControl(for url: URL) -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        let workspace = NSWorkspace.shared
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? .data
        var apps = workspace.urlsForApplications(toOpen: type)
        if let preferred = workspace.urlForApplication(toOpen: url) {
            apps = [preferred] + apps.filter { $0 != preferred }  // default first
        }
        openWithApps = apps
        for app in apps {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: nil, keyEquivalent: "")
            let icon = workspace.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            popup.menu?.addItem(item)
        }
        if !apps.isEmpty { popup.menu?.addItem(.separator()) }
        popup.menu?.addItem(NSMenuItem(title: L("info.otherApp", "Other…"), action: nil, keyEquivalent: ""))
        popup.target = self
        popup.action = #selector(openWithChanged(_:))
        popup.selectItem(at: 0)
        return popup
    }

    @objc private func openWithChanged(_ sender: NSPopUpButton) {
        guard let url = inspectedURL else { return }
        // Public API sets the handler per content type (Finder's "Change All"), not per file.
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? .data
        let index = sender.indexOfSelectedItem
        if index >= 0, index < openWithApps.count {
            NSWorkspace.shared.setDefaultApplication(at: openWithApps[index], toOpen: type) { _ in }
        } else {
            let picker = NSOpenPanel()
            picker.directoryURL = URL(fileURLWithPath: "/Applications")
            picker.allowedContentTypes = [.application]
            picker.allowsMultipleSelection = false
            guard picker.runModal() == .OK, let app = picker.url else { sender.selectItem(at: 0); return }
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { _ in }
        }
    }

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

        stack.setViews([iconView, titleLabel, NSBox.horizontalLine(), fields], in: .center)
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
        // Size the panel to fit the (variable) field list.
        panel.layoutIfNeeded()
        let fitting = stack.fittingSize
        panel.setContentSize(NSSize(width: max(340, fitting.width + 40), height: fitting.height + 36))
        if !panel.isVisible { panel.centerOverMainWindow() }
        panel.makeKeyAndOrderFront(nil)
    }

    /// The single file currently shown, so an async SHA-256 ignores a stale result.
    private var inspectedURL: URL?

    /// Test hooks: number of populated fields, hide the panel, and its window number.
    var debugFieldCount: Int { fields.arrangedSubviews.count }
    func debugClose() { panel.orderOut(nil) }
    var debugWindowNumber: Int { panel.windowNumber }

    private func configure(_ urls: [URL]) {
        fields.arrangedSubviews.forEach { $0.removeFromSuperview() }
        inspectedURL = urls.count == 1 ? urls[0] : nil

        if urls.count == 1, let info = FileInfo.gather(for: urls[0]) {
            iconView.image = NSWorkspace.shared.icon(forFile: info.path)  // immediate fallback
            loadThumbnail(for: urls[0])  // replace with a real QuickLook preview when it renders
            titleLabel.stringValue = info.name
            addField(L("info.kindLabel", "Kind"), info.isSymbolicLink ? L("info.aliasSymlink", "Alias / Symlink") : info.kind)
            if info.isDataless {
                addField(L("info.sizeLabel", "Size"), L("info.onlineOnly", "Online only (not downloaded)"))
            } else if info.isDirectory {
                // Item count now, then fill in the recursive size once it's totted up off-main.
                let countText = info.itemCount.map { String(format: L("info.itemsValue", "%d items"), $0) } ?? ""
                let sizeField = addField(L("info.sizeLabel", "Size"), countText.isEmpty ? L("info.calculating", "Calculating…") : countText)
                let url = urls[0]
                let formatter = byteFormatter
                Task { @MainActor in
                    let bytes = await Task.detached { FileOperations.totalBytes(of: [url]) }.value
                    guard self.inspectedURL == url else { return }
                    let size = formatter.string(fromByteCount: bytes)
                    sizeField.stringValue = countText.isEmpty ? size : "\(countText), \(size)"
                }
            } else {
                addField(L("info.sizeLabel", "Size"), sizeDescription(info))
            }
            addField(L("info.whereLabel", "Where"), (info.path as NSString).deletingLastPathComponent)
            if let created = info.created { addField(L("info.createdLabel", "Created"), dateFormatter.string(from: created)) }
            if let modified = info.modified { addField(L("info.modifiedLabel", "Modified"), dateFormatter.string(from: modified)) }
            if let accessed = info.accessed { addField(L("info.accessedLabel", "Last opened"), dateFormatter.string(from: accessed)) }
            if let added = info.added { addField(L("info.addedLabel", "Added"), dateFormatter.string(from: added)) }
            let sources = FileMetadata.whereFroms(of: urls[0])
            if let from = sources.first { addField(L("info.whereFromLabel", "Where from"), from) }
            if let app = FileMetadata.appInfo(of: urls[0]) {
                if let version = app.version { addField(L("info.versionLabel", "Version"), version) }
                if let copyright = app.copyright { addField(L("info.copyrightLabel", "Copyright"), copyright) }
            }
            if !info.isDirectory, urls[0].isFileURL {
                addCustomField(L("info.openWithLabel", "Open with"), openWithControl(for: urls[0]))
            }
            if let comment = FileMetadata.finderComment(of: urls[0]) {
                addField(L("info.commentLabel", "Comment"), comment)
            }
            // Editable chmod grid for a local item we can attempt to modify; otherwise
            // the read-only symbolic string (remote panes, dataless placeholders).
            if let mode = info.posixMode, !info.isDataless, urls[0].isFileURL {
                let url = urls[0]
                let editor = PermissionsEditorView(mode: mode) { newMode in
                    do {
                        try FileInfo.setPosixMode(newMode, on: url)
                        return true
                    } catch {
                        return false
                    }
                }
                addCustomField(L("info.permissionsLabel", "Permissions"), editor)
            } else {
                addField(L("info.permissionsLabel", "Permissions"), info.permissions)
            }
            let ownerGroup = [info.owner, info.group].compactMap { $0 }.joined(separator: " : ")
            if !ownerGroup.isEmpty { addField(L("info.ownerLabel", "Owner"), ownerGroup) }
            if let acl = FileMetadata.aclEntries(of: urls[0]) {
                addField(L("info.aclLabel", "Sharing"), acl.joined(separator: "\n"))
            }
            if !info.tags.isEmpty { addField(L("info.tagsLabel", "Tags"), info.tags.joined(separator: ", ")) }
            if let type = info.contentType, !info.isDirectory { addField(L("info.typeLabel", "Type"), type) }
            if urls[0].isFileURL, !info.isDataless {
                let lock = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleLocked(_:)))
                lock.state = info.isLocked ? .on : .off
                addCustomField(L("info.lockedLabel", "Locked"), lock)
                if !info.isDirectory, !urls[0].pathExtension.isEmpty {
                    let hide = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleHideExtension(_:)))
                    hide.state = FileMetadata.hidesExtension(urls[0]) ? .on : .off
                    addCustomField(L("info.hideExtensionLabel", "Hide extension"), hide)
                }
            }
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
        let val = NSTextField(wrappingLabelWithString: value)
        val.font = .systemFont(ofSize: 12)
        val.isSelectable = true
        addCustomField(label, val)
        return val
    }

    /// A labeled row hosting an arbitrary trailing view (used by the chmod editor).
    private func addCustomField(_ label: String, _ trailing: NSView) {
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = .secondaryLabelColor
        name.alignment = .right
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 92).isActive = true
        name.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [name, trailing])
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
