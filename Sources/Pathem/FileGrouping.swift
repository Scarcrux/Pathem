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
    /// Finder tag colors for the `.tag` key only when named-tag metadata has not been loaded
    /// (from the view's async tag cache). No filesystem or application lookup happens here.
    static func rows(
        _ entries: [FileEntry], by key: ViewFormat.GroupKey, now: Date,
        tagColors: (FileEntry) -> [FileTag.Color] = { _ in [] }
    ) -> [Row] {
        guard key != .none else { return entries.indices.map { .item($0) } }
        // Bucket entries, preserving their incoming (already-sorted) order within each bucket.
        var buckets: [(order: Int, title: String, items: [Int])] = []
        var indexByTitle: [String: Int] = [:]
        // Per-call caches: a kind title per lowercased extension (avoids a Launch Services round
        // trip per entry) and precomputed date boundaries (avoids Calendar math per entry). Both
        // were per-entry costs that stalled the main thread on 100k-row Group By.
        var kindByExt: [String: String] = [:]
        let bounds = DateBounds(now: now)
        for (i, entry) in entries.enumerated() {
            let (order, title) = bucket(
                for: entry, key: key, tagColors: tagColors, kindByExt: &kindByExt, bounds: bounds)
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

    /// Precomputed day boundaries so date bucketing is a few comparisons per entry, not
    /// repeated Calendar.isDateInToday / dateComponents calls.
    private struct DateBounds {
        let startOfToday: Date
        let startOfYesterday: Date
        let sevenDaysAgo: Date
        let thirtyDaysAgo: Date
        init(now: Date) {
            let cal = Calendar.current
            let today = cal.startOfDay(for: now)
            startOfToday = today
            startOfYesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
            sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: today) ?? today
            thirtyDaysAgo = cal.date(byAdding: .day, value: -30, to: today) ?? today
        }
    }

    /// The (ordering, section title) for one entry under a group key.
    private static func bucket(
        for entry: FileEntry, key: ViewFormat.GroupKey,
        tagColors: (FileEntry) -> [FileTag.Color],
        kindByExt: inout [String: String], bounds: DateBounds
    ) -> (Int, String) {
        switch key {
        case .none:
            return (0, "")
        case .name:
            return nameBucket(entry.name)
        case .kind:
            if let kind = nonempty(entry.viewMetadata?.kind) {
                return (entry.isDirectory ? 0 : 1, kind)
            }
            if entry.isDirectory { return (0, L("group.folder", "Folder")) }
            let ext = (entry.name as NSString).pathExtension.lowercased()
            if let cached = kindByExt[ext] { return (1, cached) }
            let kind =
                UTType(filenameExtension: ext)?.localizedDescription
                ?? L("group.document", "Document")
            kindByExt[ext] = kind
            return (1, kind)  // files share order 1, then sort by kind title
        case .application:
            if entry.isDirectory { return (0, L("group.folders", "Folders")) }
            if let name = nonempty(entry.viewMetadata?.applicationName) { return (1, name) }
            return (2, L("group.noApplication", "No Application"))
        case .size:
            if entry.isDirectory { return (0, L("group.folders", "Folders")) }
            return sizeBucket(entry.size)
        case .dateModified:
            return dateBucket(entry.modificationDate, bounds: bounds)
        case .dateAccessed:
            // A filesystem access time is not a user's last-opened date. Missing provider /
            // Spotlight metadata is honest Unknown Date, not a made-up recency group.
            return dateBucket(entry.viewMetadata?.lastOpenedDate, bounds: bounds)
        case .dateAdded:
            return dateBucket(entry.viewMetadata?.dateAdded, bounds: bounds)
        case .dateCreated:
            return dateBucket(entry.creationDate, bounds: bounds)
        case .tag:
            // A metadata snapshot (even an empty tag list) is authoritative. Sorting the names
            // makes the chosen section independent of the provider's tag-array ordering.
            if let metadata = entry.viewMetadata {
                let tags = metadata.tagNames.compactMap { nonempty($0) }.sorted {
                    let comparison = $0.localizedStandardCompare($1)
                    return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
                }
                guard let tag = tags.first else { return (1, L("group.noTag", "No Tag")) }
                return (0, tag)
            }
            // Preserve legacy callers' color cache until they deliver named-tag metadata.
            guard let color = tagColors(entry).first else { return (1, L("group.noTag", "No Tag")) }
            return (0, color.label)
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    /// Unicode initials, not ASCII byte ranges: e.g. Éclair joins E, while a Japanese or
    /// Cyrillic initial remains readable. Composed characters are never split into scalars.
    private static func nameBucket(_ name: String) -> (Int, String) {
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return (2, L("group.nameOther", "Other"))
        }
        let initial = String(first)
        if initial.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) {
            return (0, L("group.nameNumbers", "0–9"))
        }
        if initial.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) {
            let folded = initial.folding(
                options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            return (1, folded.uppercased(with: .current))
        }
        return (2, L("group.nameOther", "Other"))
    }

    private static func sizeBucket(_ size: Int64) -> (Int, String) {
        switch size {
        case ..<1: return (1, L("group.sizeZero", "Zero bytes"))
        case ..<100_000: return (2, L("group.sizeTiny", "Tiny (under 100 KB)"))
        case ..<1_000_000: return (3, L("group.sizeSmall", "Small (100 KB to 1 MB)"))
        case ..<100_000_000: return (4, L("group.sizeMedium", "Medium (1 to 100 MB)"))
        case ..<1_000_000_000: return (5, L("group.sizeLarge", "Large (100 MB to 1 GB)"))
        default: return (6, L("group.sizeHuge", "Huge (over 1 GB)"))
        }
    }

    private static func dateBucket(_ date: Date?, bounds: DateBounds) -> (Int, String) {
        guard let date else { return (9, L("group.dateUnknown", "Unknown Date")) }
        if date >= bounds.startOfToday { return (0, L("group.today", "Today")) }
        if date >= bounds.startOfYesterday { return (1, L("group.yesterday", "Yesterday")) }
        if date >= bounds.sevenDaysAgo { return (2, L("group.prev7", "Previous 7 Days")) }
        if date >= bounds.thirtyDaysAgo { return (3, L("group.prev30", "Previous 30 Days")) }
        return (4, L("group.earlier", "Earlier"))
    }
}
