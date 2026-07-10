import CryptoKit
import Foundation
import Testing

@testable import TorrentKit

@Suite struct TorrentCreatorTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("torrent-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func createsSingleFileTorrentThatRoundTrips() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = Data((0..<50_000).map { UInt8(($0 * 7) & 0xff) })
        let fileURL = dir.appendingPathComponent("movie.bin")
        try content.write(to: fileURL)

        let data = try TorrentCreator.create(
            contentsOf: fileURL,
            options: .init(trackers: ["http://tracker.test/announce"], comment: "hi", pieceLength: 16384))
        let torrent = try TorrentFile.parse(data)

        #expect(torrent.name == "movie.bin")
        #expect(torrent.totalLength == 50_000)
        #expect(torrent.files == [.init(path: "movie.bin", length: 50_000)])
        #expect(torrent.pieceLength == 16384)
        #expect(torrent.pieceCount == 4)  // ceil(50000/16384)
        #expect(torrent.trackers == ["http://tracker.test/announce"])
        #expect(torrent.comment == "hi")
        #expect(torrent.infoHashHex.count == 40)

        // The piece hashes actually match the content: feeding it back verifies every piece.
        let pieces = PieceManager(torrent: torrent)
        var offset = 0
        for index in 0..<torrent.pieceCount {
            let size = pieces.pieceSize(index)
            var begin = 0
            while begin < size {
                let len = min(PieceManager.blockSize, size - begin)
                let block = content.subdata(in: (offset + begin)..<(offset + begin + len))
                let result = pieces.receiveBlock(index: index, begin: begin, block: block)
                if begin + len >= size {
                    #expect(result == .pieceComplete(index: index, data: content.subdata(in: offset..<(offset + size))))
                }
                begin += len
            }
            offset += size
        }
        #expect(pieces.isComplete)  // every created piece hash verified against the real bytes
    }

    @Test func createsMultiFileTorrent() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Bundle/sub"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1000).write(to: root.appendingPathComponent("Bundle/a.bin"))
        try Data(repeating: 2, count: 2000).write(to: root.appendingPathComponent("Bundle/sub/b.bin"))
        try Data().write(to: root.appendingPathComponent("Bundle/.DS_Store"))  // should be skipped

        let data = try TorrentCreator.create(contentsOf: root.appendingPathComponent("Bundle"))
        let torrent = try TorrentFile.parse(data)

        #expect(torrent.name == "Bundle")
        #expect(torrent.totalLength == 3000)
        // Sorted by path; .DS_Store excluded.
        #expect(torrent.files == [
            .init(path: "a.bin", length: 1000),
            .init(path: "sub/b.bin", length: 2000),
        ])
        #expect(torrent.pieceCount >= 1)
    }

    @Test func privateFlagAndInfoHashAreConsistent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("f")
        try Data(repeating: 9, count: 100).write(to: fileURL)

        let data = try TorrentCreator.create(contentsOf: fileURL, options: .init(isPrivate: true))
        let torrent = try TorrentFile.parse(data)
        #expect(torrent.isPrivate)
        // The info hash equals SHA-1 of the exact info-dict bytes (standard torrent invariant).
        let (_, infoBytes) = try BencodeDecoder.decodeTorrent(data)
        let expected = Insecure.SHA1.hash(data: infoBytes).map { String(format: "%02x", $0) }.joined()
        #expect(torrent.infoHashHex == expected)
    }

    @Test func rejectsMissingAndEmpty() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: TorrentCreator.CreateError.self) {
            try TorrentCreator.create(contentsOf: dir.appendingPathComponent("nope"))
        }
        let empty = dir.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(throws: TorrentCreator.CreateError.self) {
            try TorrentCreator.create(contentsOf: empty)
        }
    }

    @Test func autoPieceLengthIsPowerOfTwoInRange() {
        #expect(TorrentCreator.autoPieceLength(for: 1000) == 16 * 1024)  // tiny -> min
        let big = TorrentCreator.autoPieceLength(for: 50_000_000_000)
        #expect(big == 8 * 1024 * 1024)  // huge -> max
        let mid = TorrentCreator.autoPieceLength(for: 1_500_000_000)  // ~1.5 GB -> ~1 MB
        #expect(mid == 1024 * 1024)
        #expect((big & (big - 1)) == 0)  // power of two
    }
}
