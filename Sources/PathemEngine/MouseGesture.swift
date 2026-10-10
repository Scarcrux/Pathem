import CoreGraphics
import Foundation
import GestureSupport

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
        guard let first = points.first, points.count >= 2 else { return "" }
        var capture = MouseGestureCapture(origin: first, minSegment: minSegment)
        for point in points.dropFirst() { capture.append(point) }
        return capture.end() ?? ""
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
        let table = BindingTable(
            defaults: bindings.mapValues { GestureBindingValue($0) },
            overrides: userBindings.mapValues { GestureBindingValue($0, disabled: $0.isEmpty) })
        return GestureMap(bindings: table.effectiveBindings)
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
        let table = BindingTable(
            defaults: bindings.mapValues { GestureBindingValue($0) },
            overrides: userBindings.mapValues { GestureBindingValue($0, disabled: $0.isEmpty) })
        return DragGestureMap(bindings: table.effectiveBindings)
    }
}

/// Streaming adapter preserves Pathem's first-four semantics without retaining
/// an unbounded input path. The engine has no native event/action dependency.
public struct MouseGestureCapture {
    private var capture: StrokeCapture<String>?
    private var sequence = 0.0
    private var last: StrokeSample

    public init(origin: CGPoint, minSegment: CGFloat = 18) {
        last = StrokeSample(x: Double(origin.x), y: Double(origin.y), timestamp: 0)
        capture = try? StrokeCapture(
            origin: last, threshold: Double(minSegment), overflow: .prefix, timeoutReason: "timeout"
        )
    }
    public var visualPoints: [CGPoint] {
        (capture?.visualPoints ?? []).map { CGPoint(x: $0.x, y: $0.y) }
    }
    public var visualPointCount: Int { capture?.visualPointCount ?? 0 }
    public mutating func append(_ point: CGPoint) {
        sequence += 1
        last = StrokeSample(x: Double(point.x), y: Double(point.y), timestamp: sequence)
        capture?.move(last)
    }
    public mutating func end() -> String? {
        defer { capture = nil }
        guard let result = capture?.release(last), case .recognized(let directions) = result else {
            return nil
        }
        return directions.map(\.letter).joined()
    }
    public mutating func cancel() {
        capture?.cancel("cancelled")
        capture = nil
    }
}
