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
        total(of: url, isCancelled: { false }) ?? Measurement(bytes: 0, complete: false)
    }

    /// As `total(of:)`, but gives up as soon as `isCancelled` returns true and returns nil,
    /// so a caller that no longer wants the answer (the user navigated away, closed the
    /// window, or switched folder sizes off) stops paying for the walk. `isCancelled` is
    /// asked once per folder read, from several threads.
    public static func total(of url: URL, isCancelled: @escaping @Sendable () -> Bool)
        -> Measurement?
    {
        var rootInfo = stat()
        guard lstat(url.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else {
            return Measurement(bytes: 0, complete: false)
        }
        // The calling thread is itself a walker, so it waits for a place under the cap.
        guard WalkerPool.shared.acquire(isCancelled: isCancelled) else { return nil }
        let walk = ParallelWalk(root: url.path, isCancelled: isCancelled)
        walk.work(asCaller: true)
        walk.helpers.wait()
        WalkerPool.shared.release()
        return walk.cancelled ? nil : Measurement(bytes: walk.bytes, complete: walk.complete)
    }

    /// The most threads that walk folders at once, across every walk in the process. Without
    /// one shared cap each walk took every core, and the file list runs six walks at a time.
    public static var walkerLimit: Int { WalkerPool.shared.limit }

    /// One process-wide budget of walker threads. A walk's calling thread always holds one
    /// place; extra helper threads join only while places are free and leave as soon as
    /// another walk is waiting, so a small folder is not stuck behind a huge one.
    final class WalkerPool: @unchecked Sendable {
        static let shared = WalkerPool()
        private let condition = NSCondition()
        private var inUse = 0
        private var waiting = 0
        private var highest = 0
        private var cap = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

        var limit: Int {
            get { condition.withLock { cap } }
            set {
                condition.withLock { cap = max(1, newValue) }
                condition.broadcast()
            }
        }
        /// The most places ever held at once since `resetPeak`, for the cap's test.
        var peak: Int { condition.withLock { highest } }
        func resetPeak() { condition.withLock { highest = inUse } }
        var hasWaiters: Bool { condition.withLock { waiting > 0 } }

        func acquire(isCancelled: () -> Bool) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            waiting += 1
            defer { waiting -= 1 }
            while inUse >= cap {
                // Wake regularly: a cancelled caller must not sit in the queue.
                _ = condition.wait(until: Date().addingTimeInterval(0.05))
                if inUse >= cap, isCancelled() { return false }
            }
            take()
            return true
        }

        func tryAcquire() -> Bool {
            condition.lock()
            defer { condition.unlock() }
            guard inUse < cap, waiting == 0 else { return false }
            take()
            return true
        }

        func release() {
            condition.lock()
            inUse -= 1
            condition.unlock()
            condition.signal()
        }

        private func take() {
            inUse += 1
            highest = max(highest, inUse)
        }
    }

    /// A directory walk shared by several threads: every folder is one unit of work on a
    /// common stack, so the cores stay busy whatever the tree's shape (one huge subtree is
    /// split as its folders are discovered). Each folder is read with readdir and its files
    /// sized with fstatat, which is several times faster on a large tree than one
    /// FileManager enumerator fetching resource values per file.
    private final class ParallelWalk: @unchecked Sendable {
        private static let helperQueue = DispatchQueue(
            label: "pathem.directory-size.helpers", qos: .utility, attributes: .concurrent)
        private let lock = NSLock()
        private var stack: [String]
        private var active = 0
        private var helperCount = 0
        private let isCancelled: @Sendable () -> Bool
        let helpers = DispatchGroup()
        private(set) var bytes: Int64 = 0
        private(set) var complete = true
        private(set) var cancelled = false

        init(root: String, isCancelled: @escaping @Sendable () -> Bool) {
            stack = [root]
            self.isCancelled = isCancelled
        }

        /// Add a helper thread when there is a backlog of folders and a free place.
        private func addHelperIfUseful() {
            lock.lock()
            let backlog = stack.count
            let current = helperCount
            lock.unlock()
            guard backlog > 4 * (current + 1), WalkerPool.shared.tryAcquire() else { return }
            lock.lock()
            helperCount += 1
            lock.unlock()
            helpers.enter()
            Self.helperQueue.async {
                self.work(asCaller: false)
                self.lock.lock()
                self.helperCount -= 1
                self.lock.unlock()
                WalkerPool.shared.release()
                self.helpers.leave()
            }
        }

        func work(asCaller: Bool) {
            var handled = 0
            while true {
                if isCancelled() {
                    lock.lock()
                    cancelled = true
                    lock.unlock()
                }
                lock.lock()
                if cancelled {
                    lock.unlock()
                    return
                }
                guard let directory = stack.popLast() else {
                    let finished = active == 0
                    lock.unlock()
                    if finished { return }
                    // A helper gives its place up rather than idle while another walk waits.
                    if !asCaller, WalkerPool.shared.hasWaiters { return }
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

                handled += 1
                if asCaller {
                    if handled % 8 == 1 { addHelperIfUseful() }
                } else if WalkerPool.shared.hasWaiters {
                    return  // let the waiting walk have this place
                }
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
