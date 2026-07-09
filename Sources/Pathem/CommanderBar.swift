import AppKit

/// The orthodox-file-manager "commander" strip: a command line plus a function-key button row
/// (F3 View, F4 Edit, F5 Copy, F6 Move, F7 New Folder, F8 Delete), docked at the bottom of the
/// window. Each button runs an existing command; the command line runs in the embedded terminal.
/// A toggle over the dual pane (Total/Midnight Commander style), not a new view.
@MainActor
final class CommanderBar: NSView {
    /// The default F3–F8 command ids (orthodox: View / Edit / Copy / Move / MkDir / Delete).
    static let defaultCommandIDs = [
        "view.quickLook", "files.openInEditor", "files.copyToOtherPane",
        "files.moveToOtherPane", "files.newFolder", "files.trash",
    ]
    /// Short labels for the defaults; a reassigned key falls back to the command's own title.
    private static let shortLabels: [String: String] = [
        "view.quickLook": "View", "files.openInEditor": "Edit", "files.copyToOtherPane": "Copy",
        "files.moveToOtherPane": "Move", "files.newFolder": "MkDir", "files.trash": "Delete",
    ]

    private let promptLabel = NSTextField(labelWithString: "")
    private let commandField = NSTextField()
    private let strip = NSStackView()
    private var functionButtons: [NSButton] = []
    /// Run a typed command line (in the current folder).
    var onRunCommand: ((String) -> Void)?
    /// Run a function-key command by id.
    var onCommand: ((String) -> Void)?
    /// Resolve a command id to its display title (used to label a reassigned F-key).
    var titleForCommand: ((String) -> String)?

    /// The command bound to each of the six F-keys; setting it rebuilds the button row.
    var commandIDs: [String] = defaultCommandIDs {
        didSet { if oldValue != commandIDs { rebuildFunctionButtons() } }
    }

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
        guard sender.tag >= 0, sender.tag < commandIDs.count else { return }
        onCommand?(commandIDs[sender.tag])
    }

    /// The label for the F-key at `index`: the orthodox short label for a default command, else
    /// the command's own title.
    private func label(for id: String) -> String {
        if let short = Self.shortLabels[id] { return L("commander.\(short)", short) }
        return titleForCommand?(id) ?? id
    }

    /// Rebuild the six function-key buttons from the current `commandIDs`.
    func rebuildFunctionButtons() {
        functionButtons.forEach { strip.removeArrangedSubview($0); $0.removeFromSuperview() }
        functionButtons = []
        for (index, id) in commandIDs.prefix(6).enumerated() {
            let button = NSButton(
                title: "F\(3 + index) \(label(for: id))", target: self, action: #selector(functionTapped(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 11)
            button.toolTip = label(for: id)
            button.setContentHuggingPriority(.required, for: .horizontal)
            strip.addArrangedSubview(button)
            functionButtons.append(button)
        }
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

        strip.setViews([promptLabel, commandField], in: .leading)
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
        rebuildFunctionButtons()
    }
}
