import Foundation

/// SFTP backend that drives the system `sftp` (OpenSSH, BSD-licensed, ships with
/// macOS) as a subprocess, so SSH networking stays out of this process. The
/// password is supplied through SSH_ASKPASS, which reads it from the child's
/// environment (never in argv, never written to disk). Directory listings reuse
/// the Unix `ls -l` parser. The RemoteProvider seam means a stricter XPC +
/// libssh2 backend could replace this later without any UI changes.
public struct SFTPProvider: RemoteProvider {
    public init() {}

    public func list(_ connection: RemoteConnection, path: String, password: String) async throws
        -> [FileEntry]
    {
        let dir = path.isEmpty ? "/" : path
        let (out, status, err) = try await run(connection, password, batch: "cd \(quote(dir))\nls -l\n")
        guard status == 0 else { throw RemoteError.sftp(code: status, message: cleanError(err)) }
        return FTPListParser.parse(String(decoding: out, as: UTF8.self))
    }

    public func download(
        _ connection: RemoteConnection, remotePath: String, to localFile: URL, password: String
    ) async throws {
        let (_, status, err) = try await run(
            connection, password, batch: "get \(quote(remotePath)) \(quote(localFile.path))\n")
        guard status == 0 else { throw RemoteError.sftp(code: status, message: cleanError(err)) }
    }

    public func upload(
        _ localFile: URL, to connection: RemoteConnection, remotePath: String, password: String
    ) async throws {
        let (_, status, err) = try await run(
            connection, password, batch: "put \(quote(localFile.path)) \(quote(remotePath))\n")
        guard status == 0 else { throw RemoteError.sftp(code: status, message: cleanError(err)) }
    }

    // MARK: Helpers

    private func run(_ c: RemoteConnection, _ password: String, batch: String) async throws
        -> (Data, Int32, String)
    {
        let sftp = "/usr/bin/sftp"
        guard FileManager.default.isExecutableFile(atPath: sftp) else { throw RemoteError.sftpMissing }
        let askpass = try Self.askpassScript()
        var env = ProcessInfo.processInfo.environment
        env["PATHEM_PW"] = password  // read by the askpass helper, not visible in argv
        env["SSH_ASKPASS"] = askpass.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"  // older ssh only uses askpass when DISPLAY is set
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

    /// Quote a path for an sftp batch line: strip newlines (so a crafted name
    /// can't inject extra batch commands), escape backslash and quote, and
    /// backslash-escape the glob metacharacters sftp expands even inside quotes,
    /// so get/put of a literal name containing * ? [ ] works. Backslash must be
    /// escaped first so the escapes we add survive.
    private func quote(_ s: String) -> String {
        var escaped = s.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        for glob in ["*", "?", "[", "]"] {
            escaped = escaped.replacingOccurrences(of: glob, with: "\\" + glob)
        }
        return "\"\(escaped)\""
    }

    /// Drop OpenSSH's noise so the surfaced error is the useful line.
    private func cleanError(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("Warning: Permanently added") && !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Write a tiny askpass helper that prints $PATHEM_PW. The script holds no
    /// secret (the password arrives via the child environment); it lives in the
    /// per-user temp dir and is rewritten each time so its contents and 0700
    /// permissions are always known-good.
    private static func askpassScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-askpass.sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$PATHEM_PW\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
