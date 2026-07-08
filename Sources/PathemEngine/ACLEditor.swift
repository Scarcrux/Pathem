import Foundation

/// Edits a file's POSIX ACL (the "Sharing & Permissions" entries beyond owner/group/other) via
/// the built-in `/bin/chmod` ACL syntax — an external tool, within the hard rules (no embedded
/// scripting). `FileMetadata.aclEntries` reads them; this adds and removes them. Blocking, so run
/// off the main thread. Editing your own files needs no elevated privileges.
public enum ACLEditor {
    /// The chmod ACL permission keywords offered in the UI, in a sensible order.
    public static let permissionKeywords = [
        "read", "write", "execute", "delete", "append", "readattr", "writeattr", "readsecurity",
    ]

    /// Add an allow/deny access-control entry for `principal` (a user or group name) with the given
    /// chmod permission keywords. Returns nil on success, or the tool's error text.
    public static func add(principal: String, allow: Bool, permissions: [String], to url: URL) -> String? {
        let name = principal.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "Enter a user or group name." }
        guard !permissions.isEmpty else { return "Choose at least one permission." }
        let clause = "\(name) \(allow ? "allow" : "deny") \(permissions.joined(separator: ","))"
        return run(["+a", clause, url.path])
    }

    /// Remove the ACE at `index` (0-based, matching the order `aclEntries` returns).
    public static func removeEntry(at index: Int, from url: URL) -> String? {
        run(["-a#", "\(index)", url.path])
    }

    private static func run(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0 { return nil }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "chmod exited \(process.terminationStatus)" : text
    }
}
