import Foundation

/// SSH host-key checks for the SFTP first-connection prompt: is this host already pinned in
/// known_hosts, and if not, what is its key fingerprint. Lets the app surface a "new host key,
/// accept?" confirmation instead of silently trusting on first use. Shells to the system ssh tools
/// (ssh-keygen, ssh-keyscan); host is validated by the caller to avoid passing a smuggled authority.
public enum HostKeyCheck {
    /// Whether `host` already has a pinned key in the user's known_hosts (ssh-keygen -F succeeds).
    public static func isKnown(host: String, port: Int) -> Bool {
        guard RemoteConnection.isValidHost(host) else { return false }
        let target = port == 22 ? host : "[\(host)]:\(port)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-F", target]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0  // exit 0 == a matching entry was found
    }

    /// The host's key fingerprint (e.g. "256 SHA256:… host (ED25519)"), fetched with ssh-keyscan
    /// and summarized by ssh-keygen. Nil when the host can't be reached or scanned.
    public static func fingerprint(host: String, port: Int) async -> String? {
        guard RemoteConnection.isValidHost(host) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: scanFingerprint(host: host, port: port))
            }
        }
    }

    private static func scanFingerprint(host: String, port: Int) -> String? {
        // ssh-keyscan fetches the host's public keys (with a short timeout so an unreachable host
        // fails fast rather than hanging the prompt).
        let scan = Process()
        scan.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        scan.arguments = ["-T", "10", "-p", "\(port)", host]
        let scanOut = Pipe()
        scan.standardOutput = scanOut
        scan.standardError = Pipe()
        guard (try? scan.run()) != nil else { return nil }
        let keyData = scanOut.fileHandleForReading.readDataToEndOfFile()
        scan.waitUntilExit()
        guard scan.terminationStatus == 0, !keyData.isEmpty else { return nil }

        // ssh-keygen -lf - summarizes the scanned key(s) into fingerprint lines.
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-lf", "-"]
        let input = Pipe()
        let output = Pipe()
        keygen.standardInput = input
        keygen.standardOutput = output
        keygen.standardError = Pipe()
        guard (try? keygen.run()) != nil else { return nil }
        input.fileHandleForWriting.write(keyData)
        try? input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        keygen.waitUntilExit()
        // One line per key type; the first (ssh-keyscan prefers the strongest) is enough to show.
        return String(data: out, encoding: .utf8)?
            .split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
    }
}
