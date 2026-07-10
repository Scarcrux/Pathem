import AppKit
import TorrentKit

/// The Torrents transfer drawer: a themed, embeddable panel that docks at the bottom of the browser
/// window (like the terminal) and shows the live transfer list. Replaces the old standalone window.
/// Selecting a row drives the detail view in the main area via `onSelect`; the daemon feeds it the
/// same status stream the window used.
@MainActor
final class TorrentDrawerController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView()
    private let background = NSVisualEffectView()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let client = TorrentDaemonClient.shared

    private let addButton = NSButton()
    private let magnetButton = NSButton()
    private let pauseButton = NSButton()
    private let removeButton = NSButton()
    private let limitsButton = NSButton()

    private var rows: [TorrentSession.Status] = []
    private var active = false

    /// Fired when the selected torrent changes (nil = none) so the detail view can follow it.
    var onSelect: ((TorrentSession.Status?) -> Void)?
    /// The window used to present add/remove sheets (the browser window).
    weak var hostWindow: NSWindow?

    override init() {
        super.init()
        build()
        ThemeManager.shared.onChange(owner: self) { [weak self] in self?.table.reloadData() }
    }

    /// Start receiving live updates. Call when the drawer becomes visible.
    func activate() {
        active = true
        client.onUpdate = { [weak self] statuses in self?.apply(statuses) }
        client.onError = { [weak self] message in self?.showError(message) }
        client.startIfNeeded()
        client.requestList()
        apply(client.torrents)
    }

    /// Stop receiving updates (the daemon keeps running so downloads continue). Call when hidden.
    func deactivate() {
        active = false
        if client.onUpdate != nil { client.onUpdate = nil }
        client.onError = nil
    }

    // MARK: layout

    private func build() {
        background.material = .underWindowBackground
        background.blendingMode = .withinWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false

        for (button, symbol, tip, action) in [
            (addButton, "doc.badge.plus", L("torrents.add", "Add Torrent…"), #selector(addTapped)),
            (magnetButton, "link.badge.plus", L("torrents.addMagnet", "Add Magnet…"), #selector(addMagnetTapped)),
            (pauseButton, "pause.fill", L("torrents.pause", "Pause"), #selector(pauseResumeTapped)),
            (removeButton, "trash", L("torrents.remove", "Remove…"), #selector(removeTapped)),
            (limitsButton, "gauge.with.dots.needle.33percent", L("torrents.limits", "Speed Limits…"), #selector(limitsTapped)),
        ] as [(NSButton, String, String, Selector)] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.bezelStyle = .texturedRounded
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = tip
            button.target = self
            button.action = action
        }

        let title = NSTextField(labelWithString: L("torrents.title", "Torrents"))
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let controls = NSStackView(views: [title, NSView(), magnetButton, addButton, pauseButton, removeButton, limitsButton])
        controls.orientation = .horizontal
        controls.spacing = 6
        controls.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        controls.translatesAutoresizingMaskIntoConstraints = false

        let columns: [(String, String, CGFloat)] = [
            ("name", L("torrents.col.name", "Name"), 220),
            ("progress", L("torrents.col.progress", "Progress"), 130),
            ("down", L("torrents.col.down", "Down"), 76),
            ("up", L("torrents.col.up", "Up"), 76),
            ("eta", L("torrents.col.eta", "ETA"), 74),
            ("ratio", L("torrents.col.ratio", "Ratio"), 54),
            ("peers", L("torrents.col.peers", "Peers"), 46),
            ("state", L("torrents.col.state", "Status"), 116),
        ]
        for (id, heading, width) in columns {
            let column = NSTableColumn(identifier: .init(id))
            column.title = heading
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.rowHeight = 26
        table.target = self
        table.doubleAction = #selector(revealInFinder)
        table.allowsEmptySelection = true

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.stringValue = L("torrents.empty.short", "No torrents. Add a magnet or a .torrent file.")
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(background)
        background.addSubview(controls)
        background.addSubview(scroll)
        background.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: view.topAnchor),
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controls.topAnchor.constraint(equalTo: background.topAnchor),
            controls.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        updateButtons()
    }

    // MARK: data

    private func apply(_ statuses: [TorrentSession.Status]) {
        let keep = selected()?.infoHash
        rows = statuses.sorted { $0.name < $1.name }
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        onSelect?(selected())
    }

    private func updateButtons() {
        let sel = selected()
        pauseButton.isEnabled = sel != nil
        removeButton.isEnabled = sel != nil
        let paused = sel?.state == .paused
        pauseButton.image = NSImage(
            systemSymbolName: paused ? "play.fill" : "pause.fill",
            accessibilityDescription: paused ? L("torrents.resume", "Resume") : L("torrents.pause", "Pause"))
    }

    /// A magnet that hasn't fetched its metadata yet: no file info, so no real progress to show.
    private func isFetchingMetadata(_ status: TorrentSession.Status) -> Bool {
        status.state == .checking && status.totalLength == 0
    }

    // MARK: table view

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < rows.count else { return nil }
        let status = rows[row]

        if tableColumn.identifier.rawValue == "progress" {
            // A metadata-fetching magnet has no determinate progress; show a barber-pole so it reads
            // as working, not stuck at 0%.
            if isFetchingMetadata(status) {
                let id = NSUserInterfaceItemIdentifier("fetching")
                let spinner = (tableView.makeView(withIdentifier: id, owner: self) as? NSProgressIndicator) ?? {
                    let p = NSProgressIndicator()
                    p.identifier = id
                    p.style = .bar
                    p.isIndeterminate = true
                    p.controlSize = .small
                    return p
                }()
                spinner.startAnimation(nil)
                return spinner
            }
            let id = NSUserInterfaceItemIdentifier("progress")
            let bar = (tableView.makeView(withIdentifier: id, owner: self) as? TorrentProgressBar) ?? {
                let b = TorrentProgressBar()
                b.identifier = id
                return b
            }()
            bar.fraction = status.fractionComplete
            bar.seeding = status.state == .seeding
            return bar
        }

        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
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
        cell.textField?.font =
            tableColumn.identifier.rawValue == "name"
            ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        return cell
    }

    private func value(for status: TorrentSession.Status, column: String) -> String {
        switch column {
        case "name": return status.name
        case "down":
            return status.downloadRate > 1 ? "\(Self.size.string(fromByteCount: Int64(status.downloadRate)))/s" : "—"
        case "up":
            return status.uploadRate > 1 ? "\(Self.size.string(fromByteCount: Int64(status.uploadRate)))/s" : "—"
        case "eta": return TorrentsWindowController.etaLabel(status.etaSeconds)
        case "ratio": return status.downloaded > 0 ? String(format: "%.2f", status.ratio) : "—"
        case "peers": return "\(status.peersConnected)"
        case "state": return stateLabel(status)
        default: return ""
        }
    }

    private func stateLabel(_ status: TorrentSession.Status) -> String {
        if isFetchingMetadata(status) { return L("torrents.state.fetchingMeta", "Fetching details…") }
        switch status.state {
        case .downloading:
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

    // MARK: actions

    @objc private func addTapped() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["torrent"]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L("torrents.add.prompt", "Add")
        guard panel.runModal() == .OK else { return }
        client.startIfNeeded()
        let savePath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        for url in panel.urls { client.addTorrent(fileAt: url.path, savePath: savePath) }
    }

    @objc private func addMagnetTapped() {
        let alert = NSAlert()
        alert.messageText = L("torrents.addMagnet.title", "Add Magnet Link")
        alert.informativeText = L("torrents.addMagnet.message", "Paste a magnet link. Pathem fetches its details from peers, then downloads to your Downloads folder.")
        alert.addButton(withTitle: L("torrents.add.prompt", "Add"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "magnet:?xt=urn:btih:…"
        if let clip = NSPasteboard.general.string(forType: .string), clip.hasPrefix("magnet:") { field.stringValue = clip }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let uri = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard uri.hasPrefix("magnet:") else {
            if !uri.isEmpty { showError(L("torrents.addMagnet.invalid", "That doesn't look like a magnet link.")) }
            return
        }
        client.startIfNeeded()
        let savePath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        client.addMagnet(uri, savePath: savePath)
    }

    @objc private func pauseResumeTapped() {
        guard let sel = selected() else { return }
        if sel.state == .paused { client.resume(sel.infoHash) } else { client.pause(sel.infoHash) }
    }

    @objc private func removeTapped() {
        guard let sel = selected(), let window = hostWindow ?? view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(format: L("torrents.remove.confirm", "Remove “%@”?"), sel.name)
        alert.informativeText = L("torrents.remove.info", "You can keep the downloaded files or delete them.")
        alert.addButton(withTitle: L("torrents.remove.keep", "Remove, Keep Files"))
        alert.addButton(withTitle: L("torrents.remove.delete", "Remove and Delete Files"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.client.remove(sel.infoHash, deleteData: false)
            case .alertSecondButtonReturn: self?.client.remove(sel.infoHash, deleteData: true)
            default: break
            }
        }
    }

    @objc private func limitsTapped() {
        TorrentLimitsSheet.present(over: hostWindow ?? view.window, client: client)
    }

    @objc private func revealInFinder() {
        guard let sel = selected() else { return }
        let target = URL(fileURLWithPath: sel.savePath).appendingPathComponent(sel.name)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func showError(_ message: String) {
        guard let window = hostWindow ?? view.window else { return }
        let alert = NSAlert()
        alert.messageText = L("torrents.error", "Couldn’t add torrent")
        alert.informativeText = message
        alert.addButton(withTitle: L("common.ok", "OK"))
        alert.beginSheetModal(for: window) { _ in }
    }

    private static let size: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
}
