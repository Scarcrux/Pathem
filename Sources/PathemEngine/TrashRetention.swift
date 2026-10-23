import Darwin
import Foundation

/// Conservative, opt-in retention. Never substitutes content/creation time for the date an
/// item entered Trash. Unsupported volumes/unknown ages/symlinks are retained, not guessed old.
public enum TrashRetention {
    public struct Outcome: Sendable {
        public var removed = 0
        public var retained = 0
        public var failed = 0
    }

    public static func cleanHomeTrash(now: Date = Date()) -> Outcome {
        clean(
            directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                ".Trash"), now: now)
    }

    /// Internal injection keeps all mutation tests inside disposable directories.
    static func clean(
        directory: URL, now: Date,
        addedDate: (URL) -> Date? = {
            try? $0.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate
        }
    ) -> Outcome {
        var result = Outcome()
        let fm = FileManager.default
        func identity(_ url: URL) -> (device: dev_t, inode: ino_t, mode: mode_t, owner: uid_t)? {
            var value = stat()
            guard lstat(url.path, &value) == 0 else { return nil }
            return (value.st_dev, value.st_ino, value.st_mode & S_IFMT, value.st_uid)
        }
        guard let root = identity(directory), root.mode == S_IFDIR, root.owner == getuid(),
            let items = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.addedToDirectoryDateKey], options: [])
        else { return result }
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        for item in items {
            if Task.isCancelled { break }
            guard let original = identity(item), original.mode != S_IFLNK,
                original.owner == getuid(), let entered = addedDate(item), entered < cutoff
            else {
                result.retained += 1
                continue
            }
            // Recheck identity, location and age immediately before the coordinated delete.
            // Unknown/changed resources fail closed rather than deleting a replacement.
            var coordinationError: NSError?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(
                writingItemAt: item, options: .forDeleting, error: &coordinationError
            ) { target in
                guard !Task.isCancelled else {
                    result.retained += 1
                    return
                }
                guard target.standardizedFileURL == item.standardizedFileURL,
                    let currentRoot = identity(directory), currentRoot.device == root.device,
                    currentRoot.inode == root.inode, currentRoot.mode == S_IFDIR,
                    let current = identity(target), current.device == original.device,
                    current.inode == original.inode, current.mode != S_IFLNK,
                    let date = addedDate(target), date < cutoff
                else {
                    result.retained += 1
                    return
                }
                do {
                    try fm.removeItem(at: target)
                    result.removed += 1
                } catch { result.failed += 1 }
            }
            if coordinationError != nil { result.failed += 1 }
        }
        return result
    }
}
