import AppKit

/// `NSTableView` subclass that surfaces the keyboard actions a file pane needs:
/// open (Return / Enter / Cmd-Down), navigate (Cmd-Up / Cmd-[ / Cmd-]), and
/// copy/move (F5 / F6 — the classic dual-pane bindings). Closures are wired by
/// the pane / browser. Unhandled keys fall through to AppKit, so arrow-key
/// selection and type-select keep working.
@MainActor
final class KeyTableView: NSTableView {
    var onActivateRow: (() -> Void)?
    var onGoUp: (() -> Void)?
    var onGoBack: (() -> Void)?
    var onGoForward: (() -> Void)?
    var onCopy: (() -> Void)?
    var onMove: (() -> Void)?
    var onBecomeActive: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecomeActive?() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 36, 76: onActivateRow?()  // Return, keypad Enter
        case 125 where cmd: onActivateRow?()  // Cmd-Down = open
        case 126 where cmd: onGoUp?()  // Cmd-Up
        case 33 where cmd: onGoBack?()  // Cmd-[
        case 30 where cmd: onGoForward?()  // Cmd-]
        case 96: onCopy?()  // F5
        case 97: onMove?()  // F6
        default: super.keyDown(with: event)
        }
    }
}
