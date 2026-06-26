import Foundation

/// Reference enumerator built on `FileManager`.
///
/// Correct and simple, but not the fast path. It exists to (1) get the app
/// working end-to-end now and (2) serve as the contract oracle for the
/// `getattrlistbulk`-based `BulkEnumerator` to come: both must return the same
/// entries for the same directory (DESIGN.md §3).
public struct FoundationEnumerator: DirectoryEnumerating {
    public init() {}

    public func entries(of directory: URL, includingHidden: Bool) throws -> [FileEntry] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .contentAccessDateKey,
        ]
        var options: FileManager.DirectoryEnumerationOptions = []
        if !includingHidden { options.insert(.skipsHiddenFiles) }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: options
        )

        return try urls.map { url in
            let values = try url.resourceValues(forKeys: Set(keys))
            return FileEntry(
                name: url.lastPathComponent,
                isDirectory: values.isDirectory ?? false,
                size: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate,
                creationDate: values.creationDate,
                accessDate: values.contentAccessDate,
                isDataless: Self.isDataless(url)
            )
        }
    }

    /// SF_DATALESS via lstat, matching BulkEnumerator's flags read so the oracle
    /// and the fallback path agree on cloud placeholders.
    private static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(0x4000_0000) != 0
    }
}
