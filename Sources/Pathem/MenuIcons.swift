import AppKit

/// SF Symbol icons for the file context menus, Finder-style: a small glyph left of each
/// command title. One source of truth so the list, icon, and gallery menus stay in sync,
/// and so hiding or reordering a command never leaves a stale icon behind.
enum MenuIcons {
    /// The SF Symbol name for a command id, or nil for commands shown without an icon.
    static func symbol(for commandID: String) -> String? {
        switch commandID {
        case "files.open": return "arrow.up.forward.app"
        case "files.getInfo": return "info.circle"
        case "files.download": return "arrow.down.circle"
        case "files.reveal": return "arrow.up.forward.square"
        case "files.revealInPathem": return "dot.viewfinder"
        case "files.rename": return "pencil"
        case "files.trash": return "trash"
        case "files.newFolder": return "folder.badge.plus"
        case "files.newFile": return "doc.badge.plus"
        case "files.copy": return "doc.on.doc"
        case "files.cut": return "scissors"
        case "files.paste": return "doc.on.clipboard"
        case "files.extract": return "shippingbox"
        case "files.extractHere": return "arrow.down.doc"
        case "files.extractTo": return "folder"
        default: return nil
        }
    }

    /// A menu-sized template image for an SF Symbol (nil if unavailable on this OS), tinted
    /// by the menu the way the system's own item images are.
    static func image(_ symbol: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// The menu image for a command id (nil if the command has no icon).
    static func image(forCommand commandID: String) -> NSImage? {
        guard let name = symbol(for: commandID) else { return nil }
        return image(name)
    }
}
