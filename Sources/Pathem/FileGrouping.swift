import AppKit
import PathemEngine
import UniformTypeIdentifiers

/// Turns a sorted list of entries into display rows for the list view's "Arrange By": section
/// headers interleaved with items, in a sensible per-key order. Pure and deterministic (pass
/// `now` in), so it's unit/smoke-testable; the list controller maps row <-> entry through it.
enum FileGrouping {
    /// A list row: either a group header, or an item that indexes into the ungrouped entries.
    enum Row: Equatable {
        case header(String)
        case item(Int)
    }

    /// Flat display rows for `entries` grouped by `key`. With `.none` the result is 1:1 with
    /// entries (identity), so the ungrouped path is unchanged. `tagColors` supplies each entry's
    /// Finder tag colors for the `.tag` key (from the view's async tag cache); it's ignored for
    /// the other keys.
    static func rows(
        _ entries: [FileEntry], by key: ViewFormat.GroupKey, now: Date,
        tagColors: (FileEntry) -> [FileTag.Color] = { _ in [] }
    ) -> [Row] {
        guard key != .none else { return entries.indices.map { .item($0) } }
        // Bucket entries, preserving their incoming (already-sorted) order within each bucket.
        var buckets: [(order: Int, title: String, items: [Int])] = []
        var indexByTitle: [String: Int] = [:]
        for (i, entry) in entries.enumerated() {
            let (order, title) = bucket(for: entry, key: key, now: now, tagColors: tagColors)
            if let bi = indexByTitle[title] {
                buckets[bi].items.append(i)
            } else {
                indexByTitle[title] = buckets.count
                buckets.append((order, title, [i]))
            }
        }
        buckets.sort {
            $0.order != $1.order
                ? $0.order < $1.order
                : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return buckets.flatMap { [Row.header($0.title)] + $0.items.map { Row.item($0) } }
    }

    /// The (ordering, section title) for one entry under a group key.
    private static func bucket(
        for entry: FileEntry, key: ViewFormat.GroupKey, now: Date,
        tagColors: (FileEntry) -> [FileTag.Color]
    ) -> (Int, String) {
        switch key {
        case .none:
            return (0, "")
        case .kind:
            if entry.isDirectory { return (0, L("group.folder", "Folder")) }
            let ext = (entry.name as NSString).pathExtension
            let kind = UTType(filenameExtension: ext)?.localizedDescription ?? L("group.document", "Document")
            return (1, kind)  // files share order 1, then sort by kind title
        case .size:
            if entry.isDirectory { return (0, L("group.folders", "Folders")) }
            return sizeBucket(entry.size)
        case .dateModified:
            return dateBucket(entry.modificationDate, now: now)
        case .tag:
            // Group by the first tag color; untagged files fall into a trailing "No Tag" bucket.
            guard let color = tagColors(entry).first else { return (1, L("group.noTag", "No Tag")) }
            return (0, color.label)
        }
    }

    private static func sizeBucket(_ size: Int64) -> (Int, String) {
        switch size {
        case ..<1: return (1, L("group.sizeZero", "Zero bytes"))
        case ..<100_000: return (2, L("group.sizeTiny", "Tiny (under 100 KB)"))
        case ..<1_000_000: return (3, L("group.sizeSmall", "Small (100 KB – 1 MB)"))
        case ..<100_000_000: return (4, L("group.sizeMedium", "Medium (1 – 100 MB)"))
        case ..<1_000_000_000: return (5, L("group.sizeLarge", "Large (100 MB – 1 GB)"))
        default: return (6, L("group.sizeHuge", "Huge (over 1 GB)"))
        }
    }

    private static func dateBucket(_ date: Date?, now: Date) -> (Int, String) {
        guard let date else { return (9, L("group.dateUnknown", "Unknown Date")) }
        let calendar = Calendar.current
        if date > now || calendar.isDateInToday(date) { return (0, L("group.today", "Today")) }
        if calendar.isDateInYesterday(date) { return (1, L("group.yesterday", "Yesterday")) }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        if days < 7 { return (2, L("group.prev7", "Previous 7 Days")) }
        if days < 30 { return (3, L("group.prev30", "Previous 30 Days")) }
        return (4, L("group.earlier", "Earlier"))
    }
}
