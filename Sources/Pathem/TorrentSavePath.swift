import Foundation

/// Resolves where torrent/magnet downloads are saved: the user's configured folder when it's set and
/// still exists, otherwise the system Downloads folder. Shared by the inbound handlers and the
/// Torrents drawer so both honor the preference.
enum TorrentSavePath {
    static func resolve(_ preferred: String) -> String? {
        let trimmed = preferred.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return expanded
            }
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
    }
}
