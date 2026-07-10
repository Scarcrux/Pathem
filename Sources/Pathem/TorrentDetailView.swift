import AppKit
import TorrentKit

/// The torrent detail view: shown over the browser's pane area when you open a torrent from the
/// drawer. Four tabs -- Overview, Files, Peers, Trackers -- refreshed on a timer from the daemon.
/// A close button returns to the file browser.
@MainActor
final class TorrentDetailView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let client = TorrentDaemonClient.shared
    private let titleLabel = NSTextField(labelWithString: "")
    private let tabs = NSSegmentedControl()

    private let overview = NSStackView()
    private let filesTable = NSTableView()
    private let peersTable = NSTableView()
    private let trackersTable = NSTableView()
    private let filesScroll = NSScrollView()
    private let peersScroll = NSScrollView()
    private let trackersScroll = NSScrollView()

    private var infoHash = ""
    private var files: [TorrentSession.FileInfo] = []
    private var peers: [TorrentSession.PeerInfo] = []
    private var trackers: [String] = []
    private var refresh: Timer?

    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        ThemeManager.shared.onChange(owner: self) { [weak self] in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    // MARK: build

    private func build() {
        wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle

        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("common.close", "Close"))!, target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.toolTip = L("torrents.detail.close", "Back to files")

        tabs.segmentStyle = .automatic
        tabs.trackingMode = .selectOne
        let names = [
            L("torrents.detail.overview", "Overview"), L("torrents.detail.files", "Files"),
            L("torrents.detail.peers", "Peers"), L("torrents.detail.trackers", "Trackers"),
        ]
        tabs.segmentCount = names.count
        for (i, n) in names.enumerated() { tabs.setLabel(n, forSegment: i) }
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)

        let header = NSStackView(views: [close, titleLabel, NSView(), tabs])
        header.orientation = .horizontal
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        header.translatesAutoresizingMaskIntoConstraints = false

        overview.orientation = .vertical
        overview.alignment = .leading
        overview.spacing = 6
        overview.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        overview.translatesAutoresizingMaskIntoConstraints = false

        setupTable(filesTable, filesScroll, [
            ("wanted", "", 26), ("path", L("torrents.col.name", "Name"), 360),
            ("size", L("torrents.col.size", "Size"), 100),
        ])
        setupTable(peersTable, peersScroll, [
            ("address", L("torrents.detail.address", "Address"), 180),
            ("client", L("torrents.detail.client", "Client"), 160),
            ("progress", L("torrents.col.progress", "Progress"), 90),
            ("flags", L("torrents.detail.flags", "Flags"), 120),
        ])
        setupTable(trackersTable, trackersScroll, [("url", L("torrents.detail.source", "Source"), 480)])

        addSubview(header)
        for v in [overview, filesScroll, peersScroll, trackersScroll] {
            addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: header.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: leadingAnchor),
                v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            v.isHidden = true
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        overview.isHidden = false
    }

    private func setupTable(_ table: NSTableView, _ scroll: NSScrollView, _ cols: [(String, String, CGFloat)]) {
        for (id, heading, width) in cols {
            let c = NSTableColumn(identifier: .init(id))
            c.title = heading
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .inset
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: show / refresh

    func show(_ status: TorrentSession.Status) {
        infoHash = status.infoHash
        titleLabel.stringValue = status.name
        client.onFiles = { [weak self] hash, files in
            guard let self, hash == self.infoHash else { return }
            self.files = files
            self.filesTable.reloadData()
        }
        client.onDetails = { [weak self] hash, peers, trackers in
            guard let self, hash == self.infoHash else { return }
            self.peers = peers
            self.trackers = trackers
            self.peersTable.reloadData()
            self.trackersTable.reloadData()
        }
        renderOverview(status)
        client.requestFiles(infoHash)
        client.requestDetails(infoHash)
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func hide() {
        refresh?.invalidate()
        refresh = nil
        client.onFiles = nil
        client.onDetails = nil
    }

    private func tick() {
        guard let status = client.torrents.first(where: { $0.infoHash == infoHash }) else { return }
        renderOverview(status)
        client.requestDetails(infoHash)
        if files.isEmpty { client.requestFiles(infoHash) }
    }

    private func renderOverview(_ s: TorrentSession.Status) {
        overview.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func row(_ label: String, _ value: String) {
            let l = NSTextField(labelWithString: label)
            l.textColor = .secondaryLabelColor
            l.font = .systemFont(ofSize: 12)
            l.setContentHuggingPriority(.required, for: .horizontal)
            l.widthAnchor.constraint(equalToConstant: 140).isActive = true
            let v = NSTextField(labelWithString: value)
            v.font = .systemFont(ofSize: 12, weight: .medium)
            v.lineBreakMode = .byTruncatingMiddle
            let r = NSStackView(views: [l, v])
            r.orientation = .horizontal
            r.spacing = 8
            overview.addArrangedSubview(r)
        }
        let pct = String(format: "%.1f%%", s.fractionComplete * 100)
        let state = s.state == .seeding ? L("torrents.state.seeding", "Seeding")
            : (s.state == .paused ? L("torrents.state.paused", "Paused")
                : (s.totalLength == 0 ? L("torrents.state.fetchingMeta", "Fetching details…")
                    : L("torrents.state.downloading", "Downloading")))
        row(L("torrents.detail.status", "Status"), state)
        row(L("torrents.detail.progress", "Progress"), "\(pct)  (\(Self.size.string(fromByteCount: s.downloaded)) of \(Self.size.string(fromByteCount: s.totalLength)))")
        row(L("torrents.col.down", "Down"), s.downloadRate > 1 ? "\(Self.size.string(fromByteCount: Int64(s.downloadRate)))/s" : "—")
        row(L("torrents.col.up", "Up"), s.uploadRate > 1 ? "\(Self.size.string(fromByteCount: Int64(s.uploadRate)))/s" : "—")
        row(L("torrents.col.eta", "ETA"), TorrentsWindowController.etaLabel(s.etaSeconds))
        row(L("torrents.col.ratio", "Ratio"), s.downloaded > 0 ? String(format: "%.2f", s.ratio) : "—")
        row(L("torrents.detail.uploaded", "Uploaded"), Self.size.string(fromByteCount: s.uploaded))
        row(L("torrents.col.peers", "Peers"), "\(s.peersConnected)")
        row(L("torrents.detail.savePath", "Location"), s.savePath)
    }

    // MARK: actions

    @objc private func closeTapped() { onClose?() }
    @objc private func tabChanged() {
        let i = tabs.selectedSegment
        overview.isHidden = i != 0
        filesScroll.isHidden = i != 1
        peersScroll.isHidden = i != 2
        trackersScroll.isHidden = i != 3
    }

    @objc private func toggleWanted(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0, idx < files.count else { return }
        files[idx].wanted = sender.state == .on
        client.setFiles(infoHash, wanted: files.enumerated().filter { $0.element.wanted }.map(\.offset))
    }

    // MARK: table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case filesTable: return files.count
        case peersTable: return peers.count
        case trackersTable: return trackers.count
        default: return 0
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn?.identifier.rawValue else { return nil }
        if tableView == filesTable, col == "wanted" {
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleWanted(_:)))
            check.tag = row
            check.state = files[row].wanted ? .on : .off
            return check
        }
        let text: String
        switch tableView {
        case filesTable:
            let f = files[row]
            text = col == "size" ? Self.size.string(fromByteCount: f.length) : f.path
        case peersTable:
            let p = peers[row]
            switch col {
            case "address": text = p.address
            case "client": text = p.client
            case "progress": text = String(format: "%.0f%%", p.progress * 100)
            default:
                var flags: [String] = []
                if p.encrypted { flags.append(L("torrents.detail.enc", "encrypted")) }
                flags.append(p.choked ? L("torrents.detail.choked", "choked") : L("torrents.detail.active", "active"))
                text = flags.joined(separator: ", ")
            }
        case trackersTable: text = trackers[row]
        default: text = ""
        }
        return cell(text, mono: tableView != filesTable && col != "path")
    }

    private func cell(_ string: String, mono: Bool) -> NSView {
        let f = NSTextField(labelWithString: string)
        f.lineBreakMode = .byTruncatingMiddle
        f.font = mono ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
        return f
    }

    private static let size: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
}
