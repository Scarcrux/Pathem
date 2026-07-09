import Foundation

/// A BitTorrent HTTP tracker client (BEP 3, compact peers per BEP 23). The URL building and
/// the response/peer parsing are pure and unit-tested; `announce` performs the actual GET.
/// UDP trackers (BEP 15) and DHT (BEP 5) are separate, later layers.
public enum Tracker {
    /// A parsed announce response: how long to wait before re-announcing, and the peers.
    public struct AnnounceResponse: Equatable, Sendable {
        public let interval: Int
        public let peers: [Peer]
        public let failureReason: String?
    }

    public struct Peer: Equatable, Sendable, Hashable {
        public let host: String
        public let port: Int
        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    public enum Event: String { case started, stopped, completed }

    /// Build an HTTP announce URL. `info_hash` and `peer_id` are raw 20-byte values that must
    /// be percent-encoded byte-by-byte (a common source of "invalid info hash" errors), which
    /// URLComponents won't do, so the query is assembled by hand.
    public static func announceURL(
        base: String, infoHash: Data, peerID: Data, port: Int,
        uploaded: Int64 = 0, downloaded: Int64 = 0, left: Int64, compact: Bool = true,
        event: Event? = nil, numwant: Int = 50
    ) -> URL? {
        var query = "info_hash=\(percentEncode(infoHash))&peer_id=\(percentEncode(peerID))"
        query += "&port=\(port)&uploaded=\(uploaded)&downloaded=\(downloaded)&left=\(left)"
        query += "&compact=\(compact ? 1 : 0)&numwant=\(numwant)"
        if let event { query += "&event=\(event.rawValue)" }
        return URL(string: base + (base.contains("?") ? "&" : "?") + query)
    }

    /// Percent-encode raw bytes for a URL query, escaping everything except RFC 3986 unreserved.
    static func percentEncode(_ data: Data) -> String {
        let unreserved = Set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8)
        var out = ""
        out.reserveCapacity(data.count * 3)
        for byte in data {
            if unreserved.contains(byte) {
                out.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Parse a compact peer list (BEP 23): 6 bytes per peer, 4-byte IPv4 + 2-byte big-endian port.
    public static func parseCompactPeers(_ data: Data) -> [Peer] {
        let bytes = [UInt8](data)
        var peers: [Peer] = []
        var i = 0
        while i + 6 <= bytes.count {
            let host = "\(bytes[i]).\(bytes[i + 1]).\(bytes[i + 2]).\(bytes[i + 3])"
            let port = Int(bytes[i + 4]) << 8 | Int(bytes[i + 5])
            peers.append(Peer(host: host, port: port))
            i += 6
        }
        return peers
    }

    /// Parse a bencoded tracker response: `failure reason`, `interval`, and `peers` (either the
    /// compact byte string or a list of {ip, port} dictionaries).
    public static func parseResponse(_ data: Data) throws -> AnnounceResponse {
        let top = try BencodeDecoder.decode(data)
        if let failure = top["failure reason"]?.string {
            return AnnounceResponse(interval: 0, peers: [], failureReason: failure)
        }
        let interval = Int(top["interval"]?.intValue ?? 0)
        var peers: [Peer] = []
        switch top["peers"] {
        case .bytes(let compact):
            peers = parseCompactPeers(compact)
        case .list(let entries):
            for entry in entries {
                if let ip = entry["ip"]?.string, let port = entry["port"]?.intValue {
                    peers.append(Peer(host: ip, port: Int(port)))
                }
            }
        default:
            break
        }
        return AnnounceResponse(interval: interval, peers: peers, failureReason: nil)
    }

    /// Announce to an HTTP(S) tracker and return its peers. Networking only; the URL and the
    /// response parsing above are what the tests cover.
    public static func announce(
        base: String, infoHash: Data, peerID: Data, port: Int, left: Int64,
        event: Event? = nil, session: URLSession = .shared
    ) async throws -> AnnounceResponse {
        guard let url = announceURL(base: base, infoHash: infoHash, peerID: peerID, port: port, left: left, event: event)
        else { throw TrackerError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw TrackerError.http(http.statusCode)
        }
        return try parseResponse(data)
    }

    public enum TrackerError: Error, Equatable { case badURL, http(Int) }

    /// A fresh 20-byte peer id with the Azureus-style client prefix "-PM0001-".
    public static func makePeerID() -> Data {
        var id = Data("-PM0001-".utf8)  // "PM" = Pathem, version 0001
        while id.count < 20 { id.append(UInt8.random(in: 0...255)) }
        return id.prefix(20)
    }
}
