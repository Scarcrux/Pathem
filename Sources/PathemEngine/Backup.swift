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
    ///
    /// The provider refuses an item the user keeps downloaded (iCloud Drive with "Optimize Mac
    /// Storage" off, or a pinned item). Foundation reports that as "The file couldn't be saved",
    /// which says nothing, so that case gets `nonEvictableReason` instead.
    public static func offload(
        _ urls: [URL], nonEvictableReason: String = Backup.nonEvictableReason
    ) -> Result {
        var result = Result()
        for url in urls {
            do {
                try FileManager.default.evictUbiquitousItem(at: url)
                result.succeeded.append(url.lastPathComponent)
            } catch {
                result.failures.append(
                    .init(
                        name: url.lastPathComponent,
                        reason: isNonEvictable(error)
                            ? nonEvictableReason : error.localizedDescription))
            }
        }
        return result
    }

    public static let nonEvictableReason =
        "This item is set to stay downloaded. Turn on Optimize Mac Storage in iCloud settings, or turn off Keep Downloaded for it."

    /// Whether an eviction error is the provider's "non-evictable" refusal
    /// (`NSFileProviderErrorNonEvictable`, -2008), directly or as the underlying error.
    public static func isNonEvictable(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let e = current {
            if e.domain == "NSFileProviderErrorDomain", e.code == -2008 { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
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
