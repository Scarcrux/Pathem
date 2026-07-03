import AppKit
import PathemEngine

/// A review sheet for a proposed organization: every recommended action is a row with
/// a skip checkbox, and selecting a row reveals its full path, the reasoning, a Reveal
/// in Finder button, and good/bad feedback. Only the checked rows are applied. The
/// controller mutates its own copy of the suggestions and hands the final set back.
@MainActor
final class OrganizeReviewController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
        styleMask: [.titled], backing: .buffered, defer: true)
    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let subtitle = NSTextField(labelWithString: "")
    private let applyButton = NSButton()
    private let selectAllButton = NSButton()

    // Detail pane (for the selected row).
    private let detailName = NSTextField(labelWithString: "")
    private let detailPath = NSTextField(labelWithString: "")
    private let detailWhy = NSTextField(wrappingLabelWithString: "")
    private let feedbackNote = NSTextField(labelWithString: "")
    private let revealButton = NSButton()
    private let goodButton = NSButton()
    private let badButton = NSButton()

    private var suggestions: [OrganizePlanner.Suggestion] = []
    private var onApply: (([OrganizePlanner.Suggestion]) -> Void)?
    private let feedbackURL: URL

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    init(feedbackURL: URL) {
        self.feedbackURL = feedbackURL
        super.init()
        build()
    }

    /// Present as a sheet over `window`. `onApply` receives the suggestions with the
    /// user's final checked state (apply then filters to the accepted ones).
    func present(
        suggestions: [OrganizePlanner.Suggestion], folderName: String, over window: NSWindow,
        onApply: @escaping ([OrganizePlanner.Suggestion]) -> Void
    ) {
        self.suggestions = Self.sortedForReview(suggestions)
        self.onApply = onApply
        panel.title = String(format: L("organize.review.title", "Organize %@"), folderName)
        table.reloadData()
        updateCounts()
        clearDetail()
        window.beginSheet(panel) { _ in }
    }

    // MARK: Layout

    private func build() {
        panel.isReleasedWhenClosed = false
        let content = panel.contentView!

        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        selectAllButton.title = L("organize.review.selectNone", "Deselect All")
        selectAllButton.bezelStyle = .rounded
        selectAllButton.controlSize = .small
        selectAllButton.target = self
        selectAllButton.action = #selector(toggleSelectAll)

        table.headerView = nil
        table.rowHeight = 40
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        let column = NSTableColumn(identifier: .init("action"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let detail = buildDetailPane()

        applyButton.title = L("common.apply", "Apply")
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(apply)
        let cancel = NSButton(title: L("common.cancel", "Cancel"), target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        for view in [subtitle, selectAllButton, scrollView, detail, applyButton, cancel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            subtitle.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            subtitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            selectAllButton.centerYAnchor.constraint(equalTo: subtitle.centerYAnchor),
            selectAllButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),

            detail.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            detail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            detail.heightAnchor.constraint(equalToConstant: 118),

            applyButton.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 14),
            applyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            applyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -10),
        ])
    }

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

        revealButton.title = L("organize.review.reveal", "Reveal in Finder")
        goodButton.title = L("organize.review.good", "Good")
        badButton.title = L("organize.review.bad", "Not helpful")
        for (button, action) in [
            (revealButton, #selector(revealSelected)), (goodButton, #selector(markGood)),
            (badButton, #selector(markBad)),
        ] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        goodButton.image = NSImage(systemSymbolName: "hand.thumbsup", accessibilityDescription: nil)
        badButton.image = NSImage(systemSymbolName: "hand.thumbsdown", accessibilityDescription: nil)
        goodButton.imagePosition = .imageLeading
        badButton.imagePosition = .imageLeading

        let buttons = NSStackView(views: [revealButton, goodButton, badButton, feedbackNote])
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
        return box
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? OrganizeRowView) ?? {
            let view = OrganizeRowView()
            view.identifier = id
            view.checkbox.target = self
            view.checkbox.action = #selector(toggleRow(_:))
            return view
        }()
        cell.configure(suggestions[row], row: row, byteFormatter: byteFormatter)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard suggestions.indices.contains(row) else { clearDetail(); return }
        let s = suggestions[row]
        detailName.stringValue = s.file.lastPathComponent
        detailPath.stringValue = s.file.path
        let confidence = Int((s.confidence * 100).rounded())
        detailWhy.stringValue = String(
            format: L("organize.review.why", "Why: %@  (rule: %@, confidence %d%%)"),
            s.rationale, s.ruleID, confidence)
        feedbackNote.stringValue = ""
        [revealButton, goodButton, badButton].forEach { $0.isEnabled = true }
    }

    private func clearDetail() {
        detailName.stringValue = L("organize.review.selectRow", "Select a row to see details")
        detailPath.stringValue = ""
        detailWhy.stringValue = ""
        feedbackNote.stringValue = ""
        [revealButton, goodButton, badButton].forEach { $0.isEnabled = false }
    }

    // MARK: Actions

    @objc private func toggleRow(_ sender: NSButton) {
        guard suggestions.indices.contains(sender.tag) else { return }
        suggestions[sender.tag].accepted = sender.state == .on
        updateCounts()
    }

    @objc private func toggleSelectAll() {
        let makeOn = suggestions.contains { !$0.accepted }  // if any off, turn all on; else all off
        for i in suggestions.indices { suggestions[i].accepted = makeOn }
        table.reloadData()
        updateCounts()
    }

    @objc private func revealSelected() {
        guard suggestions.indices.contains(table.selectedRow) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([suggestions[table.selectedRow].file])
    }

    @objc private func markGood() { recordFeedback(.good) }
    @objc private func markBad() { recordFeedback(.bad) }

    private func recordFeedback(_ verdict: OrganizeFeedback.Verdict) {
        let row = table.selectedRow
        guard suggestions.indices.contains(row) else { return }
        let s = suggestions[row]
        OrganizeFeedback.record(
            .init(
                ruleID: s.ruleID, destination: s.destination?.lastPathComponent,
                ext: s.file.pathExtension.lowercased(), verdict: verdict),
            to: feedbackURL)
        // Bad feedback also skips the action this run; good keeps it checked.
        if verdict == .bad {
            suggestions[row].accepted = false
            table.reloadData(forRowIndexes: [row], columnIndexes: [0])
            updateCounts()
        }
        feedbackNote.stringValue =
            verdict == .good
            ? L("organize.review.notedGood", "Noted as good")
            : L("organize.review.notedBad", "Noted, and skipped")
    }

    private func updateCounts() {
        let selected = suggestions.filter(\.accepted)
        let reclaim = selected.filter { if case .trash = $0.kind { return true } else { return false } }
            .reduce(Int64(0)) { $0 + $1.size }
        var text = String(
            format: L("organize.review.counts", "%d of %d selected"), selected.count, suggestions.count)
        if reclaim > 0 {
            text += String(
                format: L("organize.review.frees", ", frees %@"), byteFormatter.string(fromByteCount: reclaim))
        }
        subtitle.stringValue = text
        applyButton.isEnabled = !selected.isEmpty
        applyButton.title =
            selected.isEmpty
            ? L("common.apply", "Apply")
            : String(format: L("organize.review.applyN", "Apply (%d)"), selected.count)
        selectAllButton.title =
            suggestions.contains { !$0.accepted }
            ? L("organize.review.selectAll", "Select All")
            : L("organize.review.selectNone", "Deselect All")
    }

    @objc private func apply() {
        panel.sheetParent?.endSheet(panel)
        onApply?(suggestions)
    }

    @objc private func cancel() { panel.sheetParent?.endSheet(panel) }

    /// Cluster moves by destination, trashes last, names naturally sorted within each.
    private static func sortedForReview(_ list: [OrganizePlanner.Suggestion]) -> [OrganizePlanner.Suggestion] {
        list.sorted { a, b in
            func rank(_ s: OrganizePlanner.Suggestion) -> String {
                switch s.kind {
                case .move(let dest): return "0" + dest.lastPathComponent.lowercased()
                case .trash: return "1"
                }
            }
            let (ra, rb) = (rank(a), rank(b))
            if ra != rb { return ra < rb }
            return a.file.lastPathComponent.localizedStandardCompare(b.file.lastPathComponent) == .orderedAscending
        }
    }

    // Test hooks.
    var debugRowCount: Int { suggestions.count }
    func debugLoad(_ suggestions: [OrganizePlanner.Suggestion]) {
        self.suggestions = Self.sortedForReview(suggestions)
        table.reloadData()
        updateCounts()
    }
}

/// One review row: a skip checkbox, the file icon and name, its reasoning, the action,
/// and the size.
private final class OrganizeRowView: NSTableCellView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let reason = NSTextField(labelWithString: "")
    private let action = NSTextField(labelWithString: "")
    private let size = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        reason.font = .systemFont(ofSize: 10)
        reason.textColor = .secondaryLabelColor
        reason.lineBreakMode = .byTruncatingTail
        action.font = .systemFont(ofSize: 11, weight: .medium)
        action.alignment = .right
        size.font = .systemFont(ofSize: 10)
        size.textColor = .secondaryLabelColor
        size.alignment = .right

        let text = NSStackView(views: [name, reason])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let trailing = NSStackView(views: [action, size])
        trailing.orientation = .vertical
        trailing.alignment = .trailing
        trailing.spacing = 1

        let row = NSStackView(views: [checkbox, icon, text, NSView(), trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
        ])
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ s: OrganizePlanner.Suggestion, row: Int, byteFormatter: ByteCountFormatter) {
        checkbox.state = s.accepted ? .on : .off
        checkbox.tag = row
        // Copy before resizing: icon(forFile:) returns a shared cached image.
        let raw = NSWorkspace.shared.icon(forFile: s.file.path)
        let img = (raw.copy() as? NSImage) ?? raw
        img.size = NSSize(width: 22, height: 22)
        icon.image = img
        name.stringValue = s.file.lastPathComponent
        reason.stringValue = s.rationale
        size.stringValue = byteFormatter.string(fromByteCount: s.size)
        switch s.kind {
        case .move(let dest):
            action.stringValue = "→ \(dest.lastPathComponent)"
            action.textColor = .controlAccentColor
        case .trash:
            action.stringValue = L("organize.review.trash", "Trash")
            action.textColor = .systemRed
        }
    }
}
