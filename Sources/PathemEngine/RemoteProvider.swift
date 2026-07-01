import Foundation

public enum RemoteError: Error, Sendable {
    case unsupported(String)
    case curl(code: Int32, message: String)
    case curlMissing
    case sftp(code: Int32, message: String)
    case sftpMissing
    case device(code: Int32, message: String)
    case deviceToolMissing(String)  // the named CLI (adb) isn't installed
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
    /// Create a directory at `path`.
    func makeDirectory(_ connection: RemoteConnection, path: String, password: String) async throws
    /// Delete a file or (empty) directory at `path`.
    func remove(_ connection: RemoteConnection, path: String, isDirectory: Bool, password: String) async throws
    /// Rename/move `from` to `to`.
    func rename(_ connection: RemoteConnection, from: String, to: String, password: String) async throws
}

/// Picks the right out-of-process backend for a connection's protocol. The UI
/// goes through this so adding a backend is a one-line change here.
public enum RemoteProviders {
    public static func make(for proto: RemoteConnection.Proto) -> RemoteProvider {
        switch proto {
        case .ftp, .ftps: return CurlFTPProvider()
        case .sftp: return SFTPProvider()
        case .webdav, .webdavs: return CurlWebDAVProvider()
        case .s3: return S3Provider()
        case .adb: return ADBProvider()
        case .afc: return AFCProvider()
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

    public func makeDirectory(_ connection: RemoteConnection, path: String, password: String) async throws {
        try await quote(["MKD \(try ftpArg(path))"], on: connection, password: password)
    }

    public func remove(
        _ connection: RemoteConnection, path: String, isDirectory: Bool, password: String
    ) async throws {
        try await quote(["\(isDirectory ? "RMD" : "DELE") \(try ftpArg(path))"], on: connection, password: password)
    }

    public func rename(_ connection: RemoteConnection, from: String, to: String, password: String) async throws {
        try await quote(
            ["RNFR \(try ftpArg(from))", "RNTO \(try ftpArg(to))"], on: connection, password: password)
    }

    /// Run raw FTP commands via curl's `-Q`. A bare URL is required, so we target the
    /// root; the commands carry the absolute paths.
    private func quote(_ commands: [String], on c: RemoteConnection, password: String) async throws {
        try requireFTP(c)
        var opArgs: [String] = []
        for command in commands { opArgs += ["-Q", command] }
        opArgs.append(endpoint(c, "/"))
        let (_, status, err) = try await run(c, password, opArgs)
        guard status == 0 else { throw RemoteError.curl(code: status, message: err) }
    }

    /// A remote path safe to put in an FTP command line (no CR/LF that could inject
    /// a second command).
    private func ftpArg(_ path: String) throws -> String {
        guard !path.contains("\n"), !path.contains("\r") else {
            throw RemoteError.unsupported("path contains a newline")
        }
        return path
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
        return try await Self.runCurl(base + RemoteLimits.curlArgs + tls(c) + opArgs, input: Self.credentials(c, password))
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
///
/// Reads stdout/stderr with event-driven readability handlers rather than a
/// blocking `readDataToEndOfFile()`, and completes on the child's own exit
/// (`terminationHandler`). That matters when a grandchild inherits the pipe's
/// write end and outlives the child we spawned (the classic case is the `adb`
/// daemon, but any tool that forks a persistent helper or a ProxyCommand does
/// it): a blocking read would wait for EOF that never comes and hang forever.
/// Cancellation terminates the child (SIGTERM, then SIGKILL if it lingers), so a
/// transfer can be cancelled mid-flight even against a process that ignores
/// SIGTERM.
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

                    // Accumulate both streams as data arrives, off the pipe's own queue,
                    // so nothing ever blocks waiting for an EOF that a lingering grandchild
                    // could withhold. An empty read is EOF; drop the handler then.
                    let sink = OutputSink()
                    out.fileHandleForReading.readabilityHandler = { h in
                        let d = h.availableData
                        if d.isEmpty { h.readabilityHandler = nil } else { sink.appendOut(d) }
                    }
                    err.fileHandleForReading.readabilityHandler = { h in
                        let d = h.availableData
                        if d.isEmpty { h.readabilityHandler = nil } else { sink.appendErr(d) }
                    }

                    // Fires once, on a background queue, when the direct child is reaped
                    // (even if the pipe never sees EOF). Give the readers a brief window to
                    // drain whatever is still buffered, then stop reading and report.
                    process.terminationHandler = { proc in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                            out.fileHandleForReading.readabilityHandler = nil
                            err.fileHandleForReading.readabilityHandler = nil
                            box.finish()  // release the process; disarm the SIGKILL escalation
                            let (o, e) = sink.snapshot()
                            cont.resume(
                                returning: (o, proc.terminationStatus, String(decoding: e, as: UTF8.self)))
                        }
                    }

                    guard box.adopt(process) else {  // cancelled before we could start
                        out.fileHandleForReading.readabilityHandler = nil
                        err.fileHandleForReading.readabilityHandler = nil
                        process.terminationHandler = nil
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        try process.run()
                    } catch {
                        out.fileHandleForReading.readabilityHandler = nil
                        err.fileHandleForReading.readabilityHandler = nil
                        process.terminationHandler = nil
                        cont.resume(throwing: error)
                        return
                    }
                    box.markLaunched()  // safe to terminate now (handles a cancel that raced run)
                    if let input {  // feed stdin (config / batch), then close so the tool proceeds
                        // Use the throwing API and swallow a broken pipe: if the child
                        // already exited or was cancelled mid-write, let the termination
                        // handler report rather than raising an uncatchable NSException
                        // (SIGPIPE is ignored process-wide at startup).
                        try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                        try? stdin.fileHandleForWriting.close()
                    }
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

/// Lock-guarded holder so a cancellation handler (on another thread) can
/// terminate the running process. Tracks launch state because Process.terminate()
/// on a task that has not been launched raises an uncatchable exception, and
/// escalates SIGTERM to SIGKILL so a child that ignores SIGTERM can't hang the
/// awaiting task forever.
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
        if cancelled { killNow() }
    }

    /// Request termination; only ever touches a process that has launched.
    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if launched { killNow() }
    }

    /// The child has exited and been reported; release it so a later SIGKILL
    /// escalation can't land on a reused pid.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        process = nil
    }

    /// SIGTERM now, then SIGKILL after a grace period if it is still alive. Caller
    /// holds the lock.
    private func killNow() {
        guard let process, process.isRunning else { return }
        process.terminate()  // SIGTERM: let it clean up
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.process?.isRunning == true { kill(pid, SIGKILL) }
        }
    }
}

/// Thread-safe accumulator for a subprocess's stdout/stderr, written from the
/// pipes' readability queues and read once the process exits.
private final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
    func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
    func snapshot() -> (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (out, err)
    }
}
