import Foundation

/// Read, inspect, and remove a file's extended attributes (xattrs), and the common
/// superuser case of stripping `com.apple.quarantine` so a downloaded app or script opens
/// without Gatekeeper nagging. Pure Foundation over the POSIX xattr syscalls, unit-tested.
public enum ExtendedAttributes {
    public static let quarantineName = "com.apple.quarantine"

    public struct Attribute: Sendable, Equatable {
        public let name: String
        public let size: Int
        /// A trimmed UTF-8 preview when the value is printable text, else nil (binary).
        public let preview: String?
    }

    /// The names of every xattr on `url` (does not follow symlinks).
    public static func names(of url: URL) -> [String] {
        let path = url.path
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let read = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
        guard read > 0 else { return [] }
        let data = buffer.withUnsafeBytes { Data($0.prefix(read)) }
        return data.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
    }

    /// The raw value of one xattr, or nil if it is missing.
    public static func value(_ name: String, of url: URL) -> Data? {
        let path = url.path
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        if size == 0 { return Data() }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, name, &buffer, size, 0, XATTR_NOFOLLOW)
        guard read >= 0 else { return nil }
        return Data(buffer.prefix(read))
    }

    /// Every xattr with its size and a text preview (nil for binary values).
    public static func list(_ url: URL) -> [Attribute] {
        names(of: url).map { name in
            let data = value(name, of: url) ?? Data()
            return Attribute(name: name, size: data.count, preview: printablePreview(data))
        }
    }

    /// Remove one xattr. Throws with the POSIX reason on failure.
    public static func remove(_ name: String, from url: URL) throws {
        if removexattr(url.path, name, XATTR_NOFOLLOW) != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
    }

    public static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, quarantineName, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Strip `com.apple.quarantine` from the item and, for a folder or app bundle,
    /// everything inside it. Returns how many items had the attribute removed.
    @discardableResult
    public static func removeQuarantine(from url: URL) -> Int {
        var removed = 0
        func strip(_ target: URL) {
            if removexattr(target.path, quarantineName, XATTR_NOFOLLOW) == 0 { removed += 1 }
        }
        strip(url)
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let child as URL in enumerator { strip(child) }
        }
        return removed
    }

    private static func printablePreview(_ data: Data) -> String? {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }
        // Reject values with control characters (a binary blob that happens to decode).
        guard text.unicodeScalars.allSatisfy({ $0 == "\n" || $0 == "\t" || $0.value >= 0x20 }) else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
