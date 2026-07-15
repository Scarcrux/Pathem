import AppKit

/// A borderless floating panel that can still take keyboard focus (Spotlight-style).
private final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A natural-language command bar (DESIGN.md section 10, Phase 5): type a request
/// in plain English and Pathem runs the matching command. Resolution is async
/// (the Foundation Model when available, the engine heuristic otherwise), so the
/// bar shows a "thinking" state and never blocks the UI. Presented as a rounded,
/// vibrant Spotlight-style bar with a sparkle glyph and example prompts.
@MainActor
final class AICommandBar: NSObject, NSTextFieldDelegate {
    private let panel: CommandBarPanel
    private let field = NSTextField()
    private let sparkle = NSImageView()
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let chips = NSStackView()

    private var resolve: ((String) async -> (id: String, title: String)?)?
    private var run: ((String) -> Void)?
    private var submitTask: Task<Void, Never>?

    /// Example prompts shown as chips beneath the field (also make the feature discoverable).
    private var examples: [String] {
        [
            L("aibar.ex1", "organize by file type"),
            L("aibar.ex2", "find duplicate files"),
            L("aibar.ex3", "sort by size largest first"),
        ]
    }

    override init() {
        panel = CommandBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 104),
            styleMask: [.borderless], backing: .buffered, defer: true)
        super.init()
        configure()
    }

    private func configure() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        sparkle.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        sparkle.symbolConfiguration = .init(pointSize: 22, weight: .medium)
        sparkle.contentTintColor = ThemeManager.shared.accent
        sparkle.translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = L("aibar.placeholder", "Tell Pathem what to do…")
        field.delegate = self
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        chips.orientation = .horizontal
        chips.spacing = 8
        chips.translatesAutoresizingMaskIntoConstraints = false
        for example in examples {
            let chip = NSButton(title: example, target: self, action: #selector(chipTapped(_:)))
            chip.bezelStyle = .badge
            chip.controlSize = .small
            chip.font = .systemFont(ofSize: 11)
            chips.addArrangedSubview(chip)
        }

        [sparkle, field, spinner, status, chips].forEach(blur.addSubview)
        NSLayoutConstraint.activate([
            sparkle.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 20),
            sparkle.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            sparkle.widthAnchor.constraint(equalToConstant: 26),
            field.topAnchor.constraint(equalTo: blur.topAnchor, constant: 18),
            field.leadingAnchor.constraint(equalTo: sparkle.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -10),
            spinner.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -20),
            spinner.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            status.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            status.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -20),
            chips.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            chips.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -16),
        ])
    }

    func present(
        over window: NSWindow,
        resolve: @escaping (String) async -> (id: String, title: String)?,
        run: @escaping (String) -> Void
    ) {
        submitTask?.cancel()  // abandon any resolve still running from a prior open
        submitTask = nil
        self.resolve = resolve
        self.run = run
        field.stringValue = ""
        status.stringValue = ""
        spinner.stopAnimation(nil)
        chips.isHidden = false

        let windowFrame = window.frame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: windowFrame.midX - size.width / 2, y: windowFrame.maxY - size.height - 120))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    @objc private func chipTapped(_ sender: NSButton) {
        field.stringValue = sender.title
        panel.makeFirstResponder(field)
        submit()
    }

    private func submit() {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let resolve, let run else { return }
        status.stringValue = L("aibar.thinking", "Thinking…")
        spinner.startAnimation(nil)
        chips.isHidden = true
        submitTask?.cancel()  // a new submit supersedes any in-flight one
        submitTask = Task { [weak self] in
            let match = await resolve(query)
            // Drop the result if this request was superseded or the bar was
            // dismissed while the (possibly multi-second) model call ran.
            guard let self, !Task.isCancelled, self.panel.isVisible else { return }
            self.spinner.stopAnimation(nil)
            if let match {
                self.close()
                run(match.id)
            } else {
                self.status.stringValue = String(
                    format: L("aibar.noMatch", "No command matched “%@”."), query)
            }
        }
    }

    private func close() {
        submitTask?.cancel()
        submitTask = nil
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): submit()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    var debugWindowNumber: Int { panel.windowNumber }
}
