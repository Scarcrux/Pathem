import Foundation

/// Totals for the current selection, broken down by kind, for the status bar and its popover.
/// Pure aggregation: the app decides when to run it (off the main thread, debounced) and how
/// to look up cached folder sizes.
public struct SelectionSummary: Sendable, Equatable {
    public struct Slice: Sendable, Equatable {
        public let kind: FileKindBucket
        public var count: Int
        public var bytes: Int64
    }

    /// Past this many selected items the breakdown samples the first `cap` and says so.
    public static let approximateCap = 50_000

    public let selectedCount: Int
    public let totalCount: Int
    /// Bytes of files plus folders whose size is known.
    public let bytes: Int64
    /// Selected folders whose size is not known yet (shown as "+ N folders").
    public let unmeasuredFolders: Int
    /// Non-empty kinds, largest bytes first (ties by count, then kind order).
    public let slices: [Slice]
    public let isApproximate: Bool

    /// - Parameter folderSize: the cached size of a selected folder, or nil when unknown.
    public static func summarize(
        selected: [FileEntry], totalCount: Int, cap: Int = approximateCap,
        folderSize: (FileEntry) -> Int64?
    ) -> SelectionSummary {
        var byKind: [FileKindBucket: Slice] = [:]
        var bytes: Int64 = 0
        var unmeasured = 0
        for entry in selected.prefix(cap) {
            var size = entry.size
            if entry.isDirectory {
                if let known = folderSize(entry) {
                    size = known
                } else {
                    size = 0
                    unmeasured += 1
                }
            }
            bytes += size
            let kind = FileKindBucket.of(entry)
            var slice = byKind[kind] ?? Slice(kind: kind, count: 0, bytes: 0)
            slice.count += 1
            slice.bytes += size
            byKind[kind] = slice
        }
        let order = FileKindBucket.allCases
        let slices = byKind.values.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            if $0.count != $1.count { return $0.count > $1.count }
            return order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)!
        }
        return SelectionSummary(
            selectedCount: selected.count, totalCount: totalCount, bytes: bytes,
            unmeasuredFolders: unmeasured, slices: slices, isApproximate: selected.count > cap)
    }
}
