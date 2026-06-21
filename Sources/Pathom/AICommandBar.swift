import AppKit

/// A natural-language command bar (DESIGN.md section 10, Phase 5): type a request
/// in plain English and Pathom runs the matching command. Resolution is async
/// (the Foundation Model when available, the engine heuristic otherwise), so the
/// bar shows a "thinking" state and never blocks the UI.
@MainActor
final class AICommandBar: NSObject, NSTextFieldDelegate {
    private let panel: NSPanel
    private let field = NSTextField()
    private let status = NSTextField(labelWithString: "")

    private var resolve: ((String) async -> (id: String, title: String)?)?
    private var run: ((String) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 96),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: true)
        super.init()
        configure()
    }

    private func configure() {
        panel.title = "Ask Pathom"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false

        field.placeholderString = "Tell Pathom what to do…"
        field.delegate = self
        field.font = .systemFont(ofSize: 15)
        field.translatesAutoresizingMaskIntoConstraints = false

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(field)
        content.addSubview(status)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            status.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
        ])
    }

    func present(
        over window: NSWindow,
        resolve: @escaping (String) async -> (id: String, title: String)?,
        run: @escaping (String) -> Void
    ) {
        self.resolve = resolve
        self.run = run
        field.stringValue = ""
        field.isEnabled = true
        status.stringValue = ""

        let windowFrame = window.frame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: windowFrame.midX - size.width / 2, y: windowFrame.maxY - size.height - 100))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func submit() {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let resolve else { return }
        status.stringValue = "Thinking…"
        field.isEnabled = false
        Task {
            let match = await resolve(query)
            field.isEnabled = true
            if let match {
                close()
                run?(match.id)
            } else {
                status.stringValue = "No command matched “\(query)”."
                panel.makeFirstResponder(field)
            }
        }
    }

    private func close() { panel.orderOut(nil) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): submit()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }
}
