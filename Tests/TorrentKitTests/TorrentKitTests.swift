import CryptoKit
import Foundation
import Testing

@testable import TorrentKit

@Suite struct BencodeTests {
    @Test func decodesEachType() throws {
        #expect(try BencodeDecoder.decode(Data("i42e".utf8)) == .int(42))
        #expect(try BencodeDecoder.decode(Data("i-7e".utf8)) == .int(-7))
        #expect(try BencodeDecoder.decode(Data("4:spam".utf8)).string == "spam")
        #expect(try BencodeDecoder.decode(Data("l4:spami1ee".utf8)) == .list([.bytes(Data("spam".utf8)), .int(1)]))
        let dict = try BencodeDecoder.decode(Data("d3:cow3:moo4:spam4:eggse".utf8))
        #expect(dict["cow"]?.string == "moo")
        #expect(dict["spam"]?.string == "eggs")
    }

    @Test func rejectsMalformed() {
        #expect(throws: (any Error).self) { try BencodeDecoder.decode(Data("i42".utf8)) }  // no terminator
        #expect(throws: (any Error).self) { try BencodeDecoder.decode(Data("5:ab".utf8)) }  // short string
        #expect(throws: (any Error).self) { try BencodeDecoder.decode(Data("x".utf8)) }  // bad type
    }

    @Test func encodesCanonically() throws {
        #expect(Bencode.int(42).encoded == Data("i42e".utf8))
        #expect(Bencode.bytes(Data("spam".utf8)).encoded == Data("4:spam".utf8))
        // Dictionary keys are sorted on encode, regardless of insertion order.
        let dict = Bencode.dict([("spam", .int(1)), ("cow", .bytes(Data("moo".utf8)))])
        #expect(dict.encoded == Data("d3:cow3:moo4:spami1ee".utf8))
        // Round-trips through the decoder.
        #expect(try BencodeDecoder.decode(dict.encoded) == BencodeDecoder.decode(Data("d3:cow3:moo4:spami1ee".utf8)))
    }

    @Test func decodePrefixReportsConsumed() throws {
        let (value, consumed) = try BencodeDecoder.decodePrefix(Data("i7eEXTRA".utf8))
        #expect(value == .int(7))
        #expect(consumed == 3)  // "i7e", leaving "EXTRA"
    }
}

@Suite struct TorrentFileTests {
    // Build a valid single-file torrent and remember the exact `info` bytes.
    private func sample() -> (torrent: Data, infoBytes: Data) {
        func s(_ v: String) -> String { "\(v.utf8.count):\(v)" }
        let pieces = String(repeating: "a", count: 20)  // one 20-byte piece hash
        let info =
            "d" + s("length") + "i1024e" + s("name") + s("file.txt")
            + s("piece length") + "i16384e" + s("pieces") + "20:\(pieces)e"
        let top =
            "d" + s("announce") + s("http://tracker.test/announce")
            + s("announce-list") + "ll" + s("http://tracker.test/announce") + "ee"
            + s("comment") + s("hello") + s("info") + info + "e"
        return (Data(top.utf8), Data(info.utf8))
    }

    @Test func parsesSingleFileTorrent() throws {
        let (data, infoBytes) = sample()
        let t = try TorrentFile.parse(data)
        #expect(t.name == "file.txt")
        #expect(t.totalLength == 1024)
        #expect(t.files == [.init(path: "file.txt", length: 1024)])
        #expect(t.pieceLength == 16384)
        #expect(t.pieceCount == 1)
        #expect(t.trackers == ["http://tracker.test/announce"])  // announce + announce-list de-duped
        #expect(t.comment == "hello")
        // The info hash is SHA-1 of the exact info-dict bytes.
        let expected = Insecure.SHA1.hash(data: infoBytes).map { String(format: "%02x", $0) }.joined()
        #expect(t.infoHashHex == expected)
        #expect(t.infoHashHex.count == 40)
    }

    @Test func multiFileTorrent() throws {
        func s(_ v: String) -> String { "\(v.utf8.count):\(v)" }
        let files = "l" + "d" + s("length") + "i10e" + s("path") + "l" + s("a") + s("b.txt") + "ee"
            + "d" + s("length") + "i20e" + s("path") + "l" + s("c.txt") + "ee" + "e"
        let info = "d" + s("files") + files + s("name") + s("Bundle") + s("piece length") + "i16384e" + s("pieces") + "20:\(String(repeating: "x", count: 20))e"
        let top = "d" + s("info") + info + "e"
        let t = try TorrentFile.parse(Data(top.utf8))
        #expect(t.name == "Bundle")
        #expect(t.files == [.init(path: "a/b.txt", length: 10), .init(path: "c.txt", length: 20)])
        #expect(t.totalLength == 30)
    }

    @Test func magnetLink() throws {
        let (data, _) = sample()
        let t = try TorrentFile.parse(data)
        #expect(t.magnetLink.hasPrefix("magnet:?xt=urn:btih:\(t.infoHashHex)"))
        #expect(t.magnetLink.contains("dn=file.txt"))
        #expect(t.magnetLink.contains("tr=http"))  // tracker percent-encoded
    }

    @Test func rejectsNonTorrent() {
        #expect(throws: (any Error).self) { try TorrentFile.parse(Data("i5e".utf8)) }
    }
}

@Suite struct TrackerTests {
    @Test func percentEncodesRawBytesByteByByte() {
        // Unreserved bytes pass through; everything else is %XX. 0x00, 0x20 (space), 0xFF escape.
        let data = Data([0x41, 0x00, 0x20, 0xff, 0x2d])  // "A", NUL, space, 0xFF, "-"
        #expect(Tracker.percentEncode(data) == "A%00%20%FF-")
    }

    @Test func announceURLCarriesEscapedHashAndParams() throws {
        let hash = Data((0..<20).map { UInt8($0) })
        let peerID = Data("-PM0001-1234567890AB".utf8)
        let url = try #require(
            Tracker.announceURL(base: "http://t.test/announce", infoHash: hash, peerID: peerID, port: 6881, left: 1024, event: .started))
        let s = url.absoluteString
        #expect(s.hasPrefix("http://t.test/announce?info_hash="))
        #expect(s.contains("%00%01%02"))  // low bytes escaped
        #expect(s.contains("peer_id=-PM0001-1234567890AB"))
        #expect(s.contains("port=6881"))
        #expect(s.contains("left=1024"))
        #expect(s.contains("event=started"))
        #expect(s.contains("compact=1"))
    }

    @Test func announceURLAppendsWithAmpersandWhenBaseHasQuery() throws {
        let url = try #require(
            Tracker.announceURL(base: "http://t.test/a?x=1", infoHash: Data(count: 20), peerID: Data(count: 20), port: 1, left: 0))
        #expect(url.absoluteString.contains("?x=1&info_hash="))
    }

    @Test func parsesCompactPeers() {
        // Two peers: 10.0.0.1:6881 and 192.168.1.2:51413.
        var data = Data([10, 0, 0, 1, 0x1a, 0xe1])
        data.append(contentsOf: [192, 168, 1, 2, 0xc8, 0xd5])
        data.append(contentsOf: [1, 2, 3])  // trailing partial peer is ignored
        let peers = Tracker.parseCompactPeers(data)
        #expect(peers == [.init(host: "10.0.0.1", port: 6881), .init(host: "192.168.1.2", port: 51413)])
    }

    @Test func parsesCompactResponse() throws {
        // peers is a 6-byte compact string for 10.0.0.1:6881 (raw bytes, not UTF-8 text).
        var body = Data("d8:intervali1800e5:peers6:".utf8)
        body.append(contentsOf: [10, 0, 0, 1, 0x1a, 0xe1])
        body.append(Data("e".utf8))
        let resp = try Tracker.parseResponse(body)
        #expect(resp.interval == 1800)
        #expect(resp.peers == [.init(host: "10.0.0.1", port: 6881)])
        #expect(resp.failureReason == nil)
    }

    @Test func parsesDictionaryPeers() throws {
        func s(_ v: String) -> String { "\(v.utf8.count):\(v)" }
        let peerList = "l" + "d" + s("ip") + s("1.2.3.4") + s("port") + "i6881e" + "e" + "e"
        let body = "d" + s("interval") + "i900e" + s("peers") + peerList + "e"
        let resp = try Tracker.parseResponse(Data(body.utf8))
        #expect(resp.peers == [.init(host: "1.2.3.4", port: 6881)])
    }

    @Test func surfacesFailureReason() throws {
        func s(_ v: String) -> String { "\(v.utf8.count):\(v)" }
        let body = "d" + s("failure reason") + s("torrent not registered") + "e"
        let resp = try Tracker.parseResponse(Data(body.utf8))
        #expect(resp.failureReason == "torrent not registered")
        #expect(resp.peers.isEmpty)
    }

    @Test func peerIDHasPathemPrefix() {
        let id = Tracker.makePeerID()
        #expect(id.count == 20)
        #expect(String(decoding: id.prefix(8), as: UTF8.self) == "-PM0001-")
    }
}

@Suite struct PeerMessageTests {
    @Test func handshakeRoundTrips() {
        let hash = Data((0..<20).map { UInt8($0) })
        let peerID = Data("-PM0001-abcdefghijkl".utf8)
        let hs = PeerHandshake(infoHash: hash, peerID: peerID)
        let encoded = hs.encoded
        #expect(encoded.count == 68)
        let decoded = PeerHandshake.parse(encoded)
        #expect(decoded?.infoHash == hash)
        #expect(decoded?.peerID == peerID)
    }

    @Test func handshakeRejectsBadProtocol() {
        var bad = Data([19])
        bad.append(Data("NotBitTorrent proto".utf8))
        bad.append(Data(count: 48))
        #expect(PeerHandshake.parse(bad) == nil)
        #expect(PeerHandshake.parse(Data(count: 10)) == nil)  // too short
    }

    @Test func encodesAndParsesEachMessage() {
        let cases: [PeerMessage] = [
            .keepAlive, .choke, .unchoke, .interested, .notInterested,
            .have(pieceIndex: 258),
            .bitfield(Data([0xff, 0x00, 0xab])),
            .request(index: 1, begin: 16384, length: 16384),
            .piece(index: 2, begin: 0, block: Data([1, 2, 3, 4])),
            .cancel(index: 3, begin: 32768, length: 16384),
            .port(6881),
        ]
        for message in cases {
            let encoded = message.encoded
            let parsed = PeerMessage.parse(encoded)
            #expect(parsed?.message == message)
            #expect(parsed?.consumed == encoded.count)
        }
    }

    @Test func parseWaitsForCompleteMessage() {
        let full = PeerMessage.piece(index: 0, begin: 0, block: Data([9, 9, 9])).encoded
        #expect(PeerMessage.parse(full.prefix(4)) == nil)  // length known, body missing
        #expect(PeerMessage.parse(full.prefix(2)) == nil)  // length prefix incomplete
    }

    @Test func parseConsumesOneOfSeveralQueuedMessages() {
        var stream = PeerMessage.unchoke.encoded
        stream.append(PeerMessage.have(pieceIndex: 7).encoded)
        let first = PeerMessage.parse(stream)
        #expect(first?.message == .unchoke)
        #expect(first?.consumed == 5)  // 4-byte length + 1-byte id
        let rest = stream.dropFirst(first!.consumed)
        #expect(PeerMessage.parse(rest)?.message == .have(pieceIndex: 7))
    }

    @Test func keepAliveIsZeroLength() {
        #expect(PeerMessage.keepAlive.encoded == Data([0, 0, 0, 0]))
    }

    @Test func extendedMessageRoundTrips() {
        let payload = Data("d1:vi1ee".utf8)  // an arbitrary bencoded extended-handshake body
        let message = PeerMessage.extended(id: 0, payload: payload)
        let parsed = PeerMessage.parse(message.encoded)
        #expect(parsed?.message == message)
        #expect(parsed?.consumed == message.encoded.count)
    }

    @Test func extensionReservedBitIsDetected() {
        let hash = Data(count: 20)
        let hs = PeerHandshake(infoHash: hash, peerID: Data(count: 20), reserved: PeerHandshake.extensionReserved)
        let decoded = PeerHandshake.parse(hs.encoded)
        #expect(decoded?.supportsExtensions == true)
        let plain = PeerHandshake(infoHash: hash, peerID: Data(count: 20))
        #expect(PeerHandshake.parse(plain.encoded)?.supportsExtensions == false)
    }
}

@Suite struct MagnetTests {
    @Test func parsesHexMagnet() throws {
        let hex = "0123456789abcdef0123456789abcdef01234567"
        let uri = "magnet:?xt=urn:btih:\(hex)&dn=My+File&tr=http%3A%2F%2Ftracker.test%2Fannounce"
        let magnet = try #require(Magnet.parse(uri))
        #expect(magnet.infoHashHex == hex)
        #expect(magnet.infoHash.count == 20)
        #expect(magnet.displayName == "My File")
        #expect(magnet.trackers == ["http://tracker.test/announce"])
    }

    @Test func parsesBase32Magnet() throws {
        // The 32-char base32 form must decode to the same 20 bytes as its hex.
        let bytes = Data((0..<20).map { UInt8($0) })
        let base32 = base32Encode(bytes)
        let magnet = try #require(Magnet.parse("magnet:?xt=urn:btih:\(base32)"))
        #expect(magnet.infoHash == bytes)
    }

    @Test func rejectsNonMagnet() {
        #expect(Magnet.parse("https://example.com") == nil)
        #expect(Magnet.parse("magnet:?dn=name") == nil)  // no info hash
        #expect(Magnet.parse("magnet:?xt=urn:btih:tooshort") == nil)
    }

    @Test func roundTripsWithTorrentFileMagnetLink() throws {
        // A TorrentFile's generated magnetLink must parse back to the same info hash.
        func s(_ v: String) -> String { "\(v.utf8.count):\(v)" }
        let pieces = String(repeating: "a", count: 20)
        let info = "d" + s("length") + "i1024e" + s("name") + s("file.txt")
            + s("piece length") + "i16384e" + s("pieces") + "20:\(pieces)e"
        let torrent = try TorrentFile.parse(Data(("d" + s("info") + info + "e").utf8))
        let magnet = try #require(Magnet.parse(torrent.magnetLink))
        #expect(magnet.infoHashHex == torrent.infoHashHex)
        #expect(magnet.displayName == "file.txt")
    }

    // A tiny base32 encoder for the test (RFC 4648, no padding).
    private func base32Encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0, out = ""
        for byte in data {
            value = value << 8 | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(value >> bits) & 0x1f])
            }
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 0x1f]) }
        return out
    }
}

@Suite struct MetadataExchangeTests {
    @Test func extendedHandshakeRoundTrips() {
        let payload = MetadataExchange.extendedHandshakePayload(utMetadataID: 3)
        let (id, size) = MetadataExchange.parseExtendedHandshake(payload)
        #expect(id == 3)
        #expect(size == nil)  // we don't advertise a size as a downloader
    }

    @Test func parsesPeerExtendedHandshake() {
        // A peer advertising ut_metadata=2 and a metadata size.
        let dict = Bencode.dict([
            ("m", .dict([("ut_metadata", .int(2))])),
            ("metadata_size", .int(31000)),
        ])
        let (id, size) = MetadataExchange.parseExtendedHandshake(dict.encoded)
        #expect(id == 2)
        #expect(size == 31000)
    }

    @Test func requestAndDataMessages() {
        let request = MetadataExchange.requestPayload(piece: 5)
        let decoded = try? BencodeDecoder.decode(request)
        #expect(decoded?["msg_type"]?.intValue == 0)
        #expect(decoded?["piece"]?.intValue == 5)

        // A data message: bencoded header immediately followed by raw block bytes.
        let header = Bencode.dict([("msg_type", .int(1)), ("piece", .int(2)), ("total_size", .int(40))])
        var message = header.encoded
        let rawBlock = Data((0..<16).map { UInt8($0) })
        message.append(rawBlock)
        let parsed = MetadataExchange.parseDataMessage(message)
        #expect(parsed?.piece == 2)
        #expect(parsed?.block == rawBlock)
    }

    @Test func pieceCountRoundsUp() {
        #expect(MetadataExchange.pieceCount(metadataSize: 16 * 1024) == 1)
        #expect(MetadataExchange.pieceCount(metadataSize: 16 * 1024 + 1) == 2)
        #expect(MetadataExchange.pieceCount(metadataSize: 40000) == 3)
    }

    @Test func buildsTorrentFromVerifiedMetadata() throws {
        // The metadata IS the info dict. Take a real torrent's info bytes and rebuild from them.
        func s(_ v: String) -> String { "\(v.utf8.count):\(v)" }
        let pieces = String(repeating: "a", count: 20)
        let info = "d" + s("length") + "i2048e" + s("name") + s("movie.mkv")
            + s("piece length") + "i16384e" + s("pieces") + "20:\(pieces)e"
        let metadata = Data(info.utf8)
        let infoHash = Data(Insecure.SHA1.hash(data: metadata))

        let built = try #require(
            MetadataExchange.buildTorrent(
                fromMetadata: metadata, infoHash: infoHash, trackers: ["http://tracker.test/announce"]))
        #expect(built.torrent.name == "movie.mkv")
        #expect(built.torrent.totalLength == 2048)
        #expect(built.torrent.infoHash == infoHash)  // preserved exactly through the rebuild
        #expect(built.torrent.trackers == ["http://tracker.test/announce"])
        // The returned bytes re-parse to the same torrent (they are what we persist).
        #expect(try TorrentFile.parse(built.torrentBytes).infoHash == infoHash)
    }

    @Test func rejectsMetadataWithWrongHash() {
        let metadata = Data("d4:name4:fakee".utf8)
        let wrongHash = Data(repeating: 0xab, count: 20)
        #expect(MetadataExchange.buildTorrent(fromMetadata: metadata, infoHash: wrongHash, trackers: []) == nil)
    }
}

@Suite struct PieceManagerTests {
    // Build a manager over `content` split into `pieceLength`-byte pieces, with correct hashes.
    private func manager(for content: Data, pieceLength: Int) -> PieceManager {
        var hashes: [Data] = []
        var offset = 0
        while offset < content.count {
            let end = min(offset + pieceLength, content.count)
            hashes.append(Data(Insecure.SHA1.hash(data: content.subdata(in: offset..<end))))
            offset = end
        }
        return PieceManager(
            pieceCount: hashes.count, pieceLength: pieceLength,
            totalLength: Int64(content.count), pieceHashes: hashes)
    }

    @Test func geometryHandlesShortLastPiece() {
        // 5 bytes over a 2-byte piece length -> pieces of 2, 2, 1.
        let m = manager(for: Data(repeating: 7, count: 5), pieceLength: 2)
        #expect(m.pieceCount == 3)
        #expect(m.pieceSize(0) == 2)
        #expect(m.pieceSize(2) == 1)
    }

    @Test func blockGeometryWithinPiece() {
        // One piece of 40000 bytes -> 3 blocks (16384, 16384, 7232).
        let content = Data((0..<40000).map { UInt8($0 & 0xff) })
        let m = manager(for: content, pieceLength: 40000)
        #expect(m.blockCount(0) == 3)
        #expect(m.blockLength(piece: 0, begin: 0) == 16384)
        #expect(m.blockLength(piece: 0, begin: 32768) == 40000 - 32768)
    }

    @Test func verifiesAndCompletesRealData() {
        // 40000 bytes, single piece, delivered as three blocks; last block completes + verifies.
        let content = Data((0..<40000).map { UInt8(($0 * 31) & 0xff) })
        let m = manager(for: content, pieceLength: 40000)
        let bs = PieceManager.blockSize
        #expect(m.receiveBlock(index: 0, begin: 0, block: content.subdata(in: 0..<bs)) == .accepted)
        #expect(m.receiveBlock(index: 0, begin: bs, block: content.subdata(in: bs..<(2 * bs))) == .accepted)
        let final = m.receiveBlock(index: 0, begin: 2 * bs, block: content.subdata(in: (2 * bs)..<40000))
        #expect(final == .pieceComplete(index: 0, data: content))
        #expect(m.hasPiece(0))
        #expect(m.isComplete)
        #expect(m.downloadedBytes == 40000)
    }

    @Test func rejectsCorruptPieceAndAllowsRetry() {
        let content = Data((0..<20).map { UInt8($0) })  // one 20-byte piece, single block
        let m = manager(for: content, pieceLength: 20)
        let bad = m.receiveBlock(index: 0, begin: 0, block: Data(repeating: 0xff, count: 20))
        #expect(bad == .hashMismatch(index: 0))
        #expect(!m.hasPiece(0))
        // The piece was reset, so the correct block now completes it.
        #expect(m.receiveBlock(index: 0, begin: 0, block: content) == .pieceComplete(index: 0, data: content))
    }

    @Test func duplicateAndOutOfRangeBlocks() {
        let content = Data((0..<40000).map { UInt8($0 & 0xff) })
        let m = manager(for: content, pieceLength: 40000)
        _ = m.receiveBlock(index: 0, begin: 0, block: content.subdata(in: 0..<PieceManager.blockSize))
        #expect(m.receiveBlock(index: 0, begin: 0, block: content.subdata(in: 0..<PieceManager.blockSize)) == .duplicate)
        #expect(m.receiveBlock(index: 5, begin: 0, block: Data([1])) == .rejected)  // no such piece
        #expect(m.receiveBlock(index: 0, begin: 999, block: Data([1])) == .rejected)  // misaligned begin
    }

    @Test func requestSelectionSkipsHeldAndInFlightBlocks() {
        let content = Data((0..<40000).map { UInt8($0 & 0xff) })  // 3 blocks
        let m = manager(for: content, pieceLength: 40000)
        let peerHas = [true]
        let first = m.nextRequest(peerHas: peerHas, inFlight: [])
        #expect(first == .init(index: 0, begin: 0, length: PieceManager.blockSize))
        // With the first block in flight, it should offer the second.
        let second = m.nextRequest(peerHas: peerHas, inFlight: [first!])
        #expect(second == .init(index: 0, begin: PieceManager.blockSize, length: PieceManager.blockSize))
        // A peer that has no pieces yields nothing.
        #expect(m.nextRequest(peerHas: [false], inFlight: []) == nil)
    }

    @Test func bitfieldRoundTrips() {
        let content = Data(repeating: 0, count: 10)  // 10 one-byte pieces
        let m = manager(for: content, pieceLength: 1)
        m.markComplete(0)
        m.markComplete(9)
        let bits = m.decodeBitfield(m.bitfield())
        #expect(bits[0] && bits[9])
        #expect(!bits[1] && !bits[5])
        #expect(m.completedCount == 2)
    }
}

@Suite struct FileLayoutTests {
    @Test func singleFileIsOneSegment() {
        let layout = FileLayout(entries: [.init(path: "movie.mkv", length: 1000)])
        #expect(layout.totalLength == 1000)
        let segs = layout.segments(at: 200, length: 300)
        #expect(segs == [.init(fileIndex: 0, path: "movie.mkv", fileOffset: 200, length: 300)])
    }

    @Test func pieceSpanningFileBoundarySplits() {
        // Three files: 100, 50, 200 bytes at offsets 0, 100, 150.
        let layout = FileLayout(entries: [
            .init(path: "a", length: 100),
            .init(path: "b", length: 50),
            .init(path: "c", length: 200),
        ])
        #expect(layout.totalLength == 350)
        // A range [80, 260) touches all three files.
        let segs = layout.segments(at: 80, length: 180)
        #expect(segs == [
            .init(fileIndex: 0, path: "a", fileOffset: 80, length: 20),   // a[80..100)
            .init(fileIndex: 1, path: "b", fileOffset: 0, length: 50),    // b[0..50)
            .init(fileIndex: 2, path: "c", fileOffset: 0, length: 110),   // c[0..110)
        ])
    }

    @Test func pieceGeometryMapsToSegments() {
        let layout = FileLayout(entries: [.init(path: "a", length: 100), .init(path: "b", length: 100)])
        // piece length 64, piece index 1 covers global [64, 128): 36 bytes in a, 28 in b.
        let segs = layout.segments(forPiece: 1, pieceLength: 64, pieceSize: 64)
        #expect(segs == [
            .init(fileIndex: 0, path: "a", fileOffset: 64, length: 36),
            .init(fileIndex: 1, path: "b", fileOffset: 0, length: 28),
        ])
    }

    @Test func emptyRangeYieldsNothing() {
        let layout = FileLayout(entries: [.init(path: "a", length: 100)])
        #expect(layout.segments(at: 50, length: 0).isEmpty)
    }
}

@Suite struct TorrentStorageTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("torrent-storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func writesAndReadsPieceSpanningTwoFiles() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // Two files of 100 bytes each; piece length 64. Piece 1 covers global [64,128).
        let layout = FileLayout(entries: [
            .init(path: "sub/a.bin", length: 100), .init(path: "b.bin", length: 100),
        ])
        let storage = try TorrentStorage(root: root, layout: layout)
        let piece = Data((0..<64).map { UInt8(($0 + 1) & 0xff) })
        try storage.write(pieceIndex: 1, pieceLength: 64, pieceSize: 64, data: piece)

        // The bytes should land 36 in a.bin (offset 64) and 28 in b.bin (offset 0).
        #expect(try storage.read(at: 64, length: 64) == piece)
        let aTail = try Data(contentsOf: root.appendingPathComponent("sub/a.bin")).suffix(36)
        #expect(Array(aTail) == Array(piece.prefix(36)))
        let bHead = try Data(contentsOf: root.appendingPathComponent("b.bin")).prefix(28)
        #expect(Array(bHead) == Array(piece.suffix(28)))
        storage.close()
    }

    @Test func rejectsPathTraversal() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let evil = FileLayout(entries: [.init(path: "../escape.txt", length: 10)])
        #expect(throws: TorrentStorage.StorageError.self) {
            _ = try TorrentStorage(root: root, layout: evil)
        }
        let absolute = FileLayout(entries: [.init(path: "/etc/passwd", length: 10)])
        #expect(throws: TorrentStorage.StorageError.self) {
            _ = try TorrentStorage(root: root, layout: absolute)
        }
    }
}

@Suite struct TorrentControlTests {
    @Test func commandRoundTripsAsJSONLine() throws {
        let command = TorrentControl.Command(
            op: .add, id: 3, torrentPath: "/tmp/a.torrent", savePath: "/tmp/dl")
        var line = TorrentControl.encodeLine(command)
        #expect(line.last == 0x0a)  // newline-terminated
        line.removeLast()
        let decoded = try JSONDecoder().decode(TorrentControl.Command.self, from: line)
        #expect(decoded.op == .add)
        #expect(decoded.id == 3)
        #expect(decoded.torrentPath == "/tmp/a.torrent")
    }

    @Test func eventCarriesStatuses() throws {
        let status = TorrentSession.Status(
            infoHash: "abc", name: "x", totalLength: 10, downloaded: 5, fractionComplete: 0.5,
            downloadRate: 1024, peersConnected: 2, state: .downloading, savePath: "/dl")
        let event = TorrentControl.Event(kind: .status, ok: true, torrents: [status])
        var line = TorrentControl.encodeLine(event)
        line.removeLast()
        let decoded = try JSONDecoder().decode(TorrentControl.Event.self, from: line)
        #expect(decoded.kind == .status)
        #expect(decoded.torrents?.first?.fractionComplete == 0.5)
        #expect(decoded.torrents?.first?.state == .downloading)
    }
}

@Suite struct TorrentEngineTests {
    // A minimal valid trackerless single-file torrent, so adding it starts no network activity.
    private func trackerlessTorrent(to url: URL) throws {
        func s(_ v: String) -> String { "\(v.utf8.count):\(v)" }
        let pieces = String(repeating: "a", count: 20)
        let info = "d" + s("length") + "i1024e" + s("name") + s("data.bin")
            + s("piece length") + "i16384e" + s("pieces") + "20:\(pieces)e"
        try Data(("d" + s("info") + info + "e").utf8).write(to: url)
    }

    @Test func addPauseRemovePersists() async throws {
        let stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-test-\(UUID().uuidString)")
        let saveDir = stateDir.appendingPathComponent("dl")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDir) }

        let torrentURL = stateDir.appendingPathComponent("t.torrent")
        try trackerlessTorrent(to: torrentURL)

        let engine = TorrentEngine(stateDir: stateDir)
        let status = try await engine.addTorrentFile(at: torrentURL.path, savePath: saveDir.path)
        #expect(status.name == "data.bin")
        #expect(status.totalLength == 1024)

        var all = await engine.statuses()
        #expect(all.count == 1)
        #expect(all.first?.state == .downloading)

        await engine.pause(infoHash: status.infoHash)
        all = await engine.statuses()
        #expect(all.first?.state == .paused)

        // State persisted: a fresh engine over the same dir sees the torrent.
        let reopened = TorrentEngine(stateDir: stateDir)
        await reopened.restoreAll()
        #expect(await reopened.statuses().count == 1)

        await engine.remove(infoHash: status.infoHash, deleteData: false)
        #expect(await engine.statuses().isEmpty)
    }
}
