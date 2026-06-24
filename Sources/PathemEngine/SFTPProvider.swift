import Foundation

/// SFTP backend that drives the system `sftp` (OpenSSH, BSD-licensed, ships with
/// macOS) as a subprocess, so SSH networking stays out of this process. The
/// password is supplied through SSH_ASKPASS in a MINIMAL child environment built
/// from scratch (not the app's full inherited environment), and never appears in
/// argv. Directory listings reuse the Unix `ls -l` parser. The RemoteProvider
/// seam means a stricter XPC + libssh2 backend could replace this later without
/// any UI changes.
public struct SFTPProvider: RemoteProvider {
    public init() {}

    public func list(_ connection: RemoteConnection, path: String, password: String) async throws
        -> [FileEntry]
    {
        let dir = path.isEmpty ? "/" : path
        let (out, status, err) = try await run(connection, password, batch: "cd \(try quote(dir))\nls -l\n")
        guard status == 0 else { throw RemoteError.sftp(code: status, message: cleanError(err)) }
        return FTPListParser.parse(out)  // byte-based: preserves non-UTF-8 names as rawName
    }

    public func download(
        _ connection: RemoteConnection, remotePath: String, to localFile: URL, password: String
    ) async throws {
        let (_, status, err) = try await run(
            connection, password, batch: "get \(try quote(remotePath)) \(try quote(localFile.path))\n")
        guard status == 0 else { throw RemoteError.sftp(code: status, message: cleanError(err)) }
    }

    public func upload(
        _ localFile: URL, to connection: RemoteConnection, remotePath: String, password: String
    ) async throws {
        let (_, status, err) = try await run(
            connection, password, batch: "put \(try quote(localFile.path)) \(try quote(remotePath))\n")
        guard status == 0 else { throw RemoteError.sftp(code: status, message: cleanError(err)) }
    }

    public func makeDirectory(_ connection: RemoteConnection, path: String, password: String) async throws {
        try await batch("mkdir \(try quote(path))\n", connection, password)
    }

    public func remove(
        _ connection: RemoteConnection, path: String, isDirectory: Bool, password: String
    ) async throws {
        try await batch("\(isDirectory ? "rmdir" : "rm") \(try quote(path))\n", connection, password)
    }

    public func rename(_ connection: RemoteConnection, from: String, to: String, password: String) async throws {
        try await batch("rename \(try quote(from)) \(try quote(to))\n", connection, password)
    }

    private func batch(_ commands: String, _ connection: RemoteConnection, _ password: String) async throws {
        let (_, status, err) = try await run(connection, password, batch: commands)
        guard status == 0 else { throw RemoteError.sftp(code: status, message: cleanError(err)) }
    }

    // MARK: Helpers

    private func run(_ c: RemoteConnection, _ password: String, batch: String) async throws
        -> (Data, Int32, String)
    {
        let sftp = "/usr/bin/sftp"
        guard FileManager.default.isExecutableFile(atPath: sftp) else { throw RemoteError.sftpMissing }
        guard c.hasValidHost else {
            throw RemoteError.unsupported("Invalid host \"\(c.host)\"")  // never pass a smuggled authority to ssh
        }
        let askpass = try Self.askpassScript()
        defer { try? FileManager.default.removeItem(at: askpass) }  // don't leave it lying around
        let parent = ProcessInfo.processInfo.environment
        // Build a minimal environment from scratch rather than inheriting the app's
        // full one, so no unrelated secret leaks into the child and the password's
        // exposure is confined to exactly the process that needs it.
        let env = [
            "PATH": "/usr/bin:/bin",
            "HOME": parent["HOME"] ?? NSHomeDirectory(),  // for ~/.ssh/known_hosts
            "PATHEM_PW": password,  // read by the askpass helper, not visible in argv
            "SSH_ASKPASS": askpass.path,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": parent["DISPLAY"] ?? ":0",  // older ssh only uses askpass when DISPLAY is set
        ]
        let user = c.user.isEmpty ? "anonymous" : c.user
        let args = [
            "-q",  // suppress the banner/warnings
            "-oBatchMode=no",  // BatchMode=yes would disable password auth entirely
            "-oStrictHostKeyChecking=accept-new",  // trust on first use, then pin
            "-oConnectTimeout=20",
            "-oNumberOfPasswordPrompts=1",  // don't loop on a bad password
            "-oPort=\(c.effectivePort)",
            "-b", "-",  // read batch commands from stdin
            "\(user)@\(c.host)",
        ]
        return try await RemoteRunner.run(sftp, args, input: batch, env: env)
    }

    /// Quote a path for an sftp batch line: escape backslash and quote, and
    /// backslash-escape the glob metacharacters sftp expands even inside quotes,
    /// so get/put of a literal name containing * ? [ ] works. Backslash must be
    /// escaped first so the escapes we add survive.
    ///
    /// The sftp batch protocol is line-based, so a newline, carriage return, or NUL
    /// in a path cannot be represented; rather than silently stripping it (which
    /// would map to a DIFFERENT remote path), reject it.
    func quote(_ s: String) throws -> String {
        guard !s.contains("\n"), !s.contains("\r"), !s.contains("\0") else {
            throw RemoteError.unsupported("name contains a character sftp can't handle (newline or NUL)")
        }
        var escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        for glob in ["*", "?", "[", "]"] {
            escaped = escaped.replacingOccurrences(of: glob, with: "\\" + glob)
        }
        return "\"\(escaped)\""
    }

    /// Drop OpenSSH's noise so the surfaced error is the useful line.
    func cleanError(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("Warning: Permanently added") && !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Write a tiny askpass helper that prints $PATHEM_PW. The script holds no
    /// secret (the password arrives via the child environment). A unique per-run
    /// name (deleted by the caller's defer) avoids concurrent sftp runs racing on a
    /// shared file; 0700 keeps it readable only by this user.
    private static func askpassScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-askpass-\(UUID().uuidString).sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$PATHEM_PW\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
