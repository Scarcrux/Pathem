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
    /// A right-drag that started on a row: the super-drag flick + its swipe trail. Kept on the
    /// right button so it never collides with a left-drag (which is normal drag-and-drop).
    var onSuperDrag: ((DragSessionEvent) -> Void)?
    /// A drag left the table or ended; used to cancel a pending spring-loaded-folder open.
    var onDragExited: (() -> Void)?

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
        super.draggingExited(sender)
    }
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragExited?()
        super.draggingEnded(sender)
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
        guard superDragStartRow >= 0 else { return }
        if !selectedRowIndexes.contains(superDragStartRow) {
            selectRowIndexes([superDragStartRow], byExtendingSelection: false)  // the flick acts on it
        }
        if let screen = window?.convertPoint(toScreen: event.locationInWindow) {
            onSuperDrag?(.began(screen: screen))
        }
    }
    override func rightMouseDragged(with event: NSEvent) {
        gestureTracker.append(event)
        if superDragStartRow >= 0, let screen = window?.convertPoint(toScreen: event.locationInWindow) {
            onSuperDrag?(.moved(screen: screen))
        }
    }
    override func rightMouseUp(with event: NSEvent) {
        let navStroke = gestureTracker.end(event)
        if superDragStartRow >= 0 {
            // Reduce start->end to a single cardinal (same threshold as the trail's live hint).
            let flick = superDragStartWindow.map {
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

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)  // the right-clicked pane becomes active
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 {
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes([row], byExtendingSelection: false)  // act on the clicked item
            }
        } else {
            deselectAll(nil)  // empty space: folder-level actions only
        }
        return super.menu(for: event)
    }
}
