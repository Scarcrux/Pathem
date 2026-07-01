import AppKit
import PathemEngine

/// Batch-rename sheet: edit a rule, see a live before/after preview with conflicts
/// flagged in red, then apply. All transform and collision logic lives in the
/// engine (BatchRename); this is just the form, the preview table, and Apply.
@MainActor
final class BatchRenameController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate
{
    private let panel: NSPanel
    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let regexCheck = NSButton(checkboxWithTitle: L("rename.regex", "Regex"), target: nil, action: nil)
    private let prefixField = NSTextField()
    private let suffixField = NSTextField()
    private let casePopup = NSPopUpButton()
    private let extCheck = NSButton(checkboxWithTitle: L("rename.includeExtension", "Include extension"), target: nil, action: nil)
    private let numberCheck = NSButton(checkboxWithTitle: L("rename.number", "Number (# in a field, else appended)"), target: nil, action: nil)
    private let startField = NSTextField()
    private let padField = NSTextField()
    private let table = NSTableView()
    private let warnLabel = NSTextField(labelWithString: "")
    private let applyButton = NSButton(title: L("rename.renameButton", "Rename"), target: nil, action: nil)

    private var names: [String] = []
    private var existing: Set<String> = []
    private var directory = URL(fileURLWithPath: "/")
    private var onComplete: (() -> Void)?
    private var plan = RenamePlan(pairs: [], collisions: [])

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: true)
        super.init()
        build()
    }

    private func build() {
        panel.title = L("rename.panelTitle", "Batch Rename")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        for field in [findField, replaceField, prefixField, suffixField, startField, padField] {
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        startField.stringValue = "1"
        padField.stringValue = "1"
        startField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        padField.widthAnchor.constraint(equalToConstant: 48).isActive = true

        casePopup.addItems(withTitles: [
            L("rename.caseKeep", "Keep case"),
            L("rename.caseLower", "lowercase"),
            L("rename.caseUpper", "UPPERCASE"),
            L("rename.caseTitle", "Title Case"),
        ])
        casePopup.target = self
        casePopup.action = #selector(ruleChanged)
        for check in [regexCheck, extCheck, numberCheck] {
            check.target = self
            check.action = #selector(ruleChanged)
        }

        table.headerView = NSTableHeaderView()
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        let current = NSTableColumn(identifier: .init("current"))
        current.title = L("rename.columnCurrent", "Current")
        current.width = 250
        let renamed = NSTableColumn(identifier: .init("renamed"))
        renamed.title = L("rename.columnNewName", "New name")
        renamed.width = 250
        table.addTableColumn(current)
        table.addTableColumn(renamed)
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        warnLabel.font = .systemFont(ofSize: 11)
        warnLabel.textColor = .systemRed
        warnLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: L("common.cancel", "Cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"  // Esc
        applyButton.target = self
        applyButton.action = #selector(apply)
        applyButton.keyEquivalent = "\r"  // Return

        let form = NSStackView(views: [
            row(L("rename.rowFind", "Find"), findField, regexCheck),
            row(L("rename.rowReplace", "Replace"), replaceField),
            row(L("rename.rowPrefix", "Prefix"), prefixField),
            row(L("rename.rowSuffix", "Suffix"), suffixField),
            row(L("rename.rowCase", "Case"), casePopup, extCheck),
            row(L("rename.rowNumbering", "Numbering"), numberCheck),
            row(L("rename.rowStart", "Start"), startField, label(L("rename.labelPad", "Pad")), padField),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        form.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [warnLabel, NSView(), cancel, applyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(form)
        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            form.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func row(_ title: String, _ views: NSView...) -> NSStackView {
        let titleLabel = label(title)
        titleLabel.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let stack = NSStackView(views: [titleLabel] + views)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    func present(
        names: [String], in directory: URL, existing: Set<String>,
        over window: NSWindow, onComplete: @escaping () -> Void
    ) {
        self.names = names
        self.directory = directory
        self.existing = existing
        self.onComplete = onComplete
        recompute()

        let windowFrame = window.frame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: windowFrame.midX - size.width / 2, y: windowFrame.midY - size.height / 2))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(findField)
    }

    private func currentRule() -> RenameRule {
        var rule = RenameRule()
        rule.find = findField.stringValue
        rule.replace = replaceField.stringValue
        rule.useRegex = regexCheck.state == .on
        rule.prefix = prefixField.stringValue
        rule.suffix = suffixField.stringValue
        let cases: [RenameRule.CaseMode] = [.none, .lower, .upper, .title]
        rule.caseMode = cases[min(max(casePopup.indexOfSelectedItem, 0), 3)]
        rule.includeExtension = extCheck.state == .on
        if numberCheck.state == .on {
            rule.counterStart = Int(startField.stringValue) ?? 1
            rule.counterPadding = max(1, Int(padField.stringValue) ?? 1)
        }
        return rule
    }

    private func recompute() {
        plan = BatchRename.plan(currentRule(), names: names, existing: existing)
        table.reloadData()
        let changes = plan.pairs.contains { $0.original != $0.renamed }
        applyButton.isEnabled = changes && !plan.hasCollisions
        warnLabel.stringValue =
            plan.hasCollisions ? L("rename.conflicts", "Name conflicts: adjust the rule before renaming.") : ""
    }

    func controlTextDidChange(_ obj: Notification) { recompute() }
    @objc private func ruleChanged() { recompute() }

    @objc private func cancel() { panel.orderOut(nil) }

    @objc private func apply() {
        guard applyButton.isEnabled else { return }
        let outcome = BatchRename.perform(in: directory, pairs: plan.pairs)
        panel.orderOut(nil)
        onComplete?()
        if !outcome.failures.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(
                format: L("rename.renameResult", "Renamed %d; %d failed"),
                outcome.renamed, outcome.failures.count)
            alert.informativeText = outcome.failures.prefix(8).joined(separator: "\n")
            alert.runModal()
        }
    }

    // MARK: Preview table

    func numberOfRows(in tableView: NSTableView) -> Int { plan.pairs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < plan.pairs.count else { return nil }
        let pair = plan.pairs[row]
        let id = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? Self.makeCell(id)
        if id.rawValue == "current" {
            cell.textField?.stringValue = pair.original
            cell.textField?.textColor = .secondaryLabelColor
        } else {
            cell.textField?.stringValue = pair.renamed
            cell.textField?.textColor = plan.collisions.contains(pair.renamed) ? .systemRed : .labelColor
        }
        return cell
    }

    private static func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingMiddle
        field.font = .systemFont(ofSize: 12)
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
