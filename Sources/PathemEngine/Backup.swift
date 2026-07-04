import Foundation

/// Reclaim local space without losing data: offload iCloud files (evict the local copy so
/// only the cloud copy remains, and the file becomes an online-only placeholder), and back
/// a selection up to a chosen destination. Distinct from Secure Delete, both are
/// non-destructive. Pure Foundation, unit-tested where the API allows.
public enum Backup {
    public struct Result: Sendable, Equatable {
        public var succeeded: [String] = []
        public var failures: [FileOperations.Failure] = []
        public init() {}
    }

    /// Whether the item is an iCloud file whose bytes are currently local, so evicting them
    /// would actually free space (an already offline-only item can't be offloaded again).
    public static func isOffloadable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        guard values?.isUbiquitousItem == true else { return false }
        switch values?.ubiquitousItemDownloadingStatus {
        case .downloaded, .current: return true  // present locally, can be evicted
        default: return false  // not downloaded (already offloaded) or unknown
        }
    }

    /// Evict the local copy of each iCloud item. The file stays in iCloud and becomes an
    /// online-only placeholder; opening it later re-downloads it.
    public static func offload(_ urls: [URL]) -> Result {
        var result = Result()
        for url in urls {
            do {
                try FileManager.default.evictUbiquitousItem(at: url)
                result.succeeded.append(url.lastPathComponent)
            } catch {
                result.failures.append(.init(name: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        return result
    }

    /// Copy each item into `destination`, keeping both (a backup copy, never a move).
    public static func backup(_ urls: [URL], to destination: URL) -> Result {
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let outcome = FileOperations.copy(urls: urls, into: destination, onConflict: .keepBoth)
        var result = Result()
        result.succeeded = outcome.performed.map { $0.destination.lastPathComponent }
        result.failures = outcome.failures
        return result
    }
}
