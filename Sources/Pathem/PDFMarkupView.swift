import AppKit
import PDFKit

/// A `PDFView` subclass that adds Preview-style markup, all savable back into the PDF:
///
/// - **Selection markup** (highlight, underline, strikethrough) applied to the current text
///   selection -- these are actions, invoked from the toolbar while text is selected.
/// - **Modal tools** that capture the mouse: freehand ink (`draw`), a drawn `signature`, `rectangle`,
///   `oval`, `line`, `arrow`, a `text` box, and a sticky `note`.
///
/// With no tool active it behaves like a normal PDFView (scroll, select text), except that clicking
/// an existing annotation lets you drag it to reposition -- like Preview's arrow tool. Every edit is
/// undoable through a private undo manager and flips the document to a modified state via
/// `onDocumentEdited`, so the host can enable Save.
@MainActor
final class PDFMarkupView: PDFView {
    enum Tool: Equatable {
        case none, draw, signature, rectangle, oval, line, arrow, text, note
        /// A tool that rubber-bands out a shape between the drag's start and end points.
        var isDragShape: Bool {
            switch self {
            case .rectangle, .oval, .line, .arrow: return true
            default: return false
            }
        }
        /// A freehand tool that accumulates the pointer's path.
        var isFreehand: Bool { self == .draw || self == .signature }
    }

    var activeTool: Tool = .none { didSet { window?.invalidateCursorRects(for: self) } }
    var markupColor: NSColor = .systemYellow
    var lineWidth: CGFloat = 2
    /// Fired the first time an edit lands (and on every subsequent edit) so the host can show Save.
    var onDocumentEdited: (() -> Void)?

    private let markupUndo = UndoManager()
    private var freehandPoints: [CGPoint] = []
    private var dragStartPage: PDFPage?
    private var dragStartPoint: CGPoint = .zero
    private var liveAnnotation: PDFAnnotation?  // the shape/ink being previewed mid-drag
    private var hasDraggedFar = false  // did the pointer travel enough to count as a real drag?
    private var movingAnnotation: PDFAnnotation?
    private var moveGrabOffset: CGSize = .zero
    private var moveOriginalOrigin: CGPoint = .zero

    // MARK: Selection markup (applies to the current text selection)

    /// Mark up the current text selection with `subtype` (`.highlight`, `.underline`, `.strikeOut`),
    /// one annotation per visual line so multi-line selections wrap correctly. Returns false (and
    /// beeps) when there is no usable selection.
    @discardableResult
    func markUpSelection(_ subtype: PDFAnnotationSubtype) -> Bool {
        guard let selection = currentSelection else { NSSound.beep(); return false }
        var added = false
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 1, bounds.height > 1 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
                annotation.color = markupColor
                page.addAnnotation(annotation)
                registerAddUndo(annotation, page)
                added = true
            }
        }
        clearSelection()
        if added { markEdited() } else { NSSound.beep() }
        return added
    }

    // MARK: Undo / redo

    var canUndoMarkup: Bool { markupUndo.canUndo }
    var canRedoMarkup: Bool { markupUndo.canRedo }
    func undoMarkup() { if markupUndo.canUndo { markupUndo.undo() } }
    func redoMarkup() { if markupUndo.canRedo { markupUndo.redo() } }

    /// Register the add so undo removes it (and redo re-adds it, symmetrically).
    private func registerAddUndo(_ annotation: PDFAnnotation, _ page: PDFPage) {
        markupUndo.registerUndo(withTarget: self) { view in
            page.removeAnnotation(annotation)
            view.registerRemoveUndo(annotation, page)
            view.markEdited()
        }
    }

    private func registerRemoveUndo(_ annotation: PDFAnnotation, _ page: PDFPage) {
        markupUndo.registerUndo(withTarget: self) { view in
            page.addAnnotation(annotation)
            view.registerAddUndo(annotation, page)
            view.markEdited()
        }
    }

    private func registerMoveUndo(_ annotation: PDFAnnotation, from origin: CGPoint) {
        let restored = origin
        markupUndo.registerUndo(withTarget: self) { view in
            let current = annotation.bounds.origin
            annotation.bounds = CGRect(origin: restored, size: annotation.bounds.size)
            view.registerMoveUndo(annotation, from: current)
            view.setNeedsDisplay(view.bounds)
            view.markEdited()
        }
    }

    func markEdited() {
        onDocumentEdited?()
    }

    // MARK: Mouse handling

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else {
            super.mouseDown(with: event)
            return
        }
        let pagePoint = convert(viewPoint, to: page)
        dragStartPage = page
        dragStartPoint = pagePoint
        hasDraggedFar = false

        switch activeTool {
        case .none:
            // Grab a movable annotation to drag it; otherwise fall through to normal selection.
            // Text-anchored markup (highlight/underline/strikethrough) is NOT movable, so a click on
            // highlighted text still places the caret / starts a selection instead of being eaten.
            if let hit = page.annotation(at: pagePoint), hit.shouldDisplay, isMovable(hit) {
                movingAnnotation = hit
                moveOriginalOrigin = hit.bounds.origin
                moveGrabOffset = CGSize(
                    width: pagePoint.x - hit.bounds.minX, height: pagePoint.y - hit.bounds.minY)
            } else {
                dragStartPage = nil
                super.mouseDown(with: event)
            }
        case .draw, .signature:
            freehandPoints = [pagePoint]
        case .rectangle, .oval, .line, .arrow:
            break  // the shape is built up in mouseDragged
        case .text:
            addTextBox(at: pagePoint, page: page)
            activeTool = .none
            dragStartPage = nil
        case .note:
            addNote(at: pagePoint, page: page)
            activeTool = .none
            dragStartPage = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeTool != .none || movingAnnotation != nil, let page = dragStartPage else {
            super.mouseDragged(with: event)
            return
        }
        let pagePoint = convert(convert(event.locationInWindow, from: nil), to: page)

        if let moving = movingAnnotation {
            moving.bounds = CGRect(
                x: pagePoint.x - moveGrabOffset.width, y: pagePoint.y - moveGrabOffset.height,
                width: moving.bounds.width, height: moving.bounds.height)
            setNeedsDisplay(bounds)
            return
        }

        if abs(pagePoint.x - dragStartPoint.x) > 3 || abs(pagePoint.y - dragStartPoint.y) > 3 {
            hasDraggedFar = true
        }
        if activeTool.isFreehand {
            freehandPoints.append(pagePoint)
        }
        replaceLiveAnnotation(makeLiveAnnotation(currentPoint: pagePoint), on: page)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            freehandPoints = []
            dragStartPage = nil
        }
        if let moving = movingAnnotation {
            movingAnnotation = nil
            if moving.bounds.origin != moveOriginalOrigin {
                registerMoveUndo(moving, from: moveOriginalOrigin)
                markEdited()
            }
            return
        }
        // Finalize the in-progress shape/ink regardless of activeTool: the tool can be disarmed
        // between drag and release (the markup bar toggled off), and the live annotation is already
        // on the page, so it must be either registered or removed -- never left as a stray.
        if let live = liveAnnotation, let page = dragStartPage {
            liveAnnotation = nil
            // Discard a click / sub-pixel jitter rather than permanently adding a tiny stray
            // annotation. Gate on how far the pointer actually travelled, not the annotation bounds:
            // shapes pad their bounds by the line width and ink insets too, so a bounds test would let
            // a near-zero drag through.
            if hasDraggedFar {
                registerAddUndo(live, page)
                markEdited()
            } else {
                page.removeAnnotation(live)
            }
            return
        }
        if activeTool == .none { super.mouseUp(with: event) }
    }

    /// Whether an annotation can be dragged to reposition it. Text-anchored markup (highlight,
    /// underline, strikethrough) is excluded -- it belongs to the text it covers.
    private func isMovable(_ annotation: PDFAnnotation) -> Bool {
        switch annotation.type {
        case "FreeText", "Text", "Ink", "Square", "Circle", "Line": return true
        default: return false
        }
    }

    /// Swap the in-progress preview annotation for a freshly built one, so the shape/ink tracks the
    /// pointer without accumulating stale geometry.
    private func replaceLiveAnnotation(_ annotation: PDFAnnotation?, on page: PDFPage) {
        if let old = liveAnnotation { page.removeAnnotation(old) }
        liveAnnotation = annotation
        if let annotation { page.addAnnotation(annotation) }
        setNeedsDisplay(bounds)
    }

    private func makeLiveAnnotation(currentPoint: CGPoint) -> PDFAnnotation? {
        switch activeTool {
        case .draw: return inkAnnotation(points: freehandPoints, color: markupColor, width: lineWidth)
        case .signature:
            return inkAnnotation(points: freehandPoints, color: .black, width: max(lineWidth, 2.5))
        case .rectangle: return shapeAnnotation(.square, from: dragStartPoint, to: currentPoint)
        case .oval: return shapeAnnotation(.circle, from: dragStartPoint, to: currentPoint)
        case .line: return lineAnnotation(from: dragStartPoint, to: currentPoint, arrow: false)
        case .arrow: return lineAnnotation(from: dragStartPoint, to: currentPoint, arrow: true)
        default: return nil
        }
    }

    // MARK: Annotation builders

    private func inkAnnotation(points: [CGPoint], color: NSColor, width: CGFloat) -> PDFAnnotation? {
        guard points.count > 1 else { return nil }
        var box = CGRect(origin: points[0], size: .zero)
        for point in points { box = box.union(CGRect(origin: point, size: .zero)) }
        box = box.insetBy(dx: -width * 2, dy: -width * 2)
        let annotation = PDFAnnotation(bounds: box, forType: .ink, withProperties: nil)
        let border = PDFBorder()
        border.lineWidth = width
        annotation.border = border
        annotation.color = color
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        // PDFKit draws an ink path relative to the annotation's bounds origin, so the page-space
        // points must be translated into bounds-local space -- otherwise the stroke lands off-page
        // (bounds.origin + point) and never renders.
        let origin = box.origin
        path.move(to: CGPoint(x: points[0].x - origin.x, y: points[0].y - origin.y))
        for point in points.dropFirst() {
            path.line(to: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
        }
        annotation.add(path)
        return annotation
    }

    private func shapeAnnotation(_ subtype: PDFAnnotationSubtype, from a: CGPoint, to b: CGPoint)
        -> PDFAnnotation
    {
        // Pad the bounds by the line width so the border stroke (centered on the box edge) isn't
        // clipped by the annotation bounds at larger widths, matching the line/ink tools.
        let box = CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)
        ).insetBy(dx: -lineWidth, dy: -lineWidth)
        let annotation = PDFAnnotation(bounds: box, forType: subtype, withProperties: nil)
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        annotation.color = markupColor  // stroke color for square/circle
        return annotation
    }

    private func lineAnnotation(from a: CGPoint, to b: CGPoint, arrow: Bool) -> PDFAnnotation {
        let box = CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)
        ).insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2)
        let annotation = PDFAnnotation(bounds: box, forType: .line, withProperties: nil)
        annotation.startPoint = CGPoint(x: a.x - box.minX, y: a.y - box.minY)
        annotation.endPoint = CGPoint(x: b.x - box.minX, y: b.y - box.minY)
        if arrow { annotation.endLineStyle = .closedArrow }
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        annotation.color = markupColor
        return annotation
    }

    private func addTextBox(at point: CGPoint, page: PDFPage) {
        guard let text = promptForText(L("markup.enterText", "Text"), initial: ""), !text.isEmpty
        else { return }
        place(textBoxAnnotation(text: text, at: point), on: page)
    }

    private func addNote(at point: CGPoint, page: PDFPage) {
        guard let text = promptForText(L("markup.noteText", "Note"), initial: ""), !text.isEmpty
        else { return }
        place(noteAnnotation(text: text, at: point), on: page)
    }

    /// A free-text box whose top-left sits at `point` (page coordinates), sized to its text.
    private func textBoxAnnotation(text: String, at point: CGPoint) -> PDFAnnotation {
        let font = NSFont.systemFont(ofSize: 14)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let box = CGRect(
            x: point.x, y: point.y - size.height, width: max(size.width + 10, 44),
            height: size.height + 8)
        let annotation = PDFAnnotation(bounds: box, forType: .freeText, withProperties: nil)
        annotation.font = font
        annotation.fontColor = legibleTextColor(markupColor)
        annotation.color = .clear
        annotation.contents = text
        return annotation
    }

    /// Keep typed text readable on the white page: a very light markup color (e.g. the yellow
    /// highlight default) would be near-invisible, so fall back to near-black for text.
    private func legibleTextColor(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        let luminance =
            0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? .labelColor : color
    }

    /// A sticky note (icon + hidden contents) anchored at `point` (page coordinates).
    private func noteAnnotation(text: String, at point: CGPoint) -> PDFAnnotation {
        let box = CGRect(x: point.x, y: point.y - 18, width: 18, height: 18)
        let annotation = PDFAnnotation(bounds: box, forType: .text, withProperties: nil)
        annotation.color = markupColor
        annotation.contents = text
        return annotation
    }

    /// Add an annotation to the page, register its undo, and flag the document edited.
    private func place(_ annotation: PDFAnnotation, on page: PDFPage) {
        page.addAnnotation(annotation)
        registerAddUndo(annotation, page)
        markEdited()
    }

    /// A modal prompt for a note / text-box string. Returns nil on Cancel.
    private func promptForText(_ title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: L("common.ok", "OK"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    // MARK: Cursor

    override func resetCursorRects() {
        if activeTool == .none {
            super.resetCursorRects()
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: Test hooks

    /// Draw a freehand ink stroke through `points` (page coordinates) on page `pageIndex`, exactly as
    /// a drag would, for the coordinate-space verification. Returns the resulting annotation bounds.
    @discardableResult
    func debugAddInk(_ points: [CGPoint], pageIndex: Int = 0) -> CGRect? {
        guard let page = document?.page(at: pageIndex),
            let annotation = inkAnnotation(points: points, color: markupColor, width: lineWidth)
        else { return nil }
        page.addAnnotation(annotation)
        registerAddUndo(annotation, page)
        markEdited()
        return annotation.bounds
    }

    /// Add a shape / line / arrow between two page-space points, exactly as a drag would, for the
    /// render verification. Returns false for a non-shape tool or a missing page.
    @discardableResult
    func debugAddShape(_ tool: Tool, from a: CGPoint, to b: CGPoint, pageIndex: Int = 0) -> Bool {
        guard let page = document?.page(at: pageIndex) else { return false }
        let annotation: PDFAnnotation
        switch tool {
        case .rectangle: annotation = shapeAnnotation(.square, from: a, to: b)
        case .oval: annotation = shapeAnnotation(.circle, from: a, to: b)
        case .line: annotation = lineAnnotation(from: a, to: b, arrow: false)
        case .arrow: annotation = lineAnnotation(from: a, to: b, arrow: true)
        default: return false
        }
        page.addAnnotation(annotation)
        registerAddUndo(annotation, page)
        markEdited()
        return true
    }

    /// Place a text box / sticky note at `point` (page coordinates), bypassing the modal prompt, for
    /// the render verification. `note == true` makes a sticky note, else a free-text box.
    @discardableResult
    func debugAddText(_ text: String, at point: CGPoint, note: Bool, pageIndex: Int = 0) -> Bool {
        guard let page = document?.page(at: pageIndex) else { return false }
        place(note ? noteAnnotation(text: text, at: point) : textBoxAnnotation(text: text, at: point), on: page)
        return true
    }

    /// Add a highlight over `rect` on page `pageIndex` exactly as the toolbar would, for the
    /// save/reload round-trip smoke check. Returns false if the page is missing.
    @discardableResult
    func debugAddHighlight(_ rect: CGRect, pageIndex: Int = 0) -> Bool {
        guard let page = document?.page(at: pageIndex) else { return false }
        let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
        annotation.color = markupColor
        page.addAnnotation(annotation)
        registerAddUndo(annotation, page)
        markEdited()
        return true
    }
}
