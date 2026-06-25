import Foundation

/// Finds duplicate files by content. Cheap-to-expensive funnel: gather files (via
/// the flat walk), group by size, then SHA-256 only the size-collision groups and
/// keep hash matches. Pure (real I/O), so it's unit-tested with temp trees; callers
/// run it off the main thread. Builds on FlatEnumerator + FileHasher.
public enum DuplicateFinder {
    public struct Group: Sendable, Equatable {
        public let hash: String
        public let files: [FileEntry]  // each carries its folder via FileEntry.location
        public init(hash: String, files: [FileEntry]) {
            self.hash = hash
            self.files = files
        }
    }

    /// Duplicate groups (2+ files with identical content) under `roots`. Files
    /// smaller than `minSize` are skipped (empty files are trivially identical noise).
    public static func find(
        in roots: [URL], includingHidden: Bool = false, minSize: Int64 = 1,
        excludingDirectories: Set<String> = [], maxItems: Int = 200_000
    ) -> [Group] {
        // 1. Gather candidate files, bucketed by size (different size => different content).
        var bySize: [Int64: [FileEntry]] = [:]
        for root in roots {
            let flat = FlatEnumerator.entries(
                of: root, includingHidden: includingHidden, includeFolders: false,
                excludingDirectories: excludingDirectories, maxItems: maxItems)
            for entry in flat.entries where !entry.isDirectory && entry.size >= minSize {
                bySize[entry.size, default: []].append(entry)
            }
        }

        // 2. Within each size-collision group, confirm by content hash.
        var groups: [Group] = []
        for (_, candidates) in bySize where candidates.count > 1 {
            var byHash: [String: [FileEntry]] = [:]
            for entry in candidates {
                guard let location = entry.location else { continue }
                let url = URL(fileURLWithPath: location).appendingPathComponent(entry.name)
                guard let hash = try? FileHasher.hash(url) else { continue }
                byHash[hash, default: []].append(entry)
            }
            for (hash, files) in byHash where files.count > 1 {
                groups.append(Group(hash: hash, files: files))
            }
        }
        // Largest wasted space first (files beyond the first in each group are redundant).
        return groups.sorted { ($0.files.first?.size ?? 0) > ($1.files.first?.size ?? 0) }
    }
}
