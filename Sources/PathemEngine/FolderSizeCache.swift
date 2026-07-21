import Foundation

/// A persistable cache of computed directory sizes, so "calculate all sizes" doesn't re-walk a
/// folder's whole subtree on every visit (or after a restart). Each entry remembers the directory's
/// content-modification time; a lookup is a hit only when that time is unchanged, so adding or
/// removing items in a folder invalidates its cached size. (A change deep inside a subtree that
/// doesn't touch the folder's own mtime is not caught until the folder itself changes -- the usual
/// tradeoff for an mtime-keyed size cache, and far cheaper than re-walking every time.)
///
/// Pure and `Codable` so it unit-tests and round-trips through JSON; the app wraps it in a
/// thread-safe, debounced-saving store.
public struct FolderSizeCache: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let bytes: Int64
        public let complete: Bool
        public let mtime: Int64  // directory content-modification time, whole epoch seconds
    }

    private var entries: [String: Entry]
    /// Insertion/refresh order (oldest first), for LRU pruning so the file can't grow without bound.
    private var order: [String]
    public let maxEntries: Int

    public init(maxEntries: Int = 8000) {
        self.entries = [:]
        self.order = []
        self.maxEntries = max(1, maxEntries)
    }

    private enum CodingKeys: String, CodingKey { case entries, order, maxEntries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        maxEntries = max(1, try c.decodeIfPresent(Int.self, forKey: .maxEntries) ?? 8000)
        // Drop any order refs whose entry is gone, and any entry missing from order (tolerant load).
        order = order.filter { entries[$0] != nil }
        for key in entries.keys where !order.contains(key) { order.append(key) }
    }

    public var count: Int { entries.count }

    /// The cached measurement for `path`, but only if the directory's mtime still matches (unchanged
    /// since it was recorded). Returns nil on a miss or a stale entry.
    public func measurement(forPath path: String, currentMtime: Int64)
        -> DirectorySize.Measurement?
    {
        guard let entry = entries[path], entry.mtime == currentMtime else { return nil }
        return DirectorySize.Measurement(bytes: entry.bytes, complete: entry.complete)
    }

    /// Record (or refresh) a folder's measured size at the given mtime, evicting the least-recently
    /// recorded entries when over `maxEntries`.
    public mutating func record(
        path: String, measurement: DirectorySize.Measurement, mtime: Int64
    ) {
        entries[path] = Entry(bytes: measurement.bytes, complete: measurement.complete, mtime: mtime)
        if let existing = order.firstIndex(of: path) { order.remove(at: existing) }
        order.append(path)
        while entries.count > maxEntries, !order.isEmpty {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    /// Round a directory's modification date to whole epoch seconds, the cache's mtime key. Whole
    /// seconds so a sub-second re-read compares equal.
    public static func mtimeKey(_ date: Date?) -> Int64 {
        Int64((date ?? .distantPast).timeIntervalSince1970.rounded())
    }
}
