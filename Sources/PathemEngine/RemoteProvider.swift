import Foundation

public enum RemoteError: Error, Sendable {
    case unsupported(String)
    case curl(code: Int32, message: String)
    case curlMissing
}

/// The seam between the browser and remote networking. Implementations run the
/// actual protocol work OUT OF PROCESS (never in the Full-Disk-Access app
/// process). The UI (panes) only ever talks to this protocol, so a backend can
/// be swapped (curl now; a signed XPC helper with libssh2 for SFTP later)
/// without touching the browser.
public protocol RemoteProvider: Sendable {
    func list(_ connection: RemoteConnection, path: String, password: String) async throws -> [FileEntry]
    func download(_ connection: RemoteConnection, remotePath: String, to localFile: URL, password: String)
        async throws
    func upload(_ localFile: URL, to connection: RemoteConnection, remotePath: String, password: String)
        async throws
}

/// FTP / FTPS backend that shells out to the system `curl` (a separate process,
/// permissively licensed). SFTP is not supported here (system curl lacks it);
/// that arrives with the XPC + libssh2 backend.
public struct CurlFTPProvider: RemoteProvider {
    public init() {}

    public func list(_ connection: RemoteConnection, path: String, password: String) async throws
        -> [FileEntry]
    {
        try requireFTP(connection)
        var dir = path.isEmpty ? "/" : path
        if !dir.hasSuffix("/") { dir += "/" }  // trailing slash makes curl LIST, not retrieve
        let url = endpoint(connection, dir)
        let (data, status, err) = try await Self.runCurl(auth(connection, password) + tls(connection) + [url])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
        return FTPListParser.parse(String(decoding: data, as: UTF8.self))
    }

    public func download(
        _ connection: RemoteConnection, remotePath: String, to localFile: URL, password: String
    ) async throws {
        try requireFTP(connection)
        let url = endpoint(connection, remotePath)
        let (_, status, err) = try await Self.runCurl(
            auth(connection, password) + tls(connection) + ["-o", localFile.path, url])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    public func upload(
        _ localFile: URL, to connection: RemoteConnection, remotePath: String, password: String
    ) async throws {
        try requireFTP(connection)
        let url = endpoint(connection, remotePath)
        let (_, status, err) = try await Self.runCurl(
            auth(connection, password) + tls(connection) + ["--ftp-create-dirs", "-T", localFile.path, url])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    // MARK: Helpers

    private func requireFTP(_ c: RemoteConnection) throws {
        if c.proto == .sftp { throw RemoteError.unsupported("SFTP requires the XPC backend") }
    }

    private func endpoint(_ c: RemoteConnection, _ path: String) -> String {
        let clean = path.hasPrefix("/") ? path : "/" + path
        return "ftp://\(c.host):\(c.effectivePort)\(clean)"  // ftp:// + --ssl-reqd handles explicit FTPS
    }

    private func auth(_ c: RemoteConnection, _ password: String) -> [String] {
        ["-s", "--show-error", "--connect-timeout", "20", "-u", "\(c.user):\(password)"]
    }

    private func tls(_ c: RemoteConnection) -> [String] {
        c.proto == .ftps ? ["--ssl-reqd"] : []
    }

    /// Run curl off the main actor. Returns (stdout, exit code, stderr). Reads
    /// stdout to EOF concurrently so a large listing can't deadlock the pipe.
    nonisolated static func runCurl(_ args: [String]) async throws -> (Data, Int32, String) {
        try await Task.detached(priority: .userInitiated) {
            let curl = "/usr/bin/curl"
            guard FileManager.default.isExecutableFile(atPath: curl) else { throw RemoteError.curlMissing }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: curl)
            process.arguments = args
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (outData, process.terminationStatus, String(decoding: errData, as: UTF8.self))
        }.value
    }
}
