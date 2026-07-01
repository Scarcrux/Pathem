import Foundation

/// Extra Get Info metadata read on demand (heavier or less common than the core
/// `FileInfo` fields): download source, Finder comment, hidden-extension flag,
/// bundle version/copyright, and the POSIX ACL. Foundation-only, so it stays in
/// the engine and is unit-testable.
public enum FileMetadata {
    /// The "where from" URLs Safari/others stamp on downloads
    /// (`com.apple.metadata:kMDItemWhereFroms`, a binary-plist array of strings).
    public static func whereFroms(of url: URL) -> [String] {
        guard let data = xattr("com.apple.metadata:kMDItemWhereFroms", of: url),
            let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return list.filter { !$0.isEmpty }
    }

    /// The Finder/Spotlight comment (`com.apple.metadata:kMDItemFinderComment`).
    public static func finderComment(of url: URL) -> String? {
        guard let data = xattr("com.apple.metadata:kMDItemFinderComment", of: url),
            let comment = try? PropertyListSerialization.propertyList(from: data, format: nil) as? String,
            !comment.isEmpty
        else { return nil }
        return comment
    }

    /// Whether Finder hides this item's extension.
    public static func hidesExtension(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.hasHiddenExtensionKey]))?.hasHiddenExtension ?? false
    }

    public static func setHidesExtension(_ hide: Bool, on url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.hasHiddenExtension = hide
        try url.setResourceValues(values)
    }

    /// For an `.app` bundle: its marketing version and human-readable copyright.
    public static func appInfo(of url: URL) -> (version: String?, copyright: String?)? {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url) else { return nil }
        let info = bundle.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let copyright = info?["NSHumanReadableCopyright"] as? String
        guard version != nil || copyright != nil else { return nil }
        return (version, copyright)
    }

    // MARK: xattr

    private static func xattr(_ name: String, of url: URL) -> Data? {
        let path = url.path
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, 0) }
        guard read == length else { return nil }
        return data
    }
}
