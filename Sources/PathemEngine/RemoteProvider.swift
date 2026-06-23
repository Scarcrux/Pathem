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
        // Percent-encode each path segment so spaces, #, ?, etc. in names don't
        // break the URL (slashes are preserved as separators).
        let encoded = clean.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return "ftp://\(c.host):\(c.effectivePort)\(encoded)"  // ftp:// + --ssl-reqd handles explicit FTPS
    }

    private func run(_ c: RemoteConnection, _ password: String, _ opArgs: [String]) async throws
        -> (Data, Int32, String)
    {
        // -q first: never read the ambient ~/.curlrc. --globoff: names with []{}
        // aren't treated as curl globs.
        let base = ["-q", "-s", "--show-error", "--globoff", "--connect-timeout", "20", "-K", "-"]
        return try await Self.runCurl(base + tls(c) + opArgs, input: Self.credentials(c, password))
    }

    private func tls(_ c: RemoteConnection) -> [String] {
        c.proto == .ftps ? ["--ssl-reqd"] : []
    }

    /// A curl config (read via `-K -` on stdin) carrying the credentials, so the
    /// password never appears in the process argument list (visible to `ps`).
    static func credentials(_ c: RemoteConnection, _ password: String) -> String {
        let user = c.user.isEmpty ? "anonymous" : c.user  // empty user means anonymous FTP
        // Escape backslash/quote and control chars so a value can't break out of
        // the quoted config and inject curl directives (e.g. a newline).
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\u{0B}", with: "\\v")
        }
        return "user \"\(esc(user)):\(esc(password))\"\n"
    }

    /// Run curl off the main actor. Returns (stdout, exit code, stderr). Reads
    /// stdout to EOF concurrently so a large listing can't deadlock the pipe.
    nonisolated static func runCurl(_ args: [String], input: String? = nil) async throws
        -> (Data, Int32, String)
    {
        // Run the blocking process work on a background queue; the concurrent
        // pipe drain (a DispatchGroup wait) is legal there but not in an async
        // context, so a continuation bridges it back.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, Int32, String), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let curl = "/usr/bin/curl"
                guard FileManager.default.isExecutableFile(atPath: curl) else {
                    cont.resume(throwing: RemoteError.curlMissing)
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: curl)
                process.arguments = args
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                let stdin = Pipe()
                if input != nil { process.standardInput = stdin }
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                if let input {  // feed the credential config, then close so curl proceeds
                    stdin.fileHandleForWriting.write(Data(input.utf8))
                    stdin.fileHandleForWriting.closeFile()
                }
                // Drain stdout and stderr concurrently so a large stream on either
                // pipe can't fill its buffer and deadlock the process.
                let group = DispatchGroup()
                var errData = Data()
                DispatchQueue.global().async(group: group) {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                cont.resume(returning: (outData, process.terminationStatus, String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}
