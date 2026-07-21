import Foundation
import PathemEngine

/// Process-wide, thread-safe, debounced-saving wrapper around `FolderSizeCache`. Every pane shares
/// it, so a folder size computed once (in any pane) is reused everywhere and survives a restart --
/// "calculate all sizes" then only re-walks folders whose contents actually changed.
final class FolderSizeStore: @unchecked Sendable {
    static let shared = FolderSizeStore()

    private let lock = NSLock()
    private var cache: FolderSizeCache
    private let fileURL: URL?
    private let saveQueue = DispatchQueue(label: "com.scarcrux.pathem.foldersizes", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    static var defaultFileURL: URL? { ConfigStore.url("folder-sizes.json") }

    /// `fileURL == nil` makes an in-memory-only store (tests), so it never touches the real cache file.
    init(cache: FolderSizeCache? = nil, fileURL: URL? = FolderSizeStore.defaultFileURL) {
        self.fileURL = fileURL
        self.cache =
            cache ?? fileURL.flatMap { ConfigStore.load(FolderSizeCache.self, from: $0) }
            ?? FolderSizeCache()
    }

    /// The cache key mtime for a directory: whole epoch seconds of its content-modification date.
    static func mtimeKey(of url: URL) -> Int64 {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return FolderSizeCache.mtimeKey(date)
    }

    /// A still-valid cached size for `path` (nil on a miss or if the folder's mtime changed).
    func measurement(forPath path: String, mtime: Int64) -> DirectorySize.Measurement? {
        lock.lock()
        defer { lock.unlock() }
        return cache.measurement(forPath: path, currentMtime: mtime)
    }

    /// Record a freshly measured folder size and schedule a debounced save.
    func record(path: String, measurement: DirectorySize.Measurement, mtime: Int64) {
        lock.lock()
        cache.record(path: path, measurement: measurement, mtime: mtime)
        lock.unlock()
        scheduleSave()
    }

    /// Coalesce a burst of records (a folder full of subfolders finishing at once) into one write.
    private func scheduleSave() {
        guard fileURL != nil else { return }
        lock.lock()
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        pendingSave = work
        lock.unlock()
        saveQueue.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func persist() {
        lock.lock()
        let snapshot = cache
        lock.unlock()
        ConfigStore.save(snapshot, to: fileURL)
    }

    /// Persist immediately (on quit).
    func flush() {
        lock.lock()
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = cache
        lock.unlock()
        ConfigStore.save(snapshot, to: fileURL)
    }
}
