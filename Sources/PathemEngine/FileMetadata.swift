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

    /// Set (or clear, when empty) the Finder/Spotlight comment, written in the same binary-plist
    /// form Finder uses (`com.apple.metadata:kMDItemFinderComment`), so Finder and Spotlight both
    /// read it back. Throws on the underlying setxattr/removexattr failure.
    public static func setFinderComment(_ comment: String, on url: URL) throws {
        let name = "com.apple.metadata:kMDItemFinderComment"
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: Int32 = url.withUnsafeFileSystemRepresentation { fsr in
            guard let fsr else { return -1 }
            if trimmed.isEmpty {
                let code = removexattr(fsr, name, XATTR_NOFOLLOW)
                return (code == 0 || errno == ENOATTR) ? 0 : code  // clearing an absent comment is fine
            }
            guard let data = try? PropertyListSerialization.data(fromPropertyList: comment, format: .binary, options: 0)
            else { return -1 }
            return data.withUnsafeBytes { setxattr(fsr, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        }
        if result != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EIO : errno), userInfo: [
                NSLocalizedDescriptionKey: "Couldn’t set the Finder comment on \(url.lastPathComponent)."
            ])
        }
    }

    /// The item's Finder tag names (the colored/labeled tags, `.tagNamesKey`). Reads
    /// via a fresh URL so a value cached on the caller's URL can't mask a recent write.
    public static func tags(of url: URL) -> [String] {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    /// Set (or clear, when empty) the item's Finder tags. Written to the same
    /// `com.apple.metadata:_kMDItemUserTags` xattr (a binary-plist array of names)
    /// that Finder uses, since the `URLResourceValues.tagNames` setter is macOS 26+.
    /// Tags are written as plain names; Finder resolves a known name to its color.
    public static func setTags(_ tags: [String], on url: URL) throws {
        let name = "com.apple.metadata:_kMDItemUserTags"
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let result: Int32 = url.withUnsafeFileSystemRepresentation { fsr in
            guard let fsr else { return -1 }
            if cleaned.isEmpty {
                let code = removexattr(fsr, name, XATTR_NOFOLLOW)
                return (code == 0 || errno == ENOATTR) ? 0 : code  // clearing absent tags is fine
            }
            guard let data = try? PropertyListSerialization.data(fromPropertyList: cleaned, format: .binary, options: 0)
            else { return -1 }
            return data.withUnsafeBytes { setxattr(fsr, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        }
        if result != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EIO : errno), userInfo: [
                NSLocalizedDescriptionKey: "Couldn’t set the tags on \(url.lastPathComponent)."
            ])
        }
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

    /// The item's POSIX ACL entries as readable lines (Finder's "Sharing & Permissions"
    /// list beyond owner/group/other), or nil if it has no extended ACL.
    public static func aclEntries(of url: URL) -> [String]? {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var size: ssize_t = 0
        guard let text = acl_to_text(acl, &size) else { return nil }
        defer { acl_free(text) }
        let lines = String(cString: text)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("!") }  // drop the "!#acl 1" header line
        return lines.isEmpty ? nil : lines
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
