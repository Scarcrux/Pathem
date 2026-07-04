import AppKit
import PathemEngine

/// Manage reusable "create" templates: a list with New / Edit / Delete / Run. Editing
/// uses a simple sheet (name + one entry per line; a trailing "/" makes a folder).
/// Changes are reported via `onChange` (the browser persists them and registers a
/// bindable command per template); Run instantiates a template in the active folder.
@MainActor
final class TemplatesController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private var templates: [CreateTemplate] = []
    private var onChange: (([CreateTemplate]) -> Void)?
    private var onRun: ((CreateTemplate) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        build()
    }

    func present(
        over window: NSWindow, templates: [CreateTemplate],
        onChange: @escaping ([CreateTemplate]) -> Void, onRun: @escaping (CreateTemplate) -> Void
    ) {
        self.templates = templates
        self.onChange = onChange
        self.onRun = onRun
        table.reloadData()
        panel.centerOverMainWindow()
        panel.makeKeyAndOrderFront(nil)
    }

    private func build() {
        panel.title = L("templates.title", "Create Templates")
        let column = NSTableColumn(identifier: .init("name"))
        column.title = L("templates.colName", "Template")
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.doubleAction = #selector(editTapped)
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        func button(_ title: String, _ selector: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: selector)
            b.bezelStyle = .rounded
            return b
        }
        let run = button(L("templates.run", "Run"), #selector(runTapped))
        run.keyEquivalent = "\r"  // default action, highlighted
        let buttons = NSStackView(views: [
            button(L("templates.new", "New…"), #selector(newTapped)),
            button(L("templates.edit", "Edit…"), #selector(editTapped)),
            button(L("templates.delete", "Delete"), #selector(deleteTapped)),
            NSView(),
            run,
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    /// Append a template authored elsewhere (Batch Create's "Save as Template").
    func add(_ template: CreateTemplate) {
        templates.append(template)
        onChange?(templates)
        table.reloadData()
    }

    private var selected: Int? {
        (0..<templates.count).contains(table.selectedRow) ? table.selectedRow : nil
    }

    @objc private func newTapped() {
        guard let edited = editorSheet(CreateTemplate(id: UUID().uuidString, name: "", entries: [])) else {
            return
        }
        templates.append(edited)
        commit()
    }

    @objc private func editTapped() {
        guard let index = selected, let edited = editorSheet(templates[index]) else { return }
        templates[index] = edited
        commit()
    }

    @objc private func deleteTapped() {
        guard let index = selected else { NSSound.beep(); return }
        templates.remove(at: index)
        commit()
    }

    @objc private func runTapped() {
        guard let index = selected else { NSSound.beep(); return }
        onRun?(templates[index])
    }

    private func commit() {
        onChange?(templates)
        table.reloadData()
    }

    /// A modal editor for one template (name + entries). Returns the edited template,
    /// or nil if cancelled or the name is empty.
    private func editorSheet(_ template: CreateTemplate) -> CreateTemplate? {
        let nameField = NSTextField(string: template.name)
        nameField.placeholderString = L("templates.namePlaceholder", "Template name")
        let entriesView = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 150))
        entriesView.string = template.entries.joined(separator: "\n")
        entriesView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        entriesView.isRichText = false
        entriesView.isAutomaticQuoteSubstitutionEnabled = false
        let entriesScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 150))
        entriesScroll.documentView = entriesView
        entriesScroll.hasVerticalScroller = true
        entriesScroll.borderType = .bezelBorder

        let hint = NSTextField(
            wrappingLabelWithString:
                L("templates.entriesHint", "One entry per line. End with “/” for a folder; nest with “/” (e.g. src/main.swift)."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [nameField, hint, entriesScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 210)
        nameField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        entriesScroll.widthAnchor.constraint(equalToConstant: 360).isActive = true
        entriesScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let alert = NSAlert()
        alert.messageText =
            template.name.isEmpty
            ? L("templates.newTitle", "New Template") : L("templates.editTitle", "Edit Template")
        alert.addButton(withTitle: L("common.save", "Save"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let entries = entriesView.string.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return CreateTemplate(id: template.id, name: name, entries: entries)
    }

    // MARK: Table
    func numberOfRows(in tableView: NSTableView) -> Int { templates.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let c = NSTableCellView()
                c.identifier = id
                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(field)
                c.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
        if row < templates.count { cell.textField?.stringValue = templates[row].name }
        return cell
    }
}
