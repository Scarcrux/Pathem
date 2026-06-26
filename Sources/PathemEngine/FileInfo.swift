import Foundation

/// A snapshot of a file's metadata for the Get Info inspector. Pure Foundation
/// so it is unit-testable against real temp files.
public struct FileInfo: Sendable, Equatable {
    public var name: String
    public var path: String
    public var kind: String
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var size: Int64
    public var created: Date?
    public var modified: Date?
    public var permissions: String  // e.g. "rwxr-xr-x"
    public var posixMode: UInt16?  // raw mode bits (& 0o7777) for the chmod editor
    public var owner: String?
    public var group: String?
    public var accessed: Date?  // last opened
    public var added: Date?  // date added to its folder
    public var allocatedSize: Int64  // bytes used on disk
    public var tags: [String]  // native Finder tags
    public var contentType: String?  // UTI identifier, e.g. "public.png"
    public var itemCount: Int?  // number of children, for a single folder
    public var isLocked: Bool  // Finder "Locked" (user immutable flag)
    public var isDataless: Bool  // online-only cloud placeholder

    public init(
        name: String, path: String, kind: String, isDirectory: Bool, isSymbolicLink: Bool,
        size: Int64, created: Date?, modified: Date?, permissions: String, owner: String?,
        group: String? = nil, accessed: Date? = nil, added: Date? = nil, allocatedSize: Int64 = 0,
        tags: [String] = [], contentType: String? = nil, itemCount: Int? = nil, isLocked: Bool = false,
        posixMode: UInt16? = nil, isDataless: Bool = false
    ) {
        self.posixMode = posixMode
        self.name = name
        self.path = path
        self.kind = kind
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.created = created
        self.modified = modified
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.accessed = accessed
        self.added = added
        self.allocatedSize = allocatedSize
        self.tags = tags
        self.contentType = contentType
        self.itemCount = itemCount
        self.isLocked = isLocked
        self.isDataless = isDataless
    }

    public static func gather(for url: URL) -> FileInfo? {
        let keys: Set<URLResourceKey> = [
            .nameKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey,
            .contentModificationDateKey, .contentAccessDateKey, .addedToDirectoryDateKey,
            .totalFileAllocatedSizeKey, .localizedTypeDescriptionKey, .typeIdentifierKey,
            .tagNamesKey, .isUserImmutableKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let modeNumber = attrs[.posixPermissions] as? NSNumber
        let permissions = modeNumber.map { rwxString($0.uint16Value) } ?? "---------"
        let isDirectory = values.isDirectory ?? false
        // SF_DATALESS (0x40000000) marks an online-only cloud placeholder. Read it
        // from st_flags without materializing the file.
        var st = stat()
        let isDataless = lstat(url.path, &st) == 0 && (st.st_flags & UInt32(0x4000_0000)) != 0
        var itemCount: Int?
        if isDirectory, !isDataless {
            itemCount = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count
        }
        return FileInfo(
            name: values.name ?? url.lastPathComponent,
            path: url.path,
            kind: values.localizedTypeDescription ?? (isDirectory ? "Folder" : "Document"),
            isDirectory: isDirectory,
            isSymbolicLink: values.isSymbolicLink ?? false,
            size: Int64(values.fileSize ?? 0),
            created: values.creationDate,
            modified: values.contentModificationDate,
            permissions: permissions,
            owner: attrs[.ownerAccountName] as? String,
            group: attrs[.groupOwnerAccountName] as? String,
            accessed: values.contentAccessDate,
            added: values.addedToDirectoryDate,
            allocatedSize: Int64(values.totalFileAllocatedSize ?? 0),
            tags: values.tagNames ?? [],
            contentType: values.typeIdentifier,
            itemCount: itemCount,
            isLocked: values.isUserImmutable ?? false,
            posixMode: modeNumber.map { $0.uint16Value & 0o7777 },
            isDataless: isDataless)
    }

    /// Apply POSIX mode bits to a file (chmod). `mode` is the full octal (lower 12 bits).
    public static func setPosixMode(_ mode: UInt16, on url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode & 0o7777)], ofItemAtPath: url.path)
    }

    /// Set Finder's "Locked" (the user-immutable flag).
    public static func setLocked(_ locked: Bool, on url: URL) throws {
        var values = URLResourceValues()
        values.isUserImmutable = locked
        var url = url
        try url.setResourceValues(values)
    }

    /// POSIX mode bits (lower 9) as a 9-char "rwxr-xr-x" string.
    public static func rwxString(_ mode: UInt16) -> String {
        let m = Int(mode)
        var out = ""
        for shift in [6, 3, 0] {  // owner, group, other
            let bits = (m >> shift) & 0x7
            out += (bits & 0x4) != 0 ? "r" : "-"
            out += (bits & 0x2) != 0 ? "w" : "-"
            out += (bits & 0x1) != 0 ? "x" : "-"
        }
        return out
    }
}
