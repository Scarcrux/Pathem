import AppKit
import PathemEngine

/// Collects right-button drag points and reduces them to a gesture stroke on mouse-up,
/// using the engine recognizer. Shared by the list and grid views. Window coordinates
/// are y-up regardless of a view's flippedness, so they feed the recognizer directly.
@MainActor
final class MouseGestureTracker {
    private var points: [CGPoint] = []

    func begin(_ event: NSEvent) { points = [event.locationInWindow] }
    func append(_ event: NSEvent) { points.append(event.locationInWindow) }

    /// The stroke for this drag, or nil when the movement was too small to be a gesture
    /// (so the caller should fall back to showing the context menu).
    func end(_ event: NSEvent) -> String? {
        points.append(event.locationInWindow)
        let stroke = MouseGesture.reduce(points)
        points.removeAll()
        return stroke.isEmpty ? nil : stroke
    }
}
