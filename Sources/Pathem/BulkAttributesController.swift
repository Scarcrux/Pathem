import AppKit
import PathemEngine

/// A sheet to set metadata across a whole selection: modification/creation date, POSIX
/// permissions, and tags to add or remove. Each field is opt-in (a checkbox), so only the
/// ticked ones are applied. Hands the assembled changes back to the caller.
@MainActor
final class BulkAttributesController: NSObject {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
        styleMask: [.titled], backing: .buffered, defer: true)

    private let modCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let modPicker = NSDatePicker()
    private let createCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let createPicker = NSDatePicker()
    private let permCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let permField = NSTextField()
    private let groupCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let groupField = NSTextField()
    private let addTagsField = NSTextField()
    private let removeTagsField = NSTextField()
    private var onApply: ((BulkAttributes.Changes) -> Void)?

    override init() {
        super.init()
        panel.title = L("attrs.title", "Set Attributes")
        panel.isReleasedWhenClosed = false
        build()
    }

    func present(count: Int, over window: NSWindow, onApply: @escaping (BulkAttributes.Changes) -> Void) {
        self.onApply = onApply
        panel.title = String(format: L("attrs.titleFor", "Set Attributes: %d item(s)"), count)
        panel.growToFitContent()
        window.beginSheet(panel) { _ in }
    }

    private func build() {
        for picker in [modPicker, createPicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
            picker.dateValue = Date()
        }
        permField.placeholderString = "644"
        permField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        groupField.placeholderString = L("attrs.groupHint", "group name (e.g. staff)")
        groupField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        addTagsField.placeholderString = L("attrs.addTagsHint", "comma-separated")
        removeTagsField.placeholderString = L("attrs.removeTagsHint", "comma-separated")

        func labeled(_ title: String, _ control: NSView, check: NSButton? = nil) -> NSStackView {
            let name = NSTextField(labelWithString: title)
            name.font = .systemFont(ofSize: 12)
            name.alignment = .right
            name.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let views: [NSView] = check.map { [$0, name, control] } ?? [name, control]
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.spacing = 8
            return row
        }

        let rows = NSStackView(views: [
            labeled(L("attrs.modDate", "Modification date"), modPicker, check: modCheck),
            labeled(L("attrs.createDate", "Creation date"), createPicker, check: createCheck),
            labeled(L("attrs.permissions", "Permissions (octal)"), permField, check: permCheck),
            labeled(L("attrs.group", "Group"), groupField, check: groupCheck),
            labeled(L("attrs.addTags", "Add tags"), addTagsField),
            labeled(L("attrs.removeTags", "Remove tags"), removeTagsField),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10

        let apply = NSButton(title: L("common.apply", "Apply"), target: self, action: #selector(applyTapped))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        let cancel = NSButton(title: L("common.cancel", "Cancel"), target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let root = NSStackView(views: [rows, buttons])
        root.orientation = .vertical
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(root)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                buttons.trailingAnchor.constraint(equalTo: rows.trailingAnchor),
            ])
        }
    }

    private func parseTags(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @objc private func applyTapped() {
        var changes = BulkAttributes.Changes()
        if modCheck.state == .on { changes.modificationDate = modPicker.dateValue }
        if createCheck.state == .on { changes.creationDate = createPicker.dateValue }
        if permCheck.state == .on, let mode = UInt16(permField.stringValue.trimmingCharacters(in: .whitespaces), radix: 8) {
            changes.posixPermissions = mode & 0o7777
        }
        if groupCheck.state == .on {
            let group = groupField.stringValue.trimmingCharacters(in: .whitespaces)
            if !group.isEmpty { changes.groupOwnerName = group }
        }
        changes.addTags = parseTags(addTagsField.stringValue)
        changes.removeTags = parseTags(removeTagsField.stringValue)
        panel.sheetParent?.endSheet(panel)
        onApply?(changes)
    }

    @objc private func cancelTapped() { panel.sheetParent?.endSheet(panel) }

    /// Test hook: build the changes as if Apply were tapped, without a window.
    var debugContentReady: Bool { panel.contentView?.subviews.isEmpty == false }
}
