import Foundation
import Network
import Testing

@testable import TorrentKit

/// A magnet's ws= web seeds and xs= exact source, and the metadata search's published phases.
/// Hermetic: a loopback HTTP server stands in for the .torrent host and the web seed, there are
/// no trackers and the DHT is off, so nothing reaches the public network and no peer exists.
@Suite struct MagnetSourcesTests {
    @Test func parsesWebSeedsAndExactSourcesHTTPOnly() throws {
        let hex = String(repeating: "ab", count: 20)
        let uri =
            "magnet:?xt=urn:btih:\(hex)&ws=https%3A%2F%2Fseed.test%2Ffiles%2F"
            + "&xs=http%3A%2F%2Fhost.test%2Fa.torrent&ws=ftp%3A%2F%2Fseed.test%2F"
            + "&xs=file%3A%2F%2F%2Fetc%2Fpasswd"
        let magnet = try #require(Magnet.parse(uri))
        #expect(magnet.webSeeds == ["https://seed.test/files/"])
        #expect(magnet.exactSources == ["http://host.test/a.torrent"])
    }

    @Test func builtTorrentCarriesWebSeedsAndKeepsItsHash() throws {
        let (bytes, _) = try Self.fixtureTorrent()
        let parsed = try TorrentFile.parse(bytes)
        let (_, info) = try BencodeDecoder.decodeTorrent(bytes)
        let built = try #require(
            MetadataExchange.buildTorrent(
                fromMetadata: info, infoHash: parsed.infoHash, trackers: [],
                webSeeds: ["http://a.test/", "http://b.test/"]))
        #expect(built.torrent.webSeeds == ["http://a.test/", "http://b.test/"])
        #expect(built.torrent.infoHash == parsed.infoHash)
        #expect(try TorrentFile.parse(built.torrentBytes).webSeeds.count == 2)
    }

    /// No peer anywhere: the metadata must come from xs= and every byte from ws=.
    @Test func exactSourceAndWebSeedDownloadWithoutAnyPeer() async throws {
        let (torrentBytes, content) = try Self.fixtureTorrent()
        let torrent = try TorrentFile.parse(torrentBytes)
        let server = LoopbackHTTP(routes: [
            "/meta/fixture.torrent": torrentBytes, "/seed/\(torrent.name)": content,
        ])
        let port = try await server.start()
        defer { server.stop() }
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        let engine = TorrentEngine(stateDir: root.appendingPathComponent("state"))
        await engine.configureSearchForTests(rounds: 2, delay: .milliseconds(50))
        let base = "http://127.0.0.1:\(port)"
        let magnet =
            "magnet:?xt=urn:btih:\(torrent.infoHashHex)&dn=\(torrent.name)"
            + "&xs=\(Self.encoded(base + "/meta/fixture.torrent"))&ws=\(Self.encoded(base + "/seed/"))"
        let pending = try #require(await engine.addMagnet(uri: magnet, savePath: downloads.path))
        #expect(pending.metadataSearch?.phase == .fetchingSource)

        var done = false
        for _ in 0..<200 {
            if let s = await engine.statuses().first, s.fractionComplete == 1, s.state == .seeding {
                #expect(s.metadataSearch == nil)
                done = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(done)
        #expect(
            try Data(contentsOf: downloads.appendingPathComponent(torrent.name)) == content)
        // The stored .torrent keeps the web seed, so a restart still has it.
        let stored = root.appendingPathComponent("state/torrents/\(torrent.infoHashHex).torrent")
        #expect(try TorrentFile.parse(Data(contentsOf: stored)).webSeeds == [base + "/seed/"])
        await engine.remove(infoHash: torrent.infoHashHex, deleteData: true)
    }

    /// A source serving some other torrent is refused; the search then runs out of rounds,
    /// publishes each phase on the way, ends as an error saying it gave up, and Resume restarts it.
    @Test func wrongSourceIsRefusedAndTheSearchSaysItGaveUp() async throws {
        let (otherBytes, _) = try Self.fixtureTorrent(seed: 9)
        let (rightBytes, _) = try Self.fixtureTorrent()
        let wanted = try TorrentFile.parse(rightBytes)
        let server = LoopbackHTTP(routes: ["/other.torrent": otherBytes])
        let port = try await server.start()
        defer { server.stop() }
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = TorrentEngine(stateDir: root.appendingPathComponent("state"))
        await engine.configureSearchForTests(rounds: 2, delay: .milliseconds(300))
        let magnet =
            "magnet:?xt=urn:btih:\(wanted.infoHashHex)"
            + "&xs=\(Self.encoded("http://127.0.0.1:\(port)/other.torrent"))"
        _ = try #require(await engine.addMagnet(uri: magnet, savePath: root.path))

        var seen: [TorrentSession.MetadataSearch.Phase] = []
        var last: TorrentSession.Status?
        for _ in 0..<200 {
            last = await engine.statuses().first
            if let phase = last?.metadataSearch?.phase, seen.last != phase { seen.append(phase) }
            if last?.metadataSearch?.phase == .gaveUp { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(seen.contains(.fetchingSource))
        #expect(seen.contains(.waitingToRetry))
        let status = try #require(last)
        #expect(status.metadataSearch?.phase == .gaveUp)
        #expect(status.metadataSearch?.round == 2 && status.metadataSearch?.rounds == 2)
        #expect(status.state == .error)
        #expect(status.totalLength == 0)  // never accepted the other torrent

        await engine.resume(infoHash: wanted.infoHashHex)
        let resumed = await engine.statuses().first
        #expect(resumed?.metadataSearch?.phase != .gaveUp)
        #expect(resumed?.state == .checking)
        await engine.remove(infoHash: wanted.infoHashHex, deleteData: false)
        #expect(await engine.statuses().isEmpty)
    }

    @Test func statusWithoutTheSearchFieldStillDecodes() throws {
        // An older daemon sends no metadataSearch key; the app must still decode its status.
        let json = Data(
            #"{"infoHash":"aa","name":"n","totalLength":0,"downloaded":0,"fractionComplete":0,"downloadRate":0,"uploadRate":0,"uploaded":0,"peersConnected":0,"state":"checking","savePath":"/tmp","etaSeconds":-1,"ratio":0}"#
                .utf8)
        let status = try JSONDecoder().decode(TorrentSession.Status.self, from: json)
        #expect(status.metadataSearch == nil)
    }

    // MARK: fixtures

    static func fixtureTorrent(seed: UInt8 = 1) throws -> (Data, Data) {
        let dir = tempRoot()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) })
        let file = dir.appendingPathComponent("payload-\(seed).bin")
        try content.write(to: file)
        var options = TorrentCreator.Options()
        options.pieceLength = 32 * 1024
        return (try TorrentCreator.create(contentsOf: file, options: options), content)
    }

    static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "magnet-sources-\(UUID().uuidString)")
    }

    static func encoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

/// A minimal loopback HTTP/1.1 server: GET of a fixed route, with single Range support.
private final class LoopbackHTTP: @unchecked Sendable {
    private let routes: [String: Data]
    private var listener: NWListener?
    private static let queue = DispatchQueue(label: "com.pathem.tests.loopback-http")

    init(routes: [String: Data]) { self.routes = routes }

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let routes = self.routes
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: Self.queue)
                Self.serve(connection, routes: routes, buffer: Data())
            }
            listener.start(queue: Self.queue)
        }
    }

    private static func serve(_ connection: NWConnection, routes: [String: Data], buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    serve(connection, routes: routes, buffer: buffer)
                }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            var response: Data
            if let body = routes[path] {
                var slice = body
                var status = "200 OK"
                var extra = ""
                if let range = lines.first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
                    let spec = range.split(separator: "=")[1].split(
                        separator: "-", omittingEmptySubsequences: false)
                    let lo = Int(spec[0]) ?? 0
                    let hi = min(Int(spec[1]) ?? (body.count - 1), body.count - 1)
                    slice = body.subdata(in: lo..<(hi + 1))
                    status = "206 Partial Content"
                    extra = "Content-Range: bytes \(lo)-\(hi)/\(body.count)\r\n"
                }
                response = Data(
                    "HTTP/1.1 \(status)\r\nContent-Length: \(slice.count)\r\n\(extra)Connection: close\r\n\r\n"
                        .utf8)
                response.append(slice)
            } else {
                response = Data(
                    "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
            connection.send(
                content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
