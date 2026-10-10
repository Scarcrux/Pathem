#if canImport(AppKit)
import AppKit
import GestureSupport

public enum RecordingCancellation: Equatable, Sendable {
    case escape, timeout, deactivated, removed, replaced
}

/// Shared recording/practice surface. Callbacks return a stroke, never execute
/// an app action. Styles, hint text and action titles are supplied by the host.
@MainActor
open class StrokeRecordingView: NSView {
    public var allowedButtons: Set<Int> = [0, 1]
    public var onStroke: (([StrokeDirection]) -> Void)?
    public var onEmpty: (() -> Void)?
    public var preview: (([StrokeDirection]) -> String)?
    public var idleText = "Draw to record" { didSet { if capture == nil { setHint(idleText) } } }
    public var hintFont: NSFont = .systemFont(ofSize: 13) { didSet { needsDisplay = true } }
    public var accentColor: NSColor = .controlAccentColor
    public var overflowPolicy: StrokeOverflowPolicy = .reject
    public private(set) var hint = ""
    public var capturedPointCount: Int { capture?.visualPointCount ?? 0 }
    public var isRecording: Bool { capture != nil }
    private var capture: StrokeCapture<RecordingCancellation>?
    private var mouseButton: Int?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.4).cgColor
        setHint(idleText)
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    open override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 120) }
    open override var acceptsFirstResponder: Bool { true }
    open override func mouseDown(with event: NSEvent) { begin(event) }
    open override func rightMouseDown(with event: NSEvent) { begin(event) }
    open override func mouseDragged(with event: NSEvent) { move(event) }
    open override func rightMouseDragged(with event: NSEvent) { move(event) }
    open override func mouseUp(with event: NSEvent) { release(event) }
    open override func rightMouseUp(with event: NSEvent) { release(event) }
    open override func keyDown(with event: NSEvent) {
        if !handleCancellationKey(event) { super.keyDown(with: event) }
    }

    @discardableResult
    public func handleCancellationKey(_ event: NSEvent) -> Bool {
        guard capture != nil, event.keyCode == 53, event.windowNumber == window?.windowNumber else {
            return false
        }
        cancelRecording(.escape)
        return true
    }

    public func cancelRecording(_ reason: RecordingCancellation = .removed) {
        capture?.cancel(reason)
        finish()
    }

    // NSEvent.mouseEvent can report buttonNumber=0 for a synthetic right event.
    // The explicit native event family identifies these two owned button cycles.
    private func button(for event: NSEvent) -> Int {
        switch event.type {
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp: return 1
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: return 0
        default: return event.buttonNumber
        }
    }

    private func sample(_ event: NSEvent) -> StrokeSample {
        let point = convert(event.locationInWindow, from: nil)
        return StrokeSample(
            x: Double(point.x), y: Double(point.y), timestamp: event.timestamp,
            convention: isFlipped ? .yDown : .yUp)
    }
    private func begin(_ event: NSEvent) {
        cancelRecording(.replaced)
        guard allowedButtons.contains(button(for: event)), let window,
            event.windowNumber == window.windowNumber, window.attachedSheet == nil
        else { return }
        capture = try? StrokeCapture(
            origin: sample(event), maximumDuration: 10, overflow: overflowPolicy,
            timeoutReason: .timeout)
        mouseButton = button(for: event)
        updateHint()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleCancellationKey(event) == true ? nil : event }
        }
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if name == NSApplication.didResignActiveNotification
                            || (note.object as? NSWindow) === self.window
                        {
                            self.cancelRecording(.deactivated)
                        }
                    }
                })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.capture?.advanceClock(to: ProcessInfo.processInfo.systemUptime)
                if self.capture?.state != .capturing { self.finish() }
            }
        }
    }
    private func move(_ event: NSEvent) {
        guard capture != nil, button(for: event) == mouseButton,
            event.windowNumber == window?.windowNumber
        else { return }
        capture?.move(sample(event))
        if capture?.state != .capturing { finish() } else { updateHint() }
    }
    private func release(_ event: NSEvent) {
        guard button(for: event) == mouseButton, event.windowNumber == window?.windowNumber,
            let result = capture?.release(sample(event))
        else { return }
        finish()
        switch result {
        case .recognized(let directions): onStroke?(directions)
        case .empty: onEmpty?()
        case .cancelled, .rejected: break
        }
    }
    private func updateHint() {
        let directions = capture?.directions ?? []
        setHint(
            preview?(directions)
                ?? (directions.isEmpty
                    ? "Draw · Escape cancels"
                    : directions.map(\.arrow).joined() + " · release to record"))
        needsDisplay = true
    }
    private func setHint(_ text: String) {
        hint = text
        needsDisplay = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text)
    }
    private func finish() {
        capture = nil
        mouseButton = nil
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        setHint(idleText)
        needsDisplay = true
    }
    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelRecording(.removed) }
    }
    /// Draw hint text directly so an AppKit label's intrinsic constraints cannot
    /// resize or shift a SwiftUI-owned recording surface during layout.
    public var hintBounds: NSRect {
        NSRect(
            x: 6, y: isFlipped ? 8 : max(0, bounds.height - 30),
            width: max(0, bounds.width - 12), height: min(22, bounds.height))
    }
    open override func draw(_ dirtyRect: NSRect) {
        if let points = capture?.visualPoints, points.count >= 2,
            let context = NSGraphicsContext.current?.cgContext
        {
            context.setStrokeColor(accentColor.cgColor)
            context.setLineWidth(3)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            context.move(to: CGPoint(x: points[0].x, y: isFlipped ? -points[0].y : points[0].y))
            for point in points.dropFirst() {
                context.addLine(to: CGPoint(x: point.x, y: isFlipped ? -point.y : point.y))
            }
            context.strokePath()
        }
        (hint as NSString).draw(
            in: hintBounds,
            withAttributes: [.font: hintFont, .foregroundColor: NSColor.secondaryLabelColor])
    }
}
#endif
