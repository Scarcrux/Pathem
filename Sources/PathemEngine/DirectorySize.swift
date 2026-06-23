import Foundation

/// Recursive directory size, for the Finder-style "calculate all sizes" option.
/// Synchronous and potentially slow on deep trees, so callers run it off the main
/// thread.
public enum DirectorySize {
    /// Total bytes of all regular files under `url` (descending into subfolders).
    /// Symlinks are not followed; unreadable items are skipped.
    public static func total(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles], errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
