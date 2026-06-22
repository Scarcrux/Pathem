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

    public init(
        name: String, isDirectory: Bool, size: Int64, modificationDate: Date?,
        isDataless: Bool = false
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.isDataless = isDataless
    }
}
