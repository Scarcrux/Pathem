import CryptoKit
import Foundation
import Network
import Testing

@testable import TorrentKit

#if canImport(Network)
/// A one-shot async box for handing a value (or error) out of a callback.
private actor ResultBox<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    func value() async throws -> T {
        if let pending { return try pending.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func set(_ value: T) { deliver(.success(value)) }
    func fail(_ error: Error) { deliver(.failure(error)) }
    private func deliver(_ result: Result<T, Error>) {
        if let continuation {
            continuation.resume(with: result)
            self.continuation = nil
        } else {
            pending = result
        }
    }
}

@Suite struct MSEConnectionTests {
    @Test func encryptedHandshakeAndMessageOverRealSocket() async throws {
        let infoHash = Data((0..<20).map { UInt8($0 &+ 7) })
        let serverID = Tracker.makePeerID()
        let clientID = Tracker.makePeerID()
        let req2Expected = Data(Insecure.SHA1.hash(data: Data("req2".utf8) + infoHash))

        // A listener that MSE-accepts the first connection, replies, and sends one message.
        let listener = try NWListener(using: .tcp, on: .any)
        let serverDone = ResultBox<Bool>()
        listener.newConnectionHandler = { conn in
            let peer = PeerConnection(incoming: conn, peerID: serverID)
            Task {
                do {
                    _ = try await peer.acceptEncryptedHandshake(torrentFor: {
                        $0 == req2Expected ? infoHash : nil
                    })
                    try await peer.replyHandshake()  // our BT handshake (encrypted)
                    try await peer.send(.unchoke)  // a wire message over the encrypted channel
                    await serverDone.set(true)
                } catch {
                    await serverDone.fail(error)
                }
            }
        }
        let portBox = ResultBox<UInt16>()
        listener.stateUpdateHandler = {
            if case .ready = $0, let p = listener.port?.rawValue { Task { await portBox.set(p) } }
        }
        listener.start(queue: .global())
        let port = try await portBox.value()

        // Client connects with encryption and reads the server's message.
        let client = PeerConnection(
            host: "127.0.0.1", port: port, infoHash: infoHash, peerID: clientID)
        try await client.connect(encrypted: true)
        #expect(await client.isEncrypted)
        let message = try await client.receive(timeout: 10)
        #expect(message == .unchoke)  // decrypted correctly off the encrypted stream
        #expect(try await serverDone.value())

        await client.close()
        listener.cancel()
    }
}
#endif

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
        let torrent = try TorrentFile.parse(
            makeTorrent(content: content, pieceLength: pieceLength, name: name))
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
        let leecherStatus = await leecher.status()
        await leecher.stop()
        await seeder.stop()
        await listener.stop()

        #expect(finished)
        // The downloaded bytes match the original exactly.
        let downloaded = try Data(contentsOf: leecherDir.appendingPathComponent(name))
        #expect(downloaded == content)
        // The seeder actually uploaded (it served the pieces).
        #expect(seederStatus.uploaded >= Int64(content.count))
        // A finished torrent reports no ETA (nothing left to download) and a defined ratio.
        #expect(leecherStatus.etaSeconds == -1)
        #expect(leecherStatus.ratio >= 0)
        // The seeder took nothing and served everything, so its ratio is well above zero.
        #expect(seederStatus.ratio > 0)
    }
}

/// A deterministic BEP 9 peer: its first connection serves the info dictionary, and subsequent
/// connections serve the actual pieces. This is deliberately a real TCP peer, not a mocked
/// MetadataFetcher, so the magnet-resolution/download seam is exercised on the wire.
private actor MagnetFixturePeer {
    private let metadata: Data
    private let content: Data
    private let pieceLength: Int
    private let infoHash: Data
    private var accepted = 0
    private var listener: PeerListener?

    init(metadata: Data, content: Data, pieceLength: Int, infoHash: Data) {
        self.metadata = metadata
        self.content = content
        self.pieceLength = pieceLength
        self.infoHash = infoHash
    }

    func start() async throws -> UInt16 {
        let listener = PeerListener(peerID: Tracker.makePeerID()) { [weak self] hash, peer in
            await self?.accept(hash: hash, peer: peer)
        }
        self.listener = listener
        return try await listener.start(port: 0)
    }

    func stop() async { await listener?.stop() }

    private func accept(hash: String, peer: PeerConnection) async {
        guard hash == infoHash.map({ String(format: "%02x", $0) }).joined() else {
            await peer.close()
            return
        }
        accepted += 1
        let connection = accepted
        defer { Task { await peer.close() } }
        do {
            if connection == 1 {
                try await serveMetadata(to: peer)
            } else {
                try await servePayload(to: peer)
            }
        } catch {
            // The downloader closes a successful metadata connection as soon as it has all
            // blocks, and closes the payload connection when the test removes the torrent.
        }
    }

    private func serveMetadata(to peer: PeerConnection) async throws {
        let extensionID: UInt8 = 3
        try await peer.replyHandshake(advertiseExtensions: true)
        try await peer.send(
            .extended(
                id: 0,
                payload: MetadataExchange.extendedHandshakePayload(
                    utMetadataID: Int(extensionID), metadataSize: metadata.count)))

        while true {
            let message = try await peer.receive(timeout: 5)
            guard case .extended(_, let payload) = message,
                let request = try? BencodeDecoder.decode(payload),
                request["msg_type"]?.intValue == 0,
                let pieceValue = request["piece"]?.intValue
            else { continue }
            let piece = Int(pieceValue)
            let start = piece * MetadataExchange.blockSize
            guard start < metadata.count else { continue }
            let end = min(start + MetadataExchange.blockSize, metadata.count)
            var response = Bencode.dict([
                ("msg_type", .int(1)), ("piece", .int(Int64(piece))),
                ("total_size", .int(Int64(metadata.count))),
            ]).encoded
            response.append(metadata[start..<end])
            try await peer.send(.extended(id: extensionID, payload: response))
        }
    }

    private func servePayload(to peer: PeerConnection) async throws {
        try await peer.replyHandshake()
        let pieceCount = (content.count + pieceLength - 1) / pieceLength
        var bitfield = Data(repeating: 0, count: (pieceCount + 7) / 8)
        for piece in 0..<pieceCount { bitfield[piece / 8] |= UInt8(1 << (7 - piece % 8)) }
        try await peer.send(.bitfield(bitfield))
        try await peer.send(.unchoke)

        while true {
            let message = try await peer.receive(timeout: 10)
            guard case .request(let index, let begin, let length) = message else { continue }
            let start = Int(index) * pieceLength + Int(begin)
            let end = min(start + Int(length), content.count)
            guard start >= 0, start < end else { continue }
            try await peer.send(.piece(index: index, begin: begin, block: content[start..<end]))
        }
    }
}

/// A tiny local HTTP tracker. It returns exactly the fixture peer in compact form, keeping the
/// magnet test hermetic while still exercising Tracker.announce and URLSession.
private final class LoopbackTracker: @unchecked Sendable {
    private var listener: NWListener?
    private static let queue = DispatchQueue(label: "com.pathem.tests.loopback-tracker")

    func start(peerPort: UInt16) async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let ready = ResultBox<UInt16>()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Task { await ready.set(listener.port?.rawValue ?? 0) }
            case .failed(let error):
                Task { await ready.fail(error) }
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                var body = Data("d8:intervali60e5:peers6:".utf8)
                body.append(contentsOf: [
                    127, 0, 0, 1, UInt8(peerPort >> 8), UInt8(peerPort & 0xff),
                ])
                body.append(Data("e".utf8))
                var response = Data(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                        .utf8)
                response.append(body)
                connection.send(
                    content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
            connection.start(queue: Self.queue)
        }
        listener.start(queue: Self.queue)
        return try await ready.value()
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

@Suite struct MagnetEndToEndTests {
    @Test func magnetResolvesMetadataAndDownloadsVerifiedBytes() async throws {
        let pieceLength = 16 * 1024
        let content = Data((0..<50_000).map { UInt8(($0 &* 31) & 0xff) })
        let name = "magnet-payload.bin"

        var hashes = Data()
        for offset in stride(from: 0, to: content.count, by: pieceLength) {
            hashes.append(
                Data(
                    Insecure.SHA1.hash(
                        data: content[offset..<min(offset + pieceLength, content.count)])))
        }
        func key(_ value: String) -> Data { Data("\(value.utf8.count):\(value)".utf8) }
        var metadata = Data("d".utf8)
        metadata += key("length") + Data("i\(content.count)e".utf8)
        metadata += key("name") + key(name)
        metadata += key("piece length") + Data("i\(pieceLength)e".utf8)
        metadata += key("pieces") + Data("\(hashes.count):".utf8) + hashes
        metadata += Data("e".utf8)
        let infoHash = Data(Insecure.SHA1.hash(data: metadata))
        let infoHashHex = infoHash.map { String(format: "%02x", $0) }.joined()

        let peer = MagnetFixturePeer(
            metadata: metadata, content: content, pieceLength: pieceLength, infoHash: infoHash)
        let peerPort = try await peer.start()
        let tracker = LoopbackTracker()
        let trackerPort = try await tracker.start(peerPort: peerPort)
        defer {
            tracker.stop()
            Task { await peer.stop() }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("magnet-e2e-\(UUID().uuidString)")
        let state = root.appendingPathComponent("state")
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trackerURL = "http://127.0.0.1:\(trackerPort)/announce"
        var components = URLComponents()
        components.scheme = "magnet"
        components.queryItems = [
            URLQueryItem(name: "xt", value: "urn:btih:\(infoHashHex)"),
            URLQueryItem(name: "dn", value: name),
            URLQueryItem(name: "tr", value: trackerURL),
        ]
        let magnet = try #require(components.string)
        let engine = TorrentEngine(stateDir: state)
        let pending = try #require(await engine.addMagnet(uri: magnet, savePath: downloads.path))
        #expect(pending.state == .checking)

        var finished: TorrentSession.Status?
        for _ in 0..<150 {
            if let status = await engine.statuses().first,
                status.state == .seeding, status.fractionComplete == 1
            {
                finished = status
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(finished?.infoHash == infoHashHex)
        #expect(try Data(contentsOf: downloads.appendingPathComponent(name)) == content)
        await engine.remove(infoHash: infoHashHex, deleteData: true)
        #expect(await engine.statuses().isEmpty)
        #expect(
            !FileManager.default.fileExists(atPath: downloads.appendingPathComponent(name).path))
    }
}
#endif
