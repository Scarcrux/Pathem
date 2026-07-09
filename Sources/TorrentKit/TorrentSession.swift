import Foundation

/// Drives one torrent to completion: announces to trackers for peers, opens several peer
/// connections, keeps a request pipeline full, verifies and writes each finished piece, then
/// seeds. An actor, so its bookkeeping (piece manager, in-flight set, peer roster) is serialized.
/// The daemon owns one session per torrent and polls `status()` for the UI.
public actor TorrentSession {
    public enum State: String, Sendable, Codable {
        case stopped, checking, downloading, seeding, paused, error
    }

    /// A snapshot of a torrent for the UI (Codable so the daemon can ship it over the wire).
    public struct Status: Sendable, Codable, Equatable {
        public var infoHash: String
        public var name: String
        public var totalLength: Int64
        public var downloaded: Int64
        public var fractionComplete: Double
        public var downloadRate: Double   // bytes/sec, smoothed
        public var uploadRate: Double      // bytes/sec, smoothed
        public var uploaded: Int64         // total bytes served to peers this session
        public var peersConnected: Int
        public var state: State
        public var savePath: String

        public init(
            infoHash: String, name: String, totalLength: Int64, downloaded: Int64,
            fractionComplete: Double, downloadRate: Double, uploadRate: Double = 0,
            uploaded: Int64 = 0, peersConnected: Int, state: State, savePath: String
        ) {
            self.infoHash = infoHash
            self.name = name
            self.totalLength = totalLength
            self.downloaded = downloaded
            self.fractionComplete = fractionComplete
            self.downloadRate = downloadRate
            self.uploadRate = uploadRate
            self.uploaded = uploaded
            self.peersConnected = peersConnected
            self.state = state
            self.savePath = savePath
        }
    }

    public let torrent: TorrentFile
    private let downloadRoot: URL
    private let peerID: Data
    private let pieces: PieceManager
    private let layout: FileLayout
    private let storage: TorrentStorage

    private var state: State = .stopped
    private var peerTasks: [Task<Void, Never>] = []
    private var connectedPeers = 0
    private var globalInFlight: Set<PieceManager.BlockRequest> = []
    private var knownPeers: Set<Tracker.Peer> = []
    private var activePeers: [PeerConnection] = []  // connected peers, for have-broadcast + serving
    private var announceTask: Task<Void, Never>?

    private let maxPeers = 30
    private let maxInFlightPerPeer = 8
    private let maxServedBlock = 32 * 1024  // reject absurd block requests from peers

    // Rate estimates (download and upload), sampled in status().
    private var lastSampleBytes: Int64 = 0
    private var lastSampleTime = Date()
    private var smoothedRate: Double = 0
    private var uploadedBytes: Int64 = 0
    private var lastUploadBytes: Int64 = 0
    private var smoothedUploadRate: Double = 0

    public init(torrent: TorrentFile, downloadRoot: URL, peerID: Data = Tracker.makePeerID()) throws {
        self.torrent = torrent
        self.downloadRoot = downloadRoot
        self.peerID = peerID
        self.pieces = PieceManager(torrent: torrent)
        self.layout = FileLayout(torrent: torrent)
        // Multi-file torrents nest their files under the torrent name; single-file already has it.
        let root = torrent.files.count > 1 ? downloadRoot.appendingPathComponent(torrent.name) : downloadRoot
        self.storage = try TorrentStorage(root: root, layout: layout)
    }

    // MARK: control

    public func start() {
        guard state == .stopped || state == .paused else { return }
        state = pieces.isComplete ? .seeding : .downloading
        lastSampleTime = Date()
        lastSampleBytes = pieces.downloadedBytes
        startAnnouncing()
    }

    public func pause() {
        state = .paused
        stopAllTasks()
    }

    public func stop() {
        state = .stopped
        stopAllTasks()
        storage.close()
    }

    private func stopAllTasks() {
        announceTask?.cancel()
        announceTask = nil
        for t in peerTasks { t.cancel() }
        peerTasks.removeAll()
        globalInFlight.removeAll()
        activePeers.removeAll()
        connectedPeers = 0
    }

    public func status() -> Status {
        // Smooth both rates over the interval since the last sample (exponential moving average).
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleTime)
        if elapsed >= 0.5 {
            let downInstant = Double(pieces.downloadedBytes - lastSampleBytes) / elapsed
            smoothedRate = smoothedRate * 0.6 + downInstant * 0.4
            lastSampleBytes = pieces.downloadedBytes
            let upInstant = Double(uploadedBytes - lastUploadBytes) / elapsed
            smoothedUploadRate = smoothedUploadRate * 0.6 + upInstant * 0.4
            lastUploadBytes = uploadedBytes
            lastSampleTime = now
        }
        let active = state == .downloading || state == .seeding
        return Status(
            infoHash: torrent.infoHashHex, name: torrent.name, totalLength: torrent.totalLength,
            downloaded: pieces.downloadedBytes, fractionComplete: pieces.fractionComplete,
            downloadRate: state == .downloading ? max(0, smoothedRate) : 0,
            uploadRate: active ? max(0, smoothedUploadRate) : 0, uploaded: uploadedBytes,
            peersConnected: connectedPeers, state: state, savePath: downloadRoot.path)
    }

    /// Mark which pieces we already have on disk (call before start when resuming).
    public func loadResume(havePieces: [Int]) {
        for i in havePieces { pieces.markComplete(i) }
        if pieces.isComplete { state = .seeding }
    }

    public func completedPieces() -> [Int] {
        (0..<pieces.pieceCount).filter { pieces.hasPiece($0) }
    }

    // MARK: trackers

    private func startAnnouncing() {
        announceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let hadTrackers = await self.announceRound()
                // Re-announce periodically; back off if we found no HTTP trackers at all.
                try? await Task.sleep(nanoseconds: hadTrackers ? 120_000_000_000 : 60_000_000_000)
            }
        }
    }

    /// One pass over the torrent's HTTP trackers. Returns whether any were present.
    private func announceRound() async -> Bool {
        let trackers = torrent.trackers.filter { $0.hasPrefix("http") }
        for tracker in trackers {
            if Task.isCancelled { break }
            await announceOnce(tracker)
        }
        return !trackers.isEmpty
    }

    private func announceOnce(_ tracker: String) async {
        let left = torrent.totalLength - pieces.downloadedBytes
        guard
            let response = try? await Tracker.announce(
                base: tracker, infoHash: torrent.infoHash, peerID: peerID, port: 6881,
                left: left, event: knownPeers.isEmpty ? .started : nil)
        else { return }
        for peer in response.peers { considerPeer(peer) }
    }

    private func considerPeer(_ peer: Tracker.Peer) {
        guard state == .downloading || state == .seeding else { return }
        guard !knownPeers.contains(peer), connectedPeers < maxPeers else { return }
        knownPeers.insert(peer)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runPeer(peer)
        }
        peerTasks.append(task)
    }

    /// Feed peers discovered out of band (e.g. a magnet's tracker list, or PEX later).
    public func addPeers(_ peers: [Tracker.Peer]) {
        for p in peers { considerPeer(p) }
    }

    // MARK: per-peer download loop

    private func runPeer(_ endpoint: Tracker.Peer) async {
        let peer = PeerConnection(
            host: endpoint.host, port: UInt16(endpoint.port), infoHash: torrent.infoHash, peerID: peerID)
        defer {
            knownPeers.remove(endpoint)
            Task { await peer.close() }
        }
        do {
            try await peer.connect()
            try await pump(peer)
        } catch {
            // Connection dropped or timed out; the roster shrinks and the tracker refills it.
        }
    }

    /// Accept an incoming peer (from the PeerListener): reply to its handshake, then run the same
    /// bidirectional loop as an outgoing peer. Enables seeding to peers that dial us.
    public func acceptIncomingPeer(_ peer: PeerConnection) {
        guard state == .downloading || state == .seeding, connectedPeers < maxPeers else {
            Task { await peer.close() }
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { Task { await peer.close() } }
            do {
                try await peer.replyHandshake()
                try await self.pump(peer)
            } catch {}
        }
        peerTasks.append(task)
    }

    /// The bidirectional message loop shared by outgoing and incoming peers: advertise our pieces,
    /// request blocks we still need, and serve blocks peers ask us for.
    private func pump(_ peer: PeerConnection) async throws {
        connectedPeers += 1
        activePeers.append(peer)
        defer {
            connectedPeers -= 1
            activePeers.removeAll { $0 === peer }
        }

        if pieces.completedCount > 0 { try await peer.send(.bitfield(pieces.bitfield())) }
        try await peer.send(.interested)

        var choked = true
        var peerBits: [Bool] = []
        var mine: Set<PieceManager.BlockRequest> = []

        while !Task.isCancelled && state != .paused && state != .stopped {
            topUp(choked: choked, peerBits: peerBits, mine: &mine, peer: peer)

            let message = try await peer.receive()
            switch message {
            case .choke:
                choked = true
                for r in mine { globalInFlight.remove(r) }
                mine.removeAll()
            case .unchoke:
                choked = false
            case .bitfield(let data):
                peerBits = pieces.decodeBitfield(data)
            case .have(let index):
                let i = Int(index)
                if i >= peerBits.count { peerBits += Array(repeating: false, count: i - peerBits.count + 1) }
                if i >= 0 && i < peerBits.count { peerBits[i] = true }
            case .piece(let index, let begin, let block):
                handlePiece(index: Int(index), begin: Int(begin), block: block, mine: &mine)
            case .interested:
                // A peer wants our pieces: unchoke so it can request from us (seeding).
                Task { try? await peer.send(.unchoke) }
            case .request(let index, let begin, let length):
                serveBlock(index: Int(index), begin: Int(begin), length: Int(length), to: peer)
            default:
                break
            }
        }
        for r in mine { globalInFlight.remove(r) }  // release this peer's in-flight reservations
    }

    /// Serve a block a peer requested, if we have that verified piece. Reads from storage and
    /// sends a `piece` message, counting the bytes toward our upload total. This is how we
    /// reciprocate (upload while downloading) and seed to still-connected peers after completion.
    private func serveBlock(index: Int, begin: Int, length: Int, to peer: PeerConnection) {
        guard pieces.hasPiece(index), length > 0, length <= maxServedBlock, begin >= 0 else { return }
        guard begin + length <= pieces.pieceSize(index) else { return }
        let offset = Int64(index) * Int64(pieces.pieceLength) + Int64(begin)
        guard let block = try? storage.read(at: offset, length: length), block.count == length else { return }
        uploadedBytes += Int64(length)
        let message = PeerMessage.piece(index: UInt32(index), begin: UInt32(begin), block: block)
        Task { try? await peer.send(message) }
    }

    /// Tell every connected peer we now have a piece, so they can request it from us.
    private func broadcastHave(_ index: Int) {
        let message = PeerMessage.have(pieceIndex: UInt32(index))
        for peer in activePeers { Task { try? await peer.send(message) } }
    }

    /// Keep this peer's request pipeline full while it isn't choking us.
    private func topUp(
        choked: Bool, peerBits: [Bool], mine: inout Set<PieceManager.BlockRequest>, peer: PeerConnection
    ) {
        guard !choked, !peerBits.isEmpty, !pieces.isComplete else { return }
        while mine.count < maxInFlightPerPeer {
            guard let req = pieces.nextRequest(peerHas: peerBits, inFlight: globalInFlight) else { break }
            mine.insert(req)
            globalInFlight.insert(req)
            let request = PeerMessage.request(
                index: UInt32(req.index), begin: UInt32(req.begin), length: UInt32(req.length))
            Task { try? await peer.send(request) }
        }
    }

    private func handlePiece(index: Int, begin: Int, block: Data, mine: inout Set<PieceManager.BlockRequest>) {
        let key = PieceManager.BlockRequest(index: index, begin: begin, length: block.count)
        mine.remove(key)
        globalInFlight.remove(key)
        switch pieces.receiveBlock(index: index, begin: begin, block: block) {
        case .pieceComplete(let pieceIndex, let data):
            try? storage.write(
                pieceIndex: pieceIndex, pieceLength: pieces.pieceLength,
                pieceSize: pieces.pieceSize(pieceIndex), data: data)
            broadcastHave(pieceIndex)  // let connected peers know they can request this from us
            if pieces.isComplete { state = .seeding }
            // Storage stays open so we can serve pieces to peers; it closes on stop().
        case .hashMismatch:
            break  // the piece was reset; its blocks become requestable again
        default:
            break
        }
    }
}
