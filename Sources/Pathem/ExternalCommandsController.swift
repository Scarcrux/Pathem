import AppKit
import PathemEngine

/// Manage user-defined external commands: a list with New / Edit / Delete / Run. Editing uses a
/// simple sheet (a name plus a shell command template with %F/%N/%D/%P placeholders). Changes are
/// reported via `onChange` (the browser persists them and registers a bindable command each); Run
/// executes the command on the active pane's selection.
@MainActor
final class ExternalCommandsController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private var commands: [ExternalCommand] = []
    private var onChange: (([ExternalCommand]) -> Void)?
    private var onRun: ((ExternalCommand) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        super.init()
        build()
    }

    func present(
        over window: NSWindow, commands: [ExternalCommand],
        onChange: @escaping ([ExternalCommand]) -> Void, onRun: @escaping (ExternalCommand) -> Void
    ) {
        self.commands = commands
        self.onChange = onChange
        self.onRun = onRun
        table.reloadData()
        panel.centerOverMainWindow()
        panel.makeKeyAndOrderFront(nil)
    }

    private func build() {
        panel.title = L("extcmd.title", "External Commands")
        let column = NSTableColumn(identifier: .init("name"))
        column.title = L("extcmd.colName", "Command")
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
        let run = button(L("extcmd.run", "Run"), #selector(runTapped))
        run.keyEquivalent = "\r"
        let buttons = NSStackView(views: [
            button(L("extcmd.new", "New…"), #selector(newTapped)),
            button(L("extcmd.edit", "Edit…"), #selector(editTapped)),
            button(L("extcmd.delete", "Delete"), #selector(deleteTapped)),
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

    private var selected: Int? {
        (0..<commands.count).contains(table.selectedRow) ? table.selectedRow : nil
    }

    @objc private func newTapped() {
        guard let edited = editorSheet(ExternalCommand(id: UUID().uuidString, name: "", command: "")) else { return }
        commands.append(edited)
        commit()
    }
    @objc private func editTapped() {
        guard let index = selected, let edited = editorSheet(commands[index]) else { return }
        commands[index] = edited
        commit()
    }
    @objc private func deleteTapped() {
        guard let index = selected else { NSSound.beep(); return }
        commands.remove(at: index)
        commit()
    }
    @objc private func runTapped() {
        guard let index = selected else { NSSound.beep(); return }
        onRun?(commands[index])
    }
    private func commit() {
        onChange?(commands)
        table.reloadData()
    }

    /// A modal editor for one command (name + shell template). Returns the edited command, or nil
    /// if cancelled or the name/command is empty.
    private func editorSheet(_ command: ExternalCommand) -> ExternalCommand? {
        let nameField = NSTextField(string: command.name)
        nameField.placeholderString = L("extcmd.namePlaceholder", "Command name")
        let commandView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 90))
        commandView.string = command.command
        commandView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandView.isRichText = false
        commandView.isAutomaticQuoteSubstitutionEnabled = false
        let commandScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 90))
        commandScroll.documentView = commandView
        commandScroll.hasVerticalScroller = true
        commandScroll.borderType = .bezelBorder

        let hint = NSTextField(
            wrappingLabelWithString:
                L("extcmd.hint",
                    "A shell command. Placeholders: %F selected paths, %N names, %D this folder, %P the parent. Example: open -a Preview %F"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [nameField, hint, commandScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 400, height: 160)
        nameField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        commandScroll.widthAnchor.constraint(equalToConstant: 400).isActive = true
        commandScroll.heightAnchor.constraint(equalToConstant: 90).isActive = true

        let alert = NSAlert()
        alert.messageText =
            command.name.isEmpty ? L("extcmd.newTitle", "New Command") : L("extcmd.editTitle", "Edit Command")
        alert.addButton(withTitle: L("common.save", "Save"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let template = commandView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !template.isEmpty else { return nil }
        return ExternalCommand(id: command.id, name: name, command: template)
    }

    // MARK: Table
    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }
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
        if row < commands.count { cell.textField?.stringValue = commands[row].name }
        return cell
    }
}
