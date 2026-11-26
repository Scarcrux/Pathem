import Darwin
import Foundation

/// The service accepts bounded, validated data. NSXPC does not decode custom object graphs
/// supplied by the peer. A listener must authenticate the code identity before exporting it.
@objc public protocol AdminFileServiceProtocol {
    func version(reply: @escaping (Int) -> Void)
    func authorize(_ externalForm: Data, duration: Int, reply: @escaping (Bool) -> Void)
    func lockSession(reply: @escaping () -> Void)
    func perform(_ encodedRequest: Data, reply: @escaping (Data?, NSError?) -> Void)
}

public struct AdminFileAttributes: Codable, Sendable {
    public let mode: UInt16
    public let owner: UInt32
    public let group: UInt32
    public let size: Int64
    public let modified: Date
    public let flags: UInt32

    init(_ info: stat) {
        mode = info.st_mode
        owner = info.st_uid
        group = info.st_gid
        size = info.st_size
        flags = info.st_flags
        modified = Date(
            timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}

public struct AdminDirectoryEntry: Codable, Sendable {
    public let name: String
    public let attributes: AdminFileAttributes
}

public struct AdminTrashRoot: Sendable {
    let path: String
    let owner: UInt32

    init(path: String, owner: UInt32) {
        self.path = path
        self.owner = owner
    }

    public static func homeTrash(for owner: UInt32) -> AdminTrashRoot? {
        var user = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let home: String? = buffer.withUnsafeMutableBufferPointer {
            guard getpwuid_r(owner, &user, $0.baseAddress, $0.count, &result) == 0,
                result != nil, let path = user.pw_dir
            else { return nil }
            return String(validatingCString: path)
        }
        guard let home, home.hasPrefix("/"), home != "/" else { return nil }
        return AdminTrashRoot(
            path: (home as NSString).appendingPathComponent(".Trash"), owner: owner)
    }
}

/// Create one instance per verified XPC connection. The service has no global unlock state.
public final class AdminFileService: NSObject, AdminFileServiceProtocol {
    private let verifyAuthorization: @Sendable (Data) -> Bool
    private let lifetime: Duration
    private let trashRoot: AdminTrashRoot?
    private let session = NSLock()
    private var expires: ContinuousClock.Instant?

    public init(
        lifetime: Duration = .seconds(900),
        trashRoot: AdminTrashRoot? = nil,
        verifyAuthorization: @escaping @Sendable (Data) -> Bool
    ) {
        self.verifyAuthorization = verifyAuthorization
        self.trashRoot = trashRoot
        self.lifetime = min(max(.zero, lifetime), .seconds(900))
    }

    public func version(reply: @escaping (Int) -> Void) {
        reply(1)
    }

    public func authorize(_ externalForm: Data, duration: Int, reply: @escaping (Bool) -> Void) {
        let granted = session.withLock {
            expires = nil
            guard (60...900).contains(duration), externalForm.count == 32,
                verifyAuthorization(externalForm)
            else {
                return false
            }
            expires = .now.advanced(by: min(.seconds(duration), lifetime))
            return true
        }
        reply(granted)
    }

    public func lockSession(reply: @escaping () -> Void) {
        session.withLock { expires = nil }
        reply()
    }

    public func perform(_ encodedRequest: Data, reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let result = try session.withLock {
                guard let expires, expires > .now else { throw POSIXError(.EACCES) }
                let request = try AdminFileRequest.decode(encodedRequest)
                return try performValidated(request)
            }
            reply(result, nil)
        } catch {
            reply(nil, error as NSError)
        }
    }

    private func performValidated(_ request: AdminFileRequest) throws -> Data {
        switch request.operation {
        case .attributes:
            let information: stat
            if request.source == "/" {
                var info = stat()
                guard Darwin.lstat("/", &info) == 0 else { throw AdminPath.posixError() }
                information = info
            } else {
                information = try AdminPath.withParent(of: request.source) { fd, name in
                    try AdminPath.attributes(parent: fd, name: name)
                }
            }
            return try JSONEncoder().encode(AdminFileAttributes(information))
        case .createDirectory:
            return try AdminPath.withParent(of: request.source) { fd, name in
                guard mkdirat(fd, name, 0o755) == 0 else { throw AdminPath.posixError() }
                return Data()
            }
        case .move, .rename:
            guard let destination = request.destination else { throw AdminFileError.invalidRequest }
            if request.operation == .rename,
                (request.source as NSString).deletingLastPathComponent
                    != (destination as NSString).deletingLastPathComponent
            {
                throw AdminFileError.invalidRequest
            }
            return try AdminPath.withParent(of: request.source) { from, source in
                _ = try AdminPath.attributes(parent: from, name: source)
                return try AdminPath.withParent(of: destination) { to, target in
                    guard renameatx_np(from, source, to, target, UInt32(RENAME_EXCL)) == 0 else {
                        throw AdminPath.posixError()
                    }
                    return Data()
                }
            }
        case .setPermissions, .setOwner, .setFlags:
            return try AdminPath.withFile(of: request.source) { fd in
                let result: Int32
                switch request.operation {
                case .setPermissions:
                    guard let mode = request.mode else { throw AdminFileError.invalidRequest }
                    result = fchmod(fd, mode)
                case .setOwner:
                    result = fchown(fd, request.owner ?? .max, request.group ?? .max)
                case .setFlags:
                    guard let flags = request.flags else { throw AdminFileError.invalidRequest }
                    var info = stat()
                    guard fstat(fd, &info) == 0 else { throw AdminPath.posixError() }
                    let mask = request.flagMask ?? UInt32(UF_IMMUTABLE | UF_HIDDEN)
                    result = fchflags(fd, (info.st_flags & ~mask) | flags)
                default: throw AdminFileError.invalidRequest
                }
                guard result == 0 else { throw AdminPath.posixError() }
                return Data()
            }
        case .copy:
            guard let destination = request.destination else { throw AdminFileError.invalidRequest }
            return try copyFile(from: request.source, to: destination)
        case .delete:
            return try AdminPath.withParent(of: request.source) { parent, name in
                let root = try AdminPath.attributes(parent: parent, name: name)
                try removeNode(in: parent, name: name, depth: 0, onDevice: root.st_dev)
                return Data()
            }
        case .list:
            return try JSONEncoder().encode(listDirectory(request.source))
        case .trash:
            return try JSONEncoder().encode(moveToTrash(request.source))
        }
    }

    private func listDirectory(_ path: String) throws -> [AdminDirectoryEntry] {
        try AdminPath.withDirectory(of: path) { fd in
            var entries: [AdminDirectoryEntry] = []
            try AdminPath.forEachChild(in: fd) { name in
                do {
                    let attributes = try AdminPath.attributes(parent: fd, name: name)
                    entries.append(
                        AdminDirectoryEntry(name: name, attributes: AdminFileAttributes(attributes))
                    )
                } catch AdminFileError.symlink {
                    // The service never dereferences a symbolic link.
                } catch let error as POSIXError where error.code == .ENOENT {
                    // A child disappeared during the enumeration.
                }
            }
            return entries
        }
    }

    private func moveToTrash(_ path: String) throws -> String {
        guard let trashRoot, path != trashRoot.path, !path.hasPrefix(trashRoot.path + "/")
        else { throw POSIXError(.EINVAL) }
        return try AdminPath.withParent(of: path) { parent, name in
            _ = try AdminPath.attributes(parent: parent, name: name)
            return try AdminPath.withDirectory(of: trashRoot.path) { trash in
                var info = stat()
                guard fstat(trash, &info) == 0 else { throw AdminPath.posixError() }
                guard info.st_uid == trashRoot.owner else { throw POSIXError(.EACCES) }
                for count in 1...10_000 {
                    let destination = count == 1 ? name : "\(count)-\(name)"
                    if renameatx_np(parent, name, trash, destination, UInt32(RENAME_EXCL)) == 0 {
                        return trashRoot.path + "/" + destination
                    }
                    guard errno == EEXIST else { throw AdminPath.posixError() }
                }
                throw POSIXError(.EEXIST)
            }
        }
    }

    private func copyFile(from source: String, to destination: String) throws -> Data {
        try AdminPath.withFile(of: source) { input in
            try AdminPath.withParent(of: destination) { parent, name in
                var original = stat()
                guard fstat(input, &original) == 0 else { throw AdminPath.posixError() }
                try AdminPath.rejectDescendant(of: original, from: parent)
                let staging = ".pathem-admin-\(UUID().uuidString)"
                guard mkdirat(parent, staging, 0o700) == 0 else { throw AdminPath.posixError() }
                defer { _ = unlinkat(parent, staging, AT_REMOVEDIR) }
                let privateDirectory = openat(
                    parent, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard privateDirectory >= 0 else { throw AdminPath.posixError() }
                defer { close(privateDirectory) }
                var created = stat()
                guard fstat(privateDirectory, &created) == 0 else { throw AdminPath.posixError() }
                guard created.st_uid == geteuid(), created.st_mode & 0o777 == 0o700 else {
                    throw POSIXError(.EACCES)
                }
                defer {
                    try? removeNode(
                        in: privateDirectory, name: "item", depth: 0, onDevice: created.st_dev)
                }
                try copyNode(input, into: privateDirectory, name: "item", depth: 0)
                guard
                    renameatx_np(
                        privateDirectory, "item", parent, name, UInt32(RENAME_EXCL)) == 0
                else { throw AdminPath.posixError() }
                return Data()
            }
        }
    }

    private func copyNode(_ input: Int32, into parent: Int32, name: String, depth: Int) throws {
        guard depth < 128 else { throw POSIXError(.ELOOP) }
        var info = stat()
        guard fstat(input, &info) == 0 else { throw AdminPath.posixError() }
        let type = info.st_mode & S_IFMT
        if type == S_IFDIR {
            guard mkdirat(parent, name, 0o700) == 0 else { throw AdminPath.posixError() }
            try AdminPath.withChild(in: parent, name: name) { output in
                try AdminPath.forEachChild(in: input) { child in
                    try AdminPath.withChild(in: input, name: child) { fd in
                        try copyNode(fd, into: output, name: child, depth: depth + 1)
                    }
                }
                guard fchmod(output, info.st_mode & 0o777) == 0 else {
                    throw AdminPath.posixError()
                }
            }
        } else if type == S_IFREG {
            let output = openat(
                parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw AdminPath.posixError() }
            defer { close(output) }
            // Copy only file bytes. In particular ACLs and set-ID bits are excluded.
            guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0,
                fchmod(output, info.st_mode & 0o777) == 0, fsync(output) == 0
            else { throw AdminPath.posixError() }
        } else {
            throw POSIXError(.ENOTSUP)
        }
    }

    private func removeNode(in parent: Int32, name: String, depth: Int, onDevice: dev_t) throws {
        guard depth < 128 else { throw POSIXError(.ELOOP) }
        let observed = try AdminPath.attributes(parent: parent, name: name)
        guard observed.st_dev == onDevice else { throw POSIXError(.EXDEV) }
        let type = observed.st_mode & S_IFMT
        if type == S_IFDIR {
            try AdminPath.withChild(in: parent, name: name) { fd in
                var opened = stat()
                guard fstat(fd, &opened) == 0 else { throw AdminPath.posixError() }
                guard opened.st_dev == observed.st_dev, opened.st_ino == observed.st_ino
                else { throw POSIXError(.ESTALE) }
                try AdminPath.forEachChild(in: fd) { child in
                    try removeNode(in: fd, name: child, depth: depth + 1, onDevice: onDevice)
                }
            }
        } else if type != S_IFREG {
            throw POSIXError(.ENOTSUP)
        }
        let current = try AdminPath.attributes(parent: parent, name: name)
        guard current.st_dev == observed.st_dev, current.st_ino == observed.st_ino
        else { throw POSIXError(.ESTALE) }
        guard unlinkat(parent, name, type == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else {
            throw AdminPath.posixError()
        }
    }
}
