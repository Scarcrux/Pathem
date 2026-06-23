import Foundation

/// A saved remote server (FTP / FTPS / SFTP). Stored as config-as-data
/// (connections.json); passwords are NOT kept here (they belong in the Keychain
/// or are prompted on connect). Networking happens out-of-process, never in the
/// Full-Disk-Access app process.
public struct RemoteConnection: Codable, Sendable, Equatable, Identifiable {
    public enum Proto: String, Codable, Sendable, CaseIterable {
        case ftp, ftps, sftp
        public var defaultPort: Int { self == .sftp ? 22 : 21 }
        public var label: String {
            switch self {
            case .ftp: return "FTP"
            case .ftps: return "FTPS"
            case .sftp: return "SFTP"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var proto: Proto
    public var host: String
    public var port: Int  // 0 means "use the protocol default"
    public var user: String
    public var path: String  // initial remote directory

    public init(
        id: UUID = UUID(), name: String, proto: Proto, host: String, port: Int = 0,
        user: String = "", path: String = "/"
    ) {
        self.id = id
        self.name = name
        self.proto = proto
        self.host = host
        self.port = port
        self.user = user
        self.path = path
    }

    public var effectivePort: Int { port > 0 ? port : proto.defaultPort }

    /// A display URL like "ftps://user@host:21/path".
    public var displayURL: String {
        let credentials = user.isEmpty ? "" : "\(user)@"
        return "\(proto.rawValue)://\(credentials)\(host):\(effectivePort)\(path)"
    }

    public var hasValidHost: Bool { Self.isValidHost(host) }

    /// A host is only a plain hostname, IPv4, or bracketed IPv6. Anything with
    /// characters that could redirect the URL authority (`@`, `/`, `\`, `?`, `#`,
    /// `:`, whitespace, controls) is rejected, so credentials can never be sent to
    /// a smuggled host.
    public static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") {  // bracketed IPv6
            let inner = host.dropFirst().dropLast()
            return !inner.isEmpty
                && inner.unicodeScalars.allSatisfy { Self.ipv6Allowed.contains($0) }
        }
        return host.unicodeScalars.allSatisfy { Self.hostAllowed.contains($0) }
    }

    private static let hostAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    private static let ipv6Allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.%")

    // Tolerant decoding so a connections.json from an older build (or one bad
    // entry) doesn't fail the whole array and wipe every saved connection.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? host
        proto = try c.decodeIfPresent(Proto.self, forKey: .proto) ?? .ftp
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "/"
    }
}
