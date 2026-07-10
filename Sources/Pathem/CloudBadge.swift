import AppKit
import PathemEngine

/// Composites a small cloud-service badge onto the corner of a folder icon, so a
/// cloud folder (an iCloud "Documents", a Google Drive "Projects") is recognizable
/// at a glance and same-named folders on different services read apart.
///
/// Main-actor: it draws with AppKit and holds an image cache, and every caller is the
/// (main-thread) cell setup.
@MainActor
enum CloudBadge {
    /// A badged copy of `base` with the service glyph in the bottom-right corner, drawn
    /// at `size`. Cached by the base image's identity + service + size, so scrolling a
    /// long listing doesn't recomposite, and a new icon set (a new base image) misses the
    /// cache and re-badges.
    static func badged(_ base: NSImage, service: CloudService, size: NSSize) -> NSImage {
        let key = "\(ObjectIdentifier(base).hashValue)|\(service.rawValue)|\(Int(size.width))x\(Int(size.height))"
        if let cached = cache[key] { return cached }

        let result = NSImage(size: size)
        result.lockFocus()
        base.draw(
            in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)

        let badge = max(8, size.width * 0.42)  // a corner mark, not half the icon
        let rect = NSRect(x: size.width - badge, y: 0, width: badge, height: badge)
        let tint = ThemeManager.color(fromHex: service.tintHex) ?? .systemGray
        // Draw a white halo (the glyph, slightly larger, in white) so the colored badge
        // reads against any folder color, then the tinted glyph on top.
        drawGlyph(service, color: .white, in: rect.insetBy(dx: -1, dy: -1))
        drawGlyph(service, color: tint, in: rect)

        result.unlockFocus()
        cache[key] = result
        return result
    }

    private static func drawGlyph(_ service: CloudService, color: NSColor, in rect: NSRect) {
        guard
            let symbol = NSImage(
                systemSymbolName: service.symbolName, accessibilityDescription: service.displayName)
        else { return }
        let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        (symbol.withSymbolConfiguration(config) ?? symbol)
            .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private static var cache: [String: NSImage] = [:]

    /// Drop cached badges (e.g. when the icon set changes and base icons are regenerated).
    static func clearCache() { cache.removeAll() }

    private static let home = NSHomeDirectory()

    /// `base` badged when `entry` is a cloud-service folder (a provider root or one of its
    /// top-level folders), otherwise `base` unchanged. The one entry point every view uses,
    /// so cloud badges are consistent across list / icon / gallery / column / tree.
    static func decorate(
        _ base: NSImage, for entry: FileEntry, in directory: URL?,
        size: NSSize = NSSize(width: 32, height: 32)
    ) -> NSImage {
        guard entry.isDirectory else { return base }
        let path = PaneItemKey.path(for: entry, in: directory)
        guard let service = CloudLocation.service(forFolderAt: path, home: home) else { return base }
        return badged(base, service: service, size: size)
    }
}
