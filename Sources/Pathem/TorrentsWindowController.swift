import AppKit
import TorrentKit
import UniformTypeIdentifiers

/// The Torrents panel: a live list of downloads driven by the out-of-process daemon. Add a
/// .torrent, pause/resume, or remove; rows update from the daemon's ~1 Hz status broadcasts
/// (no local polling). Modeled on ProcessViewerController.
@MainActor
final class TorrentsWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate
{
    private let window: NSWindow
    private let table = NSTableView()
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let magnetButton = NSButton(title: "", target: nil, action: nil)
    private let pauseButton = NSButton(title: "", target: nil, action: nil)
    private let removeButton = NSButton(title: "", target: nil, action: nil)
    private let limitsButton = NSButton(title: "", target: nil, action: nil)
    private let filesButton = NSButton(title: "", target: nil, action: nil)
    private let filesController = TorrentFilesController()
    private let emptyLabel = NSTextField(labelWithString: "")

    private var rows: [TorrentSession.Status] = []
    private let client = TorrentDaemonClient.shared

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
            defer: true)
        super.init()
        window.title = L("torrents.title", "Torrents")
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PathemTorrentsWindow")
        build()
    }

    func present() {
        if !window.isVisible { window.centerOverMainWindow() }
        window.makeKeyAndOrderFront(nil)
        client.onUpdate = { [weak self] statuses in self?.apply(statuses) }
        client.onError = { [weak self] message in self?.showError(message) }
        client.startIfNeeded()
        client.requestList()
        apply(client.torrents)
    }

    func windowWillClose(_ notification: Notification) {
        // Leave the daemon running so downloads continue; just stop receiving UI updates.
        client.onUpdate = nil
        client.onError = nil
        client.onFiles = nil
    }

    // MARK: layout

    private func build() {
        addButton.title = L("torrents.add", "Add Torrent…")
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addTapped)

        magnetButton.title = L("torrents.addMagnet", "Add Magnet…")
        magnetButton.bezelStyle = .rounded
        magnetButton.target = self
        magnetButton.action = #selector(addMagnetTapped)

        pauseButton.title = L("torrents.pause", "Pause")
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(pauseResumeTapped)

        removeButton.title = L("torrents.remove", "Remove…")
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeTapped)

        limitsButton.title = L("torrents.limits", "Speed Limits…")
        limitsButton.bezelStyle = .rounded
        limitsButton.target = self
        limitsButton.action = #selector(limitsTapped)

        filesButton.title = L("torrents.files", "Files…")
        filesButton.bezelStyle = .rounded
        filesButton.target = self
        filesButton.action = #selector(filesTapped)

        let controls = NSStackView(views: [
            addButton, magnetButton, NSView(), filesButton, limitsButton, pauseButton, removeButton,
        ])
        controls.orientation = .horizontal
        controls.spacing = 8

        let columns: [(String, String, CGFloat)] = [
            ("name", L("torrents.col.name", "Name"), 200),
            ("size", L("torrents.col.size", "Size"), 70),
            ("progress", L("torrents.col.progress", "Progress"), 120),
            ("down", L("torrents.col.down", "Down"), 74),
            ("up", L("torrents.col.up", "Up"), 74),
            ("eta", L("torrents.col.eta", "ETA"), 76),
            ("ratio", L("torrents.col.ratio", "Ratio"), 58),
            ("peers", L("torrents.col.peers", "Peers"), 46),
            ("state", L("torrents.col.state", "Status"), 108),
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.target = self
        table.doubleAction = #selector(revealInFinder)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        emptyLabel.stringValue = L(
            "torrents.empty", "No torrents. Add a .torrent file to start downloading.")
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [controls, scroll])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        scroll.addSubview(emptyLabel)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                controls.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
                emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            ])
        }
        updateButtons()
    }

    // MARK: data

    private func apply(_ statuses: [TorrentSession.Status]) {
        let keep = selected()?.infoHash
        rows = statuses
        table.reloadData()
        if let keep, let row = rows.firstIndex(where: { $0.infoHash == keep }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        emptyLabel.isHidden = !rows.isEmpty
        updateButtons()
    }

    private func selected() -> TorrentSession.Status? {
        let row = table.selectedRow
        return (row >= 0 && row < rows.count) ? rows[row] : nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private func updateButtons() {
        let sel = selected()
        pauseButton.isEnabled = sel != nil
        removeButton.isEnabled = sel != nil
        filesButton.isEnabled = sel != nil && sel?.state != .checking && sel?.metadataSearch == nil
        if let sel, TorrentStatusText.resumes(sel) {
            pauseButton.title = L("torrents.resume", "Resume")
        } else {
            pauseButton.title = L("torrents.pause", "Pause")
        }
    }

    // MARK: actions

    @objc private func addTapped() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "torrent")
                ?? UTType(importedAs: "org.bittorrent.torrent", conformingTo: .data)
        ]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L("torrents.add.prompt", "Add")
        panel.message = L(
            "torrents.add.message",
            "Choose one or more .torrent files. Downloads go to your Downloads folder.")
        guard panel.runModal() == .OK else { return }
        client.startIfNeeded()
        let savePath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first?.path
        for url in panel.urls {
            client.addTorrent(fileAt: url.path, savePath: savePath)
        }
    }

    @objc private func addMagnetTapped() {
        let alert = NSAlert()
        alert.messageText = L("torrents.addMagnet.title", "Add Magnet Link")
        alert.informativeText = L(
            "torrents.addMagnet.message",
            "Paste a magnet link. Pathem fetches its details from peers, then downloads to your Downloads folder."
        )
        alert.addButton(withTitle: L("torrents.add.prompt", "Add"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "magnet:?xt=urn:btih:…"
        // Pre-fill from the clipboard when it already holds a magnet link.
        if let clip = NSPasteboard.general.string(forType: .string), clip.hasPrefix("magnet:") {
            field.stringValue = clip
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let uri = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard uri.hasPrefix("magnet:") else {
            if !uri.isEmpty {
                showError(L("torrents.addMagnet.invalid", "That doesn't look like a magnet link."))
            }
            return
        }
        client.startIfNeeded()
        let savePath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first?.path
        client.addMagnet(uri, savePath: savePath)
    }

    @objc private func pauseResumeTapped() {
        guard let sel = selected() else { return }
        if TorrentStatusText.resumes(sel) {
            client.resume(sel.infoHash)
        } else {
            client.pause(sel.infoHash)
        }
    }

    @objc private func removeTapped() {
        guard let sel = selected() else { return }
        let alert = NSAlert()
        alert.messageText = String(format: L("torrents.remove.confirm", "Remove “%@”?"), sel.name)
        alert.informativeText = L(
            "torrents.remove.info", "You can keep the downloaded files or delete them.")
        alert.addButton(withTitle: L("torrents.remove.keep", "Remove, Keep Files"))
        alert.addButton(withTitle: L("torrents.remove.delete", "Remove and Delete Files"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: client.remove(sel.infoHash, deleteData: false)
        case .alertSecondButtonReturn: client.remove(sel.infoHash, deleteData: true)
        default: break
        }
    }

    @objc private func filesTapped() {
        guard let sel = selected() else { return }
        // The file list comes back asynchronously over the status stream.
        client.onFiles = { [weak self] hash, files in
            guard let self, hash == sel.infoHash else { return }
            self.client.onFiles = nil
            guard files.count > 1 else {
                self.showError(
                    L(
                        "torrents.files.single",
                        "This torrent has a single file, so there's nothing to choose."))
                return
            }
            self.filesController.present(name: sel.name, files: files, over: self.window) {
                [weak self] wanted in
                self?.client.setFiles(sel.infoHash, wanted: wanted)
            }
        }
        client.requestFiles(sel.infoHash)
    }

    @objc private func limitsTapped() {
        let alert = NSAlert()
        alert.messageText = L("torrents.limits.title", "Speed Limits")
        alert.informativeText = L(
            "torrents.limits.message",
            "Maximum download and upload speed in KB/s. Leave 0 for unlimited.")
        alert.addButton(withTitle: L("torrents.limits.apply", "Apply"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))

        // Two labeled KB/s fields, pre-filled from the current caps.
        func field(_ bytesPerSecond: Int) -> NSTextField {
            let f = NSTextField(frame: NSRect(x: 70, y: 0, width: 90, height: 22))
            f.integerValue = bytesPerSecond / 1024
            f.alignment = .right
            return f
        }
        let downField = field(client.downLimit)
        let upField = field(client.upLimit)
        let superSeed = NSButton(
            checkboxWithTitle: L(
                "torrents.limits.superSeed", "Super-seed (efficient initial seeding)"), target: nil,
            action: nil)
        superSeed.state = client.superSeed ? .on : .off
        let encrypt = NSButton(
            checkboxWithTitle: L("torrents.limits.encrypt", "Encrypt outgoing connections (MSE)"),
            target: nil, action: nil)
        encrypt.state = client.encryptOutgoing ? .on : .off
        let utp = NSButton(
            checkboxWithTitle: L("torrents.limits.utp", "Prefer µTP (BEP 29), fall back to TCP"),
            target: nil, action: nil)
        utp.state = client.preferUTP ? .on : .off
        let vpn = NSButton(
            checkboxWithTitle: L(
                "torrents.limits.vpn", "Bind torrents to a VPN (kill-switch when it drops)"),
            target: nil, action: nil)
        vpn.state = client.bindToVPN ? .on : .off
        // Live status: which tunnel is bound, or a warning when the kill-switch has paused traffic.
        let vpnStatus = NSTextField(labelWithString: vpnStatusLine())
        vpnStatus.font = .systemFont(ofSize: 11)
        vpnStatus.textColor =
            client.bindToVPN && client.vpnInterface == nil ? .systemRed : .secondaryLabelColor
        let container = NSStackView(views: [
            labeledRow(L("torrents.limits.down", "Download"), downField),
            labeledRow(L("torrents.limits.up", "Upload"), upField),
            superSeed,
            encrypt,
            utp,
            vpn,
            vpnStatus,
        ])
        container.orientation = .vertical
        container.spacing = 8
        container.alignment = .leading
        container.frame = NSRect(x: 0, y: 0, width: 340, height: 168)
        alert.accessoryView = container
        alert.window.initialFirstResponder = downField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        client.setLimits(
            down: max(0, downField.integerValue) * 1024, up: max(0, upField.integerValue) * 1024,
            superSeed: superSeed.state == .on, encryptOutgoing: encrypt.state == .on,
            preferUTP: utp.state == .on, bindToVPN: vpn.state == .on)
    }

    /// A human line describing the current VPN binding for the Speed Limits sheet.
    private func vpnStatusLine() -> String {
        guard client.bindToVPN else {
            return L("torrents.vpn.off", "Not bound. Torrents use your normal connection.")
        }
        if let iface = client.vpnInterface {
            return String(
                format: L("torrents.vpn.bound", "Bound to %@. Traffic only leaves over the VPN."),
                iface)
        }
        return L("torrents.vpn.killed", "No VPN detected. Torrents paused to prevent leaks.")
    }

    private func labeledRow(_ title: String, _ field: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 0, y: 0, width: 80, height: 22)
        let unit = NSTextField(labelWithString: L("torrents.limits.unit", "KB/s"))
        let row = NSStackView(views: [label, field, unit])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    @objc private func revealInFinder() {
        guard let sel = selected() else { return }
        let target = URL(fileURLWithPath: sel.savePath).appendingPathComponent(sel.name)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L("torrents.error", "Couldn’t add torrent")
        alert.informativeText = message
        alert.addButton(withTitle: L("common.ok", "OK"))
        alert.runModal()
    }

    // MARK: table view

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let tableColumn, row < rows.count else { return nil }
        let status = rows[row]

        if tableColumn.identifier.rawValue == "progress" {
            let id = NSUserInterfaceItemIdentifier("progress")
            let bar =
                (tableView.makeView(withIdentifier: id, owner: self) as? TorrentProgressBar)
                ?? {
                    let b = TorrentProgressBar()
                    b.identifier = id
                    return b
                }()
            bar.fraction = status.fractionComplete
            bar.seeding = status.state == .seeding
            return bar
        }

        let id = NSUserInterfaceItemIdentifier("cell")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let c = NSTableCellView()
                c.identifier = id
                let f = NSTextField(labelWithString: "")
                f.lineBreakMode = .byTruncatingMiddle
                f.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(f)
                c.textField = f
                NSLayoutConstraint.activate([
                    f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                    f.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                    f.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
        cell.textField?.stringValue = value(for: status, column: tableColumn.identifier.rawValue)
        // A long state (a magnet's search) can be truncated by a narrow column; hovering shows all.
        cell.textField?.toolTip =
            tableColumn.identifier.rawValue == "state" ? cell.textField?.stringValue : nil
        cell.textField?.font =
            tableColumn.identifier.rawValue == "name"
            ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        return cell
    }

    private func value(for status: TorrentSession.Status, column: String) -> String {
        switch column {
        case "name": return status.name
        case "size": return Self.size.string(fromByteCount: status.totalLength)
        case "down":
            return status.downloadRate > 1
                ? "\(Self.size.string(fromByteCount: Int64(status.downloadRate)))/s" : "—"
        case "up":
            return status.uploadRate > 1
                ? "\(Self.size.string(fromByteCount: Int64(status.uploadRate)))/s" : "—"
        case "eta": return Self.etaLabel(status.etaSeconds)
        case "ratio": return status.downloaded > 0 ? String(format: "%.2f", status.ratio) : "—"
        case "peers": return "\(status.peersConnected)"
        case "state": return stateLabel(status)
        default: return ""
        }
    }

    /// A compact, human ETA like "3m 12s", "1h 4m", "2d 3h", or "—" when unknown.
    static func etaLabel(_ seconds: Int) -> String {
        guard seconds >= 0 else { return "—" }
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        let h = seconds / 3600
        let d = seconds / 86400
        if seconds < 3600 { return "\(m)m \(seconds % 60)s" }
        if seconds < 86400 { return "\(h)h \((seconds % 3600) / 60)m" }
        return "\(d)d \((seconds % 86400) / 3600)h"
    }

    private func stateLabel(_ status: TorrentSession.Status) -> String {
        if let search = TorrentStatusText.metadataSearch(status) { return search }
        switch status.state {
        case .downloading:
            // Distinguish "connected and pulling bytes" from "still looking" so a stalled row
            // reads as searching rather than a broken download.
            return status.peersConnected == 0
                ? L("torrents.state.findingPeers", "Finding peers…")
                : L("torrents.state.downloading", "Downloading")
        case .seeding: return L("torrents.state.seeding", "Seeding")
        case .paused: return L("torrents.state.paused", "Paused")
        case .checking: return L("torrents.state.checking", "Checking")
        case .stopped: return L("torrents.state.stopped", "Stopped")
        case .error: return L("torrents.state.error", "Error")
        }
    }

    private static let size: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
}

/// A small theme-tinted determinate progress bar with a centered percentage, used in the
/// Progress column. Fills with the app accent (green once seeding).
@MainActor
final class TorrentProgressBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var seeding: Bool = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        ThemeManager.shared.onChange(owner: self) { [weak self] in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // No wantsUpdateLayer override: returning true makes AppKit call updateLayer() instead of
    // draw(_:), and this view only draws, so the bar never appeared on screen (in-process
    // cacheDisplay renders call draw directly, which hid the bug there).

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 4, dy: 6)
        let radius = inset.height / 2
        let track = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()

        let clamped = max(0, min(1, fraction))
        if clamped > 0 {
            var fillRect = inset
            fillRect.size.width = max(inset.height, inset.width * CGFloat(clamped))
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
            (seeding ? NSColor.systemGreen : ThemeManager.shared.accent).setFill()
            fill.fill()
        }

        let percent = String(format: "%.0f%%", clamped * 100)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let textSize = percent.size(withAttributes: attrs)
        let point = NSPoint(
            x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2)
        percent.draw(at: point, withAttributes: attrs)
    }
}
