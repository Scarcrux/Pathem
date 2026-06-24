import Foundation

/// Compares two folder trees by relative path and (optionally) mirrors one onto the
/// other. The comparison is pure and unit-tested; `mirror` performs the file ops and
/// reports what it did. Built on FlatEnumerator + FileHasher.
public enum FolderCompare {
    public enum DiffKind: String, Sendable, Equatable {
        case onlyLeft, onlyRight, differs, identical
    }

    public struct Difference: Sendable, Equatable {
        public let relativePath: String
        public let kind: DiffKind
        public init(relativePath: String, kind: DiffKind) {
            self.relativePath = relativePath
            self.kind = kind
        }
    }

    public struct MirrorResult: Sendable, Equatable {
        public var copied: Int = 0
        public var deleted: Int = 0
        public var failures: [String] = []
        public init() {}
    }

    /// Per-relative-path comparison of the files under `left` and `right`. Files
    /// differ when their sizes differ, or (with `byContent`) their SHA-256 differ,
    /// else their modification times differ.
    public static func compare(left: URL, right: URL, byContent: Bool = false, maxItems: Int = 200_000)
        -> [Difference]
    {
        let leftFiles = index(of: left, maxItems: maxItems)
        let rightFiles = index(of: right, maxItems: maxItems)
        var diffs: [Difference] = []
        for (rel, lEntry) in leftFiles {
            guard let rEntry = rightFiles[rel] else {
                diffs.append(Difference(relativePath: rel, kind: .onlyLeft))
                continue
            }
            let differs: Bool
            if lEntry.size != rEntry.size {
                differs = true
            } else if byContent {
                differs = hash(left, rel) != hash(right, rel)
            } else {
                differs = lEntry.modificationDate != rEntry.modificationDate
            }
            diffs.append(Difference(relativePath: rel, kind: differs ? .differs : .identical))
        }
        for rel in rightFiles.keys where leftFiles[rel] == nil {
            diffs.append(Difference(relativePath: rel, kind: .onlyRight))
        }
        return diffs.sorted { $0.relativePath < $1.relativePath }
    }

    /// One-way mirror: copy every file that's only-on-left or differs into `right`
    /// (creating folders as needed); when `deleteExtras`, send right-only files to
    /// the Trash. Returns counts and any failures.
    @discardableResult
    public static func mirror(
        from left: URL, to right: URL, differences: [Difference], deleteExtras: Bool
    ) -> MirrorResult {
        let fm = FileManager.default
        var result = MirrorResult()
        for diff in differences {
            switch diff.kind {
            case .onlyLeft, .differs:
                let src = left.appendingPathComponent(diff.relativePath)
                let dst = right.appendingPathComponent(diff.relativePath)
                do {
                    try fm.createDirectory(
                        at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.copyItem(at: src, to: dst)
                    result.copied += 1
                } catch {
                    result.failures.append(diff.relativePath)
                }
            case .onlyRight where deleteExtras:
                let target = right.appendingPathComponent(diff.relativePath)
                let trash = FileOperations.trash(urls: [target])
                if trash.failures.isEmpty { result.deleted += 1 } else { result.failures.append(diff.relativePath) }
            default:
                break
            }
        }
        return result
    }

    /// A summary tally for a confirmation dialog.
    public static func summary(_ diffs: [Difference]) -> (onlyLeft: Int, onlyRight: Int, differs: Int, identical: Int) {
        var s = (onlyLeft: 0, onlyRight: 0, differs: 0, identical: 0)
        for diff in diffs {
            switch diff.kind {
            case .onlyLeft: s.onlyLeft += 1
            case .onlyRight: s.onlyRight += 1
            case .differs: s.differs += 1
            case .identical: s.identical += 1
            }
        }
        return s
    }

    // MARK: Helpers

    private static func index(of root: URL, maxItems: Int) -> [String: FileEntry] {
        let flat = FlatEnumerator.entries(of: root, includingHidden: true, includeFolders: false, maxItems: maxItems)
        let rootPath = root.standardizedFileURL.path
        var map: [String: FileEntry] = [:]
        for entry in flat.entries {
            guard let location = entry.location else { continue }
            let full = (location as NSString).appendingPathComponent(entry.name)
            guard full.hasPrefix(rootPath) else { continue }
            let rel = String(full.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
            map[rel] = entry
        }
        return map
    }

    private static func hash(_ root: URL, _ rel: String) -> String? {
        try? FileHasher.hash(root.appendingPathComponent(rel))
    }
}
