import Foundation
import Testing

@testable import TorrentKit

@Suite struct TorrentPersistenceTests {
    @Test func pausedStateSurvivesEngineRestart() async throws {
        let fm = FileManager.default
        let stateDir = fm.temporaryDirectory.appendingPathComponent(
            "torrent-paused-restore-\(UUID().uuidString)")
        let saveDir = stateDir.appendingPathComponent("downloads")
        try fm.createDirectory(at: saveDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stateDir) }

        func encoded(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        let pieces = String(repeating: "a", count: 20)
        let info =
            "d" + encoded("length") + "i1024e" + encoded("name") + encoded("paused.bin")
            + encoded("piece length") + "i16384e" + encoded("pieces") + "20:\(pieces)e"
        let torrentURL = stateDir.appendingPathComponent("paused.torrent")
        try Data(("d" + encoded("info") + info + "e").utf8).write(to: torrentURL)

        let engine = TorrentEngine(stateDir: stateDir)
        let added = try await engine.addTorrentFile(at: torrentURL.path, savePath: saveDir.path)
        await engine.pause(infoHash: added.infoHash)

        let reopened = TorrentEngine(stateDir: stateDir)
        await reopened.restoreAll()
        let restored = await reopened.statuses()
        #expect(restored.count == 1)
        #expect(restored.first?.state == .paused)
    }
}
