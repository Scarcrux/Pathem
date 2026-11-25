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

/// Android device backend: drives `adb` as a subprocess (USB debugging), so device access
/// stays out of the app (crash isolation, not a TCC boundary). The connection's `host` carries the adb
/// serial. Listings use `ls -1ap` (one name per line, "/" suffix marks directories), which
/// is robust across toybox/busybox where a columnar `ls -l` parser would be fragile.
public struct ADBProvider: RemoteProvider {
    public init() {}

    public func list(_ connection: RemoteConnection, path: String, password: String) async throws
        -> [FileEntry]
    {
        let dir = path.isEmpty ? "/sdcard" : path
        let (data, status, err) = try await shell(connection.host, "ls -1ap \(quote(dir))")
        guard status == 0 else { throw RemoteError.device(code: status, message: clean(err)) }
        return ADBListParser.parse(String(decoding: data, as: UTF8.self), location: dir)
    }

    public func download(
        _ connection: RemoteConnection, remotePath: String, to localFile: URL, password: String
    ) async throws {
        // adb pull takes the paths as its own argv, so no device-shell quoting is needed.
        let (_, status, err) = try await run(connection.host, ["pull", remotePath, localFile.path])
        guard status == 0 else { throw RemoteError.device(code: status, message: clean(err)) }
    }

    public func upload(
        _ localFile: URL, to connection: RemoteConnection, remotePath: String, password: String
    ) async throws {
        let (_, status, err) = try await run(connection.host, ["push", localFile.path, remotePath])
        guard status == 0 else { throw RemoteError.device(code: status, message: clean(err)) }
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

    private func mutate(_ serial: String, _ command: String) async throws {
        let (_, status, err) = try await shell(serial, command)
        guard status == 0 else { throw RemoteError.device(code: status, message: clean(err)) }
    }

    /// Run a command in the device shell. All of `command` is one argv to adb, which passes
    /// it to the device's shell, so the path quoting inside it is for THAT shell.
    private func shell(_ serial: String, _ command: String) async throws -> (Data, Int32, String) {
        try await run(serial, ["shell", command])
    }

    private func run(_ serial: String, _ args: [String]) async throws -> (Data, Int32, String) {
        guard let adb = DeviceTools.adb else { throw RemoteError.deviceToolMissing("adb") }
        return try await RemoteRunner.run(adb, ["-s", serial] + args)
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
