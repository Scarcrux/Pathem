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
    var onBecomeActive: (() -> Void)?

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
