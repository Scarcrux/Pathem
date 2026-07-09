import CryptoKit
import Foundation

/// The metadata read from a .torrent file: enough to show a user what it contains and to
/// hand it to a download engine. Pure data derived from the bencode; no networking.
public struct TorrentFile: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let path: String  // "/"-joined relative path
        public let length: Int64
    }
    public let name: String
    public let totalLength: Int64
    public let files: [Entry]  // one entry for a single-file torrent
    public let pieceLength: Int64
    public let pieceCount: Int
    public let trackers: [String]  // announce + flattened announce-list, de-duplicated
    public let infoHashHex: String  // SHA-1 of the raw info dict, lowercase hex
    public let comment: String?
    public let createdBy: String?
    public let isPrivate: Bool

    /// A magnet URI (xt = info hash, dn = name, tr = each tracker).
    public var magnetLink: String {
        var s = "magnet:?xt=urn:btih:\(infoHashHex)"
        if let dn = name.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) {
            s += "&dn=\(dn)"
        }
        for tracker in trackers {
            if let tr = tracker.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) {
                s += "&tr=\(tr)"
            }
        }
        return s
    }

    public enum ParseError: Error, Equatable { case notATorrent(String) }

    /// Parse a .torrent file's bytes into metadata (throws on malformed input).
    public static func parse(_ data: Data) throws -> TorrentFile {
        let (top, infoBytes) = try BencodeDecoder.decodeTorrent(data)
        guard let info = top["info"] else { throw ParseError.notATorrent("missing info dictionary") }
        let name = info["name"]?.string ?? "unnamed"
        let pieceLength = info["piece length"]?.intValue ?? 0
        let pieceCount = (info["pieces"].flatMap { if case .bytes(let d) = $0 { return d.count / 20 } else { return nil } }) ?? 0
        let isPrivate = (info["private"]?.intValue ?? 0) != 0

        var files: [Entry] = []
        if let length = info["length"]?.intValue {
            files = [Entry(path: name, length: length)]  // single-file torrent
        } else if let list = info["files"]?.list {
            for f in list {
                let len = f["length"]?.intValue ?? 0
                let parts = (f["path"]?.list ?? []).compactMap { $0.string }
                files.append(Entry(path: parts.joined(separator: "/"), length: len))
            }
        }
        let total = files.reduce(Int64(0)) { $0 + $1.length }

        var trackers: [String] = []
        if let announce = top["announce"]?.string { trackers.append(announce) }
        if let tiers = top["announce-list"]?.list {
            for tier in tiers {
                for url in (tier.list ?? []) { if let s = url.string { trackers.append(s) } }
            }
        }
        var seen = Set<String>()
        trackers = trackers.filter { seen.insert($0).inserted }  // de-dupe, keep order

        let hash = Insecure.SHA1.hash(data: infoBytes).map { String(format: "%02x", $0) }.joined()

        return TorrentFile(
            name: name, totalLength: total, files: files, pieceLength: pieceLength,
            pieceCount: pieceCount, trackers: trackers, infoHashHex: hash,
            comment: top["comment"]?.string, createdBy: top["created by"]?.string,
            isPrivate: isPrivate)
    }

    /// Parse a .torrent at a path.
    public static func parse(contentsOf url: URL) throws -> TorrentFile {
        try parse(Data(contentsOf: url))
    }
}

extension CharacterSet {
    /// Query-value-safe set (RFC 3986 unreserved), so magnet parameters escape correctly.
    fileprivate static let urlQueryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
