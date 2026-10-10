import AppKit
import PathemEngine

/// Native collector delegates to the shared bounded streaming engine. Pathem's
/// right-click/menu/flick ownership and prefix recognition stay with callers.
@MainActor
final class MouseGestureTracker {
    private var capture: MouseGestureCapture?
    func begin(_ event: NSEvent) { capture = MouseGestureCapture(origin: event.locationInWindow) }
    func append(_ event: NSEvent) { capture?.append(event.locationInWindow) }
    func end(_ event: NSEvent) -> String? {
        capture?.append(event.locationInWindow)
        defer { capture = nil }
        return capture?.end()
    }
}
