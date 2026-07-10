import Foundation

/// The line-delimited JSON control protocol between the Pathem app and the `pathem-torrentd`
/// daemon. The app writes one `Command` per line to the daemon's stdin; the daemon writes one
/// `Event` per line to its stdout (a direct reply, or an unsolicited status broadcast).
public enum TorrentControl {
    public enum Op: String, Codable, Sendable {
        case add          // add a .torrent (torrentPath) or magnet (magnet), starting it
        case remove       // remove a torrent, keeping downloaded files
        case removeData   // remove a torrent and delete its downloaded files
        case pause
        case resume
        case list         // request an immediate status snapshot
        case setLimits    // set global speed caps (downLimit / upLimit, bytes/sec, 0 = unlimited)
        case files        // request a torrent's file list (infoHash)
        case setFiles     // set which files to download (infoHash + wantedFiles)
    }

    public struct Command: Codable, Sendable {
        public var op: Op
        public var id: Int                 // correlates a reply to this command
        public var infoHash: String?
        public var torrentPath: String?
        public var magnet: String?
        public var savePath: String?
        public var downLimit: Int?
        public var upLimit: Int?
        public var superSeed: Bool?
        public var encryptOutgoing: Bool?
        public var preferUTP: Bool?
        public var bindToVPN: Bool?
        public var wantedFiles: [Int]?

        public init(
            op: Op, id: Int = 0, infoHash: String? = nil, torrentPath: String? = nil,
            magnet: String? = nil, savePath: String? = nil, downLimit: Int? = nil, upLimit: Int? = nil,
            superSeed: Bool? = nil, encryptOutgoing: Bool? = nil, preferUTP: Bool? = nil,
            bindToVPN: Bool? = nil, wantedFiles: [Int]? = nil
        ) {
            self.op = op
            self.id = id
            self.infoHash = infoHash
            self.torrentPath = torrentPath
            self.magnet = magnet
            self.savePath = savePath
            self.downLimit = downLimit
            self.upLimit = upLimit
            self.superSeed = superSeed
            self.encryptOutgoing = encryptOutgoing
            self.preferUTP = preferUTP
            self.bindToVPN = bindToVPN
            self.wantedFiles = wantedFiles
        }
    }

    public enum EventKind: String, Codable, Sendable {
        case reply    // a response to a specific command (carries replyTo)
        case status   // an unsolicited periodic broadcast of all torrents
        case error
    }

    public struct Event: Codable, Sendable {
        public var kind: EventKind
        public var replyTo: Int?
        public var ok: Bool
        public var message: String?
        public var torrents: [TorrentSession.Status]?
        public var downLimit: Int?   // current global caps (bytes/sec, 0 = unlimited)
        public var upLimit: Int?
        public var superSeed: Bool?
        public var encryptOutgoing: Bool?
        public var preferUTP: Bool?
        public var bindToVPN: Bool?
        public var vpnInterface: String?          // the bound tunnel's name, nil = none/kill-switch
        public var infoHash: String?              // which torrent a files reply is for
        public var files: [TorrentSession.FileInfo]?

        public init(
            kind: EventKind, replyTo: Int? = nil, ok: Bool = true, message: String? = nil,
            torrents: [TorrentSession.Status]? = nil, downLimit: Int? = nil, upLimit: Int? = nil,
            superSeed: Bool? = nil, encryptOutgoing: Bool? = nil, preferUTP: Bool? = nil,
            bindToVPN: Bool? = nil, vpnInterface: String? = nil,
            infoHash: String? = nil, files: [TorrentSession.FileInfo]? = nil
        ) {
            self.kind = kind
            self.replyTo = replyTo
            self.ok = ok
            self.message = message
            self.torrents = torrents
            self.downLimit = downLimit
            self.upLimit = upLimit
            self.superSeed = superSeed
            self.encryptOutgoing = encryptOutgoing
            self.preferUTP = preferUTP
            self.bindToVPN = bindToVPN
            self.vpnInterface = vpnInterface
            self.infoHash = infoHash
            self.files = files
        }
    }

    /// Encode a value as one newline-terminated JSON line.
    public static func encodeLine<T: Encodable>(_ value: T) -> Data {
        var data = (try? JSONEncoder().encode(value)) ?? Data()
        data.append(0x0a)  // '\n'
        return data
    }
}
