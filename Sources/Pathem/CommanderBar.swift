import AppKit

/// The orthodox-file-manager "commander" strip: a command line plus a function-key button row
/// (F3 View, F4 Edit, F5 Copy, F6 Move, F7 New Folder, F8 Delete), docked at the bottom of the
/// window. Each button runs an existing command; the command line runs in the embedded terminal.
/// A toggle over the dual pane (Total/Midnight Commander style), not a new view.
@MainActor
final class CommanderBar: NSView {
    /// (F-key label, tooltip, command id) for each function-key button.
    static let functions: [(key: String, label: String, command: String)] = [
        ("F3", "View", "view.quickLook"),
        ("F4", "Edit", "files.openInEditor"),
        ("F5", "Copy", "files.copyToOtherPane"),
        ("F6", "Move", "files.moveToOtherPane"),
        ("F7", "MkDir", "files.newFolder"),
        ("F8", "Delete", "files.trash"),
    ]

    private let promptLabel = NSTextField(labelWithString: "")
    private let commandField = NSTextField()
    /// Run a typed command line (in the current folder).
    var onRunCommand: ((String) -> Void)?
    /// Run a function-key command by id.
    var onCommand: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Update the command-line prompt to the current folder name.
    func setPrompt(_ folderName: String) {
        promptLabel.stringValue = folderName.isEmpty ? "$" : "\(folderName) $"
    }

    func focusCommandLine() { window?.makeFirstResponder(commandField) }

    @objc private func runCommand() {
        let text = commandField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        commandField.stringValue = ""
        onRunCommand?(text)
    }

    @objc private func functionTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < Self.functions.count else { return }
        onCommand?(Self.functions[sender.tag].command)
    }

    private func build() {
        // A single compact strip: prompt, command line, then the function-key buttons.
        promptLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        promptLabel.textColor = .secondaryLabelColor
        promptLabel.setContentHuggingPriority(.required, for: .horizontal)
        promptLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        commandField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandField.placeholderString = L("commander.placeholder", "shell command, Return to run in the terminal")
        commandField.target = self
        commandField.action = #selector(runCommand)
        commandField.bezelStyle = .roundedBezel
        commandField.setContentHuggingPriority(.init(1), for: .horizontal)  // absorb slack

        var views: [NSView] = [promptLabel, commandField]
        for (index, fn) in Self.functions.enumerated() {
            let button = NSButton(title: "\(fn.key) \(L("commander.\(fn.label)", fn.label))", target: self, action: #selector(functionTapped(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 11)
            button.toolTip = L("commander.\(fn.label)", fn.label)
            button.setContentHuggingPriority(.required, for: .horizontal)
            views.append(button)
        }

        let strip = NSStackView(views: views)
        strip.orientation = .horizontal
        strip.spacing = 6
        strip.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
