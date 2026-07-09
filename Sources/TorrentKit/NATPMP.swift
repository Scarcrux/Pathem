import Foundation

/// The NAT-PMP protocol (RFC 6886) for asking a home router to forward an external port to us, so
/// peers behind the same kind of NAT most home users have can actually reach our listener. The
/// message codec here is pure and unit-tested; NATPMPClient talks to the gateway over UDP.
public enum NATPMP {
    /// A request for the router's public IP address (opcode 0).
    public static func externalAddressRequest() -> Data { Data([0, 0]) }

    /// Parse the external-address response; returns the public IPv4 string, or nil on error.
    public static func parseExternalAddress(_ data: Data) -> String? {
        let b = [UInt8](data)
        guard b.count >= 12, b[0] == 0, b[1] == 128, (UInt16(b[2]) << 8 | UInt16(b[3])) == 0 else { return nil }
        return "\(b[8]).\(b[9]).\(b[10]).\(b[11])"
    }

    /// Build a port-mapping request: map an external port to our internal port for `lifetime`
    /// seconds. Opcode 1 maps UDP, 2 maps TCP.
    public static func mapRequest(
        internalPort: UInt16, suggestedExternalPort: UInt16, tcp: Bool, lifetime: UInt32 = 3600
    ) -> Data {
        var data = Data([0, tcp ? 2 : 1, 0, 0])  // version, opcode, 2 reserved bytes
        data.append(contentsOf: be16(internalPort))
        data.append(contentsOf: be16(suggestedExternalPort))
        data.append(contentsOf: be32(lifetime))
        return data
    }

    public struct MapResult: Equatable, Sendable {
        public let resultCode: UInt16
        public let internalPort: UInt16
        public let externalPort: UInt16
        public let lifetime: UInt32
        public var ok: Bool { resultCode == 0 }
    }

    /// Parse a port-mapping response (16 bytes). Returns nil if it isn't a mapping response for the
    /// requested protocol.
    public static func parseMapResponse(_ data: Data, tcp: Bool) -> MapResult? {
        let b = [UInt8](data)
        guard b.count >= 16, b[0] == 0, b[1] == (tcp ? 2 : 1) + 128 else { return nil }
        return MapResult(
            resultCode: UInt16(b[2]) << 8 | UInt16(b[3]),
            internalPort: UInt16(b[8]) << 8 | UInt16(b[9]),
            externalPort: UInt16(b[10]) << 8 | UInt16(b[11]),
            lifetime: UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
    }

    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    }
}
