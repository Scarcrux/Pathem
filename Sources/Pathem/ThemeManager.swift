import AppKit
import PathemEngine

/// Resolves the current skin's colors and broadcasts changes so the app's own-drawn chrome (list
/// and sidebar selection, the active pane border and tab, the breadcrumb, and the pane/window
/// background) re-tints. Only elements Pathem draws itself can be themed; stock AppKit controls
/// still follow the system accent, which has no per-app override. macOS 15+.
@MainActor
final class ThemeManager {
    static let shared = ThemeManager()

    /// The custom accent, or nil when the skin uses the system accent (so views fall back to the
    /// stock selection look). `accent` is the always-non-nil effective color for drawing.
    private(set) var customAccent: NSColor?
    var accent: NSColor { customAccent ?? .controlAccentColor }
    /// The window/pane background tint, or nil for the system background.
    private(set) var windowTint: NSColor?

    /// A themed view's redraw callback, held weakly by its owner so it self-prunes on dealloc —
    /// avoids NotificationCenter tokens (which a Swift 6 nonisolated deinit can't remove).
    private struct Subscriber {
        weak var owner: AnyObject?
        let redraw: @MainActor () -> Void
    }
    private var subscribers: [Subscriber] = []

    /// Register `redraw` to run whenever the skin changes, tied to `owner`'s lifetime.
    func onChange(owner: AnyObject, _ redraw: @escaping @MainActor () -> Void) {
        // Prune dead subscribers here too, not only in apply(): a long session recreates panes and
        // cell controllers constantly, and apply() only runs when the user changes skin colors, so
        // without this the array would grow unbounded with nil-owner entries.
        subscribers.removeAll { $0.owner == nil }
        subscribers.append(Subscriber(owner: owner, redraw: redraw))
    }

    /// Adopt new colors (from Preferences) and redraw the themed chrome if anything changed.
    func apply(accentHex: String, windowTintHex: String) {
        let newAccent = Self.color(fromHex: accentHex)
        let newTint = Self.color(fromHex: windowTintHex)
        guard newAccent != customAccent || newTint != windowTint else { return }
        customAccent = newAccent
        windowTint = newTint
        subscribers.removeAll { $0.owner == nil }
        for subscriber in subscribers { subscriber.redraw() }
    }

    /// Parse "#RRGGBB" (or "#RRGGBBAA") into an sRGB color; nil for empty/invalid input.
    static func color(fromHex raw: String) -> NSColor? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        guard !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// "#RRGGBB" for a color (converted to sRGB first). Used by the custom color wells.
    static func hex(from color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
