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
