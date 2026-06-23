import AppKit
import PathemEngine

/// AppKit rendering for Finder tag colors (the engine stays AppKit-free).
enum TagColors {
    static func nsColor(_ color: FileTag.Color) -> NSColor {
        switch color {
        case .none: .clear
        case .gray: .systemGray
        case .green: .systemGreen
        case .purple: .systemPurple
        case .blue: .systemBlue
        case .yellow: .systemYellow
        case .red: .systemRed
        case .orange: .systemOrange
        }
    }

    /// A small filled circle for menus and list rows.
    static func dot(_ color: FileTag.Color, diameter: CGFloat = 12) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        nsColor(color).setFill()
        let inset: CGFloat = 1
        NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: diameter - inset * 2, height: diameter - inset * 2))
            .fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
