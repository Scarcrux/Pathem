import Foundation

/// Flattens a folder subtree into one cross-folder list: every file under `root`,
/// each tagged with its containing folder (`FileEntry.location`) so the existing
/// location-aware list can render and operate on it. Walks via the fast
/// `BulkEnumerator`. Bounded by depth and item count so a deep tree (or a symlink
/// cycle, which depth ultimately caps) can't run away.
public enum FlatEnumerator {
    /// The flattened entries, plus whether the walk was cut short by the item cap.
    public struct Result: Sendable, Equatable {
        public let entries: [FileEntry]
        public let truncated: Bool
        public init(entries: [FileEntry], truncated: Bool) {
            self.entries = entries
            self.truncated = truncated
        }
    }

    public static func entries(
        of root: URL, includingHidden: Bool = false, includeFolders: Bool = false,
        excludingDirectories: Set<String> = [], maxDepth: Int = 64, maxItems: Int = 200_000
    ) -> Result {
        var out: [FileEntry] = []
        var truncated = false
        // Depth-first so results read folder-by-folder; reverse children onto the
        // stack so a folder's own files come out before its subfolders' files.
        var stack: [(url: URL, depth: Int)] = [(root, 0)]
        while let (dir, depth) = stack.popLast() {
            guard out.count < maxItems else {
                truncated = true
                break
            }
            let children = (try? BulkEnumerator().entries(of: dir, includingHidden: includingHidden)) ?? []
            var subdirs: [(URL, Int)] = []
            for child in children {
                if out.count >= maxItems {
                    truncated = true
                    break
                }
                if child.isDirectory {
                    if includeFolders { out.append(located(child, in: dir)) }
                    // Don't descend into excluded folders (caches/VCS/build noise).
                    if depth < maxDepth, !excludingDirectories.contains(child.name) {
                        subdirs.append((dir.appendingPathComponent(child.name), depth + 1))
                    }
                } else {
                    out.append(located(child, in: dir))
                }
            }
            // Push in reverse so the first subfolder is processed next (DFS order).
            for entry in subdirs.reversed() { stack.append(entry) }
        }
        return Result(entries: out, truncated: truncated)
    }

    private static func located(_ entry: FileEntry, in dir: URL) -> FileEntry {
        FileEntry(
            name: entry.name, isDirectory: entry.isDirectory, size: entry.size,
            modificationDate: entry.modificationDate, isDataless: entry.isDataless,
            location: dir.path, rawName: entry.rawName)
    }
}
