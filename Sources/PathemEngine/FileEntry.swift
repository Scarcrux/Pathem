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
    /// Creation and last-access dates, for the optional list columns. `nil` when the
    /// source didn't provide them (e.g. remote listings).
    public let creationDate: Date?
    public let accessDate: Date?
    /// True for a cloud placeholder whose bytes are not on disk yet (SF_DATALESS).
    /// Reading its contents would trigger a download, so callers gate on this.
    public let isDataless: Bool
    /// Containing directory path, set only for cross-folder result lists (smart
    /// locations like Recents or a tag filter). `nil` for a normal listing, where
    /// the entry lives in the pane's current directory.
    public let location: String?
    /// The exact on-the-wire name bytes for a remote entry whose name isn't valid
    /// UTF-8 (so `name`, a lossy decode, doesn't lose them). `nil` for local
    /// entries and remote names that are already valid UTF-8.
    public let rawName: Data?

    public init(
        name: String, isDirectory: Bool, size: Int64, modificationDate: Date?,
        creationDate: Date? = nil, accessDate: Date? = nil,
        isDataless: Bool = false, location: String? = nil, rawName: Data? = nil
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.accessDate = accessDate
        self.isDataless = isDataless
        self.location = location
        self.rawName = rawName
    }

    /// Build an entry for a file at a known URL (used for smart-location results).
    public init(contentsOf url: URL) {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .contentAccessDateKey,
        ])
        self.name = url.lastPathComponent
        self.isDirectory = values?.isDirectory ?? false
        self.size = Int64(values?.fileSize ?? 0)
        self.modificationDate = values?.contentModificationDate
        self.creationDate = values?.creationDate
        self.accessDate = values?.contentAccessDate
        self.isDataless = false
        self.location = url.deletingLastPathComponent().path
        self.rawName = nil
    }
}
