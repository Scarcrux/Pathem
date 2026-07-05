import AppKit

extension NSColor {
    /// Parse a "#RRGGBB" (or "RRGGBB") hex string into an sRGB color; nil if malformed.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// "#RRGGBB" for this color, converted to sRGB first (a color from a picker may be in
    /// another space, where componentwise access would trap).
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X", Int(round(c.redComponent * 255)),
            Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

/// A phone-swipe-style trail drawn on the window's overlay layer while a super-drag flick is in
/// progress: a stroke through the recent drag points that tapers and fades from the tail to the
/// moving head, with a soft dot at the tip. Non-interactive (never intercepts the drag). Points
/// are in this view's coordinates; the browser converts each drag screen point before adding it.
final class DragTrailOverlay: NSView {
    var color: NSColor = .systemBlue
    var trailWidth: CGFloat = 6

    private var points: [NSPoint] = []
    private let maxPoints = 22  // the streak length that follows the cursor

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

    /// Append a point (in this view's coordinates) to the head of the trail. Draws
    /// synchronously: during a drag the run loop is in event-tracking mode and a deferred
    /// needsDisplay would not flush until the drag ended, so nothing would show mid-drag.
    func add(_ point: NSPoint) {
        points.append(point)
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
        // Tail -> head: each segment gets brighter and thicker toward the head, so the trail
        // reads as a fading swipe with a solid leading tip.
        let n = points.count
        for i in 1..<n {
            let t = CGFloat(i) / CGFloat(n - 1)  // 0 at the tail, 1 at the head
            ctx.setStrokeColor(color.withAlphaComponent(0.12 + 0.78 * t).cgColor)
            ctx.setLineWidth(max(1, trailWidth * (0.25 + 0.75 * t)))
            ctx.beginPath()
            ctx.move(to: points[i - 1])
            ctx.addLine(to: points[i])
            ctx.strokePath()
        }
        let head = points[n - 1]
        let r = trailWidth * 0.7
        ctx.setFillColor(color.withAlphaComponent(0.95).cgColor)
        ctx.fillEllipse(in: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2))
    }
}
