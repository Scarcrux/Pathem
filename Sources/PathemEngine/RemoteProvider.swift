import Foundation

public enum RemoteError: Error, Sendable {
    case unsupported(String)
    case curl(code: Int32, message: String)
    case curlMissing
    case sftp(code: Int32, message: String)
    case sftpMissing
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

/// Picks the right out-of-process backend for a connection's protocol. The UI
/// goes through this so adding a backend is a one-line change here.
public enum RemoteProviders {
    public static func make(for proto: RemoteConnection.Proto) -> RemoteProvider {
        switch proto {
        case .ftp, .ftps: return CurlFTPProvider()
        case .sftp: return SFTPProvider()
        }
    }
}

/// FTP / FTPS backend that shells out to the system `curl` (a separate process,
/// permissively licensed). SFTP is handled by `SFTPProvider` (system `sftp`).
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
        return FTPListParser.parse(data)  // byte-based: preserves non-UTF-8 names as rawName
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
        // Defensive: RemoteProviders.make never routes SFTP here, but this provider
        // is public and could be constructed directly.
        if c.proto == .sftp {
            throw RemoteError.unsupported("CurlFTPProvider handles FTP/FTPS only; use SFTPProvider for SFTP")
        }
        guard c.hasValidHost else {
            throw RemoteError.unsupported("Invalid host \"\(c.host)\"")  // never shell out to a smuggled authority
        }
    }

    func endpoint(_ c: RemoteConnection, _ path: String) -> String {
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
        // aren't treated as curl globs. --proto: a smuggled scheme can't redirect.
        let base = [
            "-q", "-s", "--show-error", "--globoff", "--proto", "=ftp,ftps",
            "--connect-timeout", "20", "-K", "-",
        ]
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

    /// Run curl, checking it exists first. Returns (stdout, exit code, stderr).
    nonisolated static func runCurl(_ args: [String], input: String? = nil) async throws
        -> (Data, Int32, String)
    {
        let curl = "/usr/bin/curl"
        guard FileManager.default.isExecutableFile(atPath: curl) else { throw RemoteError.curlMissing }
        return try await RemoteRunner.run(curl, args, input: input)
    }
}

/// Runs a subprocess off the main actor. Returns (stdout, exit code, stderr).
/// Drains stdout and stderr concurrently so a large transfer can't deadlock the
/// pipe, and honors Task cancellation by terminating the process (so a transfer
/// can be cancelled mid-flight).
enum RemoteRunner {
    nonisolated static func run(
        _ executable: String, _ args: [String], input: String? = nil, env: [String: String]? = nil,
        cwd: URL? = nil
    ) async throws -> (Data, Int32, String) {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, Int32, String), Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = args
                    if let env { process.environment = env }
                    if let cwd { process.currentDirectoryURL = cwd }
                    let out = Pipe()
                    let err = Pipe()
                    process.standardOutput = out
                    process.standardError = err
                    let stdin = Pipe()
                    if input != nil { process.standardInput = stdin }
                    guard box.adopt(process) else {  // cancelled before we could start
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        try process.run()
                    } catch {
                        cont.resume(throwing: error)
                        return
                    }
                    box.markLaunched()  // safe to terminate now (handles a cancel that raced run)
                    if let input {  // feed stdin (config / batch), then close so the tool proceeds
                        // Use the throwing API and swallow a broken pipe: if the child
                        // already exited or was cancelled mid-write, fall through to
                        // draining + waitUntilExit rather than raising an uncatchable
                        // NSException (SIGPIPE is ignored process-wide at startup).
                        try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                        try? stdin.fileHandleForWriting.close()
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
                    cont.resume(
                        returning: (outData, process.terminationStatus, String(decoding: errData, as: UTF8.self)))
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

/// Lock-guarded holder so a cancellation handler (on another thread) can
/// terminate the running process. Tracks launch state because Process.terminate()
/// on a task that has not been launched raises an uncatchable exception.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var launched = false
    private var cancelled = false

    /// Take ownership of the process. Returns false if cancellation already
    /// happened (the task was cancelled before the process started).
    func adopt(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        self.process = process
        return true
    }

    /// The process has actually been launched. If cancellation arrived in the
    /// window between adopt and run, terminate it now.
    func markLaunched() {
        lock.lock()
        defer { lock.unlock() }
        launched = true
        if cancelled, process?.isRunning == true { process?.terminate() }
    }

    /// Request termination; only ever touches a process that has launched.
    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if launched, process?.isRunning == true { process?.terminate() }
    }
}
