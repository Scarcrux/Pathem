import AppKit
import PathemEngine

/// Renders a gesture stroke ("RD") as arrows ("→↓").
enum GestureFormat {
    private static let arrows: [Character: String] = ["R": "→", "L": "←", "U": "↑", "D": "↓"]
    static func display(_ stroke: String) -> String {
        stroke.map { arrows[$0] ?? String($0) }.joined()
    }
}

/// A bordered area that records a right-button stroke. Right-drag inside it to set a
/// gesture; a right-click without movement clears it. Mirrors KeyRecorderView for the
/// keyboard, so the Settings editor reads the same for keys and gestures.
@MainActor
final class GestureRecorderView: NSView {
    var onRecord: ((String) -> Void)?
    var onClear: (() -> Void)?
    var stroke: String = "" { didSet { updateLabel() } }

    private let label = NSTextField(labelWithString: "")
    private let tracker = MouseGestureTracker()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 44) }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.4).cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
        ])
        updateLabel()
    }

    override func rightMouseDown(with event: NSEvent) { tracker.begin(event) }
    override func rightMouseDragged(with event: NSEvent) { tracker.append(event) }
    override func rightMouseUp(with event: NSEvent) {
        if let stroke = tracker.end(event) {
            onRecord?(stroke)
        } else {
            onClear?()  // a click with no movement clears the binding
        }
    }

    private func updateLabel() {
        label.stringValue =
            stroke.isEmpty
            ? L("gestures.recordHint", "Right-drag here") : GestureFormat.display(stroke)
    }
}
