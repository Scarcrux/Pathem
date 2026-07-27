import Foundation

/// Ranks the immediate children of a folder by how much disk space each occupies,
/// for the "what's eating my space here" cleanup view. Folders are summed
/// recursively (via `DirectorySize`); regular files count their own size. Largest
/// first. Pure and synchronous (real I/O), so it's unit-tested with temp trees and
/// callers run it off the main thread.
public enum DiskUsage {
    /// One immediate child of the scanned folder, with its total footprint.
    public struct Item: Sendable, Equatable {
        public let url: URL
        public let name: String
        public let bytes: Int64
        public let isDirectory: Bool
        /// For a directory, false when part of its subtree was unreadable (so `bytes`
        /// is a lower bound the UI can flag as approximate). Always true for a file.
        public let complete: Bool
        public init(url: URL, name: String, bytes: Int64, isDirectory: Bool, complete: Bool) {
            self.url = url
            self.name = name
            self.bytes = bytes
            self.isDirectory = isDirectory
            self.complete = complete
        }
    }

    /// Immediate children of `folder`, each sized (folders recursively), sorted
    /// largest-first. Hidden items are included by default since they take space
    /// too. Symlinks report their own (tiny) size and are never followed, so a link
    /// to a huge tree can't inflate the total or send the walk out of the folder.
    public static func rankedChildren(of folder: URL, includingHidden: Bool = true) -> [Item] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        let options: FileManager.DirectoryEnumerationOptions = includingHidden ? [] : [.skipsHiddenFiles]
        guard
            let children = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: options)
        else { return [] }

        var items: [Item] = []
        for child in children {
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isSymlink = values?.isSymbolicLink == true
            if values?.isDirectory == true && !isSymlink {
                let measurement = DirectorySize.total(of: child)
                items.append(
                    Item(
                        url: child, name: child.lastPathComponent, bytes: measurement.bytes,
                        isDirectory: true, complete: measurement.complete))
            } else {
                let size = Int64(values?.fileSize ?? 0)
                items.append(
                    Item(
                        url: child, name: child.lastPathComponent, bytes: size,
                        isDirectory: false, complete: true))
            }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }
}
