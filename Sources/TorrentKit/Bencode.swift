import Foundation

/// A decoded bencode value (the encoding used by .torrent files and the BitTorrent
/// protocol). Dictionaries keep their entries as ordered (key, value) pairs so the
/// exact byte range of a nested value (the `info` dict, for the info hash) can be
/// recovered during parsing. Keys in .torrent files are ASCII, kept as Strings.
public indirect enum Bencode: Equatable, Sendable {
    case int(Int64)
    case bytes(Data)
    case list([Bencode])
    case dict([(String, Bencode)])

    // The dict case holds tuples (to preserve order), which blocks synthesized Equatable.
    public static func == (lhs: Bencode, rhs: Bencode) -> Bool {
        switch (lhs, rhs) {
        case (.int(let a), .int(let b)): return a == b
        case (.bytes(let a), .bytes(let b)): return a == b
        case (.list(let a), .list(let b)): return a == b
        case (.dict(let a), .dict(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    /// The UTF-8 string form of a `.bytes` value (nil for other cases or invalid UTF-8).
    public var string: String? {
        if case .bytes(let d) = self { return String(data: d, encoding: .utf8) }
        return nil
    }
    public var intValue: Int64? { if case .int(let n) = self { return n } else { return nil } }
    public var list: [Bencode]? { if case .list(let l) = self { return l } else { return nil } }

    /// Look up a key in a `.dict` value.
    public subscript(_ key: String) -> Bencode? {
        guard case .dict(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    /// Serialize to canonical bencode (dictionary keys sorted by raw bytes, as the spec requires).
    /// Used to build the small extension-protocol messages we send; the info dict is never
    /// re-encoded (its bytes are preserved from the wire so its hash stays intact).
    public var encoded: Data {
        switch self {
        case .int(let n):
            return Data("i\(n)e".utf8)
        case .bytes(let d):
            var out = Data("\(d.count):".utf8)
            out.append(d)
            return out
        case .list(let items):
            var out = Data("l".utf8)
            for item in items { out.append(item.encoded) }
            out.append(0x65)  // 'e'
            return out
        case .dict(let pairs):
            var out = Data("d".utf8)
            for (key, value) in pairs.sorted(by: { $0.0 < $1.0 }) {
                out.append(Data("\(key.utf8.count):\(key)".utf8))
                out.append(value.encoded)
            }
            out.append(0x65)  // 'e'
            return out
        }
    }

    /// Convenience for building a bencoded dictionary from key/value pairs.
    public static func dictionary(_ pairs: [(String, Bencode)]) -> Bencode { .dict(pairs) }
}

/// A recursive-descent bencode decoder over raw bytes. Strict: malformed input throws
/// rather than guessing, and it tracks byte offsets so a caller can grab the raw bytes of a
/// nested value (needed to hash the `info` dict exactly as it appeared on disk).
public struct BencodeDecoder {
    public enum DecodeError: Error, Equatable {
        case unexpectedEnd
        case invalid(String)
    }

    private let data: [UInt8]
    private var i = 0
    private var depth = 0

    /// Cap on nested containers, so an adversarial `llll…` or `dddd…` from the network can't recurse
    /// the parser into a stack overflow. Real torrents and KRPC messages nest only a few levels.
    private static let maxDepth = 100

    public init(_ data: Data) { self.data = [UInt8](data) }

    /// Decode a single top-level value.
    public static func decode(_ data: Data) throws -> Bencode {
        var d = BencodeDecoder(data)
        let value = try d.parseValue()
        return value
    }

    /// Decode the first bencoded value and report how many bytes it consumed. Used for the
    /// ut_metadata data message, where a bencoded header is immediately followed by raw bytes.
    public static func decodePrefix(_ data: Data) throws -> (value: Bencode, consumed: Int) {
        var d = BencodeDecoder(data)
        let value = try d.parseValue()
        return (value, d.i)
    }

    /// Decode a .torrent's top dictionary, also returning the raw bytes of its `info` value
    /// (so the caller can SHA-1 it for the info hash). Throws if there's no info dict.
    public static func decodeTorrent(_ data: Data) throws -> (top: Bencode, infoBytes: Data) {
        var d = BencodeDecoder(data)
        guard d.peek() == UInt8(ascii: "d") else {
            throw DecodeError.invalid("a torrent must be a bencoded dictionary")
        }
        var infoRange: Range<Int>?
        d.i += 1  // consume 'd'
        var pairs: [(String, Bencode)] = []
        while d.peek() != UInt8(ascii: "e") {
            let keyData = try d.parseByteString()
            let key = String(decoding: keyData, as: UTF8.self)
            let start = d.i
            let value = try d.parseValue()
            if key == "info" { infoRange = start..<d.i }
            pairs.append((key, value))
        }
        d.i += 1  // consume 'e'
        guard let infoRange else { throw DecodeError.invalid("no info dictionary") }
        return (.dict(pairs), Data(d.data[infoRange]))
    }

    // MARK: parsing

    private func peek() -> UInt8? { i < data.count ? data[i] : nil }

    private mutating func parseValue() throws -> Bencode {
        guard let c = peek() else { throw DecodeError.unexpectedEnd }
        switch c {
        case UInt8(ascii: "i"): return .int(try parseInt())
        case UInt8(ascii: "l"): return .list(try parseList())
        case UInt8(ascii: "d"): return try parseDict()
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return .bytes(Data(try parseByteString()))
        default: throw DecodeError.invalid("unexpected byte \(c) at \(i)")
        }
    }

    /// Enter a nested container, enforcing the depth cap.
    private mutating func enter() throws {
        depth += 1
        guard depth <= Self.maxDepth else { throw DecodeError.invalid("nesting too deep") }
    }

    private mutating func parseInt() throws -> Int64 {
        i += 1  // 'i'
        var digits = [UInt8]()
        while let c = peek(), c != UInt8(ascii: "e") { digits.append(c); i += 1 }
        guard peek() == UInt8(ascii: "e") else { throw DecodeError.unexpectedEnd }
        i += 1  // 'e'
        guard let n = Int64(String(decoding: digits, as: UTF8.self)) else {
            throw DecodeError.invalid("bad integer")
        }
        return n
    }

    private mutating func parseByteString() throws -> [UInt8] {
        var lenDigits = [UInt8]()
        while let c = peek(), c != UInt8(ascii: ":") { lenDigits.append(c); i += 1 }
        guard peek() == UInt8(ascii: ":") else { throw DecodeError.unexpectedEnd }
        i += 1  // ':'
        guard let len = Int(String(decoding: lenDigits, as: UTF8.self)), len >= 0,
            i + len <= data.count
        else { throw DecodeError.invalid("bad string length") }
        let bytes = Array(data[i..<(i + len)])
        i += len
        return bytes
    }

    private mutating func parseList() throws -> [Bencode] {
        try enter()
        defer { depth -= 1 }
        i += 1  // 'l'
        var items = [Bencode]()
        while peek() != UInt8(ascii: "e") { items.append(try parseValue()) }
        guard peek() == UInt8(ascii: "e") else { throw DecodeError.unexpectedEnd }
        i += 1  // 'e'
        return items
    }

    private mutating func parseDict() throws -> Bencode {
        try enter()
        defer { depth -= 1 }
        i += 1  // 'd'
        var pairs = [(String, Bencode)]()
        while peek() != UInt8(ascii: "e") {
            let key = String(decoding: try parseByteString(), as: UTF8.self)
            pairs.append((key, try parseValue()))
        }
        guard peek() == UInt8(ascii: "e") else { throw DecodeError.unexpectedEnd }
        i += 1  // 'e'
        return .dict(pairs)
    }
}
