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

    /// The background of the file views (list, tree, icon, gallery, columns): the theme's tint,
    /// so the whole window reads as one surface, or the stock content background.
    var contentBackground: NSColor { windowTint ?? .controlBackgroundColor }
    /// The alternate-row stripe over a tinted background (the stock stripes are system gray and
    /// look wrong on a colored theme), or nil to use AppKit's own.
    var stripeColor: NSColor? { windowTint.map { Self.shifted($0, by: 0.04) } }
    /// Whether AppKit may draw its own alternating rows. Its row views paint system gray stripes
    /// that ignore a tinted background, so a tinted theme turns them off: the list draws its own
    /// themed stripes (TintRowView), the tree and columns show the plain themed background.
    var allowsSystemStripes: Bool { windowTint == nil }
    /// The sidebar's background under a tint: a step away from the content so the two stay
    /// distinguishable, or nil to keep the stock translucent sidebar.
    var sidebarBackground: NSColor? { windowTint.map { Self.shifted($0, by: 0.07) } }

    /// `color` moved toward white when dark and toward black when light.
    static func shifted(_ color: NSColor, by fraction: CGFloat) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let luminance =
            0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return c.blended(withFraction: fraction, of: luminance < 0.5 ? .white : .black) ?? c
    }

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
        guard let c = HexColor.parse(raw) else { return nil }  // one parser in the engine
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    /// The heading for a group of themes in the theme menus.
    static func groupTitle(_ appearance: Preferences.Appearance) -> String {
        switch appearance {
        case .system: return L("theme.group.system", "Follow System")
        case .light: return L("theme.group.light", "Light Themes")
        case .dark: return L("theme.group.dark", "Dark Themes")
        }
    }

    /// A menu item for a theme: its name with a swatch of its background and accent, so the
    /// list shows at a glance what each theme looks like and whether it is light or dark.
    static func menuItem(for preset: ThemePreset, action: Selector?, target: AnyObject?)
        -> NSMenuItem
    {
        let item = NSMenuItem(title: preset.name, action: action, keyEquivalent: "")
        item.target = target
        item.image = swatch(for: preset)
        let mode: String
        switch preset.appearance {
        case .system: mode = L("prefs.appearanceSystem", "System")
        case .light: mode = L("prefs.appearanceLight", "Light")
        case .dark: mode = L("prefs.appearanceDark", "Dark")
        }
        item.toolTip = "\(preset.name) (\(mode))"
        return item
    }

    /// A small rounded swatch: the theme's background with an accent dot. Themes without a tint
    /// show a half light, half dark swatch, since they follow the system appearance.
    static func swatch(for preset: ThemePreset) -> NSImage {
        let size = NSSize(width: 18, height: 14)
        return NSImage(size: size, flipped: false) { rect in
            let box = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            if let background = color(fromHex: preset.backgroundHex) {
                background.setFill()
                box.fill()
            } else {
                NSColor.white.setFill()
                box.fill()
                NSGraphicsContext.saveGraphicsState()
                box.addClip()
                NSColor(white: 0.12, alpha: 1).setFill()
                NSRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
                    .fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            NSColor.separatorColor.setStroke()
            box.lineWidth = 1
            box.stroke()
            let accent = color(fromHex: preset.accentHex) ?? .controlAccentColor
            accent.setFill()
            NSBezierPath(
                ovalIn: NSRect(x: rect.midX - 3.5, y: rect.midY - 3.5, width: 7, height: 7)
            ).fill()
            return true
        }
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
