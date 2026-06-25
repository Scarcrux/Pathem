import Foundation

/// Finds the support files an app leaves around the user Library (caches, preferences,
/// containers, saved state, logs, ...), so uninstalling an .app can also reclaim them
/// (ForkLift's "App Deleter"). Pure: it reads the bundle id and checks which standard
/// locations exist, so it's unit-tested against a temp home.
public enum AppLeftovers {
    public struct Found: Sendable, Equatable {
        public let path: String
        public let size: Int64
        public init(path: String, size: Int64) {
            self.path = path
            self.size = size
        }
    }

    public static func bundleIdentifier(of appURL: URL) -> String? {
        Bundle(url: appURL)?.bundleIdentifier
    }

    /// Existing support files/folders for the app at `appURL`, newest-Library-locations
    /// first by size. `home` is injectable for testing.
    public static func find(forApp appURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [Found]
    {
        let fm = FileManager.default
        let library = home.appendingPathComponent("Library")
        let name = appURL.deletingPathExtension().lastPathComponent
        var candidates: [URL] = []

        if let id = bundleIdentifier(of: appURL), !id.isEmpty {
            candidates += [
                "Application Support/\(id)", "Caches/\(id)", "Preferences/\(id).plist",
                "Containers/\(id)", "Saved Application State/\(id).savedState",
                "Logs/\(id)", "HTTPStorages/\(id)", "WebKit/\(id)",
                "Cookies/\(id).binarycookies",
            ].map { library.appendingPathComponent($0) }

            // Group containers carry a team-id prefix, so match by substring.
            let groups = library.appendingPathComponent("Group Containers")
            if let children = try? fm.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil) {
                candidates += children.filter { $0.lastPathComponent.contains(id) }
            }
        }
        // Some apps store under their display name rather than the bundle id.
        candidates += ["Application Support/\(name)", "Caches/\(name)", "Logs/\(name)"]
            .map { library.appendingPathComponent($0) }

        var seen = Set<String>()
        var found: [Found] = []
        for url in candidates {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), fm.fileExists(atPath: path) else { continue }
            seen.insert(path)
            found.append(Found(path: path, size: size(of: url)))
        }
        return found.sorted { $0.size > $1.size }
    }

    private static func size(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if isDir.boolValue { return DirectorySize.total(of: url).bytes }
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
