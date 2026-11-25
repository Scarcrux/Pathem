import Darwin
import Foundation

/// Locates the device CLI tools we drive out-of-process. We invoke whatever the user
/// installed (Android platform-tools, libimobiledevice, pymobiledevice3) and never bundle
/// or link them; the Devices section simply stays empty when a tool is absent.
public enum DeviceTools {
    private static func find(_ names: [String], extra: [String] = []) -> String? {
        let home = NSHomeDirectory()
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        dirs.append(contentsOf: extra.map { $0.replacingOccurrences(of: "~", with: home) })
        for dir in dirs {
            for name in names {
                let path = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }
    public static var adb: String? {
        find(["adb"], extra: ["~/Library/Android/sdk/platform-tools"])
    }
}

/// Android device backend. Listing and transfers go through the bundled `pathem-adb` helper,
/// which speaks the adb server protocol (sync LIST/STAT/RECV/SEND) natively, so listings carry
/// real sizes and dates and big files stream with progress and cancellation. The helper runs
/// out of process for crash isolation and to keep protocol parsing out of the app (on macOS it
/// is attributed to Pathem for privacy permissions, so this is not a privilege boundary). If
/// the helper is missing or the server conversation breaks, the original path is used: the
/// `adb` CLI with `ls -1ap`, `pull` and `push`. Definitive answers (no adb, an unauthorized or
/// offline phone) are reported as they are, with a clear message, never retried through the
/// CLI. mkdir, rm and mv stay shell commands with strict quoting. The connection's `host`
/// carries the adb serial.
public struct ADBProvider: RemoteProvider {
    /// Overrides for tests: where the helper lives, and the helper's environment (for
    /// `ANDROID_ADB_SERVER_PORT`). Production uses the bundled helper and the app's environment.
    let helperOverride: String?
    let adbOverride: String?
    let environment: [String: String]?
    /// Called with (bytes so far, total or -1) while a transfer streams.
    let progress: (@Sendable (Int64, Int64) -> Void)?

    public init(progress: (@Sendable (Int64, Int64) -> Void)? = nil) {
        self.init(helper: nil, environment: nil, progress: progress)
    }

    init(
        helper: String?, environment: [String: String]?, adb: String? = nil,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) {
        self.helperOverride = helper
        adbOverride = adb
        self.environment = environment
        self.progress = progress
    }

    struct HelperEntry: Decodable {
        let name: String
        let dir: Bool
        let size: Int64
        let mtime: Double?
    }

    /// Locate the bundled helper (next to the app executable) or the dev build product.
    public static func helperPath() -> String? {
        var candidates: [String] = []
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exe.appendingPathComponent("pathem-adb").path)
        }
        candidates.append(
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("pathem-adb").path)
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var helper: String? {
        if let helperOverride {
            return FileManager.default.isExecutableFile(atPath: helperOverride)
                ? helperOverride : nil
        }
        return Self.helperPath()
    }

    public func list(_ connection: RemoteConnection, path: String, password: String) async throws
        -> [FileEntry]
    {
        let dir = path.isEmpty ? "/sdcard" : path
        if let data = try await viaHelper(["ls", connection.host, dir]) {
            if let entries = try? JSONDecoder().decode([HelperEntry].self, from: data) {
                return entries.map {
                    FileEntry(
                        name: $0.name, isDirectory: $0.dir, size: $0.size,
                        modificationDate: $0.mtime.map { Date(timeIntervalSince1970: $0) },
                        location: dir)
                }
            }
        }
        let (data, status, err) = try await shell(connection.host, "ls -1ap \(quote(dir))")
        guard status == 0 else { throw RemoteError.device(code: status, message: clean(err)) }
        return ADBListParser.parse(String(decoding: data, as: UTF8.self), location: dir)
    }

    public func download(
        _ connection: RemoteConnection, remotePath: String, to localFile: URL, password: String
    ) async throws {
        // Own the temporary directory in the parent process. Even a force-killed helper
        // leaves only contents this scope will remove, with the prior destination untouched.
        let staging = localFile.deletingLastPathComponent().appendingPathComponent(
            ".pathem-adb-download-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(
            at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let output = staging.appendingPathComponent("file")
        if try await viaHelper(["pull", connection.host, remotePath, output.path]) == nil {
            // The CLI takes paths as argv so device-shell quoting is unnecessary.
            let (_, status, error) = try await run(
                connection.host, ["pull", remotePath, output.path])
            guard status == 0 else { throw RemoteError.device(code: status, message: clean(error)) }
        }
        try Task.checkCancellation()
        guard Darwin.rename(output.path, localFile.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func upload(
        _ localFile: URL, to connection: RemoteConnection, remotePath: String, password: String
    ) async throws {
        let parent = (remotePath as NSString).deletingLastPathComponent
        guard remotePath.hasPrefix("/"), !remotePath.hasSuffix("/"),
            !remotePath.utf8.contains(0), !parent.isEmpty
        else { throw RemoteError.device(code: 1, message: "Invalid Android upload path.") }
        let stage = (parent as NSString).appendingPathComponent(
            ".pathem-upload-\(UUID().uuidString)")
        let output = stage + "/file"
        let serial = connection.host
        try await mutate(serial, "mkdir -- \(quote(stage))")
        do {
            if try await viaHelper(["push", serial, localFile.path, output]) == nil {
                let (_, status, error) = try await run(serial, ["push", localFile.path, output])
                guard status == 0 else {
                    throw RemoteError.device(code: status, message: clean(error))
                }
            }
            try Task.checkCancellation()
            // Publish only after all bytes arrive. Treat a directory at the destination
            // as an error rather than moving the temporary file down into that directory.
            try await mutate(serial, "mv -fT -- \(quote(output)) \(quote(remotePath))")
        } catch {
            await removeUploadStage(stage, serial: serial)
            throw error
        }
        await removeUploadStage(stage, serial: serial)
    }

    public func makeDirectory(_ connection: RemoteConnection, path: String, password: String)
        async throws
    {
        try await mutate(connection.host, "mkdir -p \(quote(path))")
    }

    public func remove(
        _ connection: RemoteConnection, path: String, isDirectory: Bool, password: String
    ) async throws {
        try await mutate(connection.host, "rm -rf \(quote(path))")
    }

    public func rename(_ connection: RemoteConnection, from: String, to: String, password: String)
        async throws
    {
        try await mutate(connection.host, "mv -f \(quote(from)) \(quote(to))")
    }

    // MARK: Helpers

    private func removeUploadStage(_ path: String, serial: String) async {
        // A canceled transfer task cannot run a cleanup command through RemoteRunner.
        // This task only sees the UUID directory created by the provider.
        await Task.detached(priority: .utility) {
            try? await mutate(serial, "rm -rf -- \(quote(path))")
        }.value
    }

    private func mutate(_ serial: String, _ command: String) async throws {
        let (_, status, err) = try await shell(serial, command)
        guard status == 0 else { throw RemoteError.device(code: status, message: clean(err)) }
    }

    /// Run a command in the device shell. All of `command` is one argv to adb, which passes
    /// it to the device's shell, so the path quoting inside it is for THAT shell.
    private func shell(_ serial: String, _ command: String) async throws -> (Data, Int32, String) {
        try await run(serial, ["shell", command])
    }

    /// Run a helper command. Returns its stdout, or nil when the helper is missing or the server
    /// conversation broke (the caller falls back to the CLI). Any other failure throws with the
    /// helper's own message, already mapped to something the user can act on.
    private func viaHelper(_ args: [String]) async throws -> Data? {
        guard let helper else { return nil }
        let onStderr: (@Sendable (Data) -> Void)?
        if let progress {
            let reader = ADBProgressLines(report: progress)
            onStderr = { (chunk: Data) in reader.receive(chunk) }
        } else {
            onStderr = nil
        }
        let (data, status, err) = try await RemoteRunner.run(
            helper, args, env: environment, onStderr: onStderr)
        try Task.checkCancellation()
        if status == 0 { return data }
        if ADBError.allowsCLIFallback(exitCode: status) { return nil }
        switch status {
        case ADBError.exitCodeMissing: throw RemoteError.deviceState(.adbMissing)
        case ADBError.exitCodeUnauthorized: throw RemoteError.deviceState(.unauthorized)
        case ADBError.exitCodeOffline: throw RemoteError.deviceState(.offline)
        case ADBError.exitCodeNotFound:
            throw RemoteError.deviceState(.notFound(args.dropFirst().first ?? ""))
        case ADBError.exitCodeCancelled: throw CancellationError()
        default: break
        }
        let message = err.split(separator: "\n").filter { !$0.hasPrefix("PROGRESS ") }
            .joined(separator: "\n")
        throw RemoteError.device(code: status, message: clean(message))
    }

    private func run(_ serial: String, _ args: [String]) async throws -> (Data, Int32, String) {
        guard let adb = adbOverride ?? DeviceTools.adb else {
            throw RemoteError.deviceState(.adbMissing)
        }
        return try await RemoteRunner.run(adb, ["-s", serial] + args, env: environment)
    }

    /// Single-quote a path for the device shell, escaping embedded single quotes.
    private func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func clean(_ err: String) -> String {
        err.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Parses `adb shell ls -1ap` output: one entry per line, a trailing "/" marking a
/// directory. Pure and tested. Strips the CR that `adb shell` appends to each line, and
/// drops the "." / ".." self entries.
public enum ADBListParser {
    public static func parse(_ output: String, location: String) -> [FileEntry] {
        var entries: [FileEntry] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard !line.isEmpty, line != "./", line != "../" else { continue }
            let isDirectory = line.hasSuffix("/")
            let name = isDirectory ? String(line.dropLast()) : line
            guard !name.isEmpty else { continue }
            entries.append(
                FileEntry(
                    name: name, isDirectory: isDirectory, size: 0, modificationDate: nil,
                    location: location))
        }
        return entries
    }
}

/// One helper stderr read may split a progress line or contain several of them.
final class ADBProgressLines: @unchecked Sendable {
    private let lock = NSLock()
    private let report: @Sendable (Int64, Int64) -> Void
    private var pending = Data()
    private var discarding = false

    init(report: @escaping @Sendable (Int64, Int64) -> Void) {
        self.report = report
    }

    func receive(_ chunk: Data) {
        let events: [(Int64, Int64)] = lock.withLock {
            chunk.compactMap { byte in
                if byte == 10 {
                    defer {
                        pending.removeAll(keepingCapacity: true)
                        discarding = false
                    }
                    guard !discarding else { return nil }
                    let fields = String(decoding: pending, as: UTF8.self).split(separator: " ")
                    guard fields.count == 3, fields[0] == "PROGRESS",
                        let done = Int64(fields[1]), done >= 0,
                        let total = Int64(fields[2]), total >= -1
                    else { return nil }
                    return (done, total)
                }
                if pending.count >= 128 { discarding = true }
                if !discarding { pending.append(byte) }
                return nil
            }
        }
        for (done, total) in events { report(done, total) }
    }
}
