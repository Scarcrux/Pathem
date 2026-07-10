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
        var wantedFiles: [Int]?       // nil = all files (per-file selection)
    }

    /// A magnet whose metadata we're still fetching from peers (no info dict yet).
    private struct PendingMagnet {
        var infoHashHex: String
        var infoHash: Data
        var name: String
        var savePath: String
        var trackers: [String]
    }

    private let stateDir: URL
    private let torrentsDir: URL
    private let peerID = Tracker.makePeerID()
    private let dht = DHTClient()  // shared across sessions for trackerless peer discovery
    private lazy var dhtServer = DHTServer(client: dht)  // serves DHT queries: a full participant
    private let natpmp = NATPMPClient()  // best-effort router port mapping for inbound peers
    private let upnp = UPnPClient()      // fallback when the router speaks UPnP, not NAT-PMP
    private let downLimiter: RateLimiter  // global caps (0 = unlimited), shared by all sessions
    private let uploadLimiter: RateLimiter
    private var limits: Limits

    /// Global speed caps in bytes/second (0 = unlimited), plus the super-seed toggle.
    public struct Limits: Codable, Sendable, Equatable {
        public var down: Int
        public var up: Int
        public var superSeed: Bool
        public var encryptOutgoing: Bool
        public init(down: Int = 0, up: Int = 0, superSeed: Bool = false, encryptOutgoing: Bool = false) {
            self.down = down
            self.up = up
            self.superSeed = superSeed
            self.encryptOutgoing = encryptOutgoing
        }
        // Tolerate older limits.json that predates these keys.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            down = try c.decodeIfPresent(Int.self, forKey: .down) ?? 0
            up = try c.decodeIfPresent(Int.self, forKey: .up) ?? 0
            superSeed = try c.decodeIfPresent(Bool.self, forKey: .superSeed) ?? false
            encryptOutgoing = try c.decodeIfPresent(Bool.self, forKey: .encryptOutgoing) ?? false
        }
    }

    private var sessions: [String: TorrentSession] = [:]
    private var meta: [String: Persisted]
    private var pending: [String: PendingMagnet] = [:]
    private var resolverTasks: [String: Task<Void, Never>] = [:]
    private var listener: PeerListener?

    public init(stateDir: URL) {
        self.stateDir = stateDir
        self.torrentsDir = stateDir.appendingPathComponent("torrents")
        try? FileManager.default.createDirectory(at: torrentsDir, withIntermediateDirectories: true)
        self.meta = Self.loadState(from: stateDir.appendingPathComponent("state.json"))
        let loaded = Self.loadLimits(from: stateDir.appendingPathComponent("limits.json"))
        self.limits = loaded
        self.downLimiter = RateLimiter(bytesPerSecond: loaded.down)
        self.uploadLimiter = RateLimiter(bytesPerSecond: loaded.up)
    }

    /// Set the global download / upload caps (bytes/second, 0 = unlimited) and the super-seed
    /// toggle, apply them live, and persist.
    public func setLimits(down: Int, up: Int, superSeed: Bool, encryptOutgoing: Bool) async {
        limits = Limits(down: down, up: up, superSeed: superSeed, encryptOutgoing: encryptOutgoing)
        await downLimiter.setRate(bytesPerSecond: down)
        await uploadLimiter.setRate(bytesPerSecond: up)
        for session in sessions.values {
            await session.setSuperSeeding(superSeed)
            await session.setPreferEncryption(encryptOutgoing)
        }
        if let data = try? JSONEncoder().encode(limits) {
            try? data.write(to: stateDir.appendingPathComponent("limits.json"))
        }
    }

    public func currentLimits() -> Limits { limits }

    /// The files of a torrent and their selection state (empty if there's no such session).
    public func files(infoHash: String) async -> [TorrentSession.FileInfo] {
        guard let session = sessions[infoHash] else { return [] }
        return await session.files()
    }

    /// Set which files of a torrent to download (nil = all), apply live, and persist.
    public func setFiles(infoHash: String, wanted: [Int]?) async {
        guard let session = sessions[infoHash] else { return }
        await session.setWantedFiles(wanted.map(Set.init))
        meta[infoHash]?.wantedFiles = wanted
        saveState()
    }

    private static func loadLimits(from file: URL) -> Limits {
        guard let data = try? Data(contentsOf: file),
            let limits = try? JSONDecoder().decode(Limits.self, from: data)
        else { return Limits() }
        return limits
    }

    /// Start accepting incoming peers so we can seed to peers that dial us. Idempotent; safe to
    /// call on every add. Failure to bind (e.g. port in use) is non-fatal: outbound still works.
    private func ensureListener() async {
        guard listener == nil else { return }
        let l = PeerListener(peerID: peerID) { [weak self] hex, peer in
            guard let self, let session = await self.session(forHash: hex) else {
                await peer.close()
                return
            }
            await session.acceptIncomingPeer(peer)
        }
        listener = l
        _ = try? await l.start(port: 6881)
        // Serve DHT queries on the same port (UDP), turning us from a lookup-only client into a
        // full participant: other nodes can find peers through us and announce to us.
        _ = try? await dhtServer.start(port: 6881)
        // Ask the router to forward our port so peers behind NAT can reach us (best-effort):
        // try NAT-PMP first, then fall back to UPnP-IGD if that gets no answer.
        Task { [natpmp, upnp] in
            if await natpmp.mapTCP(port: 6881) == nil {
                _ = await upnp.mapTCP(port: 6881)
            }
        }
    }

    private func session(forHash hex: String) -> TorrentSession? { sessions[hex] }

    // MARK: commands

    /// Add a torrent from a .torrent file, copying it into the state directory and starting it.
    @discardableResult
    public func addTorrentFile(at path: String, savePath: String) async throws -> TorrentSession.Status {
        await ensureListener()
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let torrent = try TorrentFile.parse(data)
        let hash = torrent.infoHashHex
        if let existing = sessions[hash] { return await existing.status() }

        let storedName = "\(hash).torrent"
        try data.write(to: torrentsDir.appendingPathComponent(storedName))

        let session = try TorrentSession(
            torrent: torrent, downloadRoot: URL(fileURLWithPath: savePath), peerID: peerID, dht: dht, downLimiter: downLimiter, uploadLimiter: uploadLimiter)
        sessions[hash] = session
        meta[hash] = Persisted(
            infoHashHex: hash, torrentFileName: storedName, savePath: savePath,
            paused: false, completedPieces: [])
        await session.setSuperSeeding(limits.superSeed)
        await session.setPreferEncryption(limits.encryptOutgoing)
        await session.start()
        saveState()
        return await session.status()
    }

    /// Add a magnet link. Since a magnet carries no metadata, this registers a pending torrent
    /// (shown as "checking") and kicks off a background resolver that fetches the info dict from
    /// peers, then promotes it to a normal download. Returns a placeholder status, or nil if the
    /// magnet URI is invalid.
    @discardableResult
    public func addMagnet(uri: String, savePath: String) -> TorrentSession.Status? {
        guard let magnet = Magnet.parse(uri) else { return nil }
        let hash = magnet.infoHashHex
        if sessions[hash] != nil || pending[hash] != nil {
            return pending[hash].map(pendingStatus)
        }
        let entry = PendingMagnet(
            infoHashHex: hash, infoHash: magnet.infoHash, name: magnet.displayName ?? hash,
            savePath: savePath, trackers: magnet.trackers)
        pending[hash] = entry
        resolverTasks[hash] = Task { [weak self] in await self?.resolveMagnet(hash) }
        return pendingStatus(entry)
    }

    public func remove(infoHash: String, deleteData: Bool) async {
        if pending[infoHash] != nil {
            resolverTasks[infoHash]?.cancel()
            resolverTasks[infoHash] = nil
            pending[infoHash] = nil
            return
        }
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

    /// Snapshot every torrent for the UI, including magnets still fetching their metadata.
    public func statuses() async -> [TorrentSession.Status] {
        var out: [TorrentSession.Status] = []
        for session in sessions.values { out.append(await session.status()) }
        for entry in pending.values { out.append(pendingStatus(entry)) }
        return out.sorted { $0.name < $1.name }
    }

    private func pendingStatus(_ entry: PendingMagnet) -> TorrentSession.Status {
        TorrentSession.Status(
            infoHash: entry.infoHashHex, name: entry.name, totalLength: 0, downloaded: 0,
            fractionComplete: 0, downloadRate: 0, peersConnected: 0, state: .checking,
            savePath: entry.savePath)
    }

    // MARK: magnet resolution

    /// Fetch a magnet's metadata from peers over several rounds (trackers and peers can be slow or
    /// lack extension support), then promote it to a real session. Gives up quietly after a few
    /// rounds, leaving the torrent shown as "checking" so the user can remove it.
    private func resolveMagnet(_ hash: String) async {
        for round in 0..<8 {
            if Task.isCancelled { return }
            guard let entry = pending[hash] else { return }
            let peers = await gatherPeers(entry)
            if let resolved = await fetchMetadata(entry, from: peers) {
                await promote(hash: hash, resolved: resolved, savePath: entry.savePath)
                return
            }
            if Task.isCancelled || pending[hash] == nil { return }
            // Back off before re-announcing; a little longer each round.
            try? await Task.sleep(nanoseconds: UInt64(10 + round * 5) * 1_000_000_000)
        }
    }

    /// Gather peers to fetch a magnet's metadata from: its HTTP trackers plus the DHT, so a
    /// trackerless magnet still resolves.
    private func gatherPeers(_ entry: PendingMagnet) async -> [Tracker.Peer] {
        var peers: [Tracker.Peer] = []
        for tracker in entry.trackers where tracker.hasPrefix("http") {
            if let response = try? await Tracker.announce(
                base: tracker, infoHash: entry.infoHash, peerID: peerID, port: 6881, left: 0,
                event: .started)
            {
                peers.append(contentsOf: response.peers)
            }
        }
        // The DHT is what makes a trackerless magnet work: it finds peers we can ask for metadata.
        peers.append(contentsOf: await dht.findPeers(infoHash: entry.infoHash))
        var seen = Set<Tracker.Peer>()
        return peers.filter { seen.insert($0).inserted }
    }

    /// Race several peers for the metadata; keep the first that returns a verified torrent.
    private func fetchMetadata(_ entry: PendingMagnet, from peers: [Tracker.Peer]) async
        -> MetadataExchange.ResolvedTorrent?
    {
        guard !peers.isEmpty else { return nil }
        let peerID = self.peerID
        let infoHash = entry.infoHash
        let trackers = entry.trackers
        return await withTaskGroup(of: MetadataExchange.ResolvedTorrent?.self) { group in
            for peer in peers.prefix(12) {
                group.addTask {
                    await MetadataFetcher.fetch(
                        host: peer.host, port: UInt16(peer.port), infoHash: infoHash,
                        peerID: peerID, trackers: trackers)
                }
            }
            for await result in group where result != nil {
                group.cancelAll()
                return result
            }
            return nil
        }
    }

    /// Turn a resolved magnet into a persisted, running download.
    private func promote(hash: String, resolved: MetadataExchange.ResolvedTorrent, savePath: String) async {
        // Do the (possibly slow) listener setup BEFORE the guard, so the check-and-commit below is
        // atomic on the actor. Otherwise a remove() during the ensureListener await could clear
        // `pending[hash]` and this would resurrect the removed magnet.
        await ensureListener()
        guard pending[hash] != nil, sessions[hash] == nil else { return }
        pending[hash] = nil
        resolverTasks[hash] = nil
        let storedName = "\(hash).torrent"
        try? resolved.torrentBytes.write(to: torrentsDir.appendingPathComponent(storedName))
        guard let session = try? TorrentSession(
            torrent: resolved.torrent, downloadRoot: URL(fileURLWithPath: savePath), peerID: peerID, dht: dht, downLimiter: downLimiter, uploadLimiter: uploadLimiter)
        else { return }
        sessions[hash] = session
        meta[hash] = Persisted(
            infoHashHex: hash, torrentFileName: storedName, savePath: savePath, paused: false,
            completedPieces: [])
        await session.setSuperSeeding(limits.superSeed)
        await session.setPreferEncryption(limits.encryptOutgoing)
        await session.start()
        saveState()
    }

    /// Snapshot resume data (completed pieces) for all torrents and write state to disk. The
    /// daemon calls this on a timer so progress survives a crash.
    public func checkpoint() async {
        for (hash, session) in sessions {
            meta[hash]?.completedPieces = await session.completedPieces()
        }
        saveState()
        // Persist the DHT routing table so the next run warm-starts (small; written with state).
        let routingTable = await dht.routingTableData()
        if !routingTable.isEmpty { try? routingTable.write(to: dhtFile) }
    }

    private var dhtFile: URL { stateDir.appendingPathComponent("dht.dat") }

    // MARK: restore

    /// Recreate sessions from persisted metadata, marking already-downloaded pieces and resuming
    /// any that weren't paused. Called once at daemon startup.
    public func restoreAll() async {
        await ensureListener()
        // Warm-start the DHT from the routing table saved last run.
        if let data = try? Data(contentsOf: dhtFile) { await dht.loadRoutingTable(data) }
        for persisted in meta.values {
            let fileURL = torrentsDir.appendingPathComponent(persisted.torrentFileName)
            guard let data = try? Data(contentsOf: fileURL),
                let torrent = try? TorrentFile.parse(data),
                let session = try? TorrentSession(
                    torrent: torrent, downloadRoot: URL(fileURLWithPath: persisted.savePath), peerID: peerID, dht: dht, downLimiter: downLimiter, uploadLimiter: uploadLimiter)
            else { continue }
            await session.loadResume(havePieces: persisted.completedPieces)
            if let wanted = persisted.wantedFiles { await session.setWantedFiles(Set(wanted)) }
            await session.setSuperSeeding(limits.superSeed)
        await session.setPreferEncryption(limits.encryptOutgoing)
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
