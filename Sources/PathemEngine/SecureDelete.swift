import Foundation
import Security

/// Best-effort secure erase: overwrite a file's bytes with random data before unlinking,
/// so a casual undelete can't recover the contents. Honest caveat, surfaced by the UI: on
/// flash storage (APFS/SSD) copy-on-write and wear-leveling mean the original blocks may
/// still physically exist, so this is not a guarantee against a determined forensic effort.
/// Unlike Move to Trash, it is irreversible. Pure Foundation, unit-tested with temp files.
public enum SecureDelete {
    public struct Result: Sendable, Equatable {
        public var deleted: [String] = []
        public var failures: [FileOperations.Failure] = []
        public init() {}
    }

    /// Overwrite each file `passes` times with random data, then remove it. Folders recurse
    /// (files shredded, then the directories removed); a symlink is just unlinked (its
    /// target is left alone).
    public static func shred(_ urls: [URL], passes: Int = 1) -> Result {
        var result = Result()
        for url in urls { shredItem(url, passes: max(1, passes), into: &result) }
        return result
    }

    private static func shredItem(_ url: URL, passes: Int, into result: inout Result) {
        let fm = FileManager.default
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            remove(url, into: &result)  // never follow the link into its target
            return
        }
        if values?.isDirectory == true {
            if let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                for child in children { shredItem(child, passes: passes, into: &result) }
            }
            remove(url, into: &result)
            return
        }
        do {
            try overwrite(url, passes: passes)
            try fm.removeItem(at: url)
            result.deleted.append(url.lastPathComponent)
        } catch {
            result.failures.append(.init(name: url.lastPathComponent, reason: error.localizedDescription))
        }
    }

    /// Overwrite a file's existing bytes in place with cryptographically-random data.
    static func overwrite(_ url: URL, passes: Int) throws {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let chunkSize = 1 << 16  // 64 KB
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        for _ in 0..<passes {
            try handle.seek(toOffset: 0)
            var remaining = size
            while remaining > 0 {
                let n = min(chunkSize, remaining)
                _ = SecRandomCopyBytes(kSecRandomDefault, n, &buffer)
                try handle.write(contentsOf: Data(buffer[0..<n]))
                remaining -= n
            }
            try handle.synchronize()  // push each pass to disk before the next
        }
    }

    private static func remove(_ url: URL, into result: inout Result) {
        do {
            try FileManager.default.removeItem(at: url)
            result.deleted.append(url.lastPathComponent)
        } catch {
            result.failures.append(.init(name: url.lastPathComponent, reason: error.localizedDescription))
        }
    }
}
