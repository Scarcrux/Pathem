import Foundation

/// Reads a file's owner/group and builds the privileged `chown` command for the terminal route.
/// Changing the *group* (when you own the file and belong to the group) goes through
/// `BulkAttributes` and needs no root; changing the *owner* to another user always needs root, so
/// Pathem hands the user a ready-to-run `sudo chown` line in its embedded terminal instead of
/// bundling a privileged helper. Foundation-only, unit-tested.
public enum OwnershipEditor {
    public struct Ownership: Sendable, Equatable {
        public let owner: String
        public let group: String
        public init(owner: String, group: String) {
            self.owner = owner
            self.group = group
        }
    }

    /// The current owner and group names, or nil if they can't be read.
    public static func read(_ url: URL) -> Ownership? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let owner = attributes[.ownerAccountName] as? String,
            let group = attributes[.groupOwnerAccountName] as? String
        else { return nil }
        return Ownership(owner: owner, group: group)
    }

    public static func userID(_ name: String) -> UInt32? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.utf8.contains(0) else { return nil }
        if let id = UInt32(name), id != .max { return id }
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        return buffer.withUnsafeMutableBufferPointer {
            guard getpwnam_r(name, &record, $0.baseAddress, $0.count, &result) == 0,
                result != nil
            else { return nil }
            return record.pw_uid
        }
    }

    public static func groupID(_ name: String) -> UInt32? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.utf8.contains(0) else { return nil }
        if let id = UInt32(name), id != .max { return id }
        var record = group()
        var result: UnsafeMutablePointer<group>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        return buffer.withUnsafeMutableBufferPointer {
            guard getgrnam_r(name, &record, $0.baseAddress, $0.count, &result) == 0,
                result != nil
            else { return nil }
            return record.gr_gid
        }
    }

    /// A `sudo chown` command for the terminal route. `owner` (and optional `group`) is applied to
    /// every path; recursive adds `-R`. Paths and names are shell-quoted. Empty owner yields "".
    public static func sudoChownCommand(
        owner: String, group: String?, recursive: Bool, paths: [String]
    ) -> String {
        let ownerName = owner.trimmingCharacters(in: .whitespaces)
        guard !ownerName.isEmpty, !paths.isEmpty else { return "" }
        var spec = quote(ownerName)
        if let group = group?.trimmingCharacters(in: .whitespaces), !group.isEmpty {
            spec = quote("\(ownerName):\(group)")
        }
        let quotedPaths = paths.map(quote).joined(separator: " ")
        return "sudo chown \(recursive ? "-R " : "")\(spec) \(quotedPaths)"
    }

    /// Single-quote for /bin/sh, escaping embedded single quotes.
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
