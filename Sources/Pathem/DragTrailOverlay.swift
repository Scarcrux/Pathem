import AppKit
import PathemEngine
import QuartzCore

extension NSColor {
    /// Parse a "#RRGGBB" / "#RRGGBBAA" hex string into an sRGB color; nil if malformed.
    /// Thin wrapper over the engine's single HexColor parser.
    convenience init?(hex: String) {
        guard let c = HexColor.parse(hex) else { return nil }
        self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    /// "#RRGGBB" for this color, converted to sRGB first (a color from a picker may be in
    /// another space, where componentwise access would trap).
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return HexColor.format(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
    }
}

/// A phone-swipe-style trail drawn on the window's overlay layer while a super-drag flick is in
/// progress: a stroke through the recent drag points that tapers and fades from the tail to the
/// moving head, with a soft dot at the tip. Non-interactive (never intercepts the drag). Points
/// are in this view's coordinates; the browser converts each drag screen point before adding it.
final class DragTrailOverlay: NSView {
    var color: NSColor = .systemBlue
    var trailWidth: CGFloat = 6
    /// Seconds a point stays on the trail before it fades out (longer = a longer, more visible
    /// trail). Set from the preference each time a drag begins.
    var decaySeconds: Double = 0.6
    /// What the current flick will do (e.g. "Move to Trash  ⌫"), shown as a badge at the head.
    var hint: String = ""

    private var points: [(point: NSPoint, time: CFTimeInterval)] = []
    private let maxPoints = 400  // safety cap on a very long slow drag

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true  // layer-backed so it composites reliably over the drag image
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Never swallow the drag (or any click) -- this is pure decoration on top of the panes.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func begin() {
        points = []
        isHidden = false
    }

    /// Append a point (in this view's coordinates) to the head of the trail, then drop points
    /// older than the decay time. Draws synchronously: during a drag the run loop is in
    /// event-tracking mode and a deferred needsDisplay would not flush until the drag ended.
    func add(_ point: NSPoint) {
        let now = CACurrentMediaTime()
        points.append((point, now))
        let cutoff = now - decaySeconds
        points.removeAll { $0.time < cutoff }
        if points.count > maxPoints { points.removeFirst(points.count - maxPoints) }
        display()
    }

    func end() {
        points = []
        isHidden = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count >= 2, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // Fade + taper each segment by how recently it was drawn, so a fresh head is solid and
        // the tail dissolves as it reaches the decay time.
        let now = CACurrentMediaTime()
        let n = points.count
        for i in 1..<n {
            let age = now - points[i].time
            let t = max(0, 1 - CGFloat(age / max(0.01, decaySeconds)))  // 1 fresh -> 0 decayed
            ctx.setStrokeColor(color.withAlphaComponent(0.1 + 0.8 * t).cgColor)
            ctx.setLineWidth(max(1, trailWidth * (0.2 + 0.8 * t)))
            ctx.beginPath()
            ctx.move(to: points[i - 1].point)
            ctx.addLine(to: points[i].point)
            ctx.strokePath()
        }
        let head = points[n - 1].point
        let r = trailWidth * 0.7
        ctx.setFillColor(color.withAlphaComponent(0.95).cgColor)
        ctx.fillEllipse(in: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2))
        drawHint(near: head)
    }

    /// A rounded badge at the head naming the action + its keyboard shortcut, so the gesture
    /// reads as a shortcut for that command. Clamped to stay inside the overlay.
    private func drawHint(near head: NSPoint) {
        guard !hint.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = hint as NSString
        let textSize = text.size(withAttributes: attrs)
        let padX: CGFloat = 8, padY: CGFloat = 4
        var box = CGRect(
            x: head.x + 16, y: head.y + 16, width: textSize.width + padX * 2, height: textSize.height + padY * 2)
        box.origin.x = min(max(box.origin.x, 4), bounds.maxX - box.width - 4)
        box.origin.y = min(max(box.origin.y, 4), bounds.maxY - box.height - 4)
        let path = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
        color.blended(withFraction: 0.15, of: .black)?.withAlphaComponent(0.95).setFill()
        path.fill()
        text.draw(at: CGPoint(x: box.minX + padX, y: box.minY + padY), withAttributes: attrs)
    }
}
