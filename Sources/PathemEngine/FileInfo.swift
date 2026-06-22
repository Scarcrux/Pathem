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
    public var owner: String?
    public var isDataless: Bool  // online-only cloud placeholder

    public init(
        name: String, path: String, kind: String, isDirectory: Bool, isSymbolicLink: Bool,
        size: Int64, created: Date?, modified: Date?, permissions: String, owner: String?,
        isDataless: Bool = false
    ) {
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
        self.isDataless = isDataless
    }

    public static func gather(for url: URL) -> FileInfo? {
        let keys: Set<URLResourceKey> = [
            .nameKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .creationDateKey, .contentModificationDateKey, .localizedTypeDescriptionKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let permissions = (attrs[.posixPermissions] as? NSNumber).map { rwxString($0.uint16Value) } ?? "---------"
        let isDirectory = values.isDirectory ?? false
        // SF_DATALESS (0x40000000) marks an online-only cloud placeholder. Read it
        // from st_flags without materializing the file.
        var st = stat()
        let isDataless = lstat(url.path, &st) == 0 && (st.st_flags & UInt32(0x4000_0000)) != 0
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
            isDataless: isDataless)
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
