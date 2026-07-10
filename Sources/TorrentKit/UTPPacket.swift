import Foundation

/// A uTP packet (BEP 29 / the "micro transport protocol"): a 20-byte header over UDP plus an
/// optional payload. Pure encode/decode; the connection state machine that uses it is UTPSocket.
public struct UTPPacket: Equatable, Sendable {
    public enum PacketType: UInt8, Sendable {
        case data = 0    // ST_DATA
        case fin = 1     // ST_FIN
        case state = 2   // ST_STATE (an ack, no payload)
        case reset = 3   // ST_RESET
        case syn = 4     // ST_SYN (connection request)
    }

    public static let version: UInt8 = 1
    public static let headerLength = 20

    public var type: PacketType
    public var connectionID: UInt16
    public var timestampMicros: UInt32
    public var timestampDiffMicros: UInt32
    public var windowSize: UInt32
    public var seqNr: UInt16
    public var ackNr: UInt16
    public var payload: Data

    public init(
        type: PacketType, connectionID: UInt16, timestampMicros: UInt32 = 0,
        timestampDiffMicros: UInt32 = 0, windowSize: UInt32 = 0, seqNr: UInt16, ackNr: UInt16,
        payload: Data = Data()
    ) {
        self.type = type
        self.connectionID = connectionID
        self.timestampMicros = timestampMicros
        self.timestampDiffMicros = timestampDiffMicros
        self.windowSize = windowSize
        self.seqNr = seqNr
        self.ackNr = ackNr
        self.payload = payload
    }

    /// Serialize to wire bytes (header + payload). No extensions are emitted.
    public var encoded: Data {
        var data = Data(capacity: Self.headerLength + payload.count)
        data.append(type.rawValue << 4 | Self.version)  // type + version
        data.append(0)                                    // extension = none
        data.append(contentsOf: be16(connectionID))
        data.append(contentsOf: be32(timestampMicros))
        data.append(contentsOf: be32(timestampDiffMicros))
        data.append(contentsOf: be32(windowSize))
        data.append(contentsOf: be16(seqNr))
        data.append(contentsOf: be16(ackNr))
        data.append(payload)
        return data
    }

    /// Parse a uTP packet, skipping any extension chain to find the payload. Nil if malformed.
    public static func decode(_ data: Data) -> UTPPacket? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerLength, bytes[0] & 0x0f == version,
            let type = PacketType(rawValue: bytes[0] >> 4)
        else { return nil }

        // Walk the extension list (byte 1 is the first extension type; each ext: type, len, data).
        var offset = headerLength
        var nextExtension = bytes[1]
        while nextExtension != 0 {
            guard offset + 2 <= bytes.count else { return nil }
            let thisType = nextExtension
            nextExtension = bytes[offset]
            let length = Int(bytes[offset + 1])
            offset += 2 + length
            guard offset <= bytes.count else { return nil }
            _ = thisType
        }
        let payload = offset <= bytes.count ? Data(bytes[offset...]) : Data()

        return UTPPacket(
            type: type,
            connectionID: read16(bytes, 2),
            timestampMicros: read32(bytes, 4),
            timestampDiffMicros: read32(bytes, 8),
            windowSize: read32(bytes, 12),
            seqNr: read16(bytes, 16),
            ackNr: read16(bytes, 18),
            payload: payload)
    }

    // MARK: byte helpers

    private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    }
    private static func read16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
    private static func read32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}
