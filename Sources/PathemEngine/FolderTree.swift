import Foundation

/// Pure logic behind the always-visible folder tree: which ancestors to expand to reveal a
/// folder, which root to use, and a folders-only, lazily loaded listing of one directory.
/// Nothing here walks more than the one directory it is asked about.
public enum FolderTree {
    public static let minWidth: Double = 120
    public static let maxWidth: Double = 480
    public static let defaultWidth: Double = 220

    public static func clampedWidth(_ width: Double) -> Double {
        max(minWidth, min(maxWidth, width))
    }

    /// The folders to expand, from `root` down to `target` inclusive, or nil when `target`
    /// is not inside `root`. Compared by path components, so `/Users/meow` is not inside
    /// `/Users/me`.
    public static func revealChain(root: URL, target: URL) -> [URL]? {
        let rootParts = root.standardizedFileURL.pathComponents
        let targetParts = target.standardizedFileURL.pathComponents
        guard targetParts.count >= rootParts.count,
            Array(targetParts.prefix(rootParts.count)) == rootParts
        else { return nil }
        var chain = [root.standardizedFileURL]
        var current = root.standardizedFileURL
        for part in targetParts.dropFirst(rootParts.count) {
            current = current.appendingPathComponent(part, isDirectory: true)
            chain.append(current)
        }
        return chain
    }

    /// The tree's root for a folder: the home folder when the folder is inside it, otherwise
    /// the volume root `/`.
    public static func root(for folder: URL, home: URL) -> URL {
        revealChain(root: home, target: folder) != nil
            ? home.standardizedFileURL : URL(fileURLWithPath: "/")
    }

    public struct Folder: Sendable, Equatable {
        public let name: String
        public let url: URL
    }

    public struct Listing: Sendable {
        public let folders: [Folder]
        /// False when the directory could not be read (no permission, no Full Disk Access).
        public let isReadable: Bool
    }

    /// The immediate subfolders of `directory`, sorted like Finder. Never throws: an
    /// unreadable folder yields an empty, not-readable listing so the tree can show it dimmed.
    public static func subfolders(
        of directory: URL, includingHidden: Bool,
        using enumerator: any DirectoryEnumerating = BulkEnumerator()
    ) -> Listing {
        guard
            let entries = try? enumerator.entries(of: directory, includingHidden: includingHidden)
        else { return Listing(folders: [], isReadable: false) }
        let folders = entries.filter(\.isDirectory)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map {
                Folder(
                    name: $0.name, url: directory.appendingPathComponent($0.name, isDirectory: true)
                )
            }
        return Listing(folders: folders, isReadable: true)
    }
}
