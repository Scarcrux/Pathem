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
}
