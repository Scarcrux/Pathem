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

    /// Bytes hashed for the cheap head prefilter. Two files that differ within their first
    /// 64 KB can't be identical, so only head collisions get read in full.
    private static let headBytes = 64 * 1024

    /// Duplicate groups (2+ files with identical content) under `roots`. Files smaller than
    /// `minSize` are skipped (empty files are trivially identical noise). Pass `isCancelled` to
    /// stop early on a long scan; it returns whatever groups were confirmed so far.
    public static func find(
        in roots: [URL], includingHidden: Bool = false, minSize: Int64 = 1,
        excludingDirectories: Set<String> = [], maxItems: Int = 200_000,
        isCancelled: () -> Bool = { false }
    ) -> [Group] {
        // 1. Gather candidate files, bucketed by size (different size => different content).
        var bySize: [Int64: [FileEntry]] = [:]
        for root in roots {
            if isCancelled() { return [] }
            let flat = FlatEnumerator.entries(
                of: root, includingHidden: includingHidden, includeFolders: false,
                excludingDirectories: excludingDirectories, maxItems: maxItems)
            for entry in flat.entries where !entry.isDirectory && entry.size >= minSize {
                bySize[entry.size, default: []].append(entry)
            }
        }

        // 2. Within each size-collision group, prefilter by a cheap head hash, then confirm the
        //    head collisions by full content hash. A full read only ever happens for files that
        //    already agree on both size and their first 64 KB, so two big files that merely share
        //    a size are never both read end to end.
        var groups: [Group] = []
        for (size, candidates) in bySize where candidates.count > 1 {
            if isCancelled() { return groups }
            let head = min(headBytes, max(1, Int(min(size, Int64(headBytes)))))  // don't read past EOF
            for headBucket in bucket(candidates, by: { try FileHasher.hashHead($0, maxBytes: head) })
            where headBucket.count > 1 {
                if isCancelled() { return groups }
                for (hash, files) in byHashDict(headBucket, using: { try FileHasher.hash($0) })
                where files.count > 1 {
                    groups.append(Group(hash: hash, files: files))
                }
            }
        }
        // Largest wasted space first (files beyond the first in each group are redundant).
        return groups.sorted { ($0.files.first?.size ?? 0) > ($1.files.first?.size ?? 0) }
    }

    /// Group entries by a hash of the file, dropping any that can't be read. Returns the buckets
    /// (order unspecified); callers keep those with more than one member.
    private static func bucket(_ entries: [FileEntry], by hash: (URL) throws -> String) -> [[FileEntry]] {
        Array(byHashDict(entries, using: hash).values)
    }

    private static func byHashDict(_ entries: [FileEntry], using hash: (URL) throws -> String)
        -> [String: [FileEntry]]
    {
        var byHash: [String: [FileEntry]] = [:]
        for entry in entries {
            guard let location = entry.location else { continue }
            let url = URL(fileURLWithPath: location).appendingPathComponent(entry.name)
            guard let digest = try? hash(url) else { continue }
            byHash[digest, default: []].append(entry)
        }
        return byHash
    }
}
