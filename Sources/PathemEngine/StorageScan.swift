import Foundation

/// Scans a folder for reclaimable space, like macOS Storage but actionable and
/// reversible: developer/cache junk and duplicate copies are "safe to remove", while
/// large and old files are surfaced for review. Pure (real I/O), so it's unit-tested
/// with temp trees; the UI runs it off-main and the on-device model can recommend
/// from the report. Builds on DirectorySize + DuplicateFinder.
public enum StorageScan {
    /// Regenerable directory names treated as junk (listed as reclaimable, not descended into).
    static let junkDirectories: Set<String> = [
        "node_modules", "DerivedData", "__pycache__", ".gradle", ".build", ".next", "Pods", ".venv",
        "venv", ".pytest_cache", ".mypy_cache",
    ]

    /// Directories to skip entirely: version control, caches, and other dev/system
    /// noise that shouldn't be deleted or counted, and (crucially) shouldn't flood the
    /// duplicate results with thousands of meaningless copies.
    static let excludedDirectories: Set<String> = [
        ".git", ".svn", ".hg", ".Trash", ".Trashes", "Caches", ".cache", ".npm", ".cargo",
        ".rustup", ".cocoapods", ".m2", "target", ".terraform", ".stack-work", "vendor",
        "DerivedData", ".gradle",
    ]

    /// Folders whose contents are excluded from the duplicate scan (junk + noise).
    static var duplicateExclusions: Set<String> { junkDirectories.union(excludedDirectories) }

    /// Cache folders: listed for review with their size, never descended into or pre-checked.
    static let cacheDirectories: Set<String> = ["Caches", ".cache"]

    public enum Category: String, Sendable, Codable { case junk, duplicate, large, old, cache }

    /// How many files the duplicate pass examines; beyond this the duplicate results are partial.
    public static let duplicateFileLimit = 300_000

    public struct Item: Sendable, Equatable {
        public let path: String
        public let size: Int64
        public let category: Category
        public let reason: String
        public let isDirectory: Bool
        /// When a junk folder last changed, so a stale project's build output stands out.
        public let modified: Date?
        public init(
            path: String, size: Int64, category: Category, reason: String, isDirectory: Bool,
            modified: Date? = nil
        ) {
            self.modified = modified
            self.path = path
            self.size = size
            self.category = category
            self.reason = reason
            self.isDirectory = isDirectory
        }
    }

    public struct Report: Sendable, Equatable {
        public var junk: [Item] = []
        public var duplicates: [Item] = []
        public var large: [Item] = []
        public var old: [Item] = []
        public var caches: [Item] = []
        /// True only when the walk was stopped before it finished (cancelled or an explicit limit).
        public var truncated = false
        /// Entries visited by the walk, and regular files among them (for progress and for
        /// telling whether the duplicate pass covered everything).
        public var itemsScanned = 0
        public var filesScanned = 0
        /// Bytes that are safe to remove (junk + duplicate extras); large/old are review-only.
        public var safeReclaimable: Int64 {
            (junk + duplicates).reduce(0) { $0 + $1.size }
        }
    }

    /// Full scan (quick categories + duplicates). The UI prefers the two-phase API
    /// below so it can show quick results first, but this keeps a one-call entry point.
    public static func scan(
        _ root: URL, oldAfterDays: Int = 180, largeThreshold: Int64 = 50_000_000,
        oldMinSize: Int64 = 5_000_000, maxPerReviewCategory: Int = 30, maxItems: Int = .max
    ) -> Report {
        var report = scanQuick(
            root, oldAfterDays: oldAfterDays, largeThreshold: largeThreshold,
            oldMinSize: oldMinSize,
            maxPerReviewCategory: maxPerReviewCategory, maxItems: maxItems)
        report.duplicates = duplicates(root)
        return report
    }

    /// The fast phase: junk, caches, large, and old files from a single walk (no hashing), so
    /// results can be shown while duplicates are still computing. The walk covers the whole
    /// tree: it only stops early when `isCancelled` returns true or an explicit `maxItems` is
    /// hit, and then sets `truncated`. Only candidate files are kept, so memory stays small.
    public static func scanQuick(
        _ root: URL, oldAfterDays: Int = 180, largeThreshold: Int64 = 50_000_000,
        oldMinSize: Int64 = 5_000_000, maxPerReviewCategory: Int = 30, maxItems: Int = .max,
        progress: ((Int) -> Void)? = nil, isCancelled: () -> Bool = { false }
    ) -> Report {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let cutoff = Date(timeIntervalSinceNow: -Double(oldAfterDays) * 86_400)
        var report = Report()
        var large: [(path: String, size: Int64)] = []
        var old: [(path: String, size: Int64)] = []
        var count = 0
        var stack = [root]
        walk: while let dir = stack.popLast() {
            if isCancelled() || count >= maxItems {
                report.truncated = true
                break
            }
            guard
                let entries = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: keys, options: [])
            else { continue }
            for entry in entries {
                count += 1
                if count >= maxItems {
                    report.truncated = true
                    break walk
                }
                if count % 5000 == 0 {
                    progress?(count)
                    if isCancelled() {
                        report.truncated = true
                        break walk
                    }
                }
                let values = try? entry.resourceValues(forKeys: Set(keys))
                let name = entry.lastPathComponent
                if values?.isDirectory == true {
                    if junkDirectories.contains(name) {
                        report.junk.append(
                            Item(
                                path: entry.path, size: DirectorySize.total(of: entry).bytes,
                                category: .junk, reason: name, isDirectory: true,
                                modified: values?.contentModificationDate))
                    } else if cacheDirectories.contains(name) {
                        report.caches.append(
                            Item(
                                path: entry.path, size: DirectorySize.total(of: entry).bytes,
                                category: .cache, reason: name, isDirectory: true))
                    } else if excludedDirectories.contains(name) {
                        continue  // skip VCS/system noise entirely (no descend, no listing)
                    } else {
                        stack.append(entry)  // descend
                    }
                } else {
                    let size = Int64(values?.fileSize ?? 0)
                    if name == ".DS_Store" {
                        report.junk.append(
                            Item(
                                path: entry.path, size: size, category: .junk, reason: ".DS_Store",
                                isDirectory: false))
                        continue
                    }
                    report.filesScanned += 1
                    if size >= largeThreshold { large.append((entry.path, size)) }
                    if size >= oldMinSize,
                        (values?.contentModificationDate ?? .distantPast) < cutoff
                    {
                        old.append((entry.path, size))
                    }
                }
            }
        }
        report.itemsScanned = count
        report.large = large.sorted { $0.size > $1.size }.prefix(maxPerReviewCategory).map {
            Item(
                path: $0.path, size: $0.size, category: .large, reason: "large file",
                isDirectory: false)
        }
        report.old = old.sorted { $0.size > $1.size }.prefix(maxPerReviewCategory).map {
            Item(
                path: $0.path, size: $0.size, category: .old, reason: "unused for a long time",
                isDirectory: false)
        }
        return report
    }

    /// One row of the Cleanup list: a single big item, or many small items of one kind folded
    /// together so thousands of tiny folders don't bury the few that matter.
    public struct Group: Sendable, Equatable {
        public let category: Category
        public let kind: String
        public let items: [Item]
        public init(category: Category, kind: String, items: [Item]) {
            self.category = category
            self.kind = kind
            self.items = items
        }
        public var size: Int64 { items.reduce(0) { $0 + $1.size } }
        public var isSingle: Bool { items.count == 1 }
    }

    /// Group `items` per (category, kind): each item of at least `individualAtLeast` bytes gets
    /// its own row, and the smaller ones of that kind fold into one row. Biggest row first.
    public static func grouped(_ items: [Item], individualAtLeast: Int64) -> [Group] {
        var singles: [Group] = []
        var folded: [String: [Item]] = [:]
        var order: [String] = []
        for item in items {
            if item.size >= individualAtLeast {
                singles.append(Group(category: item.category, kind: item.reason, items: [item]))
            } else {
                let key = item.category.rawValue + "\u{0}" + item.reason
                if folded[key] == nil { order.append(key) }
                folded[key, default: []].append(item)
            }
        }
        let groups =
            singles
            + order.compactMap { key in
                folded[key].map { Group(category: $0[0].category, kind: $0[0].reason, items: $0) }
            }
        return groups.sorted { $0.size > $1.size }
    }

    /// The slow phase: duplicate copies (content-hashed). Run after `scanQuick` so the
    /// user already sees junk/large/old while this completes.
    public static func duplicates(_ root: URL, maxItems: Int = duplicateFileLimit) -> [Item] {
        var items: [Item] = []
        // Exclude caches/VCS/build dirs so results are meaningful files, not noise.
        for group in DuplicateFinder.find(
            in: [root], minSize: 1, excludingDirectories: duplicateExclusions, maxItems: maxItems)
        {
            for extra in group.files.dropFirst() {  // keep one per group; the rest are reclaimable
                guard let location = extra.location else { continue }
                items.append(
                    Item(
                        path: (location as NSString).appendingPathComponent(extra.name),
                        size: extra.size,
                        category: .duplicate, reason: "duplicate copy", isDirectory: false))
            }
        }
        return items
    }
}
