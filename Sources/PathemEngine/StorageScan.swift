import Foundation

/// Scans a folder for reclaimable space, like macOS Storage but actionable and
/// reversible: developer/cache junk and duplicate copies are "safe to remove", while
/// large and old files are surfaced for review. Pure (real I/O), so it's unit-tested
/// with temp trees; the UI runs it off-main and the on-device model can recommend
/// from the report. Builds on DirectorySize + DuplicateFinder.
public enum StorageScan {
    /// Regenerable directory names treated as junk (not descended into).
    static let junkDirectories: Set<String> = [
        "node_modules", "DerivedData", "__pycache__", ".gradle", ".build", ".next", "Pods", ".venv",
        "venv", ".pytest_cache", ".mypy_cache",
    ]

    public enum Category: String, Sendable, Codable { case junk, duplicate, large, old }

    public struct Item: Sendable, Equatable {
        public let path: String
        public let size: Int64
        public let category: Category
        public let reason: String
        public let isDirectory: Bool
        public init(path: String, size: Int64, category: Category, reason: String, isDirectory: Bool) {
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
        public var truncated = false
        /// Bytes that are safe to remove (junk + duplicate extras); large/old are review-only.
        public var safeReclaimable: Int64 {
            (junk + duplicates).reduce(0) { $0 + $1.size }
        }
    }

    public static func scan(
        _ root: URL, oldAfterDays: Int = 180, largeThreshold: Int64 = 50_000_000,
        oldMinSize: Int64 = 5_000_000, maxPerReviewCategory: Int = 30, maxItems: Int = 300_000
    ) -> Report {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var report = Report()
        var files: [(path: String, size: Int64, mtime: Date)] = []
        var count = 0
        var stack = [root]
        while let dir = stack.popLast() {
            if count >= maxItems { report.truncated = true; break }
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [])
            else { continue }
            for entry in entries {
                count += 1
                if count >= maxItems { report.truncated = true; break }
                let values = try? entry.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if junkDirectories.contains(entry.lastPathComponent) {
                        report.junk.append(
                            Item(
                                path: entry.path, size: DirectorySize.total(of: entry).bytes,
                                category: .junk, reason: entry.lastPathComponent, isDirectory: true))
                    } else {
                        stack.append(entry)  // descend
                    }
                } else {
                    let size = Int64(values?.fileSize ?? 0)
                    if entry.lastPathComponent == ".DS_Store" {
                        report.junk.append(
                            Item(path: entry.path, size: size, category: .junk, reason: ".DS_Store", isDirectory: false))
                    } else {
                        files.append((entry.path, size, values?.contentModificationDate ?? .distantPast))
                    }
                }
            }
        }

        report.large =
            files.filter { $0.size >= largeThreshold }.sorted { $0.size > $1.size }
            .prefix(maxPerReviewCategory)
            .map { Item(path: $0.path, size: $0.size, category: .large, reason: "large file", isDirectory: false) }

        let cutoff = Date(timeIntervalSinceNow: -Double(oldAfterDays) * 86_400)
        report.old =
            files.filter { $0.mtime < cutoff && $0.size >= oldMinSize }.sorted { $0.size > $1.size }
            .prefix(maxPerReviewCategory)
            .map {
                Item(path: $0.path, size: $0.size, category: .old, reason: "unused for a long time", isDirectory: false)
            }

        // Duplicate extras (keep one per group; the rest are reclaimable).
        for group in DuplicateFinder.find(in: [root], minSize: 1, maxItems: maxItems) {
            for extra in group.files.dropFirst() {
                guard let location = extra.location else { continue }
                report.duplicates.append(
                    Item(
                        path: (location as NSString).appendingPathComponent(extra.name), size: extra.size,
                        category: .duplicate, reason: "duplicate copy", isDirectory: false))
            }
        }
        return report
    }
}
