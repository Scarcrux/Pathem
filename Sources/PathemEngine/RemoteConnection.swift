import Foundation

/// A saved remote server (FTP / FTPS / SFTP). Stored as config-as-data
/// (connections.json); passwords are NOT kept here (they belong in the Keychain
/// or are prompted on connect). Networking happens out-of-process, never in the
/// Full-Disk-Access app process.
public struct RemoteConnection: Codable, Sendable, Equatable, Identifiable {
    public enum Proto: String, Codable, Sendable, CaseIterable {
        case ftp, ftps, sftp, webdav, webdavs, s3, azure, adb, afc
        public var defaultPort: Int {
            switch self {
            case .sftp: return 22
            case .ftp, .ftps: return 21
            case .webdav: return 80
            case .webdavs, .s3, .azure: return 443
            case .adb, .afc: return 0  // USB devices, no network port
            }
        }
        public var label: String {
            switch self {
            case .ftp: return "FTP"
            case .ftps: return "FTPS"
            case .sftp: return "SFTP"
            case .webdav: return "WebDAV"
            case .webdavs: return "WebDAV (HTTPS)"
            case .s3: return "Amazon S3"
            case .azure: return "Azure Blob"
            case .adb: return "Android (ADB)"
            case .afc: return "iOS (AFC)"
            }
        }
        /// True for the HTTP-based WebDAV protocols.
        public var isWebDAV: Bool { self == .webdav || self == .webdavs }
        /// A USB-attached device (no host/port/password), browsed via a CLI tool.
        public var isDevice: Bool { self == .adb || self == .afc }
    }

    public var id: UUID
    public var name: String
    public var proto: Proto
    public var host: String
    public var port: Int  // 0 means "use the protocol default"
    public var user: String
    public var path: String  // initial remote directory
    public var region: String  // S3 region for SigV4 signing (e.g. "us-east-1"); unused otherwise
    /// Path to an SFTP private key (e.g. an EC2 `.pem`), or empty for password / agent auth.
    /// Only the path is stored; any passphrase is prompted at connect and never persisted.
    public var keyFile: String
    /// An optional color-label name for the site (shown as a dot in the sidebar), one of
    /// FileTag.Color's names, or empty for none.
    public var colorLabel: String
    /// An optional default local directory: on connect, the other pane opens here (a saved
    /// local-to-remote pairing). Empty leaves the local pane where it is.
    public var localPath: String
    /// Saved remote paths on this site, jumped to from the Bookmarks menu.
    public var bookmarks: [RemoteBookmark]

    public init(
        id: UUID = UUID(), name: String, proto: Proto, host: String, port: Int = 0,
        user: String = "", path: String = "/", region: String = "", keyFile: String = "",
        colorLabel: String = "", localPath: String = "", bookmarks: [RemoteBookmark] = []
    ) {
        self.id = id
        self.name = name
        self.proto = proto
        self.host = host
        self.port = port
        self.user = user
        self.path = path
        self.region = region
        self.keyFile = keyFile
        self.colorLabel = colorLabel
        self.localPath = localPath
        self.bookmarks = bookmarks
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

    /// An empty user is allowed (anonymous). A non-empty user must be a plain login
    /// name: no leading `-` (so it can't be parsed as an ssh/sftp option when it is
    /// interpolated into the `user@host` argv token), and no `@`, whitespace, or
    /// controls. Without this, a `user` like `-oProxyCommand=…` would smuggle an ssh
    /// option and run an arbitrary command in a child of the app.
    public static func isValidUser(_ user: String) -> Bool {
        guard !user.isEmpty else { return true }
        guard user.count <= 64, !user.hasPrefix("-") else { return false }
        return user.unicodeScalars.allSatisfy { Self.userAllowed.contains($0) }
    }

    private static let hostAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    private static let ipv6Allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.%")
    private static let userAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    // Tolerant decoding so a connections.json from an older build (or one bad
    // entry) doesn't fail the whole array and wipe every saved connection.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? host
        // try? for the enum: an unknown protocol falls back instead of dropping the
        // whole connection (and, in an array, every other connection with it).
        proto = (try? c.decode(Proto.self, forKey: .proto)) ?? .ftp
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "/"
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? ""
        keyFile = try c.decodeIfPresent(String.self, forKey: .keyFile) ?? ""
        colorLabel = try c.decodeIfPresent(String.self, forKey: .colorLabel) ?? ""
        localPath = try c.decodeIfPresent(String.self, forKey: .localPath) ?? ""
        bookmarks = (try? c.decodeIfPresent([RemoteBookmark].self, forKey: .bookmarks)) ?? []
    }
}

/// A saved remote path on a site, jumped to from the Bookmarks menu.
public struct RemoteBookmark: Codable, Sendable, Equatable {
    public var name: String
    public var remotePath: String
    public init(name: String, remotePath: String) {
        self.name = name
        self.remotePath = remotePath
    }
}
