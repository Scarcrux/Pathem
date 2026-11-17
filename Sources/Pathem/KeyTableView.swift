import AppKit
import PathemEngine

/// NSTableView subclass that turns each key press into a `KeyChord` and offers
/// it to a handler. If the handler consumes it (a keymap binding fired), the key
/// is swallowed; otherwise it falls through to AppKit so arrow-key selection and
/// type-select keep working. All bindings live in the keymap, not here.
@MainActor
final class KeyTableView: NSTableView {
    /// Return true if the chord was handled (the key is then consumed).
    var onKeyChord: ((KeyChord) -> Bool)?
    /// Return true if the right-button stroke was handled (then the menu is suppressed).
    var onMouseGesture: ((String) -> Bool)?
    var onBecomeActive: (() -> Void)?

    /// The selected files for a Service (set by the owning controller; location-aware).
    var servicesURLs: (() -> [URL])?
    /// Whether the selection is local files at all. False on a remote pane, whose rows have no
    /// file URL to hand a service. Kept separate from `servicesURLs` because AppKit asks
    /// `validRequestor` on every menu update, and building every URL there would be wasteful.
    var servicesAvailable: () -> Bool = { true }
    // Services: answer for file types only with a selection and no return type, else defer.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if FileServices.accepts(
            sendType: sendType, returnType: returnType,
            hasSelection: !selectedRowIndexes.isEmpty && servicesAvailable())
        {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    @objc func writeSelection(
        to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        FileServices.write(servicesURLs?() ?? [], to: pboard, types: types)
    }

    /// Alternating row stripes stop at the last real row. With the inset table style AppKit
    /// keeps drawing rounded stripes down the empty part of the list (macOS 26 and 27), which
    /// read as loading placeholders for rows that will never arrive.
    override func drawBackground(inClipRect clipRect: NSRect) {
        drawStripesOnlyBehindRows(in: clipRect) { super.drawBackground(inClipRect: $0) }
    }
    /// A right-drag that started on a row: the super-drag flick + its swipe trail. Kept on the
    /// right button so it never collides with a left-drag (which is normal drag-and-drop).
    var onSuperDrag: ((DragSessionEvent) -> Void)?
    /// A drag left the table or ended; used to cancel a pending spring-loaded-folder open.
    var onDragExited: (() -> Void)?

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
        super.draggingExited(sender)
    }
    // draggingEnded: is an OPTIONAL NSDraggingDestination method that NSView does not implement, so
    // without an explicit @objc the Swift override is never exposed to the ObjC runtime. AppKit's
    // drag-completion (CoreDragEndDragging) then sends draggingEnded:, hits "unrecognized selector",
    // and the swallowed NSException leaves the drag SESSION un-concluded -- so after any drag out to
    // another app, every later drag is silently dead until relaunch. @objc forces the selector; do
    // NOT call super (there is no NSView draggingEnded: to forward to -- super would raise the same
    // unrecognized-selector exception).
    @objc override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragExited?()
    }

    private let gestureTracker = MouseGestureTracker()
    private var superDragStartRow = -1  // >= 0 means the right-drag began on a file row
    private var superDragStartWindow: NSPoint?

    // The right button: a drag starting on a row is a super-drag flick (acting on that row); a
    // drag on empty space is a navigation stroke; a plain click shows the context menu.
    override func rightMouseDown(with event: NSEvent) {
        gestureTracker.begin(event)
        superDragStartWindow = event.locationInWindow
        superDragStartRow = row(at: convert(event.locationInWindow, from: nil))
        if superDragStartRow >= 0, !selectedRowIndexes.contains(superDragStartRow) {
            selectRowIndexes([superDragStartRow], byExtendingSelection: false)  // the flick acts on it
        }
        // Draw the trail for any right-drag; the flick hint shows only for a row super-drag (empty
        // space runs a navigation stroke, not a flick).
        if let screen = window?.convertPoint(toScreen: event.locationInWindow) {
            onSuperDrag?(.began(screen: screen, showsHint: superDragStartRow >= 0))
        }
    }
    override func rightMouseDragged(with event: NSEvent) {
        gestureTracker.append(event)
        if let screen = window?.convertPoint(toScreen: event.locationInWindow) {
            onSuperDrag?(.moved(screen: screen))
        }
    }
    override func rightMouseUp(with event: NSEvent) {
        let navStroke = gestureTracker.end(event)
        if superDragStartRow >= 0 {
            // Reduce start->end to a single cardinal (same threshold as the trail's live hint).
            let flick =
                superDragStartWindow.map {
                    MouseGesture.reduce([$0, event.locationInWindow], minSegment: 44)
                } ?? ""
            onSuperDrag?(.ended(flick: flick.isEmpty ? nil : flick))
            superDragStartRow = -1
            superDragStartWindow = nil
            if flick.isEmpty, let menu = menu(for: event) {  // no flick: treat as a plain right-click
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            }
            return
        }
        onSuperDrag?(.ended(flick: nil))  // end the empty-space trail; the stroke/menu runs below
        superDragStartWindow = nil
        if let navStroke, onMouseGesture?(navStroke) == true { return }
        if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecomeActive?() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let chord = KeyChord.from(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            cmd: flags.contains(.command),
            opt: flags.contains(.option),
            ctrl: flags.contains(.control),
            shift: flags.contains(.shift))
        if onKeyChord?(chord) == true { return }
        super.keyDown(with: event)
    }

    /// A menu for right-clicking the empty area below the rows (folder-level actions like
    /// Copy Path of the current folder). Falls back to the item menu when nil.
    var onBackgroundMenu: (() -> NSMenu?)?
    /// A middle-click on a row (used to open a folder in a new tab).
    var onMiddleClick: ((Int) -> Void)?

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {  // the middle button
            let row = self.row(at: convert(event.locationInWindow, from: nil))
            if row >= 0 {
                onMiddleClick?(row)
                return
            }
        }
        super.otherMouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)  // the right-clicked pane becomes active
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 {
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes([row], byExtendingSelection: false)  // act on the clicked item
            }
        } else {
            deselectAll(nil)  // empty space: folder-level actions only
            if let background = onBackgroundMenu?() { return background }
        }
        return super.menu(for: event)
    }
}

extension NSTableView {
    /// Shared by the list and tree views: fill the clip with the plain background, then let
    /// AppKit draw its alternating stripes only over the rows that exist.
    func drawStripesOnlyBehindRows(in clipRect: NSRect, drawStripes: (NSRect) -> Void) {
        guard usesAlternatingRowBackgroundColors else {
            drawStripes(clipRect)
            return
        }
        let lastRowBottom = numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : 0
        let rows = NSRect(x: bounds.minX, y: 0, width: bounds.width, height: lastRowBottom)
        backgroundColor.setFill()
        clipRect.fill()
        let striped = clipRect.intersection(rows)
        guard !striped.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: striped).addClip()
        drawStripes(striped)
        NSGraphicsContext.restoreGraphicsState()
    }
}
