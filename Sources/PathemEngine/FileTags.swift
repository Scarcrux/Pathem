import Foundation

/// A Finder-compatible file tag: a name and an optional color. Tags live in the
/// `com.apple.metadata:_kMDItemUserTags` extended attribute as a binary plist
/// array of "Name\nColorIndex" strings (a plain "Name" means no color), so tags
/// set in Pathem show up in Finder and vice versa.
public struct FileTag: Sendable, Equatable, Hashable {
    /// Finder's seven standard label colors (index 0 means "no color").
    public enum Color: Int, Codable, Sendable, CaseIterable {
        case none = 0, gray = 1, green = 2, purple = 3, blue = 4, yellow = 5, red = 6, orange = 7

        public var label: String {
            switch self {
            case .none: "None"
            case .gray: "Gray"
            case .green: "Green"
            case .purple: "Purple"
            case .blue: "Blue"
            case .yellow: "Yellow"
            case .red: "Red"
            case .orange: "Orange"
            }
        }

        /// The order Finder presents the colors in.
        public static let displayOrder: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]

        /// A stable string identifier for persistence (unlike `label`, which is localized).
        public var nameKey: String {
            switch self {
            case .none: "none"
            case .gray: "gray"
            case .green: "green"
            case .purple: "purple"
            case .blue: "blue"
            case .yellow: "yellow"
            case .red: "red"
            case .orange: "orange"
            }
        }
        public init?(nameKey: String) {
            guard let match = Self.allCases.first(where: { $0.nameKey == nameKey }) else { return nil }
            self = match
        }
    }

    public var name: String
    public var color: Color

    public init(name: String, color: Color = .none) {
        self.name = name
        self.color = color
    }

    /// A tag that is just a color uses the color's name (matches Finder).
    public init(color: Color) {
        self.name = color.label
        self.color = color
    }
}

public enum FileTags {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"

    /// Read the file's tags (empty if none or unreadable). Tags attach to a
    /// symlink itself (XATTR_NOFOLLOW), matching Finder.
    public static func tags(of url: URL) -> [FileTag] {
        url.withUnsafeFileSystemRepresentation { fsr -> [FileTag] in
            guard let fsr else { return [] }
            // Bounded retry: a pathological writer that keeps growing the attribute
            // between probe and read can't pin this background worker forever.
            for _ in 0..<4 {
                let size = getxattr(fsr, attribute, nil, 0, 0, XATTR_NOFOLLOW)
                guard size > 0 else { return [] }  // ENOATTR / empty -> no tags
                var buffer = [UInt8](repeating: 0, count: size)
                let read = getxattr(fsr, attribute, &buffer, size, 0, XATTR_NOFOLLOW)
                if read < 0 {
                    if errno == ERANGE { continue }  // attribute grew between probe and read; retry
                    return []
                }
                let data = Data(buffer.prefix(read))
                guard
                    let list = (try? PropertyListSerialization.propertyList(
                        from: data, options: [], format: nil)) as? [String]
                else { return [] }
                return list.map(parse)
            }
            return []
        }
    }

    /// Replace the file's tags (an empty array removes the attribute).
    public static func setTags(_ tags: [FileTag], on url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { fsr in
            guard let fsr else { return }
            if tags.isEmpty {
                let result = removexattr(fsr, attribute, XATTR_NOFOLLOW)
                // ENOATTR just means there was nothing to remove.
                if result != 0, errno != ENOATTR {
                    throw tagError("removexattr")
                }
                return
            }
            let strings = tags.map(format)
            let data = try PropertyListSerialization.data(
                fromPropertyList: strings, format: .binary, options: 0)
            let result = data.withUnsafeBytes {
                setxattr(fsr, attribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW)
            }
            if result != 0 { throw tagError("setxattr") }
        }
    }

    /// Add a named tag if absent, or remove it (by name, case-insensitive) if present.
    /// Used to apply/remove named labels, which are just colored tags.
    @discardableResult
    public static func toggle(_ tag: FileTag, on url: URL) throws -> Bool {
        var tags = tags(of: url)
        if let index = tags.firstIndex(where: { $0.name.caseInsensitiveCompare(tag.name) == .orderedSame }) {
            tags.remove(at: index)
            try setTags(tags, on: url)
            return false
        }
        tags.append(tag)
        try setTags(tags, on: url)
        return true
    }

    /// Add a color tag if absent, or remove it if already present.
    @discardableResult
    public static func toggleColor(_ color: FileTag.Color, on url: URL) throws -> Bool {
        var tags = tags(of: url)
        let added: Bool
        if let index = tags.firstIndex(where: { $0.color == color }) {
            tags.remove(at: index)
            added = false
        } else {
            tags.append(FileTag(color: color))
            added = true
        }
        try setTags(tags, on: url)
        return added
    }

    // MARK: Helpers

    static func parse(_ raw: String) -> FileTag {
        let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts.first ?? "")
        let color = parts.count > 1 ? (Int(parts[1]).flatMap(FileTag.Color.init(rawValue:)) ?? .none) : .none
        return FileTag(name: name, color: color)
    }

    static func format(_ tag: FileTag) -> String {
        tag.color == .none ? tag.name : "\(tag.name)\n\(tag.color.rawValue)"
    }

    private static func tagError(_ call: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(call) failed: \(String(cString: strerror(errno)))"])
    }
}
