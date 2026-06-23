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
        let (data, status, err) = try await run(connection, password, [endpoint(connection, dir)])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
        return FTPListParser.parse(String(decoding: data, as: UTF8.self))
    }

    public func download(
        _ connection: RemoteConnection, remotePath: String, to localFile: URL, password: String
    ) async throws {
        try requireFTP(connection)
        let (_, status, err) = try await run(
            connection, password, ["-o", localFile.path, endpoint(connection, remotePath)])
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    public func upload(
        _ localFile: URL, to connection: RemoteConnection, remotePath: String, password: String
    ) async throws {
        try requireFTP(connection)
        let (_, status, err) = try await run(
            connection, password, ["--ftp-create-dirs", "-T", localFile.path, endpoint(connection, remotePath)])
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

    private func run(_ c: RemoteConnection, _ password: String, _ opArgs: [String]) async throws
        -> (Data, Int32, String)
    {
        let base = ["-s", "--show-error", "--connect-timeout", "20", "-K", "-"]
        return try await Self.runCurl(base + tls(c) + opArgs, input: Self.credentials(c, password))
    }

    private func tls(_ c: RemoteConnection) -> [String] {
        c.proto == .ftps ? ["--ssl-reqd"] : []
    }

    /// A curl config (read via `-K -` on stdin) carrying the credentials, so the
    /// password never appears in the process argument list (visible to `ps`).
    static func credentials(_ c: RemoteConnection, _ password: String) -> String {
        let user = c.user.isEmpty ? "anonymous" : c.user  // empty user means anonymous FTP
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        return "user \"\(esc(user)):\(esc(password))\"\n"
    }

    /// Run curl off the main actor. Returns (stdout, exit code, stderr). Reads
    /// stdout to EOF concurrently so a large listing can't deadlock the pipe.
    nonisolated static func runCurl(_ args: [String], input: String? = nil) async throws
        -> (Data, Int32, String)
    {
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
            let stdin = Pipe()
            if input != nil { process.standardInput = stdin }
            try process.run()
            if let input {  // feed the credential config, then close so curl proceeds
                stdin.fileHandleForWriting.write(Data(input.utf8))
                stdin.fileHandleForWriting.closeFile()
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (outData, process.terminationStatus, String(decoding: errData, as: UTF8.self))
        }.value
    }
}
