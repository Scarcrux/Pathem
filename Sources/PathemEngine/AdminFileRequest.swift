import Darwin
import Foundation

/// The privileged file service accepts only this operation vocabulary. It has no process
/// execution endpoint and no operation that writes an arbitrary byte buffer.
public enum AdminFileOperation: String, Codable, Sendable, CaseIterable {
    case copy, move, rename, createDirectory, trash, delete
    case setPermissions, setOwner, setFlags
    case list, attributes
}

/// Validate the request before any filesystem lookup. Pass paths as path strings so the
/// decoder never applies URL dot-segment normalization before validation.
public struct AdminFileRequest: Codable, Sendable {
    public let operation: AdminFileOperation
    public let source: String
    public let destination: String?
    public let mode: UInt16?
    public let owner: UInt32?
    public let group: UInt32?
    public let flags: UInt32?

    public init(
        operation: AdminFileOperation, source: String, destination: String? = nil,
        mode: UInt16? = nil, owner: UInt32? = nil, group: UInt32? = nil, flags: UInt32? = nil
    ) {
        self.operation = operation
        self.source = source
        self.destination = destination
        self.mode = mode
        self.owner = owner
        self.group = group
        self.flags = flags
    }

    public static func decode(_ data: Data) throws -> AdminFileRequest {
        guard data.count <= 16 * 1024 else { throw AdminFileError.invalidRequest }
        let request = try JSONDecoder().decode(Self.self, from: data)
        try request.validate()
        return request
    }

    public func validate() throws {
        _ = try AdminPath.components(
            of: source, allowRoot: operation == .list || operation == .attributes)
        switch operation {
        case .copy, .move, .rename:
            guard let destination, source != destination else {
                throw AdminFileError.invalidRequest
            }
            _ = try AdminPath.components(of: destination, allowRoot: false)
        default:
            guard destination == nil else { throw AdminFileError.invalidRequest }
        }
        switch operation {
        case .setPermissions:
            guard let mode, mode <= 0o777, owner == nil, group == nil, flags == nil else {
                throw AdminFileError.invalidRequest
            }
        case .setOwner:
            guard owner != nil || group != nil, owner != .max, group != .max,
                mode == nil, flags == nil
            else { throw AdminFileError.invalidRequest }
        case .setFlags:
            guard let flags, flags & ~UInt32(UF_IMMUTABLE | UF_HIDDEN) == 0,
                mode == nil, owner == nil, group == nil
            else { throw AdminFileError.invalidRequest }
        default:
            guard mode == nil, owner == nil, group == nil, flags == nil else {
                throw AdminFileError.invalidRequest
            }
        }
    }
}

public enum AdminFileError: Error, Sendable, Equatable {
    case invalidRequest
    case symlink
}

/// Walk the requested path using directory descriptors. The caller performs the operation
/// against the returned parent descriptor instead of reopening the original absolute path.
enum AdminPath {
    static func components(of path: String, allowRoot: Bool) throws -> [String] {
        guard path.first == "/", path.utf8.count < Int(PATH_MAX), !path.utf8.contains(0) else {
            throw AdminFileError.invalidRequest
        }
        if path == "/", allowRoot { return [] }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
            components.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= Int(NAME_MAX)
            })
        else { throw AdminFileError.invalidRequest }
        return components.map(String.init)
    }

    static func withParent<T>(of path: String, _ operation: (Int32, String) throws -> T) throws -> T
    {
        let names = try components(of: path, allowRoot: false)
        guard let leaf = names.last else { throw AdminFileError.invalidRequest }
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        var fd = open("/", flags)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        for name in names.dropLast() {
            let next = openat(fd, name, flags)
            guard next >= 0 else { throw posixError() }
            close(fd)
            fd = next
        }
        return try operation(fd, leaf)
    }

    static func attributes(parent: Int32, name: String) throws -> stat {
        var result = stat()
        guard fstatat(parent, name, &result, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
        guard result.st_mode & S_IFMT != S_IFLNK else { throw AdminFileError.symlink }
        return result
    }

    static func withFile<T>(of path: String, _ operation: (Int32) throws -> T) throws -> T {
        try withParent(of: path) { parent, name in
            let original = try attributes(parent: parent, name: name)
            guard original.st_mode & S_IFMT == S_IFREG || original.st_mode & S_IFMT == S_IFDIR
            else { throw POSIXError(.ENOTSUP) }
            let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw posixError() }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0 else { throw posixError() }
            guard original.st_dev == opened.st_dev, original.st_ino == opened.st_ino else {
                throw POSIXError(.ESTALE)
            }
            return try operation(fd)
        }
    }

    static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
