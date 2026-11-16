import Foundation

/// What the iCloud entries ("Download Now", "Remove Download") need to know about one item.
public struct CloudItemFacts: Sendable, Equatable {
    /// An iCloud item at all (an ordinary local file is not).
    public var isUbiquitous: Bool
    /// An online-only placeholder: its bytes are not on disk.
    public var isDataless: Bool
    /// Its bytes are local and the local copy can be evicted (see `Backup.isOffloadable`).
    public var isOffloadable: Bool

    public init(isUbiquitous: Bool, isDataless: Bool, isOffloadable: Bool) {
        self.isUbiquitous = isUbiquitous
        self.isDataless = isDataless
        self.isOffloadable = isOffloadable
    }

    /// Read the facts from disk. Metadata only: never starts a download or an eviction.
    public init(url: URL) {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        let ubiquitous = values?.isUbiquitousItem == true
        var st = stat()
        let flagged =
            lstat(url.path, &st) == 0 && (st.st_flags & UInt32(0x4000_0000)) != 0  // SF_DATALESS
        let status = values?.ubiquitousItemDownloadingStatus
        self.isUbiquitous = ubiquitous
        self.isDataless = flagged || (ubiquitous && status == .notDownloaded)
        self.isOffloadable = ubiquitous && (status == .downloaded || status == .current)
    }
}

/// Which iCloud entries apply to a selection. The one rule behind the context menu, the File menu
/// and the commands' enabled state, so they cannot disagree. A selection offers an entry when at
/// least one item in it can use it, as in Finder.
public struct CloudItemActions: Sendable, Equatable {
    /// "Download Now": some selected item is an iCloud item that is not local.
    public let showsDownloadNow: Bool
    /// "Remove Download": some selected item is an iCloud item that is local and removable.
    public let showsRemoveDownload: Bool

    public init(for items: [CloudItemFacts]) {
        showsDownloadNow = items.contains { $0.isUbiquitous && $0.isDataless }
        showsRemoveDownload = items.contains {
            $0.isUbiquitous && !$0.isDataless && $0.isOffloadable
        }
    }

    /// The actions for URLs on disk.
    public init(urls: [URL]) {
        self.init(for: urls.map { CloudItemFacts(url: $0) })
    }
}
