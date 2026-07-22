import AppKit
import PathemEngine

/// Renders a gesture stroke ("RD") as arrows ("→↓").
enum GestureFormat {
    private static let arrows: [Character: String] = ["R": "→", "L": "←", "U": "↑", "D": "↓"]
    static func display(_ stroke: String) -> String {
        stroke.map { arrows[$0] ?? String($0) }.joined()
    }
}

/// A bordered canvas that records a stroke gesture: drag inside it (either mouse button, so it
/// is easy to test) and the path is drawn live, then reduced to a direction string on mouse-up.
/// A click without movement clears the binding. Mirrors KeyRecorderView for the keyboard.
@MainActor
final class GestureRecorderView: NSView {
    var onRecord: ((String) -> Void)?
    var onClear: (() -> Void)?
    var stroke: String = "" { didSet { updateLabel() } }

    private let label = NSTextField(labelWithString: "")
    private var points: [NSPoint] = []  // view-local (y-up), for live drawing + reduction

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // A real canvas, tall enough that up/down strokes clear the recognizer's segment threshold
    // (the old 44pt-tall box couldn't register a vertical gesture).
    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 120) }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.4).cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
        ])
        updateLabel()
    }

    // Record with either button so the box works however you drag in it.
    override func mouseDown(with event: NSEvent) { beginStroke(event) }
    override func mouseDragged(with event: NSEvent) { appendStroke(event) }
    override func mouseUp(with event: NSEvent) { endStroke() }
    override func rightMouseDown(with event: NSEvent) { beginStroke(event) }
    override func rightMouseDragged(with event: NSEvent) { appendStroke(event) }
    override func rightMouseUp(with event: NSEvent) { endStroke() }

    private func beginStroke(_ event: NSEvent) {
        points = [convert(event.locationInWindow, from: nil)]
        needsDisplay = true
    }

    private func appendStroke(_ event: NSEvent) {
        points.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    private func endStroke() {
        let reduced = MouseGesture.reduce(points)  // view coords are y-up, as reduce expects
        points = []
        needsDisplay = true
        if reduced.isEmpty { onClear?() } else { onRecord?(reduced) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count >= 2, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(ThemeManager.shared.accent.cgColor)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: points[0])
        for point in points.dropFirst() { ctx.addLine(to: point) }
        ctx.strokePath()
    }

    private func updateLabel() {
        label.stringValue =
            stroke.isEmpty
            ? L("gestures.recordHint", "Drag here to record a gesture") : GestureFormat.display(stroke)
    }
}
