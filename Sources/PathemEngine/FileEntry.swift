import Foundation

/// A single directory entry, as a value type.
///
/// The engine emits these into a contiguous array and the UI reads them
/// directly. No reference types and no `NSURL` in the hot path — this is what
/// lets a 100k+ file listing sort/filter and scroll without an object graph
/// (DESIGN.md §4, §5).
public struct FileEntry: Sendable, Hashable {
    /// Last path component (the display name), e.g. `report.pdf`.
    public let name: String
    public let isDirectory: Bool
    /// Logical file size in bytes. `0` for directories.
    public let size: Int64
    public let modificationDate: Date?
    /// True for a cloud placeholder whose bytes are not on disk yet (SF_DATALESS).
    /// Reading its contents would trigger a download, so callers gate on this.
    public let isDataless: Bool
    /// Containing directory path, set only for cross-folder result lists (smart
    /// locations like Recents or a tag filter). `nil` for a normal listing, where
    /// the entry lives in the pane's current directory.
    public let location: String?

    public init(
        name: String, isDirectory: Bool, size: Int64, modificationDate: Date?,
        isDataless: Bool = false, location: String? = nil
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.isDataless = isDataless
        self.location = location
    }

    /// Build an entry for a file at a known URL (used for smart-location results).
    public init(contentsOf url: URL) {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        ])
        self.name = url.lastPathComponent
        self.isDirectory = values?.isDirectory ?? false
        self.size = Int64(values?.fileSize ?? 0)
        self.modificationDate = values?.contentModificationDate
        self.isDataless = false
        self.location = url.deletingLastPathComponent().path
    }
}
