import Foundation

/// A cloud-storage service a folder belongs to, used to badge cloud folders so a
/// "Documents" in iCloud reads differently from a "Documents" in Google Drive.
/// Foundation-only: the symbol name and tint are plain strings the app turns into
/// an NSImage / NSColor.
public enum CloudService: String, Sendable, CaseIterable, Equatable {
    case iCloud, dropbox, googleDrive, oneDrive, box, generic

    public var displayName: String {
        switch self {
        case .iCloud: return "iCloud Drive"
        case .dropbox: return "Dropbox"
        case .googleDrive: return "Google Drive"
        case .oneDrive: return "OneDrive"
        case .box: return "Box"
        case .generic: return "Cloud"
        }
    }

    /// An SF Symbol for the corner badge. iCloud uses Apple's own glyph; the rest use a
    /// generic cloud (SF Symbols has no third-party brand logos, and bundling them raises
    /// trademark questions), distinguished by tint.
    public var symbolName: String {
        self == .iCloud ? "icloud.fill" : "cloud.fill"
    }

    /// A brand-ish tint for the badge, as a hex string (the app resolves it to a color).
    public var tintHex: String {
        switch self {
        case .iCloud: return "#3B9CFF"  // iCloud blue
        case .dropbox: return "#0061FF"  // Dropbox blue
        case .googleDrive: return "#1DA462"  // Drive green
        case .oneDrive: return "#0364B8"  // OneDrive blue
        case .box: return "#0075C9"  // Box blue
        case .generic: return "#8E8E93"  // neutral gray
        }
    }
}

/// Recognizes the cloud-storage folders macOS exposes and which service they belong to.
/// Pure and testable: the caller passes the home directory so it doesn't read the
/// environment.
public enum CloudLocation {
    /// The service for a folder at `path`, but only when it's a service root or one of its
    /// top-level folders (the badge-worthy case: the folders you'd see side by side and
    /// need to tell apart). Deeper folders return nil, so a folder deep inside Dropbox
    /// isn't badged on every row. Returns nil for non-cloud paths.
    public static func service(forFolderAt path: String, home: String) -> CloudService? {
        let p = normalize(path)
        let h = normalize(home)
        guard !p.isEmpty, !h.isEmpty else { return nil }

        // iCloud Drive: the container and its top-level folders (Documents, Desktop, apps).
        let iCloudRoot = h + "/Library/Mobile Documents/com~apple~CloudDocs"
        if p == iCloudRoot || parent(of: p) == iCloudRoot { return .iCloud }

        // Third-party providers under ~/Library/CloudStorage/<Provider...>.
        let container = h + "/Library/CloudStorage"
        if p == container { return nil }  // the container itself is not a service
        if let rel = relativePath(of: p, under: container) {
            let comps = rel.split(separator: "/").map(String.init)
            // comps[0] is the provider directory; badge it and its direct children only.
            if comps.count >= 1, comps.count <= 2 { return provider(fromDirectory: comps[0]) }
            return nil
        }

        // Legacy sync-folder roots in the home directory, and their top-level folders.
        for (name, service): (String, CloudService) in [("Dropbox", .dropbox), ("Google Drive", .googleDrive)] {
            let root = h + "/" + name
            if p == root || parent(of: p) == root { return service }
        }
        return nil
    }

    /// Map a `~/Library/CloudStorage` provider directory name to a service. The names look
    /// like "Dropbox", "GoogleDrive-you@gmail.com", "OneDrive-Personal", "Box-Box".
    static func provider(fromDirectory name: String) -> CloudService {
        let lower = name.lowercased()
        if lower.hasPrefix("icloud") { return .iCloud }  // e.g. "iCloudDrive-iCloudDrive (...)"
        if lower.hasPrefix("dropbox") { return .dropbox }
        if lower.hasPrefix("googledrive") { return .googleDrive }
        if lower.hasPrefix("onedrive") { return .oneDrive }
        if lower.hasPrefix("box") { return .box }
        return .generic
    }

    // MARK: Path helpers (no FileManager: pure string work on absolute POSIX paths)

    private static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// The remaining path when `path` is `base` or under it, else nil. "" when equal.
    private static func relativePath(of path: String, under base: String) -> String? {
        if path == base { return "" }
        if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        return nil
    }
}
