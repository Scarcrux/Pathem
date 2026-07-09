import CryptoKit
import Foundation

/// The message construction for fetching a torrent's metadata from peers (BEP 9 ut_metadata over
/// the BEP 10 extension protocol). A magnet link carries only the info hash, so before downloading
/// we ask peers for the info dictionary, verify its SHA-1 against the info hash, and build a
/// TorrentFile from it. These helpers are pure and unit-tested; the peer loop that uses them lives
/// in MetadataFetcher.
public enum MetadataExchange {
    /// The metadata block size (16 KiB), same as a normal piece block.
    public static let blockSize = 16 * 1024

    /// Our extended handshake (extended message id 0): advertise ut_metadata as extension id 1.
    public static func extendedHandshakePayload(utMetadataID: Int = 1) -> Data {
        let dict = Bencode.dict([
            ("m", .dict([("ut_metadata", .int(Int64(utMetadataID)))]))
        ])
        return dict.encoded
    }

    /// Parse a peer's extended handshake: their ut_metadata message id and the metadata size.
    public static func parseExtendedHandshake(_ payload: Data) -> (utMetadataID: UInt8?, metadataSize: Int?) {
        guard let dict = try? BencodeDecoder.decode(payload) else { return (nil, nil) }
        let id = dict["m"]?["ut_metadata"]?.intValue
        let size = dict["metadata_size"]?.intValue
        return (id.map { UInt8(truncatingIfNeeded: $0) }, size.map { Int($0) })
    }

    /// A ut_metadata request for one metadata piece: `{"msg_type":0,"piece":i}`.
    public static func requestPayload(piece: Int) -> Data {
        Bencode.dict([("msg_type", .int(0)), ("piece", .int(Int64(piece)))]).encoded
    }

    /// Parse a ut_metadata data message: the bencoded header `{"msg_type":1,"piece":i,...}` then
    /// the raw piece bytes that follow it. Returns nil if it isn't a data (msg_type 1) message.
    public static func parseDataMessage(_ payload: Data) -> (piece: Int, block: Data)? {
        guard let (header, consumed) = try? BencodeDecoder.decodePrefix(payload),
            header["msg_type"]?.intValue == 1,
            let piece = header["piece"]?.intValue
        else { return nil }
        let block = consumed <= payload.count ? payload.suffix(from: payload.startIndex + consumed) : Data()
        return (Int(piece), Data(block))
    }

    /// Number of 16 KiB metadata pieces for a given metadata size.
    public static func pieceCount(metadataSize: Int) -> Int {
        (metadataSize + blockSize - 1) / blockSize
    }

    /// Verify assembled metadata against the expected info hash, and if it matches, wrap it into a
    /// parseable .torrent (preserving the raw info bytes so the hash stays intact). Returns both
    /// the parsed TorrentFile and the .torrent bytes (so a resolved magnet can be persisted).
    /// Returns nil on hash mismatch or parse failure.
    public static func buildTorrent(
        fromMetadata metadata: Data, infoHash: Data, trackers: [String]
    ) -> (torrent: TorrentFile, torrentBytes: Data)? {
        guard Data(Insecure.SHA1.hash(data: metadata)) == infoHash else { return nil }

        // Assemble a top-level dict by hand so the info dict's exact bytes are preserved:
        // d [8:announce <url>] [13:announce-list l l<url>... e e] 4:info <metadata> e.
        // Keys stay in sorted order (announce < announce-list < info).
        var bytes = Data("d".utf8)
        if let first = trackers.first {
            bytes.append(Data("8:announce".utf8))
            bytes.append(Data("\(first.utf8.count):\(first)".utf8))
        }
        if !trackers.isEmpty {
            bytes.append(Data("13:announce-list".utf8))
            bytes.append(Data("l".utf8))
            for tracker in trackers {
                bytes.append(Data("l\(tracker.utf8.count):\(tracker)e".utf8))
            }
            bytes.append(Data("e".utf8))
        }
        bytes.append(Data("4:info".utf8))
        bytes.append(metadata)
        bytes.append(Data("e".utf8))

        guard let torrent = try? TorrentFile.parse(bytes) else { return nil }
        return (torrent, bytes)
    }
}
