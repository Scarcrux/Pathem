import AppKit
import PathemEngine

/// AppKit rendering for Finder tag colors (the engine stays AppKit-free).
enum TagColors {
    static func label(_ color: FileTag.Color) -> String {
        switch color {
        case .none: L("tags.color.none", "No Color")
        case .gray: L("tags.color.gray", "Gray")
        case .green: L("tags.color.green", "Green")
        case .purple: L("tags.color.purple", "Purple")
        case .blue: L("tags.color.blue", "Blue")
        case .yellow: L("tags.color.yellow", "Yellow")
        case .red: L("tags.color.red", "Red")
        case .orange: L("tags.color.orange", "Orange")
        }
    }

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
        NSBezierPath(
            ovalIn: NSRect(
                x: inset, y: inset, width: diameter - inset * 2, height: diameter - inset * 2)
        )
        .fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
