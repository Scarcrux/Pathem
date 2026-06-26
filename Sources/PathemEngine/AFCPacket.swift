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
        case removePath = 0x0000_0008
        case makeDir = 0x0000_0009
        case getFileInfo = 0x0000_000A
        case fileOpen = 0x0000_000D
        case fileOpenResult = 0x0000_000E
        case fileRead = 0x0000_000F
        case fileWrite = 0x0000_0010
        case fileClose = 0x0000_0014
        case renamePath = 0x0000_0018
    }

    /// AFC file-open modes.
    public enum OpenMode: UInt64 {
        case read = 0x0000_0001  // AFC_FOPEN_RDONLY
        case write = 0x0000_0003  // AFC_FOPEN_WRONLY (create + truncate)
    }

    public struct Header: Equatable {
        public let entireLength: UInt64
        public let thisLength: UInt64
        public let packetNum: UInt64
        public let operation: UInt64
    }

    /// Encode an AFC packet whose entire payload is the operation header (this_length ==
    /// entire_length). Used by every op except FILE_WRITE.
    public static func encode(_ operation: Op, packetNum: UInt64, payload: Data) -> Data {
        encode(operation, packetNum: packetNum, header: payload, data: Data())
    }

    /// Encode an AFC packet with a distinct header payload and trailing data. `this_length`
    /// covers the header (40 + header.count); `entire_length` also covers the data. FILE_WRITE
    /// needs this: the 8-byte handle is the header, the file bytes are the data.
    public static func encode(_ operation: Op, packetNum: UInt64, header: Data, data: Data) -> Data {
        var packet = magic
        let thisLength = UInt64(headerSize + header.count)
        appendUInt64(&packet, thisLength + UInt64(data.count))  // entire_length
        appendUInt64(&packet, thisLength)  // this_length
        appendUInt64(&packet, packetNum)
        appendUInt64(&packet, operation.rawValue)
        packet.append(header)
        packet.append(data)
        return packet
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

    /// FILE_OPEN: uint64 mode followed by the null-terminated path.
    public static func openPayload(mode: OpenMode, path: String) -> Data {
        var data = Data()
        appendUInt64(&data, mode.rawValue)
        data.append(contentsOf: path.utf8)
        data.append(0)
        return data
    }

    /// FILE_READ: uint64 handle + uint64 length.
    public static func readPayload(handle: UInt64, length: UInt64) -> Data {
        var data = Data()
        appendUInt64(&data, handle)
        appendUInt64(&data, length)
        return data
    }

    /// FILE_WRITE / FILE_CLOSE prefix: uint64 handle, optionally followed by data.
    public static func handlePayload(_ handle: UInt64, appending data: Data = Data()) -> Data {
        var out = Data()
        appendUInt64(&out, handle)
        out.append(data)
        return out
    }

    /// FILE_OPEN result payload carries the 8-byte file handle.
    public static func handle(_ payload: Data) -> UInt64? {
        guard payload.count >= 8 else { return nil }
        return readUInt64(payload, at: payload.startIndex)
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
