import AppKit

/// A lightweight image markup editor: draw freehand annotations over a picture (pick a color and
/// width, undo strokes) and save a flattened copy. macOS has no public API to invoke the system
/// Markup sheet and no PencilKit canvas, so this is a small self-contained annotator. The canvas
/// overlays the image at its native pixel size (1:1), so strokes composite without scaling math.
@MainActor
final class MarkupController: NSObject {
    private var window: NSWindow?
    private let canvas = MarkupCanvas()
    private let colorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 24, target: nil, action: nil)
    private var sourceURL: URL?
    private var sourceImage: NSImage?
    /// Called with the new file after a successful save.
    var onSaved: ((URL) -> Void)?
    var onFailed: ((String) -> Void)?

    /// Open `url` (an image) for markup.
    func markup(_ url: URL) {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else {
            onFailed?(L("markup.cantOpen", "This image can’t be opened for markup."))
            return
        }
        sourceURL = url
        sourceImage = image
        canvas.reset(imageSize: image.size, background: image)
        colorWell.color = .systemRed
        canvas.strokeColor = colorWell.color
        canvas.strokeWidth = CGFloat(widthSlider.doubleValue)

        let window = self.window ?? makeWindow()
        self.window = window
        window.title = String(format: L("markup.title", "Markup: %@"), url.lastPathComponent)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(canvas)
    }

    @objc private func colorChanged() { canvas.strokeColor = colorWell.color }
    @objc private func widthChanged() { canvas.strokeWidth = CGFloat(widthSlider.doubleValue) }
    @objc private func undo() { canvas.undoStroke() }
    @objc private func cancel() { window?.orderOut(nil) }

    @objc private func save() {
        let result = renderAndSave()
        if let out = result.url {
            window?.orderOut(nil)
            onSaved?(out)
        } else {
            onFailed?(result.error ?? L("markup.saveFailed", "Couldn’t render the marked-up image."))
        }
    }

    /// Flatten the image + strokes to a new PNG; returns the output URL, or an error message.
    private func renderAndSave() -> (url: URL?, error: String?) {
        guard let url = sourceURL, let image = sourceImage else {
            return (nil, L("markup.saveFailed", "Couldn’t render the marked-up image."))
        }
        let output = NSImage(size: image.size)
        output.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        canvas.drawStrokes()  // strokes are in image-pixel coordinates (1:1), y-up like lockFocus
        output.unlockFocus()
        guard let tiff = output.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return (nil, L("markup.saveFailed", "Couldn’t render the marked-up image.")) }
        let out = Self.uniqueOutput(for: url)
        do {
            try png.write(to: out)
            return (out, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// PATHEM_SMOKE: load an image, draw a stroke, flatten, and return the output (or nil).
    func debugMarkupAndSave(_ url: URL) -> URL? {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return nil }
        sourceURL = url
        sourceImage = image
        canvas.reset(imageSize: image.size, background: image)
        canvas.debugAddStroke(
            [NSPoint(x: 0, y: 0), NSPoint(x: image.size.width, y: image.size.height)], color: .systemRed, width: 5)
        return renderAndSave().url
    }

    /// "<name> marked.png", unique in the source folder.
    private static func uniqueOutput(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + " marked"
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(base).appendingPathExtension("png")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension("png")
            n += 1
        }
        return candidate
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false  // the controller caches it in self.window; the default extra release UAFs
        window.center()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = canvas  // sized to the image in reset()
        scroll.translatesAutoresizingMaskIntoConstraints = false

        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)
        widthSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let undoButton = NSButton(title: L("markup.undo", "Undo Stroke"), target: self, action: #selector(undo))
        undoButton.bezelStyle = .rounded
        let cancelButton = NSButton(title: L("common.cancel", "Cancel"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        let saveButton = NSButton(title: L("markup.save", "Save a Copy"), target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let bar = NSStackView(views: [
            NSTextField(labelWithString: L("markup.color", "Color")), colorWell,
            NSTextField(labelWithString: L("markup.width", "Width")), widthSlider,
            undoButton, NSView(), cancelButton, saveButton,
        ])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(scroll)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return window
    }
}

/// The drawing surface: shows the image and captures freehand strokes over it (y-up, so strokes
/// composite onto an NSImage lockFocus at the same coordinates).
private final class MarkupCanvas: NSView {
    private struct Stroke {
        var points: [NSPoint]
        let color: NSColor
        let width: CGFloat
    }
    private var strokes: [Stroke] = []
    private var current: Stroke?
    private var background: NSImage?
    var strokeColor: NSColor = .systemRed
    var strokeWidth: CGFloat = 4

    override var isFlipped: Bool { false }  // y-up, matching NSImage lockFocus
    override var acceptsFirstResponder: Bool { true }

    func reset(imageSize: NSSize, background: NSImage) {
        self.background = background
        strokes = []
        current = nil
        setFrameSize(imageSize)
        needsDisplay = true
    }

    func undoStroke() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        needsDisplay = true
    }

    func debugAddStroke(_ points: [NSPoint], color: NSColor, width: CGFloat) {
        strokes.append(Stroke(points: points, color: color, width: width))
    }

    override func mouseDown(with event: NSEvent) {
        current = Stroke(points: [convert(event.locationInWindow, from: nil)], color: strokeColor, width: strokeWidth)
    }
    override func mouseDragged(with event: NSEvent) {
        current?.points.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let stroke = current, stroke.points.count > 1 { strokes.append(stroke) }
        current = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        background?.draw(in: bounds)
        drawStrokes()
        if let current { path(for: current).stroke() }
    }

    /// Stroke the committed annotations (used both on screen and when flattening to save).
    func drawStrokes() {
        for stroke in strokes {
            stroke.color.setStroke()
            path(for: stroke).stroke()
        }
    }

    private func path(for stroke: Stroke) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = stroke.width
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        stroke.color.setStroke()
        guard let first = stroke.points.first else { return path }
        path.move(to: first)
        for point in stroke.points.dropFirst() { path.line(to: point) }
        return path
    }
}
