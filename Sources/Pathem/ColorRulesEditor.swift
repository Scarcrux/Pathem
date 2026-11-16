import AppKit
import PathemEngine

/// The editor for file color rules (Directory-Opus labels), shown in Settings > Labels.
/// A reorderable list of rules, each with an enable checkbox and a live-styled preview;
/// Add / Edit open a sheet to set the match (field, test, value) and style (color, bold,
/// italic). The first enabled rule that matches an entry colors it.
@MainActor
final class ColorRulesEditorController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView()
    private let table = NSTableView()
    private let rowType = NSPasteboard.PasteboardType("com.scarcrux.pathem.colorrule-row")
    private var rules: [ColorRule]
    var onChange: (([ColorRule]) -> Void)?

    init(rules: [ColorRule]) {
        self.rules = rules
        super.init()
        build()
    }

    private func build() {
        let column = NSTableColumn(identifier: .init("rule"))
        column.title = L("prefs.labelsColumn", "Color Rules")
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(editSelected)
        table.target = self
        table.registerForDraggedTypes([rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(
            wrappingLabelWithString: L(
                "prefs.labelsHint",
                "Color and style filenames by rules. Drag to reorder (the first enabled rule that matches wins); uncheck to disable. Double-click a rule to edit it."
            ))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let add = button(L("common.add", "Add"), #selector(addRule))
        let edit = button(L("conn.editButton", "Edit"), #selector(editSelected))
        let remove = button(L("common.remove", "Remove"), #selector(removeSelected))
        let bar = NSStackView(views: [add, edit, remove])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(hint)
        view.addSubview(scroll)
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: view.topAnchor),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 320),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func commit() {
        table.reloadData()
        onChange?(rules)
    }

    // MARK: Edit sheet

    // Live controls of the open editor, so changing Field can repopulate Op + the value hint.
    private weak var editFieldPopup: NSPopUpButton?
    private weak var editOpPopup: NSPopUpButton?
    private weak var editValueField: NSTextField?

    static func ops(for field: ColorRule.Field) -> [ColorRule.Op] {
        switch field {
        case .ext, .kind: return [.isAnyOf]
        case .name: return [.contains, .beginsWith, .endsWith, .matches]
        case .size: return [.greaterThan, .lessThan]
        }
    }

    private static func opLabel(_ op: ColorRule.Op, field: ColorRule.Field) -> String {
        switch op {
        case .isAnyOf:
            return field == .kind
                ? L("prefs.labelOpIs", "is") : L("prefs.labelOpAnyOf", "is any of")
        case .contains: return L("prefs.labelOpContains", "contains")
        case .beginsWith: return L("prefs.labelOpBegins", "begins with")
        case .endsWith: return L("prefs.labelOpEnds", "ends with")
        case .matches: return L("prefs.labelOpMatches", "matches (glob)")
        case .greaterThan: return L("prefs.labelOpGreater", "greater than")
        case .lessThan: return L("prefs.labelOpLess", "less than")
        }
    }

    private static func valueHint(for field: ColorRule.Field) -> String {
        switch field {
        case .ext: return L("prefs.labelHintExt", "tmp, log, bak")
        case .name: return L("prefs.labelHintName", "draft")
        case .size: return L("prefs.labelHintSize", "1000  (MB)")
        case .kind: return L("prefs.labelHintKind", "folder or file")
        }
    }

    private func presentEditor(for rule: ColorRule, completion: @escaping (ColorRule) -> Void) {
        let (alert, name, field, opPopup, value, colorWell, noColor, bold, italic) =
            makeRuleEditorDialog(rule: rule)
        guard let host = view.window else { return }
        alert.beginSheetModal(for: host) { response in
            guard response == .alertFirstButtonReturn else { return }
            var edited = rule
            edited.name = name.stringValue
            edited.field = ColorRule.Field.allCases[field.indexOfSelectedItem]
            let ops = Self.ops(for: edited.field)
            edited.op = ops[min(opPopup.indexOfSelectedItem, ops.count - 1)]
            edited.value = value.stringValue.trimmingCharacters(in: .whitespaces)
            edited.colorHex = noColor.state == .on ? "" : (ThemeManager.hex(from: colorWell.color))
            edited.bold = bold.state == .on
            edited.italic = italic.state == .on
            completion(edited)
        }
    }

    @objc private func editFieldChanged() {
        guard let field = editFieldPopup else { return }
        let f = ColorRule.Field.allCases[field.indexOfSelectedItem]
        editValueField?.placeholderString = Self.valueHint(for: f)
        repopulateOps(selecting: Self.ops(for: f).first ?? .isAnyOf)
    }

    private func repopulateOps(selecting op: ColorRule.Op) {
        guard let field = editFieldPopup, let opPopup = editOpPopup else { return }
        let f = ColorRule.Field.allCases[field.indexOfSelectedItem]
        let ops = Self.ops(for: f)
        opPopup.removeAllItems()
        opPopup.addItems(withTitles: ops.map { Self.opLabel($0, field: f) })
        opPopup.selectItem(at: ops.firstIndex(of: op) ?? 0)
    }

    // MARK: Actions

    @objc private func addRule() {
        var rule = ColorRule(field: .ext, op: .isAnyOf, value: "tmp, log, bak", colorHex: "#8E8E93")
        rule.name = L("prefs.labelNewRule", "New Rule")
        presentEditor(for: rule) { [weak self] edited in
            self?.rules.append(edited)
            self?.commit()
        }
    }

    @objc private func editSelected() {
        let row = table.selectedRow
        guard rules.indices.contains(row) else { return }
        presentEditor(for: rules[row]) { [weak self] edited in
            self?.rules[row] = edited
            self?.commit()
        }
    }

    @objc private func removeSelected() {
        let row = table.selectedRow
        guard rules.indices.contains(row) else { return }
        rules.remove(at: row)
        commit()
    }

    @objc private func toggleRow(_ sender: NSButton) {
        guard rules.indices.contains(sender.tag) else { return }
        rules[sender.tag].enabled = sender.state == .on
        onChange?(rules)  // no reload: the checkbox already reflects it
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? RuleCell) ?? RuleCell(id: id)
        let rule = rules[row]
        cell.checkbox.state = rule.enabled ? .on : .off
        cell.checkbox.target = self
        cell.checkbox.action = #selector(toggleRow(_:))
        cell.checkbox.tag = row
        cell.swatch.fillColor = ThemeManager.color(fromHex: rule.colorHex) ?? .clear
        // A live preview: the rule's description drawn in its own color and style.
        let color = ThemeManager.color(fromHex: rule.colorHex) ?? .labelColor
        var font = NSFont.systemFont(ofSize: 12)
        if rule.bold || rule.italic {
            var traits: NSFontTraitMask = []
            if rule.bold { traits.insert(.boldFontMask) }
            if rule.italic { traits.insert(.italicFontMask) }
            font = NSFontManager.shared.convert(font, toHaveTrait: traits)
        }
        cell.label.attributedStringValue = NSAttributedString(
            string: Self.describe(rule), attributes: [.foregroundColor: color, .font: font])
        return cell
    }

    static func describe(_ rule: ColorRule) -> String {
        let field: String
        switch rule.field {
        case .ext: field = L("prefs.labelFieldExt", "Extension")
        case .name: field = L("prefs.labelFieldName", "Name")
        case .size: field = L("prefs.labelFieldSize", "Size")
        case .kind: field = L("prefs.labelFieldKind", "Kind")
        }
        let op: String
        switch rule.op {
        case .isAnyOf:
            op =
                rule.field == .kind
                ? L("prefs.labelOpIs", "is") : L("prefs.labelOpAnyOf", "is any of")
        case .contains: op = L("prefs.labelOpContains", "contains")
        case .beginsWith: op = L("prefs.labelOpBegins", "begins with")
        case .endsWith: op = L("prefs.labelOpEnds", "ends with")
        case .matches: op = L("prefs.labelOpMatches", "matches")
        case .greaterThan: op = L("prefs.labelOpGreater", "greater than")
        case .lessThan: op = L("prefs.labelOpLess", "less than")
        }
        let unit = rule.field == .size ? " MB" : ""
        return "\(field) \(op) \(rule.value)\(unit)"
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> NSPasteboardWriting?
    {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: rowType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
        proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        dropOperation == .above && info.draggingPasteboard.availableType(from: [rowType]) != nil
            ? .move : []
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let str = info.draggingPasteboard.string(forType: rowType), let from = Int(str),
            rules.indices.contains(from)
        else { return false }
        var target = row
        let moved = rules.remove(at: from)
        if from < target { target -= 1 }
        rules.insert(moved, at: min(max(target, 0), rules.count))
        commit()
        return true
    }

    /// A row: an enable checkbox, a color swatch, and a styled description.
    private final class RuleCell: NSTableCellView {
        let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        let swatch = SwatchView()
        let label = NSTextField(labelWithString: "")

        init(id: NSUserInterfaceItemIdentifier) {
            super.init(frame: .zero)
            identifier = id
            let stack = NSStackView(views: [checkbox, swatch, label])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
                swatch.widthAnchor.constraint(equalToConstant: 14),
                swatch.heightAnchor.constraint(equalToConstant: 14),
            ])
        }
        required init?(coder: NSCoder) { fatalError("not used") }
    }

    /// A small rounded color chip.
    final class SwatchView: NSView {
        var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            fillColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
        }
    }
}

@MainActor
extension ColorRulesEditorController {
    /// Production construction shared with isolated transient checks.
    func makeRuleEditorDialog(rule: ColorRule) -> (
        NSAlert, NSTextField, NSPopUpButton, NSPopUpButton, NSTextField, NSColorWell, NSButton,
        NSButton, NSButton
    ) {
        let alert = NSAlert()
        alert.messageText = L("prefs.labelEditTitle", "Color Rule")
        alert.addButton(withTitle: L("common.save", "Save"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))

        let field = NSPopUpButton()
        field.addItems(withTitles: [
            L("prefs.labelFieldExt", "Extension"), L("prefs.labelFieldName", "Name"),
            L("prefs.labelFieldSize", "Size"), L("prefs.labelFieldKind", "Kind"),
        ])
        field.selectItem(at: ColorRule.Field.allCases.firstIndex(of: rule.field) ?? 0)
        field.target = self
        field.action = #selector(editFieldChanged)
        editFieldPopup = field

        let opPopup = NSPopUpButton()
        editOpPopup = opPopup

        let value = NSTextField(string: rule.value)
        value.placeholderString = Self.valueHint(for: rule.field)
        editValueField = value
        repopulateOps(selecting: rule.op)  // fill the op popup for the current field

        let name = NSTextField(string: rule.name)
        name.placeholderString = L("prefs.labelRuleName", "Rule name (optional)")

        let colorWell = NSColorWell()
        colorWell.color = ThemeManager.color(fromHex: rule.colorHex) ?? .systemGray
        let noColor = NSButton(
            checkboxWithTitle: L("prefs.labelNoColor", "No color"), target: nil, action: nil)
        noColor.state = rule.colorHex.isEmpty ? .on : .off
        let bold = NSButton(
            checkboxWithTitle: L("prefs.labelBold", "Bold"), target: nil, action: nil)
        bold.state = rule.bold ? .on : .off
        let italic = NSButton(
            checkboxWithTitle: L("prefs.labelItalic", "Italic"), target: nil, action: nil)
        italic.state = rule.italic ? .on : .off

        func labeled(_ title: String, _ control: NSView) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 70).isActive = true
            control.translatesAutoresizingMaskIntoConstraints = false
            let row = NSStackView(views: [label, control])
            row.orientation = .horizontal
            row.spacing = 8
            control.widthAnchor.constraint(equalToConstant: 220).isActive = true
            return row
        }
        let styleRow = NSStackView(views: [colorWell, noColor, bold, italic])
        styleRow.orientation = .horizontal
        styleRow.spacing = 8
        let form = NSStackView(views: [
            labeled(L("prefs.labelRuleNameShort", "Name"), name),
            labeled(L("prefs.labelFieldLabel", "If"), field),
            labeled(L("prefs.labelOpLabel", "Test"), opPopup),
            labeled(L("prefs.labelValueLabel", "Value"), value),
            labeled(L("prefs.labelStyleLabel", "Style"), styleRow),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.translatesAutoresizingMaskIntoConstraints = false
        form.setFrameSize(NSSize(width: 320, height: 180))
        form.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = form
        return (alert, name, field, opPopup, value, colorWell, noColor, bold, italic)
    }
}
