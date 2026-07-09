import Foundation

/// Owns every active torrent: adds/removes/pauses them, aggregates their status, and persists
/// enough state (the .torrent files plus which pieces are done) to resume across restarts. The
/// daemon wraps one of these; the app never touches it directly.
public actor TorrentEngine {
    /// What we save to disk so a torrent survives a restart.
    struct Persisted: Codable {
        var infoHashHex: String
        var torrentFileName: String   // file within `torrentsDir`
        var savePath: String
        var paused: Bool
        var completedPieces: [Int]
    }

    private let stateDir: URL
    private let torrentsDir: URL
    private let peerID = Tracker.makePeerID()

    private var sessions: [String: TorrentSession] = [:]
    private var meta: [String: Persisted]

    public init(stateDir: URL) {
        self.stateDir = stateDir
        self.torrentsDir = stateDir.appendingPathComponent("torrents")
        try? FileManager.default.createDirectory(at: torrentsDir, withIntermediateDirectories: true)
        self.meta = Self.loadState(from: stateDir.appendingPathComponent("state.json"))
    }

    // MARK: commands

    /// Add a torrent from a .torrent file, copying it into the state directory and starting it.
    @discardableResult
    public func addTorrentFile(at path: String, savePath: String) async throws -> TorrentSession.Status {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let torrent = try TorrentFile.parse(data)
        let hash = torrent.infoHashHex
        if let existing = sessions[hash] { return await existing.status() }

        let storedName = "\(hash).torrent"
        try data.write(to: torrentsDir.appendingPathComponent(storedName))

        let session = try TorrentSession(
            torrent: torrent, downloadRoot: URL(fileURLWithPath: savePath), peerID: peerID)
        sessions[hash] = session
        meta[hash] = Persisted(
            infoHashHex: hash, torrentFileName: storedName, savePath: savePath,
            paused: false, completedPieces: [])
        await session.start()
        saveState()
        return await session.status()
    }

    public func remove(infoHash: String, deleteData: Bool) async {
        guard let session = sessions[infoHash] else { return }
        let savePath = await session.status().savePath
        let name = session.torrent.name
        await session.stop()
        sessions[infoHash] = nil
        if let stored = meta[infoHash]?.torrentFileName {
            try? FileManager.default.removeItem(at: torrentsDir.appendingPathComponent(stored))
        }
        if deleteData {
            let target = URL(fileURLWithPath: savePath).appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
        }
        meta[infoHash] = nil
        saveState()
    }

    public func pause(infoHash: String) async {
        guard let session = sessions[infoHash] else { return }
        await session.pause()
        meta[infoHash]?.paused = true
        meta[infoHash]?.completedPieces = await session.completedPieces()
        saveState()
    }

    public func resume(infoHash: String) async {
        guard let session = sessions[infoHash] else { return }
        await session.start()
        meta[infoHash]?.paused = false
        saveState()
    }

    /// Snapshot every torrent for the UI.
    public func statuses() async -> [TorrentSession.Status] {
        var out: [TorrentSession.Status] = []
        for session in sessions.values { out.append(await session.status()) }
        return out.sorted { $0.name < $1.name }
    }

    /// Snapshot resume data (completed pieces) for all torrents and write state to disk. The
    /// daemon calls this on a timer so progress survives a crash.
    public func checkpoint() async {
        for (hash, session) in sessions {
            meta[hash]?.completedPieces = await session.completedPieces()
        }
        saveState()
    }

    // MARK: restore

    /// Recreate sessions from persisted metadata, marking already-downloaded pieces and resuming
    /// any that weren't paused. Called once at daemon startup.
    public func restoreAll() async {
        for persisted in meta.values {
            let fileURL = torrentsDir.appendingPathComponent(persisted.torrentFileName)
            guard let data = try? Data(contentsOf: fileURL),
                let torrent = try? TorrentFile.parse(data),
                let session = try? TorrentSession(
                    torrent: torrent, downloadRoot: URL(fileURLWithPath: persisted.savePath), peerID: peerID)
            else { continue }
            await session.loadResume(havePieces: persisted.completedPieces)
            sessions[persisted.infoHashHex] = session
            if !persisted.paused { await session.start() }
        }
    }

    // MARK: persistence

    private var stateFile: URL { stateDir.appendingPathComponent("state.json") }

    private static func loadState(from file: URL) -> [String: Persisted] {
        guard let data = try? Data(contentsOf: file),
            let list = try? JSONDecoder().decode([Persisted].self, from: data)
        else { return [:] }
        var out: [String: Persisted] = [:]
        for item in list { out[item.infoHashHex] = item }
        return out
    }

    private func saveState() {
        let list = Array(meta.values)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: stateFile) }
    }
}
