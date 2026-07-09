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
