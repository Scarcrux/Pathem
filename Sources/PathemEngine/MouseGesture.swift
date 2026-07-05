import CoreGraphics
import Foundation

/// Recognizes a right-button mouse "stroke" gesture (Directory Opus style) and maps it
/// to a command. The recognizer reduces a path of points into a compact direction
/// string ("R", "L", "U", "D", or combos like "RD"); the map turns that into a command
/// id. Both are pure (no AppKit), so they're unit-tested. Points use a y-up convention
/// (pass NSEvent.locationInWindow, which is y-up regardless of a view's flippedness).
public enum MouseGesture {
    /// Reduce a path into a direction string. A segment counts once it moves more than
    /// `minSegment` from the last anchor; consecutive same directions collapse. Returns
    /// "" for movement too small to be a gesture (so a plain right-click still gets its
    /// context menu). Capped at four directions.
    public static func reduce(_ points: [CGPoint], minSegment: CGFloat = 18) -> String {
        guard points.count >= 2 else { return "" }
        var directions: [Character] = []
        var anchor = points[0]
        for point in points.dropFirst() {
            let dx = point.x - anchor.x
            let dy = point.y - anchor.y
            guard abs(dx) >= minSegment || abs(dy) >= minSegment else { continue }
            let direction: Character =
                abs(dx) >= abs(dy) ? (dx > 0 ? "R" : "L") : (dy > 0 ? "U" : "D")
            if directions.last != direction { directions.append(direction) }
            anchor = point
        }
        return String(directions.prefix(4))
    }
}

/// Maps gesture strokes (canonical strings like "RD") to command ids. Serializes as a
/// flat JSON object overlaid on the built-in defaults, mirroring Keymap.
public struct GestureMap: Codable, Sendable {
    public var bindings: [String: String]

    public init(bindings: [String: String]) { self.bindings = bindings }

    public func commandID(for stroke: String) -> String? { bindings[stroke] }

    public static let defaultBindings: [String: String] = [
        "L": "nav.back",
        "R": "nav.forward",
        "U": "nav.up",
        "D": "tab.new",
        "DR": "tab.close",
        "UD": "view.quickLook",
    ]

    public static var standard: GestureMap { GestureMap(bindings: defaultBindings) }

    /// Overlay user bindings; an empty command id unbinds a stroke.
    public func merging(userBindings: [String: String]) -> GestureMap {
        var merged = bindings
        for (stroke, command) in userBindings {
            if command.isEmpty { merged[stroke] = nil } else { merged[stroke] = command }
        }
        return GestureMap(bindings: merged)
    }

    /// The minimal user overlay that turns the defaults into `effective` (mirrors
    /// Keymap.overlay): changed strokes are listed, removed defaults listed as "".
    public static func overlay(forEffective effective: [String: String]) -> [String: String] {
        var overlay: [String: String] = [:]
        for (stroke, command) in effective where defaultBindings[stroke] != command {
            overlay[stroke] = command
        }
        for stroke in defaultBindings.keys where effective[stroke] == nil {
            overlay[stroke] = ""
        }
        return overlay
    }
}

/// Maps a super-drag flick direction ("U"/"D"/"L"/"R") to a command id: the file-manager
/// analog of the "Super Drag" browser gesture -- flick the selection a short way and release
/// without a drop target to fire a quick action on it. Mirrors GestureMap (overlaid on the
/// defaults, hand-editable JSON), so it's config-as-data and unit-tested.
public struct DragGestureMap: Codable, Sendable {
    public var bindings: [String: String]

    public init(bindings: [String: String]) { self.bindings = bindings }

    public func commandID(for direction: String) -> String? { bindings[direction] }

    public static let defaultBindings: [String: String] = [
        "U": "files.open",  // flick up: open
        "R": "files.copyToOtherPane",  // flick right: copy to the other pane
        "L": "files.moveToOtherPane",  // flick left: move to the other pane
        "D": "files.trash",  // flick down: move to Trash
    ]

    public static var standard: DragGestureMap { DragGestureMap(bindings: defaultBindings) }

    /// Overlay user bindings; an empty command id unbinds a direction.
    public func merging(userBindings: [String: String]) -> DragGestureMap {
        var merged = bindings
        for (direction, command) in userBindings {
            if command.isEmpty { merged[direction] = nil } else { merged[direction] = command }
        }
        return DragGestureMap(bindings: merged)
    }
}
