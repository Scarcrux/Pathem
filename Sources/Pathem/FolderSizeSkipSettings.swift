import Foundation
import PathemEngine

/// The app-wide choice of which folders the automatic folder-size walk leaves alone, set from
/// Preferences. Lists re-read it when `changed` is posted.
@MainActor
enum FolderSizeSkipSettings {
    static let changed = Notification.Name("PathemFolderSizeSkipSettingsChanged")
    private(set) static var enabled = true
    private(set) static var userRules: [String] = []

    static func apply(_ prefs: Preferences) {
        let rules = FolderSizeSkip.rules(from: prefs.folderSizeExclusions)
        guard prefs.skipCacheFolderSizes != enabled || rules != userRules else { return }
        enabled = prefs.skipCacheFolderSizes
        userRules = rules
        NotificationCenter.default.post(name: changed, object: nil)
    }

    #if DEBUG
    static func debugSet(enabled: Bool) {
        self.enabled = enabled
        NotificationCenter.default.post(name: changed, object: nil)
    }
    #endif

    /// Why `path` is not sized automatically, or nil. The user's own rules apply even when
    /// the cache and temporary skip is switched off.
    static func reason(for path: String) -> FolderSizeSkip.Reason? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let reason = FolderSizeSkip.reason(for: path, home: home, userRules: userRules)
        return enabled || reason == .excluded ? reason : nil
    }

    static func explanation(_ reason: FolderSizeSkip.Reason) -> String {
        let why: String
        switch reason {
        case .cache: why = L("sizes.skip.cache", "Cache folder")
        case .temporary: why = L("sizes.skip.temporary", "Temporary folder")
        case .regenerable: why = L("sizes.skip.regenerable", "Build or dependency folder")
        case .excluded: why = L("sizes.skip.excluded", "On your skip list in Settings")
        }
        return why + ". "
            + L(
                "sizes.skip.how",
                "Not sized automatically. Right-click and choose Calculate Size to measure it.")
    }
}
