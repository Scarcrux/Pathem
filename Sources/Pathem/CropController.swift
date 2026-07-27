import AppKit
import PathemEngine

/// A small interactive image cropper: shows the image with a draggable / resizable crop rectangle
/// (drag inside to move, drag a corner to resize) and an aspect-ratio picker, then writes a cropped
/// copy. The actual crop is done by the pure `ImageCropper`; this is just the rectangle UI.
@MainActor
final class CropController: NSObject {
    private var window: NSWindow?
    private let cropView = CropView()
    private var sourceURL: URL?
    /// Called with the written cropped-copy URL on Apply.
    var onCropped: ((URL) -> Void)?

    func present(url: URL, over host: NSWindow?) {
        guard let image = NSImage(contentsOf: url), let pixelSize = ImageCropper.pixelSize(of: url) else {
            NSSound.beep()
            return
        }
        sourceURL = url
        cropView.configure(image: image, pixelSize: pixelSize)

        let aspect = NSPopUpButton()
        aspect.addItems(withTitles: AspectRatio.allCases.map(\.title))
        aspect.target = self
        aspect.action = #selector(aspectChanged(_:))
        let cancel = NSButton(title: L("common.cancel", "Cancel"), target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: L("crop.apply", "Crop"), target: self, action: #selector(applyCrop))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        let bar = NSStackView(views: [
            NSTextField(labelWithString: L("crop.aspect", "Aspect:")), aspect, NSView(), cancel, apply,
        ])
        bar.orientation = .horizontal
        bar.translatesAutoresizingMaskIntoConstraints = false
        cropView.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(cropView)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            cropView.topAnchor.constraint(equalTo: content.topAnchor),
            cropView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            cropView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: cropView.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.title = String(format: L("crop.windowTitle", "Crop “%@”"), url.lastPathComponent)
        window.contentView = content
        window.center()
        self.window = window
        if let host {
            host.beginSheet(window) { _ in }
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func aspectChanged(_ sender: NSPopUpButton) {
        cropView.aspect = AspectRatio.allCases[sender.indexOfSelectedItem]
    }

    @objc private func cancel() { close() }

    @objc private func applyCrop() {
        guard let sourceURL, let pixelRect = cropView.pixelCropRect() else { close(); return }
        let destination = PhotoLibrary.uniqueURL(
            in: sourceURL.deletingLastPathComponent(), name: ImageCropper.croppedName(for: sourceURL.lastPathComponent))
        do {
            try ImageCropper.crop(sourceURL, pixelRect: pixelRect, to: destination)
            close()
            onCropped?(destination)
        } catch {
            let alert = NSAlert()
            alert.messageText = L("crop.failedTitle", "Couldn’t crop the image")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L("common.ok", "OK"))
            if let window { alert.beginSheetModal(for: window) { _ in } }
        }
    }

    private func close() {
        guard let window else { return }
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
        self.window = nil
    }
}

enum AspectRatio: CaseIterable {
    case free, original, square, fourThree, sixteenNine

    var title: String {
        switch self {
        case .free: L("crop.free", "Free")
        case .original: L("crop.original", "Original")
        case .square: "1:1"
        case .fourThree: "4:3"
        case .sixteenNine: "16:9"
        }
    }

    /// width / height for a fixed ratio; nil = free, `originalSize` supplies the image ratio.
    func ratio(originalSize: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: originalSize.height > 0 ? originalSize.width / originalSize.height : nil
        case .square: 1
        case .fourThree: 4.0 / 3.0
        case .sixteenNine: 16.0 / 9.0
        }
    }
}

/// The crop canvas: draws the image aspect-fit, a dimmed outside, and a draggable/resizable crop
/// rectangle with corner handles. Flipped (top-left origin) so its coordinates match image pixels.
final class CropView: NSView {
    private var image: NSImage?
    private var pixelSize: CGSize = .zero
    private var cropRect: CGRect = .zero  // in view coordinates, inside imageFrame
    var aspect: AspectRatio = .free { didSet { applyAspect() } }

    private let handleSize: CGFloat = 12
    private let minSize: CGFloat = 24

    override var isFlipped: Bool { true }

    func configure(image: NSImage, pixelSize: CGSize) {
        self.image = image
        self.pixelSize = pixelSize
        cropRect = .zero
        needsLayout = true
        needsDisplay = true
    }

    /// The rect the image is drawn in: aspect-fit within the view, centered.
    private var imageFrame: CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return bounds }
        let scale = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        // Seed / clamp the crop rect to the current image frame.
        let frame = imageFrame
        if cropRect == .zero || !frame.contains(cropRect) {
            cropRect = frame.insetBy(dx: frame.width * 0.1, dy: frame.height * 0.1)
            applyAspect()
        }
    }

    private func applyAspect() {
        guard let ratio = aspect.ratio(originalSize: pixelSize) else { needsDisplay = true; return }
        let frame = imageFrame
        // Largest centered rect of `ratio` that fits inside the current crop rect's bounds (the image).
        var width = frame.width
        var height = width / ratio
        if height > frame.height {
            height = frame.height
            width = height * ratio
        }
        cropRect = CGRect(
            x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let image else { return }
        let frame = imageFrame
        image.draw(in: frame, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        // Dim everything outside the crop rect.
        NSColor.black.withAlphaComponent(0.5).setFill()
        let outside = NSBezierPath(rect: frame)
        outside.append(NSBezierPath(rect: cropRect).reversed)
        outside.fill()

        // Crop border + corner handles.
        ThemeManager.shared.accent.setStroke()
        let border = NSBezierPath(rect: cropRect)
        border.lineWidth = 2
        border.stroke()
        ThemeManager.shared.accent.setFill()
        for corner in corners(of: cropRect) {
            NSBezierPath(ovalIn: CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)).fill()
        }
    }

    private func corners(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ]
    }

    // MARK: - Mouse

    private enum Handle { case topLeft, topRight, bottomLeft, bottomRight, body }
    private var activeHandle: Handle?
    private var dragOrigin: CGPoint = .zero
    private var startRect: CGRect = .zero

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = point
        startRect = cropRect
        activeHandle = handle(at: point)
    }

    private func handle(at point: CGPoint) -> Handle? {
        let named: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: cropRect.minX, y: cropRect.minY)),
            (.topRight, CGPoint(x: cropRect.maxX, y: cropRect.minY)),
            (.bottomLeft, CGPoint(x: cropRect.minX, y: cropRect.maxY)),
            (.bottomRight, CGPoint(x: cropRect.maxX, y: cropRect.maxY)),
        ]
        for (handle, corner) in named where hypot(point.x - corner.x, point.y - corner.y) <= handleSize {
            return handle
        }
        return cropRect.contains(point) ? .body : nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let activeHandle else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - dragOrigin.x
        let dy = point.y - dragOrigin.y
        let frame = imageFrame
        var rect = startRect

        switch activeHandle {
        case .body:
            rect.origin.x = startRect.minX + dx
            rect.origin.y = startRect.minY + dy
            rect.origin.x = min(max(rect.minX, frame.minX), frame.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, frame.minY), frame.maxY - rect.height)
        case .topLeft:
            rect = normalized(from: CGPoint(x: startRect.maxX, y: startRect.maxY), to: point, in: frame)
        case .topRight:
            rect = normalized(from: CGPoint(x: startRect.minX, y: startRect.maxY), to: point, in: frame)
        case .bottomLeft:
            rect = normalized(from: CGPoint(x: startRect.maxX, y: startRect.minY), to: point, in: frame)
        case .bottomRight:
            rect = normalized(from: CGPoint(x: startRect.minX, y: startRect.minY), to: point, in: frame)
        }
        cropRect = rect
        needsDisplay = true
    }

    /// Build a rect from a fixed anchor corner to the dragged point, honoring the aspect ratio and
    /// the minimum size, clamped inside `frame`.
    private func normalized(from anchor: CGPoint, to dragged: CGPoint, in frame: CGRect) -> CGRect {
        let clamped = CGPoint(
            x: min(max(dragged.x, frame.minX), frame.maxX), y: min(max(dragged.y, frame.minY), frame.maxY))
        var width = abs(clamped.x - anchor.x)
        var height = abs(clamped.y - anchor.y)
        if let ratio = aspect.ratio(originalSize: pixelSize) {
            // Lock to the ratio using the larger drag axis.
            if width / max(height, 1) > ratio { height = width / ratio } else { width = height * ratio }
        }
        width = max(width, minSize)
        height = max(height, minSize)
        let x = clamped.x < anchor.x ? anchor.x - width : anchor.x
        let y = clamped.y < anchor.y ? anchor.y - height : anchor.y
        return CGRect(x: x, y: y, width: width, height: height).intersection(frame)
    }

    /// The crop rect in image pixel coordinates (origin top-left), or nil if degenerate.
    func pixelCropRect() -> CGRect? {
        let frame = imageFrame
        guard frame.width > 0, pixelSize.width > 0 else { return nil }
        let scale = pixelSize.width / frame.width
        let rect = CGRect(
            x: (cropRect.minX - frame.minX) * scale,
            y: (cropRect.minY - frame.minY) * scale,
            width: cropRect.width * scale,
            height: cropRect.height * scale)
        return rect.width >= 1 && rect.height >= 1 ? rect : nil
    }
}
