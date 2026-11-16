import AppKit
import PathemEngine

/// Find-in-Files: search file contents under the active folder (grep/ripgrep), list the
/// matches, and open one. The actual search + open run in the browser via callbacks.
@MainActor
final class FindInFilesController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate, NSWindowDelegate
{
    private let panel: NSPanel
    private let queryField = NSSearchField()
    private let regexCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let caseCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let table = NSTableView()
    private let replaceField = NSTextField()
    private let replaceButton = NSButton(title: "", target: nil, action: nil)
    private var matches: [ContentSearch.Match] = []
    private let gen = GenerationBox()
    /// The cap of the search whose rows are showing, when it left matches out. Replace All
    /// reads it to say its preceding search was limited.
    private var cappedAt: Int?
    /// Replace All's report, shown ahead of the refreshed search status when the search it
    /// followed was capped (the refresh would otherwise overwrite it).
    private var replaceNote: String?
    /// Whether the spinner is running (NSProgressIndicator has no getter for it).
    private var busy = false {
        didSet { busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) }
    }

    private var onSearch:
        ((_ query: String, _ regex: Bool, _ caseSensitive: Bool) async -> ContentSearch.Outcome)?
    private var onOpen: ((ContentSearch.Match) -> Void)?
    private var onReplace:
        (
            (_ query: String, _ replacement: String, _ regex: Bool, _ caseSensitive: Bool) async ->
                ContentSearch.ReplaceResult
        )?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        panel.delegate = self
        build()
    }

    /// Drop whatever is still running: its answer belongs to a query, folder or window that
    /// is no longer on screen. Every result handler checks the generation this bumps.
    private func invalidatePendingWork() {
        _ = gen.bump()
        busy = false
        replaceNote = nil
    }

    /// Closing the panel abandons a running search instead of filling an unseen list.
    func windowWillClose(_ notification: Notification) {
        invalidatePendingWork()
        matches = []
        cappedAt = nil
        statusLabel.stringValue = ""
        table.reloadData()
    }

    func present(
        over window: NSWindow, folderName: String,
        search: @escaping (String, Bool, Bool) async -> ContentSearch.Outcome,
        open: @escaping (ContentSearch.Match) -> Void,
        replace: @escaping (String, String, Bool, Bool) async -> ContentSearch.ReplaceResult
    ) {
        // A request from the previous folder may still be running; its rows must not land
        // in this folder's list, where Open would hand them to this folder's callback.
        invalidatePendingWork()
        onSearch = search
        onOpen = open
        onReplace = replace
        panel.title = String(format: L("find.inFilesTitle", "Find in %@"), folderName)
        matches = []
        cappedAt = nil
        statusLabel.stringValue = ""
        table.reloadData()
        panel.centerOverMainWindow()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(queryField)
    }

    private func build() {
        queryField.placeholderString = L("find.placeholder", "Search file contents…")
        queryField.delegate = self
        regexCheck.title = L("find.regex", "Regex")
        caseCheck.title = L("find.caseSensitive", "Case sensitive")
        for check in [regexCheck, caseCheck] {
            check.target = self
            check.action = #selector(runSearch)
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        for (id, title, width) in [
            ("loc", L("find.location", "Location"), CGFloat(220)),
            ("text", L("find.match", "Match"), 360),
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
        table.doubleAction = #selector(openSelected)
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView(views: [
            queryField, regexCheck, caseCheck, spinner, NSView(), statusLabel,
        ])
        controls.orientation = .horizontal
        controls.spacing = 8
        queryField.setContentHuggingPriority(.init(1), for: .horizontal)
        statusLabel.setContentHuggingPriority(.init(1), for: .horizontal)

        replaceField.placeholderString = L("find.replacePlaceholder", "Replace with…")
        replaceButton.title = L("find.replaceAll", "Replace All")
        replaceButton.bezelStyle = .rounded
        replaceButton.target = self
        replaceButton.action = #selector(replaceAll)
        let replaceRow = NSStackView(views: [replaceField, replaceButton])
        replaceRow.orientation = .horizontal
        replaceRow.spacing = 8
        replaceField.setContentHuggingPriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [controls, replaceRow, scroll])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                controls.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
                replaceRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            ])
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            runSearch()
            return true
        }
        return false
    }

    @objc private func runSearch() {
        let query = queryField.stringValue
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            invalidatePendingWork()  // or the running request refills the cleared list
            matches = []
            cappedAt = nil
            replaceNote = nil
            table.reloadData()
            statusLabel.stringValue = ""
            return
        }
        let generation = gen.bump()
        let search = onSearch  // this request's own callback, not whatever is set later
        busy = true
        statusLabel.stringValue = L("find.searching", "Searching…")
        let regex = regexCheck.state == .on
        let caseSensitive = caseCheck.state == .on
        Task { @MainActor in
            let outcome = await search?(query, regex, caseSensitive) ?? ContentSearch.Outcome()
            guard self.gen.isCurrent(generation) else { return }
            self.busy = false
            self.matches = outcome.matches
            self.cappedAt = outcome.truncated ? outcome.limit : nil
            self.table.reloadData()
            var status: String
            if let failure = outcome.failure {
                status = String(format: L("find.failed", "Search failed: %@"), failure)
            } else {
                var notes: [String] = []
                if outcome.truncated {
                    notes.append(
                        String(
                            format: L("find.capped", "Results limited to %d; narrow your search."),
                            outcome.limit))
                }
                if outcome.perFileCapped {
                    notes.append(
                        String(
                            format: L(
                                "find.perFileCapped",
                                "Some files have more than %d matches; only the first %d per file are listed."
                            ), outcome.perFileLimit, outcome.perFileLimit))
                }
                if notes.isEmpty {
                    status = String(format: L("find.results", "%d matches"), outcome.matches.count)
                } else {
                    // Each note is its own sentence after the count.
                    status =
                        String(
                            format: L("find.resultsThen", "%d matches. "), outcome.matches.count)
                        + notes.joined(separator: L("find.noteSep", " "))
                }
            }
            if let note = self.replaceNote {
                status = note + " " + status
                self.replaceNote = nil
            }
            self.statusLabel.stringValue = status
        }
    }

    @objc private func replaceAll() {
        let query = queryField.stringValue
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty, !matches.isEmpty else {
            NSSound.beep()
            return
        }
        let replacement = replaceField.stringValue
        let alert = Self.makeReplaceConfirmation(query: query)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performReplaceAll(query: query, replacement: replacement)
    }

    private func performReplaceAll(query: String, replacement: String) {
        let regex = regexCheck.state == .on
        let caseSensitive = caseCheck.state == .on
        // The replace itself always runs to completion (it edits files), but its report and
        // the follow-up search belong only to the session that asked for it.
        let generation = gen.bump()
        let replace = onReplace
        let cappedBefore = cappedAt
        replaceNote = nil
        busy = true
        statusLabel.stringValue = L("find.replacing", "Replacing…")
        Task { @MainActor in
            let result =
                await replace?(query, replacement, regex, caseSensitive)
                ?? ContentSearch.ReplaceResult(filesChanged: 0, replacements: 0)
            guard self.gen.isCurrent(generation) else { return }
            self.busy = false
            if let failure = result.failure {
                // Nothing was replaced; a refresh search would overwrite this and hide it.
                self.statusLabel.stringValue = String(
                    format: L("find.replaceFailed", "Replace failed: %@"), failure)
                return
            }
            let report = String(
                format: L("find.replacedResult", "Replaced %d in %d files"), result.replacements,
                result.filesChanged)
            if let cappedBefore {
                self.replaceNote =
                    report + ". "
                    + String(
                        format: L(
                            "find.replaceCapped",
                            "The search before it was limited to %d results; Replace All covered every matching file."
                        ), cappedBefore)
                self.statusLabel.stringValue = self.replaceNote ?? report
            } else {
                self.statusLabel.stringValue = report
            }
            self.runSearch()  // refresh the match list against the edited files
        }
    }

    #if DEBUG
    var debugRowCount: Int { matches.count }
    var debugStatus: String { statusLabel.stringValue }
    var debugTitle: String { panel.title }
    var debugBusy: Bool { busy }
    /// Type a query and submit it, as Return in the search field does.
    func debugSearch(_ query: String) {
        queryField.stringValue = query
        runSearch()
    }
    func debugOpenRow(_ row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        openSelected()
    }
    func debugClose() { panel.close() }
    /// Replace All with the confirmation already given.
    func debugReplaceAllConfirmed(with replacement: String) {
        replaceField.stringValue = replacement
        performReplaceAll(query: queryField.stringValue, replacement: replacement)
    }
    #endif

    @objc private func openSelected() {
        let row = table.selectedRow
        guard row >= 0, row < matches.count else { return }
        onOpen?(matches[row])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard let tableColumn, row < matches.count else { return nil }
        let match = matches[row]
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
        if tableColumn.identifier.rawValue == "loc" {
            cell.textField?.stringValue =
                "\((match.path as NSString).lastPathComponent):\(match.line)"
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.toolTip = match.path
        } else {
            cell.textField?.stringValue = match.text.trimmingCharacters(in: .whitespaces)
            cell.textField?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.textField?.textColor = .secondaryLabelColor
        }
        return cell
    }
}

@MainActor
extension FindInFilesController {
    /// Production construction shared with isolated geometry/lifecycle checks.
    static func makeReplaceConfirmation(query: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L("find.confirmReplaceTitle", "Replace in files?")
        alert.informativeText = String(
            format: L(
                "find.confirmReplaceBody",
                "Replace every match of \"%@\" in the matched files. This cannot be undone."),
            query)
        alert.addButton(withTitle: L("find.replaceAll", "Replace All"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        return alert
    }
}
