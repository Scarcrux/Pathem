import AppKit
import PathemEngine

/// A Storage-style Cleanup panel: scans a folder for reclaimable space (junk,
/// duplicates, large, old), lets the user check items and move them to the Trash
/// (reversible), and — on macOS 26 with Apple Intelligence — asks the on-device model
/// to recommend which are safe. Junk + duplicates are pre-checked; large/old are
/// review-only.
@MainActor
final class CleanupController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate
{
    /// Asks the browser to run its Empty Trash flow (confirmation included); the argument is
    /// called once the Trash has been emptied, so the disk bar can show the space freed.
    var onEmptyTrash: ((@escaping () -> Void) -> Void)?
    /// Called with the items Cleanup moved to the Trash, so the browser can record their origins
    /// (Put Back) and register an undo, like the other trash flows.
    var onTrashed: (([FileOperations.Trashed]) -> Void)?
    private struct Row {
        let group: StorageScan.Group
        var checked: Bool
        /// Set for a known place from the catalog (sized directly, not found by a scan).
        var candidate: ReclaimCatalog.Candidate?
        /// A single item, or the first of a folded group (for the icon and Reveal).
        var item: StorageScan.Item { group.items[0] }
        var size: Int64 { group.size }
        var key: String {
            if let candidate { return "place:" + candidate.place.id }
            return group.isSingle ? item.path : "group:\(group.category.rawValue):\(group.kind)"
        }
    }

    /// Items at least this big get their own row; smaller ones of the same kind fold together.
    private static let individualJunkBytes: Int64 = 100_000_000
    private static let individualDuplicateBytes: Int64 = 10_000_000

    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: L("cleanup.title", "Cleanup"))
    private let summaryLabel = NSTextField(labelWithString: "")
    private let diskBar = NSProgressIndicator()
    private let diskLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let spinner = NSProgressIndicator()
    private let aiButton = NSButton()
    private let trashButton = NSButton()
    private let stopButton = NSButton()
    private let deleteNowButton = NSButton()
    private let deepScanButton = NSButton()
    /// Known places found on this disk, and the sizes measured so far.
    private var candidates: [ReclaimCatalog.Candidate] = []
    private var placeSizes: [String: Int64] = [:]
    private var placesMeasured = 0
    private var home = FileManager.default.homeDirectoryForCurrentUser
    /// Catalog places smaller than this are not worth a row.
    private static let minimumPlaceBytes: Int64 = 50_000_000
    private let gen = GenerationBox()
    /// Bumped by Stop: the walk ends early but keeps what it found (unlike `gen`, which
    /// discards a superseded scan).
    private let stopBox = GenerationBox()
    private var rows: [Row] = []
    /// The shared behavior log, loaded at scan time so pre-checking reflects what the
    /// user tends to remove vs keep.
    private var memory = OrganizeFeedback()

    // Detail pane for the selected item.
    private let detailName = NSTextField(labelWithString: "")
    private let detailPath = NSTextField(labelWithString: "")
    private let detailWhy = NSTextField(wrappingLabelWithString: "")
    private let feedbackNote = NSTextField(labelWithString: "")
    private let goodButton = NSButton()
    private let badButton = NSButton()
    private var root = URL(fileURLWithPath: NSHomeDirectory())
    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
            defer: true)
        super.init()
        panel.title = L("reclaim.windowTitle", "Reclaim Space")
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 700, height: 480)
        panel.delegate = self
        build()
    }

    /// True once the panel's content (including the detail pane) has been built, for the
    /// layout smoke check.
    var debugContentReady: Bool { (panel.contentView?.subviews.isEmpty == false) }

    /// Smoke hooks: load a report as if a scan had finished, read the rows back, and trash.
    func debugLoad(_ report: StorageScan.Report, root: URL) {
        self.root = root
        candidates = []
        placeSizes = [:]
        quickReport = report
        rebuildRows()
        updateSummary()
    }
    var debugRows: [(title: String, count: Int, size: Int64, checked: Bool)] {
        rows.map { (Self.title(for: $0.group), $0.group.items.count, $0.size, $0.checked) }
    }
    var debugSummary: String { summaryLabel.stringValue }
    var debugTrashNote: String { lastTrashNote }
    func debugTrashChecked() { trashChecked() }
    /// Load known places under a (temporary) home with their real sizes, synchronously.
    func debugLoadPlaces(home: URL, minimumBytes: Int64) {
        self.home = home
        debugMinimumPlaceBytes = minimumBytes
        candidates = ReclaimCatalog.candidates(home: home)
        placeSizes = Dictionary(
            uniqueKeysWithValues: candidates.map {
                ($0.place.id, DirectorySize.total(of: $0.url).bytes)
            })
        placesMeasured = candidates.count
        rebuildRows()
        updateSummary()
    }
    private var debugMinimumPlaceBytes: Int64?
    func debugCheck(title: String) {
        guard let index = rows.firstIndex(where: { rowTitle($0) == title }) else { return }
        rows[index].checked = true
        updateSummary()
    }
    var debugPlaceRows: [(title: String, what: String, size: Int64, checked: Bool)] {
        rows.filter { $0.candidate != nil }.map {
            (rowTitle($0), whatHappens($0), $0.size, $0.checked)
        }
    }
    var debugDeleteNowEnabled: Bool { deleteNowButton.isEnabled }
    #if DEBUG
    var debugTransientWindow: NSWindow { panel }
    var debugTransientDeletePending: Bool { deletingNames != nil }
    private(set) var debugTransientLastResponse: NSApplication.ModalResponse?
    private(set) var debugTransientLastAlert: NSAlert?
    func debugTransientPresentDeleteNow() {
        panel.makeKeyAndOrderFront(nil)
        deleteNowClicked()
    }
    #endif
    var debugPlacesDone: Bool { !candidates.isEmpty && placesMeasured >= candidates.count }
    /// Save a picture of the window's content, to check the layout without a screen recording.
    func debugRender(to path: String) {
        guard let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // cacheDisplay draws the views on a transparent backing, so in Dark Mode the light
        // header text and button titles vanish against a white page. Put the window's own
        // background underneath, as the real window does.
        guard
            let out = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: out)
        else { return }
        out.size = rep.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: rep.size).fill()
        }
        rep.draw(
            in: NSRect(origin: .zero, size: rep.size), from: .zero, operation: .sourceOver,
            fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: path))
    }
    /// Delete the checked rebuilds-tier places as the confirmed button does, synchronously.
    func debugDeleteNowConfirmed() -> [String] {
        let targets = deletableNow.compactMap(\.candidate)
        var failed: [String] = []
        for candidate in targets {
            do { try ReclaimCatalog.deleteNow(candidate, home: home) } catch {
                failed.append(candidate.place.name)
            }
        }
        finishDeleteNow(targets, failures: failed)
        return failed
    }

    func present(for url: URL, over window: NSWindow?) {
        root = url
        #if DEBUG
        if ProcessInfo.processInfo.environment["PATHEM_TRANSIENT_SURFACES_TEST"] != nil {
            home = url
        }
        #endif
        if !panel.isVisible { panel.centerOverMainWindow() }
        panel.makeKeyAndOrderFront(nil)
        updateDiskStats()  // instant: overall capacity/used/free
        // The folder name goes in the tooltip: in the title it made the button row wider
        // than the window.
        deepScanButton.title = L("reclaim.deepScanShort", "Deep Scan…")
        deepScanButton.toolTip =
            String(format: L("reclaim.deepScan", "Deep Scan “%@”…"), url.lastPathComponent)
            + "\n"
            + L(
                "reclaim.deepScanTip",
                "Walk this folder for project build folders, large and old files, and duplicates. Can take minutes on a big folder."
            )
        quickReport = nil
        lastTrashNote = ""
        #if DEBUG
        if ProcessInfo.processInfo.environment["PATHEM_TRANSIENT_SURFACES_TEST"] != nil {
            debugLoadPlaces(home: url, minimumBytes: 1)
            return
        }
        #endif
        measurePlaces()
    }

    /// Size the known places, a few at a time, showing each row as soon as it is measured.
    /// This is the default view: seconds, where walking the whole disk takes minutes.
    private func measurePlaces() {
        let generation = gen.bump()
        home = FileManager.default.homeDirectoryForCurrentUser
        candidates = ReclaimCatalog.candidates(home: home)
        // Show the sizes measured last time at once, then refresh each in the background:
        // the first uncached read of a very large folder takes minutes.
        let remembered = Self.loadRememberedSizes()
        placeSizes = remembered.filter { id, _ in candidates.contains { $0.place.id == id } }
        placesMeasured = 0
        // The window's title bar already says "Reclaim Space"; the label is for scan status.
        titleLabel.stringValue = ""
        titleLabel.isHidden = true
        rebuildRows()
        updateSummary()
        guard !candidates.isEmpty else { return }
        spinner.startAnimation(nil)
        let pending = candidates
        let gen = self.gen
        Task { [weak self] in
            await withTaskGroup(of: (String, Int64).self) { group in
                var next = 0
                func add() {
                    guard next < pending.count else { return }
                    let candidate = pending[next]
                    next += 1
                    group.addTask(priority: .utility) {
                        // Closing the window (or a newer run) stops the walk part-way.
                        let size = DirectorySize.total(
                            of: candidate.url, isCancelled: { !gen.isCurrent(generation) })
                        return (candidate.place.id, size?.bytes ?? -1)
                    }
                }
                for _ in 0..<4 { add() }
                for await (id, bytes) in group {
                    add()
                    guard let self, gen.isCurrent(generation), bytes >= 0 else { continue }
                    self.placeSizes[id] = bytes
                    self.placesMeasured += 1
                    self.rebuildRows()
                    self.updateSummary()
                    // Per result, so closing the window mid-run keeps what was measured.
                    Self.saveRememberedSizes(self.placeSizes)
                }
            }
            guard let self, gen.isCurrent(generation) else { return }
            if self.quickReport == nil { self.spinner.stopAnimation(nil) }
            self.updateSummary()
            Self.saveRememberedSizes(self.placeSizes)
        }
    }

    private static func rememberedSizesURL() -> URL? {
        ConfigStore.directory()?.appendingPathComponent("reclaim-sizes.json")
    }

    private static func loadRememberedSizes() -> [String: Int64] {
        guard let url = rememberedSizesURL(), let data = try? Data(contentsOf: url) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: Int64].self, from: data)) ?? [:]
    }

    private static func saveRememberedSizes(_ sizes: [String: Int64]) {
        guard let url = rememberedSizesURL(), let data = try? JSONEncoder().encode(sizes) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    /// Volume capacity, used, and free for the scanned folder's disk (like the macOS
    /// Storage summary). Instant via the file system, so it shows immediately.
    private func updateDiskStats() {
        let values = try? root.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let total = values?.volumeTotalCapacity, total > 0 else {
            diskLabel.stringValue = ""
            diskBar.isHidden = true
            return
        }
        let free = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        let used = max(0, Int64(total) - free)
        diskBar.isHidden = false
        diskBar.doubleValue = Double(used) / Double(total)
        diskLabel.stringValue = String(
            format: L("cleanup.diskUsage", "%@ used of %@ · %@ free"),
            byteFormatter.string(fromByteCount: used),
            byteFormatter.string(fromByteCount: Int64(total)),
            byteFormatter.string(fromByteCount: free))
    }

    // MARK: Build

    private func build() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        diskBar.style = .bar
        diskBar.isIndeterminate = false
        diskBar.minValue = 0
        diskBar.maxValue = 1
        diskBar.controlSize = .small
        diskLabel.font = .systemFont(ofSize: 11)
        diskLabel.textColor = .secondaryLabelColor

        for (id, title, width) in [
            ("check", "", CGFloat(24)), ("name", L("cleanup.colItem", "Item"), 280),
            ("size", L("cleanup.colSize", "Size"), 90),
            ("category", L("reclaim.colWhat", "What happens if you delete it"), 250),
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        aiButton.title = L("cleanup.recommendWithAI", "Recommend with AI")
        aiButton.bezelStyle = .rounded
        aiButton.target = self
        aiButton.action = #selector(recommendWithAI)
        trashButton.title = L("cleanup.moveCheckedToTrash", "Move Checked to Trash")
        trashButton.bezelStyle = .rounded
        trashButton.keyEquivalent = "\r"
        trashButton.target = self
        trashButton.action = #selector(trashChecked)
        let reveal = NSButton(
            title: L("cleanup.reveal", "Reveal"), target: self, action: #selector(revealSelected))
        reveal.bezelStyle = .rounded
        let systemSettings = NSButton(
            title: L("cleanup.systemStorage", "System Storage…"), target: self,
            action: #selector(openSystemStorage))
        systemSettings.bezelStyle = .rounded
        systemSettings.toolTip = L(
            "cleanup.systemStorageTip",
            "Open Storage in System Settings (for app, photo, and system categories)")

        stopButton.title = L("cleanup.stop", "Stop")
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.target = self
        stopButton.action = #selector(stopScan)
        stopButton.isHidden = true
        let emptyTrash = NSButton(
            title: L("cleanup.emptyTrash", "Empty Trash…"), target: self,
            action: #selector(emptyTrashClicked))
        emptyTrash.bezelStyle = .rounded
        emptyTrash.toolTip = L(
            "cleanup.emptyTrashTip",
            "Items moved to the Trash still take up space until the Trash is emptied")

        let header = NSStackView(views: [titleLabel, summaryLabel, spinner, stopButton, NSView()])
        header.orientation = .horizontal
        header.spacing = 8
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let diskStats = NSStackView(views: [diskBar, diskLabel])
        diskStats.orientation = .vertical
        diskStats.alignment = .leading
        diskStats.spacing = 3
        deleteNowButton.title = L("reclaim.deleteNow", "Delete Now…")
        deleteNowButton.bezelStyle = .rounded
        deleteNowButton.target = self
        deleteNowButton.action = #selector(deleteNowClicked)
        deleteNowButton.isEnabled = false
        deleteNowButton.toolTip = L(
            "reclaim.deleteNowTip",
            "Permanently delete the checked items that rebuild automatically, skipping the Trash")
        deepScanButton.bezelStyle = .rounded
        deepScanButton.target = self
        deepScanButton.action = #selector(deepScanClicked)
        let actions = NSStackView(
            views: [
                deepScanButton, aiButton, systemSettings, NSView(), reveal, emptyTrash,
                deleteNowButton, trashButton,
            ])
        actions.orientation = .horizontal
        actions.spacing = 8

        let detail = buildDetailPane()

        let root = NSStackView(views: [header, diskStats, scroll, detail, actions])
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(root)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
                diskStats.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
                detail.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
                actions.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
                header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28),
                diskBar.widthAnchor.constraint(equalTo: diskStats.widthAnchor),
            ])
        }
        clearDetail()
    }

    /// A detail pane below the list: the selected item's full path, why it was flagged,
    /// and good/bad feedback (the same learning signal the organizer records).
    private func buildDetailPane() -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.fillColor = .quaternaryLabelColor.withAlphaComponent(0.25)
        box.borderColor = .separatorColor
        box.cornerRadius = 8
        box.titlePosition = .noTitle
        box.contentViewMargins = NSSize(width: 12, height: 10)

        detailName.font = .systemFont(ofSize: 13, weight: .semibold)
        detailName.lineBreakMode = .byTruncatingMiddle
        detailPath.font = .systemFont(ofSize: 11)
        detailPath.textColor = .secondaryLabelColor
        detailPath.lineBreakMode = .byTruncatingMiddle
        detailPath.isSelectable = true
        detailWhy.font = .systemFont(ofSize: 11)
        detailWhy.textColor = .secondaryLabelColor
        detailWhy.maximumNumberOfLines = 2
        feedbackNote.font = .systemFont(ofSize: 11)
        feedbackNote.textColor = .tertiaryLabelColor

        goodButton.title = L("organize.review.good", "Good")
        goodButton.image = NSImage(systemSymbolName: "hand.thumbsup", accessibilityDescription: nil)
        badButton.title = L("cleanup.keep", "Keep it")
        badButton.image = NSImage(
            systemSymbolName: "hand.thumbsdown", accessibilityDescription: nil)
        for (button, action) in [
            (goodButton, #selector(markGood)), (badButton, #selector(markBad)),
        ] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.imagePosition = .imageLeading
            button.target = self
            button.action = action
        }

        let buttons = NSStackView(views: [goodButton, badButton, feedbackNote])
        buttons.spacing = 8
        buttons.alignment = .centerY
        let stack = NSStackView(views: [detailName, detailPath, detailWhy, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor),
            detailWhy.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        box.heightAnchor.constraint(equalToConstant: 104).isActive = true
        return box
    }

    // MARK: Scan

    private var quickReport: StorageScan.Report?
    /// Shown after trashing: the space is not free until the Trash is emptied.
    private var lastTrashNote = ""

    /// Two-phase so results appear fast: the walk (junk/caches/large/old) covers the whole
    /// folder with live progress, then the slower duplicate analysis fills in. Stop ends the
    /// walk early and keeps what was found, clearly marked as partial.
    private func scan() {
        titleLabel.stringValue = String(
            format: L("cleanup.scanning", "Scanning %@…"), root.lastPathComponent)
        titleLabel.isHidden = false
        summaryLabel.stringValue = L("cleanup.phaseScanning", "Scanning files…")
        quickReport = nil
        lastTrashNote = ""
        memory = Self.feedbackURL().map { OrganizeFeedback.load(from: $0) } ?? OrganizeFeedback()
        rebuildRows()
        spinner.startAnimation(nil)
        stopButton.isHidden = false
        deepScanButton.isEnabled = false
        let generation = gen.bump()
        let stopToken = stopBox.bump()
        let url = root
        let gen = self.gen
        let stopBox = self.stopBox
        // Main-actor Task so `self` never crosses an isolation boundary; the blocking scans run
        // on detached tasks that capture only Sendable values.
        Task { [weak self] in
            let quick = await Task.detached(priority: .utility) {
                StorageScan.scanQuick(
                    url,
                    progress: { count in
                        Task { @MainActor [weak self] in
                            guard let self, gen.isCurrent(generation) else { return }
                            self.summaryLabel.stringValue = String(
                                format: L("cleanup.progress", "Scanned %@ items…"),
                                Self.countText(count))
                        }
                    },
                    isCancelled: { !gen.isCurrent(generation) || !stopBox.isCurrent(stopToken) })
            }.value
            guard let self, self.gen.isCurrent(generation) else { return }
            self.applyQuick(quick)
            guard !quick.truncated else {
                self.applyDuplicates([])
                return
            }
            let dups = await Task.detached(priority: .utility) { StorageScan.duplicates(url) }.value
            guard self.gen.isCurrent(generation) else { return }
            self.applyDuplicates(dups)
        }
    }

    @objc private func stopScan() { _ = stopBox.bump() }
    @objc private func deepScanClicked() { scan() }

    /// Closing the panel abandons a running scan instead of letting it walk the disk unseen.
    func windowWillClose(_ notification: Notification) {
        _ = gen.bump()
        spinner.stopAnimation(nil)
        stopButton.isHidden = true
    }

    /// Coming back to the panel (after emptying the Trash elsewhere, say) shows current space.
    func windowDidBecomeKey(_ notification: Notification) { updateDiskStats() }

    private static func countText(_ count: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }

    private func applyQuick(_ report: StorageScan.Report) {
        quickReport = report
        titleLabel.stringValue = String(
            format: L("cleanup.titleFor", "Cleanup: %@"), root.lastPathComponent)
        titleLabel.isHidden = false
        rebuildRows()
        updateSummary(extra: " · " + L("cleanup.phaseDuplicates", "analyzing duplicates…"))
    }

    private func applyDuplicates(_ items: [StorageScan.Item]) {
        spinner.stopAnimation(nil)
        stopButton.isHidden = true
        deepScanButton.isEnabled = true
        quickReport?.duplicates = items
        rebuildRows()
        updateSummary()
    }

    /// What the scan did not cover, said plainly: a walk stopped early, or a duplicate pass
    /// that only examines the first files of a very large folder.
    private var coverageNote: String {
        guard let report = quickReport else { return "" }
        if report.truncated {
            return String(
                format: L(
                    "cleanup.stoppedPartial",
                    " · stopped early, results are partial (%@ items scanned)"),
                Self.countText(report.itemsScanned))
        }
        if report.filesScanned > StorageScan.duplicateFileLimit {
            return String(
                format: L("cleanup.dupPartial", " · duplicates checked in the first %@ files only"),
                Self.countText(StorageScan.duplicateFileLimit))
        }
        return ""
    }

    /// Rebuild the row list from the latest report, preserving any check toggles the
    /// user made while the scan was still running.
    private func rebuildRows() {
        let priorChecked = Dictionary(
            rows.map { ($0.key, $0.checked) }, uniquingKeysWith: { a, _ in a })
        // Known places first: measured so far, big enough to matter, biggest first. They are
        // never pre-checked; the user decides.
        let minimum = debugMinimumPlaceBytes ?? Self.minimumPlaceBytes
        let placeRows: [Row] = candidates.compactMap { candidate -> Row? in
            guard let bytes = placeSizes[candidate.place.id], bytes >= minimum else { return nil }
            let item = StorageScan.Item(
                path: candidate.url.path, size: bytes, category: .cache,
                reason: candidate.place.name, isDirectory: true)
            var row = Row(
                group: .init(category: .cache, kind: candidate.place.name, items: [item]),
                checked: false, candidate: candidate)
            row.checked = priorChecked[row.key] ?? false
            return row
        }.sorted { $0.size > $1.size }
        guard var report = quickReport else {
            rows = placeRows
            table.reloadData()
            return
        }
        // The deep scan must not list a known place a second time (or its parent or contents).
        for keyPath in [
            \StorageScan.Report.junk, \.duplicates, \.caches, \.large, \.old,
        ] {
            report[keyPath: keyPath].removeAll {
                ReclaimCatalog.overlaps($0.path, with: candidates)
            }
        }
        func row(_ group: StorageScan.Group) -> Row {
            // Keep any toggle the user already made; otherwise use the learned default.
            var row = Row(group: group, checked: false)
            row.checked = priorChecked[row.key] ?? defaultChecked(for: group.category)
            return row
        }
        // Safe-to-remove first, then review-only; biggest first within each section, with small
        // items of one kind folded into a single row.
        let groups =
            StorageScan.grouped(report.junk, individualAtLeast: Self.individualJunkBytes)
            + StorageScan.grouped(
                report.duplicates, individualAtLeast: Self.individualDuplicateBytes)
            + StorageScan.grouped(report.caches, individualAtLeast: Self.individualJunkBytes)
            + StorageScan.grouped(report.large, individualAtLeast: 0)
            + StorageScan.grouped(report.old, individualAtLeast: 0)
        rows = placeRows + groups.map(row)
        table.reloadData()
    }

    /// Junk and duplicates start checked; large and old start unchecked. The learned
    /// signal for the category nudges that, so a category you consistently remove becomes
    /// pre-checked and one you consistently keep does not.
    private func defaultChecked(for category: StorageScan.Category) -> Bool {
        // Caches are review-only whatever was learned: apps rebuild them, but some hold
        // downloads or offline data.
        category != .cache && base(for: category) + learnedBias(for: category) >= 0.5
    }

    private func base(for category: StorageScan.Category) -> Double {
        switch category {
        case .junk, .duplicate: return 0.8
        case .large, .old, .cache: return 0.2
        }
    }

    /// Positive means the user tends to remove this category (nudge toward checked);
    /// negative means they tend to keep it. Bounded like the organizer's nudge.
    private func learnedBias(for category: StorageScan.Category) -> Double {
        min(0.35, max(-0.35, Double(memory.score(ruleID: "cleanup:\(category.rawValue)")) * 0.04))
    }

    private func updateSummary(extra: String = "") {
        let checked = rows.filter(\.checked).reduce(Int64(0)) { $0 + $1.size }
        func total(_ tier: ReclaimCatalog.Consequence) -> Int64 {
            rows.filter { self.tier(of: $0) == tier }.reduce(Int64(0)) { $0 + $1.size }
        }
        var text =
            lastTrashNote
            + String(
                format: L(
                    "reclaim.summary",
                    "%@ rebuilds automatically · %@ re-downloads · %@ to review · %@ checked"),
                byteFormatter.string(fromByteCount: total(.rebuilds)),
                byteFormatter.string(fromByteCount: total(.redownloads)),
                byteFormatter.string(fromByteCount: total(.review)),
                byteFormatter.string(fromByteCount: checked)) + extra + coverageNote
        if placesMeasured < candidates.count {
            text +=
                " · "
                + String(
                    format: L("reclaim.measuring", "updating sizes, %d of %d known places…"),
                    placesMeasured, candidates.count)
        }
        summaryLabel.stringValue = text
        summaryLabel.toolTip = text
        trashButton.isEnabled = checked > 0
        // Never while a delete is running: a second run over the same folders races the
        // first and reports its work as "No such file or directory".
        deleteNowButton.isEnabled = !deletableNow.isEmpty && deletingNames == nil
        if let deletingNames {
            let note = String(format: L("reclaim.deleting", "Deleting %@…"), deletingNames)
            summaryLabel.stringValue = note + " · " + text
        }
    }

    /// Names of the places being deleted right now, or nil when no delete is running.
    private var deletingNames: String?

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let tableColumn, row < rows.count else { return nil }
        let item = rows[row].item
        let group = rows[row].group
        switch tableColumn.identifier.rawValue {
        case "check":
            let id = NSUserInterfaceItemIdentifier("check")
            let button =
                (tableView.makeView(withIdentifier: id, owner: self) as? NSButton)
                ?? {
                    let b = NSButton(
                        checkboxWithTitle: "", target: self, action: #selector(toggleRow(_:)))
                    b.identifier = id
                    return b
                }()
            button.tag = row
            button.state = rows[row].checked ? .on : .off
            return button
        case "name":
            let cell = Self.textCell(tableView, owner: self, icon: true)
            cell.textField?.stringValue = rowTitle(rows[row])
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.path)
            cell.textField?.toolTip = group.isSingle ? item.path : Self.locations(of: group)
            return cell
        case "size":
            let cell = Self.textCell(tableView, owner: self, icon: false)
            cell.textField?.stringValue = byteFormatter.string(fromByteCount: group.size)
            return cell
        default:
            let cell = Self.textCell(tableView, owner: self, icon: false)
            cell.textField?.stringValue = whatHappens(rows[row])
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.toolTip = cell.textField?.stringValue
            return cell
        }
    }

    @objc private func toggleRow(_ sender: NSButton) {
        guard sender.tag < rows.count else { return }
        rows[sender.tag].checked = (sender.state == .on)
        updateSummary()
    }

    // MARK: Detail pane

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = table.selectedRow
        guard rows.indices.contains(selected) else {
            clearDetail()
            return
        }
        let group = rows[selected].group
        detailName.stringValue = rowTitle(rows[selected])
        detailPath.stringValue = group.isSingle ? group.items[0].path : Self.locations(of: group)
        detailWhy.stringValue =
            rows[selected].candidate.map { self.explanation(for: $0.place.consequence) }
            ?? whyText(for: group)
        feedbackNote.stringValue = ""
        goodButton.isEnabled = true
        badButton.isEnabled = true
    }

    private func clearDetail() {
        detailName.stringValue = L("cleanup.selectRow", "Select an item to see details")
        detailPath.stringValue = ""
        detailWhy.stringValue = ""
        feedbackNote.stringValue = ""
        goodButton.isEnabled = false
        badButton.isEnabled = false
    }

    /// The reasoning line: category, why it was flagged, size, and whether it is safe to
    /// remove (junk/duplicate) or should be reviewed first (large/old).
    /// A single item shows its name; a folded group shows how many of what ("13,909 × __pycache__").
    private static func title(for group: StorageScan.Group) -> String {
        if group.isSingle { return (group.items[0].path as NSString).lastPathComponent }
        if group.category == .duplicate {
            return String(
                format: L("cleanup.groupSmallDuplicates", "%@ small duplicate copies"),
                countText(group.items.count))
        }
        return String(
            format: L("cleanup.groupCount", "%@ × %@"), countText(group.items.count), group.kind)
    }

    private static func locations(of group: StorageScan.Group) -> String {
        let parents = Set(group.items.map { ($0.path as NSString).deletingLastPathComponent })
        return String(
            format: L("cleanup.groupLocations", "In %@ locations, for example %@"),
            countText(parents.count), group.items[0].path)
    }

    private func rowTitle(_ row: Row) -> String {
        row.candidate?.place.name ?? Self.title(for: row.group)
    }

    /// Which consequence tier a row counts toward in the summary.
    private func tier(of row: Row) -> ReclaimCatalog.Consequence {
        if let candidate = row.candidate { return candidate.place.consequence }
        return row.group.category == .junk ? .rebuilds : .review
    }

    private func consequenceText(_ consequence: ReclaimCatalog.Consequence) -> String {
        switch consequence {
        case .rebuilds: return L("reclaim.rebuilds", "Rebuilds automatically")
        case .redownloads: return L("reclaim.redownloads", "Re-downloads when needed")
        case .review: return L("reclaim.review", "Review first")
        }
    }

    private func explanation(for consequence: ReclaimCatalog.Consequence) -> String {
        switch consequence {
        case .rebuilds:
            return L(
                "reclaim.rebuildsDetail",
                "Build output or a cache. The tool recreates it the next time it runs; the first build or launch afterwards is slower."
            )
        case .redownloads:
            return L(
                "reclaim.redownloadsDetail",
                "Downloaded files. They are fetched again from the internet when next needed, which can take a while for large ones."
            )
        case .review:
            return L(
                "reclaim.reviewDetail",
                "May contain things that exist nowhere else. Open it and look before deleting.")
        }
    }

    /// The "what happens if you delete it" column: the consequence for a known place, and for
    /// scan results the kind plus, for a project's build folder, how long it has sat unused.
    private func whatHappens(_ row: Row) -> String {
        if let candidate = row.candidate { return consequenceText(candidate.place.consequence) }
        let group = row.group
        switch group.category {
        case .junk:
            var text = consequenceText(.rebuilds)
            if group.isSingle, let modified = group.items[0].modified {
                let days = Int(Date().timeIntervalSince(modified) / 86_400)
                if days >= 30 {
                    text +=
                        " · "
                        + String(
                            format: L("reclaim.stale", "not changed for %d months"), days / 30)
                }
            }
            return text
        case .duplicate: return L("reclaim.duplicate", "Duplicate copy; one original is kept")
        case .cache: return consequenceText(.review)
        case .large: return L("reclaim.large", "Large file; review first")
        case .old: return L("reclaim.old", "Not changed in a long time; review first")
        }
    }

    private func whyText(for group: StorageScan.Group) -> String {
        let item = (category: group.category, reason: group.kind, size: group.size)
        let safe = item.category == .junk || item.category == .duplicate
        let disposition =
            safe
            ? L("cleanup.safeToRemove", "safe to remove")
            : L("cleanup.reviewFirst", "review before deleting")
        var text = String(
            format: L("cleanup.whyDetail", "%@ · %@ · %@ · %@"), item.category.rawValue,
            item.reason,
            byteFormatter.string(fromByteCount: item.size), disposition)
        // Surface the learned lean when it is strong enough to have moved the default.
        let bias = learnedBias(for: item.category)
        if bias >= 0.1 {
            text += L("cleanup.learnedRemove", " · learned: you usually remove these")
        } else if bias <= -0.1 {
            text += L("cleanup.learnedKeep", " · learned: you usually keep these")
        }
        return text
    }

    @objc private func markGood() { recordFeedback(.good) }
    @objc private func markBad() { recordFeedback(.bad) }

    private func recordFeedback(_ verdict: OrganizeFeedback.Verdict) {
        let selected = table.selectedRow
        guard rows.indices.contains(selected) else { return }
        let item = rows[selected].item
        if let url = Self.feedbackURL() {
            OrganizeFeedback.record(
                .init(
                    ruleID: "cleanup:\(item.category.rawValue)", destination: nil,
                    ext: (item.path as NSString).pathExtension.lowercased(), verdict: verdict),
                to: url)
        }
        // "Keep it" also unchecks the row so it isn't trashed this pass.
        if verdict == .bad {
            rows[selected].checked = false
            table.reloadData(
                forRowIndexes: [selected], columnIndexes: IndexSet(0..<table.numberOfColumns))
            updateSummary()
        }
        feedbackNote.stringValue =
            verdict == .good
            ? L("cleanup.notedGood", "Noted as good")
            : L("cleanup.notedKeep", "Noted, and unchecked")
    }

    /// The shared feedback log (same file the organizer writes), so verdicts from both
    /// surfaces feed one behavior signal.
    private static func feedbackURL() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            return nil
        }
        let dir = base.appendingPathComponent("Pathem", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("organize-feedback.json")
    }

    // MARK: Actions

    @objc private func trashChecked() {
        let urls = rows.filter(\.checked).flatMap { $0.group.items }.map {
            URL(fileURLWithPath: $0.path)
        }
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        // Record the accept/skip decision as behavioral signal (checked = removed), so the
        // next scan's pre-checking reflects what the user actually does.
        if let url = Self.feedbackURL() {
            OrganizeFeedback.record(
                rows.map {
                    .init(
                        ruleID: "cleanup:\($0.group.category.rawValue)", destination: nil,
                        ext: ($0.item.path as NSString).pathExtension.lowercased(),
                        verdict: $0.checked ? .applied : .skipped)
                }, to: url)
        }
        let result = FileOperations.trash(urls: urls)
        let trashed = Set(result.trashed.map(\.original.path))
        // Drop what was trashed from every report list, then regroup: a folded row keeps only
        // the items that could not be removed.
        let freed = rows.flatMap { $0.group.items }.filter { trashed.contains($0.path) }
            .reduce(Int64(0)) { $0 + $1.size }
        for keyPath in [
            \StorageScan.Report.junk, \.duplicates, \.caches, \.large, \.old,
        ] {
            quickReport?[keyPath: keyPath].removeAll { trashed.contains($0.path) }
        }
        candidates.removeAll { trashed.contains($0.url.path) }
        rebuildRows()
        if freed > 0 {
            lastTrashNote =
                String(
                    format: L(
                        "cleanup.movedToTrash",
                        "Moved %@ to the Trash. Empty the Trash to free the space."),
                    byteFormatter.string(fromByteCount: freed)) + " · "
        }
        updateSummary()
        updateDiskStats()
        // Hand the trashed items to the browser so they're undoable and Put Back works, like the
        // other trash flows (Cleanup was the only one that trashed with no record).
        if !result.trashed.isEmpty { onTrashed?(result.trashed) }
        if !result.failures.isEmpty { presentTrashFailures(result.failures) }
    }

    // MARK: Delete Now (rebuilds tier only)

    /// Checked known places that rebuild automatically: the only rows that may skip the Trash.
    private var deletableNow: [Row] {
        rows.filter { $0.checked && $0.candidate?.place.consequence == .rebuilds }
    }

    @objc private func deleteNowClicked() {
        let targets = deletableNow
        guard !targets.isEmpty else {
            NSSound.beep()
            return
        }
        let total = targets.reduce(Int64(0)) { $0 + $1.size }
        let list = targets.map {
            "• \(rowTitle($0)) (\(byteFormatter.string(fromByteCount: $0.size)))"
        }.joined(separator: "\n")
        let alert = Self.deleteNowAlert(
            totalDescription: byteFormatter.string(fromByteCount: total), itemList: list)
        #if DEBUG
        debugTransientLastResponse = nil
        debugTransientLastAlert = alert
        #endif
        Self.presentDeleteNowAlert(alert, for: panel) { [weak self] response in
            #if DEBUG
            self?.debugTransientLastResponse = response
            #endif
            if response == .alertFirstButtonReturn { self?.deleteCheckedNow() }
        }
    }

    /// The production confirmation, shared with structural and input regression checks.
    static func deleteNowAlert(totalDescription: String, itemList: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: L("reclaim.deleteNowTitle", "Permanently delete %@?"), totalDescription)
        alert.informativeText =
            itemList + "\n\n"
            + L(
                "reclaim.deleteNowBody",
                "These are recreated automatically the next time each tool runs. This skips the Trash and can’t be undone. Other checked items are not affected."
            )
        alert.addButton(withTitle: L("reclaim.deleteNowConfirm", "Delete Permanently"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        return alert
    }

    /// Keep native NSAlert Return/Delete and Escape/Cancel behaviour. Production
    /// and owned-fixture tests share the same presenter without a key monitor.
    static func presentDeleteNowAlert(
        _ alert: NSAlert, for host: NSWindow,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        alert.beginSheetModal(for: host, completionHandler: completion)
    }

    private func deleteCheckedNow() {
        let targets = deletableNow.compactMap(\.candidate)
        guard !targets.isEmpty, deletingNames == nil else { return }
        let home = self.home
        deletingNames = targets.map(\.place.name).joined(separator: ", ")
        updateSummary()
        spinner.startAnimation(nil)
        Task { [weak self] in
            let failures = await Task.detached(priority: .utility) { () -> [String] in
                var failed: [String] = []
                for candidate in targets {
                    do { try ReclaimCatalog.deleteNow(candidate, home: home) } catch {
                        failed.append(Self.describe(error, for: candidate))
                    }
                }
                return failed
            }.value
            self?.finishDeleteNow(targets, failures: failures)
        }
    }

    /// One line per place that could not be emptied, naming the first item left behind and
    /// the system's reason, so "why" does not need a second investigation.
    nonisolated private static func describe(
        _ error: Error, for candidate: ReclaimCatalog.Candidate
    ) -> String {
        guard
            case ReclaimCatalog.DeleteError.incomplete(let left, let firstPath, let reason) = error
        else { return "\(candidate.place.name): \(error.localizedDescription)" }
        return String(
            format: L(
                "reclaim.deleteIncomplete",
                "%1$@: %2$d item(s) left behind, starting with %3$@ (%4$@). Everything else was deleted."
            ),
            candidate.place.name, left, (firstPath as NSString).abbreviatingWithTildeInPath,
            reason)
    }

    /// Re-measure what was deleted (a folder that could only be partly removed keeps its row
    /// with the real remaining size), refresh the totals, and report any failures.
    private func finishDeleteNow(_ targets: [ReclaimCatalog.Candidate], failures: [String]) {
        spinner.stopAnimation(nil)
        deletingNames = nil
        for candidate in targets {
            placeSizes[candidate.place.id] = DirectorySize.total(of: candidate.url).bytes
        }
        lastTrashNote = ""
        rebuildRows()
        updateSummary()
        updateDiskStats()
        if debugMinimumPlaceBytes == nil { Self.saveRememberedSizes(placeSizes) }
        guard !failures.isEmpty, panel.isVisible else { return }
        let alert = NSAlert()
        alert.messageText = L("reclaim.deleteFailedHeading", "Some items couldn’t be deleted")
        alert.informativeText = failures.prefix(8).joined(separator: "\n\n")
        alert.addButton(withTitle: L("common.ok", "OK"))
        alert.beginSheetModal(for: panel) { _ in }
    }

    @objc private func emptyTrashClicked() {
        guard let onEmptyTrash else {
            NSSound.beep()
            return
        }
        onEmptyTrash { [weak self] in
            self?.lastTrashNote = ""
            self?.updateSummary()
            self?.updateDiskStats()
        }
    }

    /// Tell the user which items couldn't be removed, instead of a bare beep that leaves
    /// them thinking the space was reclaimed when some files are still there.
    private func presentTrashFailures(_ failures: [FileOperations.Failure]) {
        let detail = failures.prefix(8).map { "• \($0.name): \($0.reason)" }.joined(separator: "\n")
        let more =
            failures.count > 8
            ? "\n" + String(format: L("cleanup.moreFailures", "…and %d more."), failures.count - 8)
            : ""
        let alert = NSAlert()
        alert.messageText = String(
            format: L("cleanup.trashFailedTitle", "%d item(s) couldn’t be removed"), failures.count)
        alert.informativeText =
            detail + more + "\n\n"
            + L(
                "cleanup.trashFailedHint",
                "They may be in use, or Pathem may need Full Disk Access to delete them.")
        alert.addButton(withTitle: L("common.ok", "OK"))
        alert.beginSheetModal(for: panel) { _ in }
    }

    /// Open Storage in System Settings, which shows app/photo/system categories and
    /// Apple's own recommendations that a third-party app can't compute.
    @objc private func openSystemStorage() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.Storage",
            "x-apple.systempreferences:com.apple.Storage-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.general",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    @objc private func revealSelected() {
        let urls = table.selectedRowIndexes.compactMap {
            $0 < rows.count ? URL(fileURLWithPath: rows[$0].item.path) : nil
        }
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func recommendWithAI() {
        if let reason = AIAvailability.unavailableReason() {
            AIAvailability.presentUnavailable(
                L("ai.cleanup.unavail", "AI recommendations are unavailable"), reason: reason,
                over: panel)
            return
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let items = rows.map {
                (
                    path: self.rowTitle($0), size: $0.size,
                    reason: self.whatHappens($0)
                )
            }
            guard !items.isEmpty else {
                NSSound.beep()
                return
            }
            aiButton.isEnabled = false
            summaryLabel.stringValue = L("ai.cleanup.thinking", "Asking the model…")
            Task { @MainActor in
                defer { self.aiButton.isEnabled = true }
                guard let advice = await recommendCleanup(items: items) else {
                    self.summaryLabel.stringValue = L(
                        "ai.cleanup.noRec", "The model had no recommendation.")
                    return
                }
                for index in advice.safeToDelete
                where index >= 0 && index < self.rows.count
                    && self.rows[index].group.category != .cache
                {
                    self.rows[index].checked = true
                }
                self.table.reloadData()
                self.updateSummary(extra: advice.summary.isEmpty ? "" : ": \(advice.summary)")
            }
        }
        #endif
    }

    private static func textCell(_ table: NSTableView, owner: Any?, icon: Bool) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(icon ? "nameCell" : "plainCell")
        if let reused = table.makeView(withIdentifier: id, owner: owner) as? NSTableCellView {
            return reused
        }
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        if icon {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }
}
