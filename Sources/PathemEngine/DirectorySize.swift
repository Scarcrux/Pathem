import Foundation

/// Recursive directory size, for the Finder-style "calculate all sizes" option.
/// Synchronous and potentially slow on deep trees, so callers run it off the main
/// thread.
public enum DirectorySize {
    /// A directory measurement: total bytes, and whether the walk was complete.
    /// `complete` is false when a subtree was unreadable (permission denied, etc.),
    /// so the byte count is a lower bound and the UI can flag it as approximate.
    public struct Measurement: Sendable, Equatable {
        public let bytes: Int64
        public let complete: Bool
        public init(bytes: Int64, complete: Bool) {
            self.bytes = bytes
            self.complete = complete
        }
    }

    /// Total bytes of all regular files under `url` (descending into subfolders).
    /// Symlinks are not followed; unreadable items are skipped but flip `complete`
    /// to false so the caller knows the total is an undercount.
    public static func total(of url: URL) -> Measurement {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var hadError = false
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys,
                options: [],  // count hidden too, like Finder
                errorHandler: { _, _ in
                    hadError = true  // an unreadable subtree: total will be a lower bound
                    return true  // keep going so the rest still counts
                })
        else { return Measurement(bytes: 0, complete: false) }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            // A throw here means the item itself was unreadable (not just a folder we
            // skip), so it undercounts; a successful read that isn't a regular file
            // (a directory/symlink) is normal and not an error.
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else {
                hadError = true
                continue
            }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return Measurement(bytes: total, complete: !hadError)
    }
}
