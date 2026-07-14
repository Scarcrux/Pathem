import Foundation

/// Reads Finder's own sidebar favorites, so they can be imported into Pathem's.
///
/// macOS keeps them in a LSSharedFileList file under
/// `~/Library/Application Support/com.apple.sharedfilelist`. That file is an NSKeyedArchiver
/// plist, but its item classes are private to Finder, so unarchiving it properly is not an option.
/// Every favorite is stored as a *bookmark* though, so we read the raw plist instead and resolve
/// each `$objects` blob carrying the `book` magic. That is stable across the format's revisions
/// (sfl2 -> sfl3 -> sfl4) because the bookmark payload is what actually changes hands.
///
/// Pure Foundation, and the parse is split from the file read so it is unit-testable.
public enum FinderFavorites {
    /// A bookmark blob always begins with this.
    private static let bookmarkMagic = Data("book".utf8)

    /// The favorites file macOS is currently using. It bumps the suffix across releases and leaves
    /// the older files behind, so prefer the newest that exists.
    public static func listFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let directory = home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        for suffix in ["sfl4", "sfl3", "sfl2"] {
            let url = directory.appendingPathComponent("com.apple.LSSharedFileList.FavoriteItems.\(suffix)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Every favorite that still resolves to a folder that exists, in file order, de-duplicated.
    public static func folders(file: URL? = nil) -> [URL] {
        guard let file = file ?? listFile(), let data = try? Data(contentsOf: file) else { return [] }
        return folders(inArchive: data)
    }

    /// The parse itself, so a test can hand it an archive directly.
    public static func folders(inArchive data: Data) -> [URL] {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let root = plist as? [String: Any],
            let objects = root["$objects"] as? [Any]
        else { return [] }

        var folders: [URL] = []
        var seen = Set<String>()
        for object in objects {
            guard let blob = object as? Data, blob.count > 4, blob.prefix(4) == bookmarkMagic else { continue }
            var stale = false
            // withoutUI + withoutMounting: a favorite pointing at an unplugged disk or an offline
            // server must be skipped, never block the import on a mount or an auth prompt.
            guard
                let url = try? URL(
                    resolvingBookmarkData: blob, options: [.withoutUI, .withoutMounting],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
            else { continue }
            // Finder's list also holds non-folder entries (AirDrop, Recents, iCloud); keep only real
            // folders that are actually there, since a sidebar shortcut has to point somewhere.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }
            if seen.insert(url.standardizedFileURL.path).inserted { folders.append(url) }
        }
        return folders
    }
}
