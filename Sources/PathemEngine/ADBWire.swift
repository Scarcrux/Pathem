import Foundation

/// Pure framing for the adb server protocol: host requests (4 hex digits of length, then the
/// text), the 8-byte sync headers (a 4-letter id and a little-endian length), and the
/// little-endian structs of LIST and STAT. No sockets here, so it is tested directly.
public enum ADBWire {
    /// The largest DATA payload a sync SEND may carry.
    public static let maxChunk = 64 * 1024

    /// `host:version` becomes `000chost:version`.
    public static func hostRequest(_ text: String) -> Data {
        let payload = Data(text.utf8)
        return Data(String(format: "%04x", payload.count).utf8) + payload
    }

    public static func hexLength(_ digits: Data) throws -> Int {
        guard digits.count == 4,
            digits.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }),
            let text = String(data: digits, encoding: .ascii),
            let value = Int(text, radix: 16)
        else { throw ADBError.protocolFailure("a bad length prefix") }
        return value
    }

    /// An id and a length field with no payload (DONE carries the mtime there).
    public static func syncHeader(_ id: String, _ value: UInt32) -> Data {
        precondition(id.utf8.count == 4)
        var data = Data(id.utf8)
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        return data
    }

    /// An id, the payload length and the payload; every sync request and DATA chunk frames
    /// its payload this way.
    public static func syncRequest(_ id: String, _ payload: Data) -> Data {
        syncHeader(id, UInt32(payload.count)) + payload
    }

    public static func uint32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else {
            throw ADBError.protocolFailure("a short reply")
        }
        let base = data.startIndex + offset
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[base + $1]) << (8 * UInt32($1)) }
    }

    public static func uint64(_ data: Data, at offset: Int) throws -> UInt64 {
        UInt64(try uint32(data, at: offset)) | UInt64(try uint32(data, at: offset + 4)) << 32
    }

    public static func date(_ seconds: Int64) -> Date? {
        seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
    }

    /// The attributes in a v2 stat or dirent body (after the 4-byte id):
    /// error, dev, ino, mode, nlink, uid, gid, size, atime, mtime, ctime.
    static func parseStatV2(_ body: Data, at base: Int) throws -> (
        mode: UInt32, size: UInt64, modified: Date?
    ) {
        (
            mode: try uint32(body, at: base + 20),
            size: try uint64(body, at: base + 36),
            modified: date(Int64(bitPattern: try uint64(body, at: base + 52)))
        )
    }

    /// Parse `host:devices-l` text: `serial  state  usb:.. product:.. model:Pixel_8 ...`.
    public static func parseDevices(_ text: String) -> [ADBDevice] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { return nil }
            let model = fields.first { $0.hasPrefix("model:") }.map {
                String($0.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
            }
            return ADBDevice(
                serial: fields[0], state: fields[1], model: (model?.isEmpty ?? true) ? nil : model)
        }
    }
}
