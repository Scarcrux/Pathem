import Foundation

/// Codec for Apple File Conduit (AFC), the binary protocol that rides over the lockdown
/// `com.apple.afc` service to read and write a device's media filesystem. This is layer 3
/// of the native iOS client: pure byte work (no I/O), so it is fully unit-tested. The
/// transport that carries these packets over a TLS lockdown tunnel is layer 2 (pending a
/// device to validate against).
///
/// Wire format: a 40-byte little-endian header { magic "CFA6LPAA", entire_length,
/// this_length, packet_num, operation } followed by the operation payload.
public enum AFCPacket {
    public static let magic = Data("CFA6LPAA".utf8)  // 8 bytes
    public static let headerSize = 40

    public enum Op: UInt64 {
        case status = 0x0000_0001
        case data = 0x0000_0002
        case readDir = 0x0000_0003
        case getFileInfo = 0x0000_000A
        case removePath = 0x0000_0008
        case makeDir = 0x0000_0009
        case fileOpen = 0x0000_000D
        case fileRead = 0x0000_000F
        case fileWrite = 0x0000_0010
        case fileClose = 0x0000_0014
        case renamePath = 0x0000_0018
    }

    public struct Header: Equatable {
        public let entireLength: UInt64
        public let thisLength: UInt64
        public let packetNum: UInt64
        public let operation: UInt64
    }

    /// Encode one AFC packet (header + payload).
    public static func encode(_ operation: Op, packetNum: UInt64, payload: Data) -> Data {
        var data = magic
        let entire = UInt64(headerSize + payload.count)
        appendUInt64(&data, entire)  // entire_length
        appendUInt64(&data, entire)  // this_length (single-chunk packets)
        appendUInt64(&data, packetNum)
        appendUInt64(&data, operation.rawValue)
        data.append(payload)
        return data
    }

    /// Decode a 40-byte header, validating the magic. Returns nil if malformed.
    public static func decodeHeader(_ header: Data) -> Header? {
        guard header.count >= headerSize, header.prefix(8) == magic else { return nil }
        let base = header.startIndex + 8
        return Header(
            entireLength: readUInt64(header, at: base),
            thisLength: readUInt64(header, at: base + 8),
            packetNum: readUInt64(header, at: base + 16),
            operation: readUInt64(header, at: base + 24))
    }

    // MARK: Payload builders

    /// A single null-terminated path (READ_DIR, GET_FILE_INFO, MAKE_DIR, REMOVE_PATH).
    public static func pathPayload(_ path: String) -> Data {
        var data = Data(path.utf8)
        data.append(0)
        return data
    }

    /// Two null-terminated paths (RENAME_PATH): from\0to\0.
    public static func renamePayload(from: String, to: String) -> Data {
        var data = Data(from.utf8)
        data.append(0)
        data.append(contentsOf: to.utf8)
        data.append(0)
        return data
    }

    // MARK: Response parsers

    /// Split a DATA payload into its null-separated strings (drops a trailing empty).
    public static func nullSeparatedStrings(_ payload: Data) -> [String] {
        payload.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
            .filter { !$0.isEmpty }
    }

    /// READ_DIR result: entry names, with "." and ".." removed.
    public static func directoryEntries(_ payload: Data) -> [String] {
        nullSeparatedStrings(payload).filter { $0 != "." && $0 != ".." }
    }

    /// GET_FILE_INFO result: key/value pairs (st_size, st_ifmt, st_mtime, ...).
    public static func fileInfo(_ payload: Data) -> [String: String] {
        let parts = nullSeparatedStrings(payload)
        var info: [String: String] = [:]
        var index = 0
        while index + 1 < parts.count {
            info[parts[index]] = parts[index + 1]
            index += 2
        }
        return info
    }

    public static func isDirectory(_ info: [String: String]) -> Bool {
        info["st_ifmt"] == "S_IFDIR"
    }

    public static func size(_ info: [String: String]) -> Int64 {
        Int64(info["st_size"] ?? "") ?? 0
    }

    /// STATUS payload carries a single uint64 error code (0 == success).
    public static func status(_ payload: Data) -> UInt64? {
        guard payload.count >= 8 else { return nil }
        return readUInt64(payload, at: payload.startIndex)
    }

    // MARK: Little-endian helpers

    static func appendUInt64(_ data: inout Data, _ value: UInt64) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    static func readUInt64(_ data: Data, at index: Data.Index) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(data[index + i]) << (8 * i) }
        return value
    }
}
