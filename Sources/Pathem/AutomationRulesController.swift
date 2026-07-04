import AppKit
import PathemEngine

/// Manage watched-folder automation rules: a list with enable toggles, add/edit/delete, and
/// a Run Now. Editing opens a form sheet for the folder, match criteria, and action. Reads
/// and writes rules through the AutomationManager.
@MainActor
final class AutomationRulesController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
    private let table = NSTableView()
    private weak var manager: AutomationManager?
    private var rules: [AutomationRule] = []
    private var editor: RuleEditor?

    override init() {
        super.init()
        panel.title = L("auto.title", "Automation Rules")
        panel.isReleasedWhenClosed = false
        build()
    }

    func present(manager: AutomationManager, over window: NSWindow?) {
        self.manager = manager
        rules = manager.rules
        table.reloadData()
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
    }

    private func build() {
        for (id, title, width) in [
            ("on", "", CGFloat(26)), ("name", L("auto.colName", "Rule"), CGFloat(170)),
            ("summary", L("auto.colWhat", "When / Do"), CGFloat(400)),
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(editSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            return b
        }
        let actions = NSStackView(views: [
            button(L("auto.add", "Add"), #selector(addRule)),
            button(L("auto.edit", "Edit"), #selector(editSelected)),
            button(L("auto.delete", "Delete"), #selector(deleteSelected)),
            NSView(),
            button(L("auto.runNow", "Run Now"), #selector(runNow)),
        ])
        actions.orientation = .horizontal
        actions.spacing = 10

        let root = NSStackView(views: [scroll, actions])
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(root)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            ])
        }
    }

    private func commit() {
        manager?.setRules(rules)
        table.reloadData()
    }

    static func summary(_ rule: AutomationRule) -> String {
        var when: [String] = []
        if let s = rule.nameContains, !s.isEmpty { when.append("name has \"\(s)\"") }
        if let e = rule.ext, !e.isEmpty { when.append(".\(e)") }
        if let k = rule.kind { when.append(k.rawValue) }
        if let d = rule.olderThanDays { when.append("older than \(d)d") }
        if let h = rule.fromHostContains, !h.isEmpty { when.append("from \(h)") }
        let match = when.isEmpty ? "any file" : when.joined(separator: ", ")
        let folder = (rule.folderPath as NSString).lastPathComponent
        let act: String
        switch rule.action {
        case .move: act = "move to \((rule.destinationPath as NSString?)?.lastPathComponent ?? "…")"
        case .trash: act = "trash"
        case .tag: act = "tag \(rule.tag ?? "…")"
        }
        return "\(folder): \(match) → \(act)"
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < rules.count else { return nil }
        let rule = rules[row]
        if tableColumn.identifier.rawValue == "on" {
            let id = NSUserInterfaceItemIdentifier("check")
            let checkbox =
                (tableView.makeView(withIdentifier: id, owner: self) as? NSButton)
                ?? {
                    let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
                    b.identifier = id
                    return b
                }()
            checkbox.tag = row
            checkbox.state = rule.enabled ? .on : .off
            return checkbox
        }
        let text = tableColumn.identifier.rawValue == "name" ? rule.name : Self.summary(rule)
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let view = NSTableCellView()
                view.identifier = id
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(field)
                view.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
                return view
            }()
        cell.textField?.stringValue = text
        return cell
    }

    // MARK: Actions

    @objc private func toggleEnabled(_ sender: NSButton) {
        guard rules.indices.contains(sender.tag) else { return }
        rules[sender.tag].enabled = sender.state == .on
        commit()
    }

    @objc private func addRule() {
        edit(AutomationRule(name: L("auto.newRule", "New Rule"))) { [weak self] new in
            self?.rules.append(new)
            self?.commit()
        }
    }

    @objc private func editSelected() {
        let row = table.selectedRow
        guard rules.indices.contains(row) else { NSSound.beep(); return }
        edit(rules[row]) { [weak self] updated in
            self?.rules[row] = updated
            self?.commit()
        }
    }

    @objc private func deleteSelected() {
        let row = table.selectedRow
        guard rules.indices.contains(row) else { NSSound.beep(); return }
        rules.remove(at: row)
        commit()
    }

    @objc private func runNow() {
        let outcomes = manager?.runNow() ?? []
        let alert = NSAlert()
        alert.messageText = L("auto.ranTitle", "Automation")
        let ok = outcomes.filter(\.success).count
        alert.informativeText = String(format: L("auto.ranBody", "%d action(s) applied."), ok)
        alert.beginSheetModal(for: panel) { _ in }
    }

    private func edit(_ rule: AutomationRule, completion: @escaping (AutomationRule) -> Void) {
        let editor = RuleEditor()
        self.editor = editor
        editor.present(rule, over: panel) { [weak self] result in
            self?.editor = nil
            if let result { completion(result) }
        }
    }

    var debugContentReady: Bool { panel.contentView?.subviews.isEmpty == false }
}

/// The add/edit form for one rule.
@MainActor
private final class RuleEditor: NSObject {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
        styleMask: [.titled], backing: .buffered, defer: true)
    private let nameField = NSTextField()
    private let folderField = NSTextField()
    private let nameContains = NSTextField()
    private let extField = NSTextField()
    private let kindPopup = NSPopUpButton()
    private let ageField = NSTextField()
    private let hostField = NSTextField()
    private let actionPopup = NSPopUpButton()
    private let destinationField = NSTextField()
    private let tagField = NSTextField()
    private let enabledCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var rule = AutomationRule()
    private var completion: ((AutomationRule?) -> Void)?

    override init() {
        super.init()
        panel.title = L("auto.editTitle", "Rule")
        panel.isReleasedWhenClosed = false
        build()
    }

    func present(_ rule: AutomationRule, over window: NSWindow, completion: @escaping (AutomationRule?) -> Void) {
        self.rule = rule
        self.completion = completion
        nameField.stringValue = rule.name
        folderField.stringValue = rule.folderPath
        nameContains.stringValue = rule.nameContains ?? ""
        extField.stringValue = rule.ext ?? ""
        kindPopup.selectItem(at: rule.kind.flatMap { AutomationRule.Kind.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        ageField.stringValue = rule.olderThanDays.map(String.init) ?? ""
        hostField.stringValue = rule.fromHostContains ?? ""
        actionPopup.selectItem(at: AutomationRule.Action.allCases.firstIndex(of: rule.action) ?? 0)
        destinationField.stringValue = rule.destinationPath ?? ""
        tagField.stringValue = rule.tag ?? ""
        enabledCheck.state = rule.enabled ? .on : .off
        window.beginSheet(panel) { _ in }
    }

    private func row(_ label: String, _ control: NSView, trailing: NSView? = nil) -> NSStackView {
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 12)
        name.alignment = .right
        name.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let views: [NSView] = trailing.map { [name, control, $0] } ?? [name, control]
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return stack
    }

    private func build() {
        for kind in ["Any kind"] + AutomationRule.Kind.allCases.map({ $0.rawValue.capitalized }) {
            kindPopup.addItem(withTitle: kind)
        }
        for action in AutomationRule.Action.allCases { actionPopup.addItem(withTitle: action.rawValue.capitalized) }
        let chooseFolder = NSButton(title: L("auto.choose", "Choose…"), target: self, action: #selector(chooseFolder))
        chooseFolder.bezelStyle = .rounded
        let chooseDest = NSButton(title: L("auto.choose", "Choose…"), target: self, action: #selector(chooseDestination))
        chooseDest.bezelStyle = .rounded

        let form = NSStackView(views: [
            row(L("auto.name", "Name"), nameField),
            row(L("auto.folder", "Watch folder"), folderField, trailing: chooseFolder),
            row(L("auto.nameHas", "Name contains"), nameContains),
            row(L("auto.ext", "Extension"), extField),
            row(L("auto.kind", "Kind"), kindPopup),
            row(L("auto.olderThan", "Older than (days)"), ageField),
            row(L("auto.fromHost", "Downloaded from"), hostField),
            row(L("auto.action", "Action"), actionPopup),
            row(L("auto.destination", "Move to"), destinationField, trailing: chooseDest),
            row(L("auto.tag", "Tag"), tagField),
            row(L("auto.enabled", "Enabled"), enabledCheck),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8

        let save = NSButton(title: L("common.save", "Save"), target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: L("common.cancel", "Cancel"), target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal

        let root = NSStackView(views: [form, buttons])
        root.orientation = .vertical
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(root)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                buttons.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            ])
        }
    }

    @objc private func chooseFolder() { pickFolder { self.folderField.stringValue = $0.path } }
    @objc private func chooseDestination() { pickFolder { self.destinationField.stringValue = $0.path } }

    private func pickFolder(_ set: @escaping (URL) -> Void) {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.beginSheetModal(for: panel) { response in
            if response == .OK, let url = picker.url { set(url) }
        }
    }

    private func optional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    @objc private func save() {
        rule.name = nameField.stringValue.isEmpty ? L("auto.newRule", "New Rule") : nameField.stringValue
        rule.folderPath = folderField.stringValue
        rule.nameContains = optional(nameContains.stringValue)
        rule.ext = optional(extField.stringValue)?.replacingOccurrences(of: ".", with: "").lowercased()
        rule.kind = kindPopup.indexOfSelectedItem > 0 ? AutomationRule.Kind.allCases[kindPopup.indexOfSelectedItem - 1] : nil
        rule.olderThanDays = Int(ageField.stringValue.trimmingCharacters(in: .whitespaces))
        rule.fromHostContains = optional(hostField.stringValue)
        rule.action = AutomationRule.Action.allCases[actionPopup.indexOfSelectedItem]
        rule.destinationPath = optional(destinationField.stringValue)
        rule.tag = optional(tagField.stringValue)
        rule.enabled = enabledCheck.state == .on
        guard !rule.folderPath.isEmpty else { NSSound.beep(); return }
        panel.sheetParent?.endSheet(panel)
        completion?(rule)
    }

    @objc private func cancel() {
        panel.sheetParent?.endSheet(panel)
        completion?(nil)
    }
}
