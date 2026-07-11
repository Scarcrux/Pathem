import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// An extension/kind-keyed file-icon cache shared by the list, column, and tree views, so
/// scrolling a large folder never stats every visible file for its icon. The active icon set
/// wins first (themed icons); otherwise the OS icon for the file's UTType is cached by lowercased
/// extension (or "folder"), which is the same tradeoff the list view has always made: generic
/// type icons instead of a per-file lookup, in exchange for smooth scrolling in huge folders.
@MainActor
enum FileIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for entry: FileEntry) -> NSImage {
        if let themed = IconSetManager.shared.icon(for: entry) { return themed }  // active icon set
        let key = entry.isDirectory ? "\u{0}folder" : (entry.name as NSString).pathExtension.lowercased()
        if let hit = cache[key] { return hit }
        let ws = NSWorkspace.shared
        let image: NSImage
        if entry.isDirectory {
            image = ws.icon(for: .folder)
        } else if !key.isEmpty, let type = UTType(filenameExtension: key) {
            image = ws.icon(for: type)
        } else {
            image = ws.icon(for: .data)
        }
        cache[key] = image
        return image
    }

    /// Drop cached icons when the active icon set changes (icons are regenerated then).
    static func clear() { cache.removeAll() }
}
