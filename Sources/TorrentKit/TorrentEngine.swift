import Foundation

/// Owns every active torrent: adds/removes/pauses them, aggregates their status, and persists
/// enough state (the .torrent files plus which pieces are done) to resume across restarts. The
/// daemon wraps one of these; the app never touches it directly.
public actor TorrentEngine {
    /// What we save to disk so a torrent survives a restart.
    struct Persisted: Codable {
        var infoHashHex: String
        var torrentFileName: String  // file within `torrentsDir`
        var savePath: String
        var paused: Bool
        var completedPieces: [Int]
        var wantedFiles: [Int]?  // nil = all files (per-file selection)
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
    private let upnp = UPnPClient()  // fallback when the router speaks UPnP, not NAT-PMP
    private let downLimiter: RateLimiter  // global caps (0 = unlimited), shared by all sessions
    private let uploadLimiter: RateLimiter
    private var limits: Limits

    /// Global speed caps in bytes/second (0 = unlimited), plus the super-seed toggle.
    public struct Limits: Codable, Sendable, Equatable {
        public var down: Int
        public var up: Int
        public var superSeed: Bool
        public var encryptOutgoing: Bool
        public var preferUTP: Bool
        public var bindToVPN: Bool  // pin torrent traffic to a VPN tunnel, kill-switch when it drops
        public init(
            down: Int = 0, up: Int = 0, superSeed: Bool = false, encryptOutgoing: Bool = false,
            preferUTP: Bool = false, bindToVPN: Bool = false
        ) {
            self.down = down
            self.up = up
            self.superSeed = superSeed
            self.encryptOutgoing = encryptOutgoing
            self.preferUTP = preferUTP
            self.bindToVPN = bindToVPN
        }
        // Tolerate older limits.json that predates these keys.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            down = try c.decodeIfPresent(Int.self, forKey: .down) ?? 0
            up = try c.decodeIfPresent(Int.self, forKey: .up) ?? 0
            superSeed = try c.decodeIfPresent(Bool.self, forKey: .superSeed) ?? false
            encryptOutgoing = try c.decodeIfPresent(Bool.self, forKey: .encryptOutgoing) ?? false
            preferUTP = try c.decodeIfPresent(Bool.self, forKey: .preferUTP) ?? false
            bindToVPN = try c.decodeIfPresent(Bool.self, forKey: .bindToVPN) ?? false
        }
    }

    private var sessions: [String: TorrentSession] = [:]
    private var meta: [String: Persisted]
    private var pending: [String: PendingMagnet] = [:]
    private var resolverTasks: [String: Task<Void, Never>] = [:]
    private var listener: PeerListener?
    private var mux: UDPMux?  // owns the shared UDP port: demuxes DHT KRPC vs inbound µTP peers
    private let vpnMonitor = VPNMonitor()
    private var vpnMonitorStarted = false
    private var killSwitchPaused: Set<String> = []  // torrents auto-paused by the kill-switch
    private var vpnInterfaceName: String?  // the bound tunnel, surfaced for status
    private var vpnEvaluated = false  // distinguishes "no VPN" from "not yet checked"

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
    public func setLimits(
        down: Int, up: Int, superSeed: Bool, encryptOutgoing: Bool, preferUTP: Bool = false,
        bindToVPN: Bool = false
    ) async {
        let wasBinding = limits.bindToVPN
        limits = Limits(
            down: down, up: up, superSeed: superSeed, encryptOutgoing: encryptOutgoing,
            preferUTP: preferUTP, bindToVPN: bindToVPN)
        await downLimiter.setRate(bytesPerSecond: down)
        await uploadLimiter.setRate(bytesPerSecond: up)
        for session in sessions.values {
            await session.setSuperSeeding(superSeed)
            await session.setPreferEncryption(encryptOutgoing)
            await session.setPreferUTP(preferUTP)
        }
        if let data = try? JSONEncoder().encode(limits) {
            try? data.write(to: stateDir.appendingPathComponent("limits.json"))
        }
        if bindToVPN != wasBinding { await applyVPNBinding(bindToVPN) }
    }

    // MARK: VPN binding + kill-switch

    /// Turn VPN binding on or off. On: start watching for a tunnel; bind new sockets to it and, if no
    /// tunnel is up, engage the kill-switch (pause everything) so nothing leaks. Off: stop watching,
    /// unbind, and release anything the kill-switch had paused.
    private func applyVPNBinding(_ on: Bool) async {
        if on {
            guard !vpnMonitorStarted else { return }
            vpnMonitorStarted = true
            await vpnMonitor.start { [weak self] name in
                Task { await self?.onVPNChanged(name) }
            }
            // Resolve the current tunnel immediately (and unconditionally), so enabling with no VPN
            // engages the kill-switch now rather than after the first network change. This sets the
            // binding, then drives onVPNChanged via the callback above.
            await vpnMonitor.evaluateNow()
        } else {
            await vpnMonitor.stop()
            vpnMonitorStarted = false
            vpnInterfaceName = nil
            vpnEvaluated = false
            NetworkBinding.shared.requiredInterface = nil
            await releaseKillSwitch()
        }
    }

    /// React to a tunnel appearing, changing, or dropping while binding is enabled.
    private func onVPNChanged(_ delivered: String?) async {
        guard limits.bindToVPN else { return }
        // The callback delivers names via independent unstructured Tasks with no FIFO guarantee,
        // so a drop-then-reconnect pair can arrive reordered. Trust the monitor's LIVE truth
        // instead of the delivered name: re-querying makes the reaction idempotent and
        // order-independent (a late, stale task reads the current state and no-ops).
        _ = delivered
        let name = await vpnMonitor.activeVPNName()
        // Skip genuine no-ops (path updates fire often), but always act on the first evaluation so
        // enabling with no VPN engages the kill-switch instead of being mistaken for "no change".
        if vpnEvaluated && name == vpnInterfaceName { return }
        vpnEvaluated = true
        vpnInterfaceName = name
        if name != nil {
            // A tunnel is up (the monitor already pinned new sockets to it). Rebind the inbound
            // listeners onto it and release anything the kill-switch paused.
            await rebindListeners()
            await releaseKillSwitch()
        } else {
            // No tunnel: kill-switch. Pause everything that's running so no packet takes the real
            // interface; remember what we paused so we can resume it when a tunnel returns.
            for (hash, session) in sessions {
                let state = await session.status().state
                if state == .downloading || state == .seeding {
                    await session.pause()
                    killSwitchPaused.insert(hash)
                }
            }
        }
    }

    /// Resume the torrents the kill-switch paused (unless the user has since paused them).
    private func releaseKillSwitch() async {
        for hash in killSwitchPaused where meta[hash]?.paused != true {
            await sessions[hash]?.start()
        }
        killSwitchPaused.removeAll()
    }

    /// Recreate the inbound listeners so they bind to the current interface.
    private func rebindListeners() async {
        await listener?.stop()
        listener = nil
        await mux?.stop()
        mux = nil
        await ensureListener()
    }

    /// The bound VPN tunnel's name, or nil when binding is off or the kill-switch is engaged.
    public func vpnStatus() -> String? { limits.bindToVPN ? vpnInterfaceName : nil }

    /// True when binding is on but no tunnel is up: nothing may run (the kill-switch).
    private var killSwitchEngaged: Bool { limits.bindToVPN && vpnInterfaceName == nil }

    /// If the kill-switch is engaged, immediately pause a just-started session so it can't touch the
    /// real interface; it resumes automatically when a tunnel returns.
    private func holdIfKillSwitch(_ hash: String) async {
        guard killSwitchEngaged, let session = sessions[hash] else { return }
        await session.pause()
        killSwitchPaused.insert(hash)
    }

    public func currentLimits() -> Limits { limits }

    /// The files of a torrent and their selection state (empty if there's no such session).
    public func files(infoHash: String) async -> [TorrentSession.FileInfo] {
        guard let session = sessions[infoHash] else { return [] }
        return await session.files()
    }

    /// The connected peers for a torrent (detail view's Peers tab).
    public func peers(infoHash: String) async -> [TorrentSession.PeerInfo] {
        guard let session = sessions[infoHash] else { return [] }
        return await session.peers()
    }

    /// A torrent's announce sources: its trackers, plus a synthetic "DHT" / "Peer Exchange" entry
    /// when it isn't private (detail view's Trackers tab).
    public func trackers(infoHash: String) async -> [String] {
        guard let session = sessions[infoHash] else { return [] }
        var out = await session.trackerURLs()
        if await session.usesDHT {
            out.append("DHT")
            out.append("Peer Exchange")
        }
        return out
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
        // One mux owns the UDP side of the same port and demultiplexes it: DHT KRPC (making us a full
        // DHT participant) and inbound µTP peer connections, which share the port with the DHT.
        let m = UDPMux(dht: dhtServer, peerID: peerID) { [weak self] hex, peer in
            guard let self, let session = await self.session(forHash: hex) else {
                await peer.close()
                return
            }
            await session.acceptIncomingPeer(peer)
        }
        mux = m
        _ = try? await m.start(port: 6881)
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
    public func addTorrentFile(at path: String, savePath: String) async throws
        -> TorrentSession.Status
    {
        await ensureListener()
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let torrent = try TorrentFile.parse(data)
        let hash = torrent.infoHashHex
        if let existing = sessions[hash] { return await existing.status() }

        let storedName = "\(hash).torrent"
        try data.write(to: torrentsDir.appendingPathComponent(storedName))

        let session = try TorrentSession(
            torrent: torrent, downloadRoot: URL(fileURLWithPath: savePath), peerID: peerID,
            dht: dht, downLimiter: downLimiter, uploadLimiter: uploadLimiter)
        sessions[hash] = session
        meta[hash] = Persisted(
            infoHashHex: hash, torrentFileName: storedName, savePath: savePath,
            paused: false, completedPieces: [])
        await session.setSuperSeeding(limits.superSeed)
        await session.setPreferEncryption(limits.encryptOutgoing)
        await session.setPreferUTP(limits.preferUTP)
        await session.start()
        await holdIfKillSwitch(hash)  // don't let a new torrent run while the VPN is down
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
        meta[infoHash]?.paused = false
        // While the kill-switch is engaged, honor the user's intent but keep it paused; it starts
        // when a tunnel returns.
        if killSwitchEngaged {
            killSwitchPaused.insert(infoHash)
        } else {
            await session.start()
        }
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
                await promote(
                    hash: hash, resolved: resolved, savePath: entry.savePath,
                    discoveredPeers: peers)
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
        // The DHT is what makes a trackerless magnet work. A responsive tracker already gave us
        // candidates, so do not delay metadata fetch on a public-network lookup we do not need.
        if peers.isEmpty { peers.append(contentsOf: await dht.findPeers(infoHash: entry.infoHash)) }
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
    private func promote(
        hash: String, resolved: MetadataExchange.ResolvedTorrent, savePath: String,
        discoveredPeers: [Tracker.Peer]
    ) async {
        // Do the (possibly slow) listener setup BEFORE the guard, so the check-and-commit below is
        // atomic on the actor. Otherwise a remove() during the ensureListener await could clear
        // `pending[hash]` and this would resurrect the removed magnet.
        await ensureListener()
        guard pending[hash] != nil, sessions[hash] == nil else { return }
        pending[hash] = nil
        resolverTasks[hash] = nil
        let storedName = "\(hash).torrent"
        try? resolved.torrentBytes.write(to: torrentsDir.appendingPathComponent(storedName))
        guard
            let session = try? TorrentSession(
                torrent: resolved.torrent, downloadRoot: URL(fileURLWithPath: savePath),
                peerID: peerID, dht: dht, downLimiter: downLimiter, uploadLimiter: uploadLimiter)
        else { return }
        sessions[hash] = session
        meta[hash] = Persisted(
            infoHashHex: hash, torrentFileName: storedName, savePath: savePath, paused: false,
            completedPieces: [])
        await session.setSuperSeeding(limits.superSeed)
        await session.setPreferEncryption(limits.encryptOutgoing)
        await session.setPreferUTP(limits.preferUTP)
        await session.start()
        // The peer that supplied magnet metadata almost certainly has the payload too. Keeping it
        // closes the resolution-to-download seam and avoids waiting for another tracker/DHT round.
        await session.addPeers(discoveredPeers)
        await holdIfKillSwitch(hash)
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
                    torrent: torrent, downloadRoot: URL(fileURLWithPath: persisted.savePath),
                    peerID: peerID, dht: dht, downLimiter: downLimiter, uploadLimiter: uploadLimiter
                )
            else { continue }
            await session.loadResume(havePieces: persisted.completedPieces)
            if let wanted = persisted.wantedFiles { await session.setWantedFiles(Set(wanted)) }
            await session.setSuperSeeding(limits.superSeed)
            await session.setPreferEncryption(limits.encryptOutgoing)
            await session.setPreferUTP(limits.preferUTP)
            sessions[persisted.infoHashHex] = session
            if persisted.paused {
                // A newly constructed session begins as .stopped. Preserve the user-visible
                // distinction across daemon restarts: this torrent was deliberately paused, not
                // stopped by an error or shutdown.
                await session.pause()
            } else {
                // With binding on we hold everything until the tunnel is confirmed (below); otherwise
                // start normally.
                if killSwitchEngaged {
                    killSwitchPaused.insert(persisted.infoHashHex)
                } else {
                    await session.start()
                }
            }
        }
        // Now that torrents are loaded, engage binding if it was enabled: this confirms a tunnel and
        // releases the held torrents, or keeps the kill-switch engaged if none is up.
        if limits.bindToVPN { await applyVPNBinding(true) }
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
