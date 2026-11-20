import AppKit
import PathemEngine

/// Renders a canonical chord string ("cmd+shift+z") as Mac key symbols ("⌘⇧Z").
enum ChordFormat {
    static func display(_ canonical: String) -> String {
        guard !canonical.isEmpty else { return "" }
        var modifiers = ""
        var key = ""
        for part in canonical.split(separator: "+").map(String.init) {
            switch part {
            case "cmd": modifiers += "⌘"
            case "opt": modifiers += "⌥"
            case "ctrl": modifiers += "⌃"
            case "shift": modifiers += "⇧"
            default: key = part
            }
        }
        return modifiers + keyDisplay(key)
    }

    private static let keys: [String: String] = [
        "return": "⏎", "enter": "⌅", "tab": "⇥", "space": "Space", "delete": "⌫",
        "forwarddelete": "⌦", "escape": "⎋", "left": "←", "right": "→", "up": "↑", "down": "↓",
        "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ]

    static func keyDisplay(_ key: String) -> String {
        if let symbol = keys[key] { return symbol }
        return key.uppercased()
    }
}

/// A small bordered control that records the next key chord pressed. Click to focus
/// ("Type a shortcut…"), then any chord is reported via `onRecord`; Esc cancels and
/// plain Delete clears. Builds the chord with the same engine logic as live keys.
@MainActor
final class KeyRecorderView: NSView {
    var onRecord: ((KeyChord) -> Void)?
    var onClear: (() -> Void)?

    /// The chord currently shown (canonical form); set to reflect the selection.
    var canonical: String = "" { didSet { if !recording { updateLabel() } } }

    private var recording = false
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: max(150, ceil(label.intrinsicContentSize.width) + 12), height: 24)
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
        updateLabel()
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func becomeFirstResponder() -> Bool {
        recording = true
        layer?.borderColor = ThemeManager.shared.accent.cgColor
        updateLabel()
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        layer?.borderColor = NSColor.separatorColor.cgColor
        updateLabel()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags
        if event.keyCode == 53 {  // Esc cancels
            window?.makeFirstResponder(nil)
            return
        }
        let bareDelete =
            event.keyCode == 51 && !flags.contains(.command) && !flags.contains(.option)
            && !flags.contains(.control)
        if bareDelete {  // Delete clears the binding
            onClear?()
            window?.makeFirstResponder(nil)
            return
        }
        let chord = KeyChord.from(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
            cmd: flags.contains(.command), opt: flags.contains(.option),
            ctrl: flags.contains(.control), shift: flags.contains(.shift))
        onRecord?(chord)
        window?.makeFirstResponder(nil)
    }

    private func updateLabel() {
        if recording {
            label.stringValue = L("shortcuts.recording", "Type a shortcut…")
        } else if canonical.isEmpty {
            label.stringValue = L("shortcuts.clickToSet", "Click to set")
        } else {
            label.stringValue = ChordFormat.display(canonical)
        }
        invalidateIntrinsicContentSize()
    }
}
