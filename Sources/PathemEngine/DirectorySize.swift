import Foundation

/// Recursive directory size, for the Finder-style "calculate all sizes" option.
/// Synchronous and potentially slow on deep trees, so callers run it off the main
/// thread.
public enum DirectorySize {
    /// A directory measurement: total bytes, and whether the walk was complete.
    /// `complete` is false when a subtree was unreadable (permission denied, etc.),
    /// so the byte count is a lower bound and the UI can flag it as approximate.
    public struct Measurement: Sendable, Equatable {
        public let bytes: Int64
        public let complete: Bool
        public init(bytes: Int64, complete: Bool) {
            self.bytes = bytes
            self.complete = complete
        }
    }

    /// Total bytes of all regular files under `url` (descending into subfolders).
    /// Symlinks are not followed; unreadable items are skipped but flip `complete`
    /// to false so the caller knows the total is an undercount.
    public static func total(of url: URL) -> Measurement {
        var rootInfo = stat()
        guard lstat(url.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else {
            return Measurement(bytes: 0, complete: false)
        }
        let walk = ParallelWalk(root: url.path)
        DispatchQueue.concurrentPerform(
            iterations: max(2, ProcessInfo.processInfo.activeProcessorCount)
        ) { _ in walk.work() }
        return Measurement(bytes: walk.bytes, complete: walk.complete)
    }

    /// A directory walk shared by several threads: every folder is one unit of work on a
    /// common stack, so the cores stay busy whatever the tree's shape (one huge subtree is
    /// split as its folders are discovered). Each folder is read with readdir and its files
    /// sized with fstatat, which is several times faster on a large tree than one
    /// FileManager enumerator fetching resource values per file.
    private final class ParallelWalk: @unchecked Sendable {
        private let lock = NSLock()
        private var stack: [String]
        private var active = 0
        private(set) var bytes: Int64 = 0
        private(set) var complete = true

        init(root: String) { stack = [root] }

        func work() {
            while true {
                lock.lock()
                guard let directory = stack.popLast() else {
                    let finished = active == 0
                    lock.unlock()
                    if finished { return }
                    usleep(200)  // another thread is still listing a folder that may add work
                    continue
                }
                active += 1
                lock.unlock()

                var localBytes: Int64 = 0
                var folders: [String] = []
                var ok = true
                if let handle = opendir(directory) {
                    let descriptor = dirfd(handle)
                    while let entry = readdir(handle) {
                        let name = withUnsafePointer(to: &entry.pointee.d_name) {
                            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                                String(cString: $0)
                            }
                        }
                        if name == "." || name == ".." { continue }
                        var kind = Int32(entry.pointee.d_type)
                        var info = stat()
                        if kind == DT_REG || kind == DT_UNKNOWN {
                            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                                ok = false
                                continue
                            }
                            if kind == DT_UNKNOWN {
                                switch info.st_mode & S_IFMT {
                                case S_IFREG: kind = DT_REG
                                case S_IFDIR: kind = DT_DIR
                                default: break
                                }
                            }
                        }
                        // Regular files are counted, folders queued; symlinks and special
                        // files are neither followed nor counted.
                        if kind == DT_REG {
                            localBytes += Int64(info.st_size)
                        } else if kind == DT_DIR {
                            folders.append(directory + "/" + name)
                        }
                    }
                    closedir(handle)
                } else {
                    ok = false  // unreadable folder: the total is a lower bound
                }

                lock.lock()
                bytes += localBytes
                if !ok { complete = false }
                stack.append(contentsOf: folders)
                active -= 1
                lock.unlock()
            }
        }
    }

    /// The original implementation, kept as the reference the fast walk is tested against.
    static func referenceTotal(of url: URL) -> Measurement {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var hadError = false
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys,
                options: [],  // count hidden too, like Finder
                errorHandler: { _, _ in
                    hadError = true  // an unreadable subtree: total will be a lower bound
                    return true  // keep going so the rest still counts
                })
        else { return Measurement(bytes: 0, complete: false) }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            // A throw here means the item itself was unreadable (not just a folder we
            // skip), so it undercounts; a successful read that isn't a regular file
            // (a directory/symlink) is normal and not an error.
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else {
                hadError = true
                continue
            }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return Measurement(bytes: total, complete: !hadError)
    }
}
