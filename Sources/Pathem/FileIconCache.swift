import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// An extension/kind-keyed file-icon cache shared by the list, column, and tree views, so
/// scrolling a large folder never stats every visible file for its icon. The active icon set
/// wins first (themed icons); otherwise the OS icon for the file's UTType is cached by lowercased
/// extension (or "folder"), which is the same tradeoff the list view has always made: generic
/// type icons instead of a per-file lookup, in exchange for smooth scrolling in huge folders.
///
/// Bundles are the exception. An `.app` is a *directory* on disk, so the kind-keyed path would file
/// every app under "folder" and draw a generic folder icon for all of /Applications. Bundles also
/// each carry their own icon, which a type icon can never represent, so they get a real per-file
/// lookup cached by path. That is safe: bundle folders hold tens or hundreds of items, not the
/// 100k-row folders the kind cache exists to protect.
@MainActor
enum FileIconCache {
    private static var cache: [String: NSImage] = [:]

    /// Bundle kinds whose icon is per-file, not per-type (each one ships its own icon).
    private static let bundleKinds: Set<String> = [
        "app", "prefpane", "framework", "bundle", "plugin", "kext", "appex",
        "component", "qlgenerator", "saver", "wdgt", "xpc", "systemextension",
    ]

    static func icon(
        for entry: FileEntry, in directory: URL? = nil, allowFileLookup: Bool = true
    ) -> NSImage {
        if let themed = IconSetManager.shared.icon(for: entry) { return themed }  // active icon set
        let ext = (entry.name as NSString).pathExtension.lowercased()

        // Bundles: real icon, keyed by path. Checked BEFORE isDirectory, because an .app bundle is
        // a directory and would otherwise fall into the shared "folder" icon.
        if allowFileLookup, bundleKinds.contains(ext) {
            let path = PaneItemKey.path(for: entry, in: directory)
            let key = "\u{0}path\u{0}" + path
            if let hit = cache[key] { return hit }
            let image = NSWorkspace.shared.icon(forFile: path)
            cache[key] = image
            return image
        }

        let key = entry.isDirectory ? "\u{0}folder" : ext
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
