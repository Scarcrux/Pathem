import AppKit
import PathemEngine

/// Find-in-Files: search file contents under the active folder (grep/ripgrep), list the
/// matches, and open one. The actual search + open run in the browser via callbacks.
@MainActor
final class FindInFilesController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate
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

    private var onSearch: ((_ query: String, _ regex: Bool, _ caseSensitive: Bool) async -> [ContentSearch.Match])?
    private var onOpen: ((ContentSearch.Match) -> Void)?
    private var onReplace: ((_ query: String, _ replacement: String, _ regex: Bool, _ caseSensitive: Bool) async -> ContentSearch.ReplaceResult)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        build()
    }

    func present(
        over window: NSWindow, folderName: String,
        search: @escaping (String, Bool, Bool) async -> [ContentSearch.Match],
        open: @escaping (ContentSearch.Match) -> Void,
        replace: @escaping (String, String, Bool, Bool) async -> ContentSearch.ReplaceResult
    ) {
        onSearch = search
        onOpen = open
        onReplace = replace
        panel.title = String(format: L("find.inFilesTitle", "Find in %@"), folderName)
        matches = []
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
            ("loc", L("find.location", "Location"), CGFloat(220)), ("text", L("find.match", "Match"), 360),
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

        let controls = NSStackView(views: [queryField, regexCheck, caseCheck, spinner, NSView(), statusLabel])
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            runSearch()
            return true
        }
        return false
    }

    @objc private func runSearch() {
        let query = queryField.stringValue
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            matches = []
            table.reloadData()
            statusLabel.stringValue = ""
            return
        }
        let generation = gen.bump()
        spinner.startAnimation(nil)
        statusLabel.stringValue = L("find.searching", "Searching…")
        let regex = regexCheck.state == .on
        let caseSensitive = caseCheck.state == .on
        Task { @MainActor in
            let results = await self.onSearch?(query, regex, caseSensitive) ?? []
            guard self.gen.isCurrent(generation) else { return }
            self.spinner.stopAnimation(nil)
            self.matches = results
            self.table.reloadData()
            self.statusLabel.stringValue = String(format: L("find.results", "%d matches"), results.count)
        }
    }

    @objc private func replaceAll() {
        let query = queryField.stringValue
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty, !matches.isEmpty else {
            NSSound.beep()
            return
        }
        let replacement = replaceField.stringValue
        let alert = NSAlert()
        alert.messageText = L("find.confirmReplaceTitle", "Replace in files?")
        alert.informativeText = String(
            format: L("find.confirmReplaceBody", "Replace every match of \"%@\" in the matched files. This cannot be undone."),
            query)
        alert.addButton(withTitle: L("find.replaceAll", "Replace All"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let regex = regexCheck.state == .on
        let caseSensitive = caseCheck.state == .on
        spinner.startAnimation(nil)
        statusLabel.stringValue = L("find.replacing", "Replacing…")
        Task { @MainActor in
            let result = await self.onReplace?(query, replacement, regex, caseSensitive)
                ?? ContentSearch.ReplaceResult(filesChanged: 0, replacements: 0)
            self.spinner.stopAnimation(nil)
            self.statusLabel.stringValue = String(
                format: L("find.replacedResult", "Replaced %d in %d files"), result.replacements,
                result.filesChanged)
            self.runSearch()  // refresh the match list against the edited files
        }
    }

    @objc private func openSelected() {
        let row = table.selectedRow
        guard row >= 0, row < matches.count else { return }
        onOpen?(matches[row])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
            cell.textField?.stringValue = "\((match.path as NSString).lastPathComponent):\(match.line)"
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
