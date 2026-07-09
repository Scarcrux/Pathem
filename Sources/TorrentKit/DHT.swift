import Foundation

/// The pure pieces of the BitTorrent DHT (BEP 5): 160-bit node IDs and XOR distance, compact node
/// parsing, and the KRPC message codec (bencoded queries/responses over UDP). The UDP socket and
/// the iterative peer lookup live in DHTClient; everything here is unit-tested.
public enum DHT {
    public static let idLength = 20  // 160-bit node IDs and info hashes

    /// A node in the DHT: its 20-byte id and address.
    public struct Node: Equatable, Sendable, Hashable {
        public let id: Data
        public let host: String
        public let port: UInt16
        public init(id: Data, host: String, port: UInt16) {
            self.id = id
            self.host = host
            self.port = port
        }
    }

    /// A fresh random 20-byte node id.
    public static func randomID() -> Data {
        var id = Data(count: idLength)
        for i in 0..<idLength { id[i] = UInt8.random(in: 0...255) }
        return id
    }

    /// Compare two ids by XOR distance to `target`: negative if `a` is closer, positive if `b` is
    /// closer, 0 if equal. Distance is the XOR of the ids read as a big-endian 160-bit number.
    public static func closer(_ a: Data, than b: Data, to target: Data) -> Int {
        let ab = [UInt8](a), bb = [UInt8](b), tb = [UInt8](target)
        for i in 0..<idLength {
            let da = (i < ab.count ? ab[i] : 0) ^ (i < tb.count ? tb[i] : 0)
            let db = (i < bb.count ? bb[i] : 0) ^ (i < tb.count ? tb[i] : 0)
            if da != db { return da < db ? -1 : 1 }
        }
        return 0
    }

    // MARK: compact encodings

    /// Parse compact node info (BEP 5): 26 bytes per node = 20-byte id + 4-byte IPv4 + 2-byte port.
    public static func parseCompactNodes(_ data: Data) -> [Node] {
        let bytes = [UInt8](data)
        var nodes: [Node] = []
        var i = 0
        while i + 26 <= bytes.count {
            let id = Data(bytes[i..<(i + 20)])
            let host = "\(bytes[i + 20]).\(bytes[i + 21]).\(bytes[i + 22]).\(bytes[i + 23])"
            let port = UInt16(bytes[i + 24]) << 8 | UInt16(bytes[i + 25])
            nodes.append(Node(id: id, host: host, port: port))
            i += 26
        }
        return nodes
    }

    // MARK: KRPC

    /// A decoded KRPC message.
    public struct Message {
        public enum Kind {
            case query(method: String, args: Bencode)
            case response(Bencode)
            case error(code: Int, message: String)
        }
        public let transaction: Data
        public let kind: Kind
    }

    public static func pingQuery(transaction: Data, nodeID: Data) -> Data {
        query(transaction, "ping", [("id", .bytes(nodeID))])
    }

    public static func findNodeQuery(transaction: Data, nodeID: Data, target: Data) -> Data {
        query(transaction, "find_node", [("id", .bytes(nodeID)), ("target", .bytes(target))])
    }

    public static func getPeersQuery(transaction: Data, nodeID: Data, infoHash: Data) -> Data {
        query(transaction, "get_peers", [("id", .bytes(nodeID)), ("info_hash", .bytes(infoHash))])
    }

    public static func announcePeerQuery(
        transaction: Data, nodeID: Data, infoHash: Data, port: Int, token: Data
    ) -> Data {
        query(
            transaction, "announce_peer",
            [
                ("id", .bytes(nodeID)), ("info_hash", .bytes(infoHash)),
                ("port", .int(Int64(port))), ("token", .bytes(token)), ("implied_port", .int(0)),
            ])
    }

    private static func query(_ transaction: Data, _ method: String, _ args: [(String, Bencode)]) -> Data {
        Bencode.dict([
            ("t", .bytes(transaction)),
            ("y", .bytes(Data("q".utf8))),
            ("q", .bytes(Data(method.utf8))),
            ("a", .dict(args)),
        ]).encoded
    }

    /// Parse a KRPC message (query, response, or error). Returns nil if it isn't well-formed.
    public static func parseMessage(_ data: Data) -> Message? {
        guard let dict = try? BencodeDecoder.decode(data),
            case .bytes(let txn)? = dict["t"],
            let y = dict["y"]?.string
        else { return nil }
        switch y {
        case "q":
            guard let method = dict["q"]?.string, let args = dict["a"] else { return nil }
            return Message(transaction: txn, kind: .query(method: method, args: args))
        case "r":
            guard let response = dict["r"] else { return nil }
            return Message(transaction: txn, kind: .response(response))
        case "e":
            guard case .list(let parts)? = dict["e"], parts.count >= 2,
                let code = parts[0].intValue, let message = parts[1].string
            else { return Message(transaction: txn, kind: .error(code: 0, message: "unknown")) }
            return Message(transaction: txn, kind: .error(code: Int(code), message: message))
        default:
            return nil
        }
    }

    /// The useful parts of a get_peers response: a token, plus either peers (`values`) or closer
    /// `nodes` to query next.
    public struct GetPeersResult: Sendable {
        public let nodeID: Data?
        public let token: Data?
        public let peers: [Tracker.Peer]
        public let nodes: [Node]
    }

    public static func parseGetPeersResponse(_ response: Bencode) -> GetPeersResult {
        let nodeID: Data? = { if case .bytes(let d)? = response["id"] { return d } else { return nil } }()
        let token: Data? = { if case .bytes(let d)? = response["token"] { return d } else { return nil } }()
        var peers: [Tracker.Peer] = []
        if case .list(let values)? = response["values"] {
            for value in values {
                if case .bytes(let compact) = value {
                    peers.append(contentsOf: Tracker.parseCompactPeers(compact))
                }
            }
        }
        var nodes: [Node] = []
        if case .bytes(let compact)? = response["nodes"] {
            nodes = parseCompactNodes(compact)
        }
        return GetPeersResult(nodeID: nodeID, token: token, peers: peers, nodes: nodes)
    }

    /// The well-known bootstrap nodes used to enter the DHT.
    public static let bootstrapNodes: [(host: String, port: UInt16)] = [
        ("router.bittorrent.com", 6881),
        ("router.utorrent.com", 6881),
        ("dht.transmissionbt.com", 6881),
    ]
}
