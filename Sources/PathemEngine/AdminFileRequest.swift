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
public struct AdminFileRequest: Codable, Sendable, Equatable {
    public let operation: AdminFileOperation
    public let source: String
    public let destination: String?
    public let mode: UInt16?
    public let owner: UInt32?
    public let group: UInt32?
    public let flags: UInt32?
    public let flagMask: UInt32?

    public init(
        operation: AdminFileOperation, source: String, destination: String? = nil,
        mode: UInt16? = nil, owner: UInt32? = nil, group: UInt32? = nil, flags: UInt32? = nil,
        flagMask: UInt32? = nil
    ) {
        self.operation = operation
        self.source = source
        self.destination = destination
        self.mode = mode
        self.owner = owner
        self.group = group
        self.flags = flags
        self.flagMask = flagMask
    }

    public static func decode(_ data: Data) throws -> AdminFileRequest {
        guard data.count <= 16 * 1024 else { throw AdminFileError.invalidRequest }
        let request = try JSONDecoder().decode(Self.self, from: data)
        try request.validate()
        return request
    }

    public static func isPermissionFailure(_ error: Error) -> Bool {
        if let enumeration = error as? BulkEnumerator.EnumerationError {
            switch enumeration {
            case .openFailed(_, let code), .syscallFailed(let code):
                return code == EACCES || code == EPERM
            }
        }
        var candidate: NSError? = error as NSError
        for _ in 0..<8 {
            guard let current = candidate else { return false }
            if current.domain == NSPOSIXErrorDomain {
                return current.code == Int(EACCES) || current.code == Int(EPERM)
            }
            candidate = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
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
            guard !destination.lowercased().hasPrefix(source.lowercased() + "/")
            else { throw AdminFileError.invalidRequest }
        default:
            guard destination == nil else { throw AdminFileError.invalidRequest }
        }
        guard operation == .setFlags || flagMask == nil else { throw AdminFileError.invalidRequest }
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
            let managed = UInt32(UF_IMMUTABLE | UF_HIDDEN)
            let mask = flagMask ?? managed
            guard let flags, mask != 0, mask & ~managed == 0, flags & ~mask == 0,
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
            try withChild(in: parent, name: name, operation)
        }
    }

    static func withChild<T>(
        in parent: Int32, name: String, _ operation: (Int32) throws -> T
    ) throws -> T {
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

    static func withDirectory<T>(of path: String, _ operation: (Int32) throws -> T) throws -> T {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        if path == "/" {
            let fd = open("/", flags)
            guard fd >= 0 else { throw posixError() }
            defer { close(fd) }
            return try operation(fd)
        }
        return try withParent(of: path) { parent, name in
            let fd = openat(parent, name, flags)
            guard fd >= 0 else { throw posixError() }
            defer { close(fd) }
            return try operation(fd)
        }
    }

    static func forEachChild(in fd: Int32, visit: (String) throws -> Void) throws {
        let streamFD = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard streamFD >= 0 else { throw posixError() }
        guard let stream = fdopendir(streamFD) else {
            let error = posixError()
            close(streamFD)
            throw error
        }
        defer { closedir(stream) }
        for _ in 0..<50_000 {
            errno = 0
            guard let item = readdir(stream) else {
                guard errno == 0 else { throw posixError() }
                return
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name, name != ".", name != ".." else { continue }
            try visit(name)
        }
        throw POSIXError(.EOVERFLOW)
    }

    static func rejectDescendant(of original: stat, from parent: Int32) throws {
        var current = fcntl(parent, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else { throw posixError() }
        defer { close(current) }
        var details = stat()
        guard fstat(current, &details) == 0 else { throw posixError() }
        for _ in 0..<128 {
            guard details.st_dev != original.st_dev || details.st_ino != original.st_ino
            else { throw AdminFileError.invalidRequest }
            let up = openat(current, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard up >= 0 else { throw posixError() }
            let previous = details
            close(current)
            current = up
            guard fstat(current, &details) == 0 else { throw posixError() }
            if details.st_dev == previous.st_dev, details.st_ino == previous.st_ino { return }
        }
        throw POSIXError(.ELOOP)
    }

    static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
