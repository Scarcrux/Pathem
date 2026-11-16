import Foundation

/// A parsed magnet URI: the info hash plus the optional display name and tracker list. A magnet
/// has no metadata (file list, piece hashes), so downloading one first fetches the info
/// dictionary from peers (BEP 9) before a normal download can begin.
public struct Magnet: Equatable, Sendable {
    public let infoHash: Data  // 20 raw bytes
    public let infoHashHex: String  // lowercase hex
    public let displayName: String?
    public let trackers: [String]
    /// `ws=` web seeds (BEP 19 HTTP sources for the payload), http and https only.
    public let webSeeds: [String]
    /// `xs=` exact sources: http(s) URLs of the .torrent file itself, so the metadata can be had
    /// without a peer. Whatever they serve is trusted only if its info hash matches `infoHash`.
    public let exactSources: [String]

    public init(
        infoHash: Data, infoHashHex: String, displayName: String?, trackers: [String],
        webSeeds: [String] = [], exactSources: [String] = []
    ) {
        self.infoHash = infoHash
        self.infoHashHex = infoHashHex
        self.displayName = displayName
        self.trackers = trackers
        self.webSeeds = webSeeds
        self.exactSources = exactSources
    }

    /// Parse a `magnet:?xt=urn:btih:...` URI. Accepts both 40-char hex and 32-char base32 info
    /// hashes. Returns nil if there's no valid btih info hash.
    public static func parse(_ uri: String) -> Magnet? {
        guard uri.lowercased().hasPrefix("magnet:?") else { return nil }
        let query = String(uri.dropFirst("magnet:?".count))

        var xtValues: [String] = []
        var name: String?
        var trackers: [String] = []
        var webSeeds: [String] = []
        var exactSources: [String] = []
        func isHTTP(_ s: String) -> Bool {
            let lower = s.lowercased()
            return lower.hasPrefix("http://") || lower.hasPrefix("https://")
        }

        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            // Magnet queries are form-encoded: '+' means space, then percent-decode.
            let raw = String(parts[1]).replacingOccurrences(of: "+", with: " ")
            let value = raw.removingPercentEncoding ?? raw
            switch key {
            case "xt": xtValues.append(value)
            case "dn": name = value
            case "tr": trackers.append(value)
            case "ws" where isHTTP(value): webSeeds.append(value)
            case "xs" where isHTTP(value): exactSources.append(value)
            default: break
            }
        }

        // Take the first xt that is a btih URN and decodes to 20 bytes.
        for xt in xtValues {
            let lower = xt.lowercased()
            guard lower.hasPrefix("urn:btih:") else { continue }
            let hashPart = String(xt.dropFirst("urn:btih:".count))
            guard let hash = decodeInfoHash(hashPart) else { continue }
            let hex = hash.map { String(format: "%02x", $0) }.joined()
            return Magnet(
                infoHash: hash, infoHashHex: hex, displayName: name, trackers: trackers,
                webSeeds: webSeeds, exactSources: exactSources)
        }
        return nil
    }

    /// Decode a btih value: 40 hex chars or 32 base32 chars, both to 20 bytes.
    static func decodeInfoHash(_ s: String) -> Data? {
        if s.count == 40 { return dataFromHex(s) }
        if s.count == 32 { return dataFromBase32(s) }
        return nil
    }

    static func dataFromHex(_ hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else {
                return nil
            }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return out
    }

    /// RFC 4648 base32 (A-Z2-7, case-insensitive) to bytes. Torrent magnets use this for the hash.
    static func dataFromBase32(_ s: String) -> Data? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var lookup: [Character: UInt8] = [:]
        for (i, c) in alphabet.enumerated() { lookup[c] = UInt8(i) }
        var bits = 0
        var value = 0
        var out = Data()
        for ch in s.uppercased() {
            guard let v = lookup[ch] else { return nil }
            value = value << 5 | Int(v)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((value >> bits) & 0xff))
            }
        }
        return out
    }
}
