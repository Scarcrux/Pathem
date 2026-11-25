import Darwin
import Foundation

/// The service accepts bounded, validated data. NSXPC does not decode custom object graphs
/// supplied by the peer. A listener must authenticate the code identity before exporting it.
@objc public protocol AdminFileServiceProtocol {
    func version(reply: @escaping (Int) -> Void)
    func authorize(_ externalForm: Data, reply: @escaping (Bool) -> Void)
    func lockSession(reply: @escaping () -> Void)
    func perform(_ encodedRequest: Data, reply: @escaping (Data?, NSError?) -> Void)
}

struct AdminFileAttributes: Codable {
    let mode: UInt16
    let owner: UInt32
    let group: UInt32
    let size: Int64
}

/// Create one instance per verified XPC connection. The service has no global unlock state.
public final class AdminFileService: NSObject, AdminFileServiceProtocol {
    private let verifyAuthorization: @Sendable (Data) -> Bool
    private let lifetime: Duration
    private let session = NSLock()
    private var expires: ContinuousClock.Instant?

    public init(
        lifetime: Duration = .seconds(300),
        verifyAuthorization: @escaping @Sendable (Data) -> Bool
    ) {
        self.verifyAuthorization = verifyAuthorization
        self.lifetime = min(max(.zero, lifetime), .seconds(300))
    }

    public func version(reply: @escaping (Int) -> Void) {
        reply(1)
    }

    public func authorize(_ externalForm: Data, reply: @escaping (Bool) -> Void) {
        let granted = session.withLock {
            expires = nil
            guard externalForm.count == 32, verifyAuthorization(externalForm) else {
                return false
            }
            expires = .now.advanced(by: lifetime)
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
            return try JSONEncoder().encode(
                AdminFileAttributes(
                    mode: information.st_mode, owner: information.st_uid,
                    group: information.st_gid, size: information.st_size))
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
                    let managed = UInt32(UF_IMMUTABLE | UF_HIDDEN)
                    result = fchflags(fd, (info.st_flags & ~managed) | flags)
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
                let info = try AdminPath.attributes(parent: parent, name: name)
                let type = info.st_mode & S_IFMT
                guard type == S_IFREG || type == S_IFDIR else { throw POSIXError(.ENOTSUP) }
                // An empty directory can be removed with unlinkat. There is no recursive
                // privileged traversal through a mutable directory tree.
                guard unlinkat(parent, name, type == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else {
                    throw AdminPath.posixError()
                }
                return Data()
            }
        case .trash, .list:
            throw POSIXError(.ENOTSUP)
        }
    }

    private func copyFile(from source: String, to destination: String) throws -> Data {
        try AdminPath.withFile(of: source) { input in
            var info = stat()
            guard fstat(input, &info) == 0 else { throw AdminPath.posixError() }
            guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.ENOTSUP) }
            return try AdminPath.withParent(of: destination) { parent, name in
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
                let output = openat(
                    privateDirectory, "file", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600)
                guard output >= 0 else { throw AdminPath.posixError() }
                defer {
                    close(output)
                    _ = unlinkat(privateDirectory, "file", 0)
                }
                // Copy only file bytes. In particular ACLs and set-ID bits are excluded.
                guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0,
                    fchmod(output, info.st_mode & 0o777) == 0,
                    fsync(output) == 0
                else { throw AdminPath.posixError() }
                guard
                    renameatx_np(
                        privateDirectory, "file", parent, name, UInt32(RENAME_EXCL)) == 0
                else {
                    throw AdminPath.posixError()
                }
                return Data()
            }
        }
    }

}
