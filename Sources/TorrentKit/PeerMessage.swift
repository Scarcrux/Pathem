import Foundation

/// The BitTorrent peer wire protocol (BEP 3): the 68-byte handshake and the length-prefixed
/// messages exchanged over a peer TCP connection. Pure encode/decode; the socket layer is
/// separate. `parse` reads one message from the front of a buffer and reports how many bytes it
/// consumed, so a caller can drive it over a growing stream.
public enum PeerMessage: Equatable, Sendable {
    case keepAlive
    case choke
    case unchoke
    case interested
    case notInterested
    case have(pieceIndex: UInt32)
    case bitfield(Data)
    case request(index: UInt32, begin: UInt32, length: UInt32)
    case piece(index: UInt32, begin: UInt32, block: Data)
    case cancel(index: UInt32, begin: UInt32, length: UInt32)
    case port(UInt16)  // DHT port (BEP 5)

    enum ID: UInt8 {
        case choke = 0, unchoke = 1, interested = 2, notInterested = 3
        case have = 4, bitfield = 5, request = 6, piece = 7, cancel = 8, port = 9
    }

    /// Serialize to wire bytes: a 4-byte big-endian length prefix, then (for non-keepalive) a
    /// 1-byte id and the payload. A zero-length message is keep-alive.
    public var encoded: Data {
        switch self {
        case .keepAlive:
            return be32(0)
        case .choke: return message(.choke)
        case .unchoke: return message(.unchoke)
        case .interested: return message(.interested)
        case .notInterested: return message(.notInterested)
        case .have(let index):
            return message(.have, be32(index))
        case .bitfield(let bits):
            return message(.bitfield, bits)
        case .request(let index, let begin, let length):
            return message(.request, be32(index) + be32(begin) + be32(length))
        case .piece(let index, let begin, let block):
            return message(.piece, be32(index) + be32(begin) + block)
        case .cancel(let index, let begin, let length):
            return message(.cancel, be32(index) + be32(begin) + be32(length))
        case .port(let p):
            return message(.port, Data([UInt8(p >> 8), UInt8(p & 0xff)]))
        }
    }

    /// Try to read one message from the front of `buffer`. Returns the message and the number of
    /// bytes consumed, or nil if the buffer doesn't yet hold a complete message.
    public static func parse(_ buffer: Data) -> (message: PeerMessage, consumed: Int)? {
        guard buffer.count >= 4 else { return nil }
        let bytes = [UInt8](buffer)
        let length = Int(readBE32(bytes, 0))
        guard buffer.count >= 4 + length else { return nil }  // wait for the full message
        if length == 0 { return (.keepAlive, 4) }
        guard let id = ID(rawValue: bytes[4]) else {
            return (.keepAlive, 4 + length)  // unknown id: skip its bytes, treat as no-op
        }
        let payload = Array(bytes[5..<(4 + length)])
        let consumed = 4 + length
        switch id {
        case .choke: return (.choke, consumed)
        case .unchoke: return (.unchoke, consumed)
        case .interested: return (.interested, consumed)
        case .notInterested: return (.notInterested, consumed)
        case .have where payload.count >= 4:
            return (.have(pieceIndex: readBE32(payload, 0)), consumed)
        case .bitfield:
            return (.bitfield(Data(payload)), consumed)
        case .request where payload.count >= 12:
            return (.request(index: readBE32(payload, 0), begin: readBE32(payload, 4), length: readBE32(payload, 8)), consumed)
        case .piece where payload.count >= 8:
            return (.piece(index: readBE32(payload, 0), begin: readBE32(payload, 4), block: Data(payload[8...])), consumed)
        case .cancel where payload.count >= 12:
            return (.cancel(index: readBE32(payload, 0), begin: readBE32(payload, 4), length: readBE32(payload, 8)), consumed)
        case .port where payload.count >= 2:
            return (.port(UInt16(payload[0]) << 8 | UInt16(payload[1])), consumed)
        default:
            return (.keepAlive, consumed)  // malformed payload: skip
        }
    }

    // MARK: helpers

    private func message(_ id: ID, _ payload: Data = Data()) -> Data {
        var out = be32(UInt32(1 + payload.count))
        out.append(id.rawValue)
        out.append(payload)
        return out
    }
}

/// The peer handshake: <19>"BitTorrent protocol"<8 reserved><20 info hash><20 peer id> = 68 bytes.
public struct PeerHandshake: Equatable, Sendable {
    public static let protocolString = "BitTorrent protocol"
    public let infoHash: Data
    public let peerID: Data
    public let reserved: Data

    public init(infoHash: Data, peerID: Data, reserved: Data = Data(count: 8)) {
        self.infoHash = infoHash
        self.peerID = peerID
        self.reserved = reserved
    }

    public var encoded: Data {
        var out = Data([UInt8(Self.protocolString.utf8.count)])
        out.append(Data(Self.protocolString.utf8))
        out.append(reserved.count == 8 ? reserved : Data(count: 8))
        out.append(infoHash.prefix(20))
        out.append(peerID.prefix(20))
        return out
    }

    /// Decode a 68-byte handshake; nil if the length or protocol string is wrong.
    public static func parse(_ data: Data) -> PeerHandshake? {
        let bytes = [UInt8](data)
        guard bytes.count >= 68, bytes[0] == 19 else { return nil }
        let proto = String(decoding: bytes[1..<20], as: UTF8.self)
        guard proto == protocolString else { return nil }
        return PeerHandshake(
            infoHash: Data(bytes[28..<48]),
            peerID: Data(bytes[48..<68]),
            reserved: Data(bytes[20..<28]))
    }
}

// MARK: big-endian byte helpers

func be32(_ v: UInt32) -> Data {
    Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
}

func readBE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
        | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
}
