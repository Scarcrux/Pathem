import CryptoKit
import Foundation
import Testing

@testable import TorrentKit

#if canImport(Network)
    /// End-to-end integration: a real leecher downloads a real file from a real seeder over a
    /// loopback TCP connection, exercising the whole stack (listener, handshake, bitfield, request
    /// pipeline, piece serving, SHA-1 verification, sparse storage). This is the test that proves
    /// the engine actually transfers bytes, not just that its pieces parse.
    @Suite struct TorrentTransferTests {
        private func tempDir() throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("torrent-xfer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        /// Build a valid single-file .torrent (with correct per-piece SHA-1 hashes) for `content`.
        private func makeTorrent(content: Data, pieceLength: Int, name: String) -> Data {
            var pieceHashes = Data()
            var offset = 0
            while offset < content.count {
                let end = min(offset + pieceLength, content.count)
                pieceHashes.append(Data(Insecure.SHA1.hash(data: content.subdata(in: offset..<end))))
                offset = end
            }
            func key(_ s: String) -> Data { Data("\(s.utf8.count):\(s)".utf8) }
            var info = Data("d".utf8)
            info += key("length") + Data("i\(content.count)e".utf8)
            info += key("name") + key(name)
            info += key("piece length") + Data("i\(pieceLength)e".utf8)
            info += key("pieces") + Data("\(pieceHashes.count):".utf8) + pieceHashes
            info += Data("e".utf8)
            return Data("d".utf8) + key("info") + info + Data("e".utf8)
        }

        @Test func leecherDownloadsFromSeederOverLoopback() async throws {
            // ~100 KB of deterministic content over a 32 KB piece length -> 4 pieces (last short).
            let pieceLength = 32 * 1024
            let content = Data((0..<100_000).map { UInt8(($0 &* 2_654_435_761) & 0xff) })
            let name = "payload.bin"
            let torrent = try TorrentFile.parse(makeTorrent(content: content, pieceLength: pieceLength, name: name))
            #expect(torrent.pieceCount == 4)

            let seederDir = try tempDir()
            let leecherDir = try tempDir()
            defer {
                try? FileManager.default.removeItem(at: seederDir)
                try? FileManager.default.removeItem(at: leecherDir)
            }
            // The seeder already has the complete file on disk.
            try content.write(to: seederDir.appendingPathComponent(name))

            let seeder = try TorrentSession(torrent: torrent, downloadRoot: seederDir)
            await seeder.loadResume(havePieces: Array(0..<torrent.pieceCount))
            await seeder.start()

            // A listener routes incoming peers to the seeder.
            let listener = PeerListener(peerID: Tracker.makePeerID()) { hex, peer in
                if hex == torrent.infoHashHex {
                    await seeder.acceptIncomingPeer(peer)
                } else {
                    await peer.close()
                }
            }
            let port = try await listener.start(port: 0)  // ephemeral

            // The leecher downloads from the seeder.
            let leecher = try TorrentSession(torrent: torrent, downloadRoot: leecherDir)
            await leecher.start()
            await leecher.addPeers([Tracker.Peer(host: "127.0.0.1", port: Int(port))])

            // Wait (generously) for the transfer to finish over loopback.
            var finished = false
            for _ in 0..<200 {
                if await leecher.status().fractionComplete >= 1.0 {
                    finished = true
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            let seederStatus = await seeder.status()
            await leecher.stop()
            await seeder.stop()
            await listener.stop()

            #expect(finished)
            // The downloaded bytes match the original exactly.
            let downloaded = try Data(contentsOf: leecherDir.appendingPathComponent(name))
            #expect(downloaded == content)
            // The seeder actually uploaded (it served the pieces).
            #expect(seederStatus.uploaded >= Int64(content.count))
        }
    }
#endif
