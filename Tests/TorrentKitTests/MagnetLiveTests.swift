import CryptoKit
import Foundation
import Testing

@testable import TorrentKit

/// A real magnet link, end to end on the public network: the engine finds peers through the
/// magnet's tracker, fetches the info dictionary from a peer (BEP 9), downloads every piece and
/// verifies it. Opt-in (`PATHEM_MAGNET_LIVE=1`) because it depends on the public network and on
/// the swarm. The torrent is Debian 13.7.0's amd64 netinst image (about 790 MB, free software,
/// seeded by Debian and many others). Only the magnet's info hash, name and tracker are given:
/// no .torrent file and no web seed, so the metadata must come from a peer.
///
/// An earlier choice, the Internet Archive's "Lost Books of the Bible", had no seeders at all
/// (its trackers list no complete peers; the Archive serves those through web seeds only).
@Suite struct MagnetLiveTests {
    static let enabled = ProcessInfo.processInfo.environment["PATHEM_MAGNET_LIVE"] == "1"
    static let infoHash = "7acf8fb590b2060dd9c3146ef770169d593433b0"
    static let name = "debian-13.7.0-amd64-netinst.iso"
    /// From https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS.
    static let sha256 = "a7ef94ac2fb9a7fec454552abd629b7cc9d5155c886165a45649f5ce6167e355"
    static let magnet =
        "magnet:?xt=urn:btih:\(infoHash)&dn=\(name)"
        + "&tr=http%3A%2F%2Fbttracker.debian.org%3A6969%2Fannounce"

    @Test(.enabled(if: MagnetLiveTests.enabled), .timeLimit(.minutes(30)))
    func publicMagnetDownloadsVerifiedBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("magnet-live-\(UUID().uuidString)")
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = TorrentEngine(stateDir: root.appendingPathComponent("state"))
        let pending = try #require(
            await engine.addMagnet(uri: Self.magnet, savePath: downloads.path))
        #expect(pending.state == .checking)
        let start = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(start)) }
        var finished: TorrentSession.Status?
        var lastReport = Date.distantPast
        var resolved = false
        while Date().timeIntervalSince(start) < 1680 {
            if let status = await engine.statuses().first {
                if !resolved, status.totalLength > 0 {
                    resolved = true
                    print(
                        "LIVE metadata after \(elapsed())s: \(status.name), \(status.totalLength) bytes"
                    )
                }
                if Date().timeIntervalSince(lastReport) > 15 {
                    lastReport = Date()
                    print(
                        "LIVE t=\(elapsed())s state=\(status.state) peers=\(status.peersConnected) "
                            + "done=\(String(format: "%.1f", status.fractionComplete * 100))% "
                            + "rate=\(Int(status.downloadRate / 1024)) KiB/s")
                }
                if status.fractionComplete == 1, status.state == .seeding {
                    finished = status
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        let status = try #require(finished, "the magnet did not complete in time")
        print("LIVE complete after \(elapsed())s: \(status.downloaded) bytes")

        // Independent of the engine's own piece checks: the image must match Debian's SHA-256.
        let file = downloads.appendingPathComponent(Self.name)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        print("LIVE sha256 \(digest)")
        #expect(digest == Self.sha256)

        await engine.remove(infoHash: Self.infoHash, deleteData: true)
        #expect(await engine.statuses().isEmpty)
    }
}
