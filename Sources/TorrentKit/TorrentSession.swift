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
        public var downloadRate: Double  // bytes/sec, smoothed
        public var uploadRate: Double  // bytes/sec, smoothed
        public var uploaded: Int64  // total bytes served to peers this session
        public var peersConnected: Int
        public var state: State
        public var savePath: String
        public var etaSeconds: Int  // estimated time to finish; -1 = unknown/infinite
        public var ratio: Double  // share ratio: uploaded / downloaded
        /// For a magnet still without its metadata: what the search is doing, so the UI can say
        /// more than "checking". Nil for every torrent that has its metadata. Optional, so an
        /// older app or daemon on the other side of the wire decodes it as absent.
        public var metadataSearch: MetadataSearch?

        public init(
            infoHash: String, name: String, totalLength: Int64, downloaded: Int64,
            fractionComplete: Double, downloadRate: Double, uploadRate: Double = 0,
            uploaded: Int64 = 0, peersConnected: Int, state: State, savePath: String,
            etaSeconds: Int = -1, ratio: Double = 0, metadataSearch: MetadataSearch? = nil
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
            self.etaSeconds = etaSeconds
            self.ratio = ratio
            self.metadataSearch = metadataSearch
        }
    }

    /// Where a magnet's metadata search stands.
    public struct MetadataSearch: Sendable, Codable, Equatable {
        public enum Phase: String, Sendable, Codable {
            /// Fetching the .torrent from the magnet's xs= source.
            case fetchingSource
            /// Announcing to trackers or searching the DHT.
            case findingPeers
            /// Asking `peersFound` peers for the metadata.
            case askingPeers
            /// This round found no peer that sent it; waiting before the next round.
            case waitingToRetry
            /// Every round failed; nothing runs until the user resumes it.
            case gaveUp
        }
        public var phase: Phase
        /// 1-based round, and how many rounds there are before giving up.
        public var round: Int
        public var rounds: Int
        /// Peers found in the current or last round.
        public var peersFound: Int

        public init(phase: Phase, round: Int, rounds: Int, peersFound: Int) {
            self.phase = phase
            self.round = round
            self.rounds = rounds
            self.peersFound = peersFound
        }
    }

    /// A file within the torrent and whether it's selected for download (per-file selection).
    public struct FileInfo: Sendable, Codable, Equatable {
        public var index: Int
        public var path: String
        public var length: Int64
        public var wanted: Bool
    }

    /// A connected peer, for the detail view's Peers tab.
    public struct PeerInfo: Sendable, Codable, Equatable {
        public var address: String  // host:port
        public var client: String  // decoded from the peer id (e.g. "qBittorrent 4.5.2")
        public var progress: Double  // how much of the torrent they have (0...1)
        public var choked: Bool  // are they choking us
        public var encrypted: Bool

        public init(
            address: String, client: String, progress: Double, choked: Bool, encrypted: Bool
        ) {
            self.address = address
            self.client = client
            self.progress = progress
            self.choked = choked
            self.encrypted = encrypted
        }

        /// Decode the client from a BitTorrent peer id. Handles the common Azureus style
        /// ("-qB4520-..." -> qBittorrent 4.5.2) and falls back to a printable prefix.
        public static func decodeClient(_ peerID: Data?) -> String {
            guard let peerID, peerID.count >= 8 else { return "unknown" }
            let bytes = [UInt8](peerID)
            if bytes[0] == UInt8(ascii: "-") {
                let code = String(bytes: bytes[1..<3], encoding: .ascii) ?? ""
                let names = [
                    "qB": "qBittorrent", "UT": "µTorrent", "TR": "Transmission", "DE": "Deluge",
                    "LT": "libtorrent", "AZ": "Vuze", "BT": "BitTorrent", "PM": "Pathem",
                ]
                let v = bytes[3..<7].map { String(Character(UnicodeScalar($0))) }
                let version =
                    v.joined().trimmingCharacters(in: CharacterSet(charactersIn: "0")).isEmpty
                    ? v.joined()
                    : "\(v[0]).\(v[1]).\(v[2])\(v[3])".replacingOccurrences(of: ".0", with: "")
                if let name = names[code] { return "\(name) \(version)" }
                return code
            }
            let printable = bytes.prefix(8).map {
                (32...126).contains($0) ? Character(UnicodeScalar($0)) : "·"
            }
            return String(printable)
        }
    }

    public let torrent: TorrentFile
    private let downloadRoot: URL
    private let peerID: Data
    private let pieces: PieceManager
    private let layout: FileLayout
    private let storage: TorrentStorage
    private let dht: DHTClient?
    private let listenPort: Int  // our inbound peer port, announced to the DHT so peers can reach us
    private var lastDHTAnnounce: Date?
    private var wantedFiles: Set<Int>?  // nil = all files selected
    private let downLimiter: RateLimiter?  // shared global download cap (nil = unlimited)
    private let uploadLimiter: RateLimiter?

    private var state: State = .stopped
    private var peerTasks: [UUID: Task<Void, Never>] = [:]  // live peer/web-seed tasks, self-pruning
    private func removePeerTask(_ id: UUID) { peerTasks[id] = nil }
    private var connectedPeers = 0
    private var globalInFlight: Set<PieceManager.BlockRequest> = []
    private var knownPeers: Set<Tracker.Peer> = []
    private var activePeers: [PeerConnection] = []  // connected peers, for have-broadcast + serving
    private var announceTask: Task<Void, Never>?
    private var pexTask: Task<Void, Never>?
    private var webSeedInFlight: Set<Int> = []  // pieces being fetched from web seeds
    private var superSeeding = false
    private var piecesGivenCount: [Int: Int] = [:]  // how often each piece was handed out (super-seed)
    private var preferEncryption = false
    private var preferUTP = false

    /// Enable/disable super-seeding (efficient initial seeding). Takes effect on new peers.
    public func setSuperSeeding(_ on: Bool) { superSeeding = on }

    /// Prefer MSE-encrypted outgoing connections (falling back to plaintext). Takes effect on new peers.
    public func setPreferEncryption(_ on: Bool) { preferEncryption = on }

    /// Prefer µTP (BEP 29) for outgoing connections, falling back to TCP. Takes effect on new peers.
    public func setPreferUTP(_ on: Bool) { preferUTP = on }

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

    public init(
        torrent: TorrentFile, downloadRoot: URL, peerID: Data = Tracker.makePeerID(),
        dht: DHTClient? = nil, listenPort: Int = 6881,
        downLimiter: RateLimiter? = nil, uploadLimiter: RateLimiter? = nil
    ) throws {
        self.torrent = torrent
        self.downloadRoot = downloadRoot
        self.peerID = peerID
        self.dht = dht
        self.listenPort = listenPort
        self.downLimiter = downLimiter
        self.uploadLimiter = uploadLimiter
        self.pieces = PieceManager(torrent: torrent)
        self.layout = FileLayout(torrent: torrent)
        // Multi-file torrents nest their files under the torrent name; single-file already has it.
        let root =
            torrent.files.count > 1
            ? downloadRoot.appendingPathComponent(torrent.name) : downloadRoot
        self.storage = try TorrentStorage(root: root, layout: layout)
    }

    // MARK: control

    public func start() {
        guard state == .stopped || state == .paused else { return }
        state = pieces.isComplete ? .seeding : .downloading
        lastSampleTime = Date()
        lastSampleBytes = pieces.downloadedBytes
        startAnnouncing()
        startPexBroadcasts()
        startWebSeeds()
    }

    /// Download pieces from any HTTP web seeds (BEP 19) in parallel with peers. A web seed has
    /// everything, so it's a reliable fallback when peers are scarce.
    private func startWebSeeds() {
        guard state == .downloading else { return }
        for base in torrent.webSeeds.filter({ $0.hasPrefix("http") }).prefix(4) {
            let id = UUID()
            peerTasks[id] = Task { [weak self] in
                guard let self else { return }
                await self.runWebSeed(base)
                await self.removePeerTask(id)
            }
        }
    }

    private func runWebSeed(_ base: String) async {
        while !Task.isCancelled, state == .downloading, !pieces.isComplete {
            guard let index = pieces.nextWantedPiece(excluding: webSeedInFlight) else {
                try? await Task.sleep(nanoseconds: 2_000_000_000)  // nothing to fetch right now
                continue
            }
            webSeedInFlight.insert(index)
            let size = pieces.pieceSize(index)
            let data = await WebSeed.fetchPiece(
                base: base, torrent: torrent, layout: layout, index: index, pieceSize: size)
            webSeedInFlight.remove(index)
            if let data, data.count == size {
                ingestWholePiece(index: index, data: data)
            } else {
                try? await Task.sleep(nanoseconds: 3_000_000_000)  // web seed failed; back off
            }
        }
    }

    /// Verify and store a whole piece fetched in one shot (from a web seed), reusing the block
    /// verification path.
    private func ingestWholePiece(index: Int, data: Data) {
        var begin = 0
        while begin < data.count {
            let length = min(PieceManager.blockSize, data.count - begin)
            let result = pieces.receiveBlock(
                index: index, begin: begin, block: data.subdata(in: begin..<(begin + length)))
            if case .pieceComplete(let pieceIndex, let bytes) = result {
                guard state == .downloading else { break }  // paused/stopped mid-fetch: don't ingest
                try? storage.write(
                    pieceIndex: pieceIndex, pieceLength: pieces.pieceLength,
                    pieceSize: pieces.pieceSize(pieceIndex), data: bytes)
                broadcastHave(pieceIndex)
                if pieces.isComplete { state = .seeding }
            }
            begin += length
        }
    }

    /// Periodically tell each ut_pex-capable peer about the peers we've learned since we last told
    /// it (send-side PEX, BEP 11). Skipped for private torrents.
    private func startPexBroadcasts() {
        guard !torrent.isPrivate else { return }
        pexTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self else { return }
                await self.broadcastPex()
            }
        }
    }

    private func broadcastPex() async {
        let current = knownPeers
        for peer in activePeers {
            guard let pexID = await peer.peerPexID else { continue }
            let lastSent = await peer.lastPexSent
            let added = current.subtracting(lastSent)
            let dropped = lastSent.subtracting(current)
            guard !added.isEmpty || !dropped.isEmpty else { continue }
            let payload = PEX.message(
                added: Array(added.prefix(50)), dropped: Array(dropped.prefix(50)))
            try? await peer.send(.extended(id: pexID, payload: payload))
            await peer.setLastPexSent(current)
        }
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
        pexTask?.cancel()
        pexTask = nil
        for t in peerTasks.values { t.cancel() }
        peerTasks.removeAll()
        globalInFlight.removeAll()
        // Close the connections so any pump blocked in receive() unblocks promptly (cancellation
        // alone won't interrupt the socket read). Do NOT zero connectedPeers/activePeers here: each
        // pump's own defer decrements from the true count, so zeroing would drive it negative.
        for peer in activePeers { Task { await peer.close() } }
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
        let downloaded = pieces.downloadedBytes
        // ETA from the smoothed rate and what's left of the wanted bytes. Only meaningful while
        // actively downloading with forward progress; -1 signals "unknown" (stalled or seeding).
        let rate = max(0, smoothedRate)
        let remaining = pieces.wantedBytesRemaining
        let eta: Int
        if state == .downloading && rate > 1 && remaining > 0 {
            eta = min(Int(Double(remaining) / rate), 100 * 365 * 24 * 3600)  // cap at ~a century
        } else {
            eta = -1
        }
        // Share ratio = bytes served / bytes taken. Guard the pre-download divide-by-zero.
        let ratio = downloaded > 0 ? Double(uploadedBytes) / Double(downloaded) : 0
        return Status(
            infoHash: torrent.infoHashHex, name: torrent.name, totalLength: torrent.totalLength,
            downloaded: downloaded, fractionComplete: pieces.fractionComplete,
            downloadRate: state == .downloading ? rate : 0,
            uploadRate: active ? max(0, smoothedUploadRate) : 0, uploaded: uploadedBytes,
            peersConnected: connectedPeers, state: state, savePath: downloadRoot.path,
            etaSeconds: eta, ratio: ratio)
    }

    /// Mark which pieces we already have on disk (call before start when resuming).
    public func loadResume(havePieces: [Int]) {
        for i in havePieces { pieces.markComplete(i) }
        if pieces.isComplete { state = .seeding }
    }

    public func completedPieces() -> [Int] {
        (0..<pieces.pieceCount).filter { pieces.hasPiece($0) }
    }

    // MARK: per-file selection

    /// The torrent's files and whether each is currently selected for download.
    public func files() -> [FileInfo] {
        torrent.files.enumerated().map { index, entry in
            FileInfo(
                index: index, path: entry.path, length: entry.length,
                wanted: wantedFiles?.contains(index) ?? true)
        }
    }

    public func wantedFileIndices() -> [Int]? { wantedFiles.map { Array($0).sorted() } }

    /// A snapshot of every connected peer, for the detail view's Peers tab.
    public func peers() async -> [PeerInfo] {
        var out: [PeerInfo] = []
        for peer in activePeers { out.append(await peer.snapshot(pieceCount: pieces.pieceCount)) }
        return out.sorted { $0.address < $1.address }
    }

    /// The torrent's announce sources: HTTP/UDP trackers plus DHT / PEX unless it's private.
    public func trackerURLs() -> [String] { torrent.trackers }
    public var usesDHT: Bool { !torrent.isPrivate }

    /// Restrict downloading to the given file indices (nil = all files). Recomputes the wanted
    /// pieces and, if they're already on disk, flips to seeding.
    public func setWantedFiles(_ indices: Set<Int>?) {
        wantedFiles = indices
        if let indices {
            let wantedPieces = layout.pieces(
                forFiles: indices, pieceLength: Int(torrent.pieceLength),
                pieceCount: pieces.pieceCount)
            pieces.setWanted(wantedPieces)
        } else {
            pieces.clearWanted()
        }
        if pieces.isComplete, state == .downloading {
            state = .seeding
        } else if !pieces.isComplete, state == .seeding {
            state = .downloading
        }
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

    /// One pass over the torrent's HTTP trackers, plus a DHT lookup when peers are scarce.
    /// Returns whether any HTTP trackers were present.
    private func announceRound() async -> Bool {
        let trackers = torrent.trackers.filter { $0.hasPrefix("http") }
        for tracker in trackers {
            if Task.isCancelled { break }
            await announceOnce(tracker)
        }
        // The DHT finds peers without trackers (what makes a trackerless magnet work) and also
        // makes US discoverable via announce_peer. Skip for private torrents (BEP 27).
        if let dht, !torrent.isPrivate, !Task.isCancelled {
            // Re-announce our presence about every 15 minutes (the BEP-5 refresh cadence); the same
            // lookup returns peers, so an announce round doubles as a discovery round.
            let announceDue = lastDHTAnnounce.map { Date().timeIntervalSince($0) > 15 * 60 } ?? true
            if announceDue {
                let peers = await dht.announcePeer(infoHash: torrent.infoHash, port: listenPort)
                lastDHTAnnounce = Date()
                for peer in peers { considerPeer(peer) }
            } else if connectedPeers < 10 {
                // Between announces, still look for peers when we're short.
                let peers = await dht.findPeers(infoHash: torrent.infoHash)
                for peer in peers { considerPeer(peer) }
            }
        }
        return !trackers.isEmpty
    }

    private func announceOnce(_ tracker: String) async {
        let left = torrent.totalLength - pieces.downloadedBytes
        guard
            let response = try? await Tracker.announce(
                base: tracker, infoHash: torrent.infoHash, peerID: peerID, port: listenPort,
                left: left, event: knownPeers.isEmpty ? .started : nil)
        else { return }
        for peer in response.peers { considerPeer(peer) }
    }

    private func considerPeer(_ peer: Tracker.Peer) {
        guard state == .downloading || state == .seeding else { return }
        // Gate on knownPeers (which counts in-flight dials too, incremented synchronously here);
        // connectedPeers only rises after the handshake, so gating on it lets a peer burst spawn
        // unbounded simultaneous connections.
        guard !knownPeers.contains(peer), knownPeers.count < maxPeers else { return }
        knownPeers.insert(peer)
        let id = UUID()
        peerTasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.runPeer(peer)
            await self.removePeerTask(id)
        }
    }

    /// Feed peers discovered out of band (e.g. a magnet's tracker list, or PEX later).
    public func addPeers(_ peers: [Tracker.Peer]) {
        for p in peers { considerPeer(p) }
    }

    // MARK: per-peer download loop

    private func runPeer(_ endpoint: Tracker.Peer) async {
        defer { knownPeers.remove(endpoint) }
        // Try the preferred transport/encryption first, falling back on failure: µTP before TCP
        // (a peer that ignores our µTP SYN times out fast), MSE before plaintext.
        let transports: [PeerConnection.Transport] = preferUTP ? [.utp, .tcp] : [.tcp]
        let encModes = preferEncryption ? [true, false] : [false]
        for transport in transports {
            for encrypted in encModes {
                let peer = PeerConnection(
                    host: endpoint.host, port: UInt16(endpoint.port), infoHash: torrent.infoHash,
                    peerID: peerID, advertiseExtensions: true)
                do {
                    // Short µTP dial timeout so we fall back to TCP quickly when a peer is TCP-only.
                    try await peer.connect(
                        timeout: transport == .utp ? 6 : 15, encrypted: encrypted,
                        transport: transport)
                } catch {
                    await peer.close()
                    continue  // this transport/mode failed: try the next
                }
                do { try await pump(peer) } catch {}  // connected: run until it drops
                await peer.close()
                return
            }
        }
    }

    /// Accept an incoming peer (from the PeerListener): reply to its handshake, then run the same
    /// bidirectional loop as an outgoing peer. Enables seeding to peers that dial us.
    public func acceptIncomingPeer(_ peer: PeerConnection) {
        guard state == .downloading || state == .seeding, connectedPeers < maxPeers else {
            Task { await peer.close() }
            return
        }
        let id = UUID()
        peerTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { Task { await peer.close() } }
            do {
                try await peer.replyHandshake()
                try await self.pump(peer)
            } catch {}
            await self.removePeerTask(id)
        }
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

        // Super-seeding withholds the full bitfield and offers pieces one at a time (below).
        let superSeed = superSeeding && pieces.isComplete
        if !superSeed, pieces.completedCount > 0 {
            try await peer.send(.bitfield(pieces.bitfield()))
        }
        try await peer.send(.interested)
        // Advertise peer exchange so the peer sends us the peers it knows (BEP 11).
        if await peer.peerSupportsExtensions {
            try await peer.send(.extended(id: 0, payload: PEX.handshakePayload()))
        }

        var choked = true
        var peerBits: [Bool] = []
        var mine: Set<PieceManager.BlockRequest> = []
        var offeredPieces: Set<Int> = []  // super-seed: pieces we've advertised to this peer

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
                if superSeed {
                    offerSuperSeedPiece(peerBits: peerBits, offered: &offeredPieces, to: peer)
                }
            case .have(let index):
                let i = Int(index)
                if i >= peerBits.count {
                    peerBits += Array(repeating: false, count: i - peerBits.count + 1)
                }
                if i >= 0 && i < peerBits.count { peerBits[i] = true }
                // Super-seed: once the peer announces the piece we gave it, offer another.
                if superSeed, offeredPieces.contains(i) {
                    piecesGivenCount[i, default: 0] += 1
                    offerSuperSeedPiece(peerBits: peerBits, offered: &offeredPieces, to: peer)
                }
            case .piece(let index, let begin, let block):
                handlePiece(index: Int(index), begin: Int(begin), block: block, mine: &mine)
            case .interested:
                // A peer wants our pieces: unchoke so it can request from us (seeding).
                Task { try? await peer.send(.unchoke) }
            case .request(let index, let begin, let length):
                // In super-seed mode only serve pieces we've actually offered this peer.
                if !superSeed || offeredPieces.contains(Int(index)) {
                    serveBlock(index: Int(index), begin: Int(begin), length: Int(length), to: peer)
                }
            case .extended(let extID, let payload):
                if extID == 0 {
                    // The peer's extended handshake: learn its ut_pex id so we can send it PEX.
                    await peer.setPeerPexID(PEX.peerPexID(fromHandshake: payload))
                } else if extID == UInt8(PEX.utPexID) {
                    // A ut_pex message (sent with the id we advertised) carries more peers.
                    for discovered in PEX.parseAddedPeers(payload) { considerPeer(discovered) }
                }
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
        guard pieces.hasPiece(index), length > 0, length <= maxServedBlock, begin >= 0 else {
            return
        }
        guard begin + length <= pieces.pieceSize(index) else { return }
        let offset = Int64(index) * Int64(pieces.pieceLength) + Int64(begin)
        guard let block = try? storage.read(at: offset, length: length), block.count == length
        else { return }
        uploadedBytes += Int64(length)
        let message = PeerMessage.piece(index: UInt32(index), begin: UInt32(begin), block: block)
        Task { [uploadLimiter] in
            await uploadLimiter?.consume(length)  // throttle upload to the global cap
            try? await peer.send(message)
        }
    }

    /// Super-seed: choose a piece this peer lacks (least-distributed first) and advertise just it.
    private func offerSuperSeedPiece(
        peerBits: [Bool], offered: inout Set<Int>, to peer: PeerConnection
    ) {
        guard
            let piece = SuperSeed.pick(
                complete: (0..<pieces.pieceCount).map { pieces.hasPiece($0) },
                peerHas: peerBits, offered: offered, givenCount: piecesGivenCount)
        else { return }
        offered.insert(piece)
        Task { try? await peer.send(.have(pieceIndex: UInt32(piece))) }
    }

    /// Tell every connected peer we now have a piece, so they can request it from us.
    private func broadcastHave(_ index: Int) {
        let message = PeerMessage.have(pieceIndex: UInt32(index))
        for peer in activePeers { Task { try? await peer.send(message) } }
    }

    /// Keep this peer's request pipeline full while it isn't choking us.
    private func topUp(
        choked: Bool, peerBits: [Bool], mine: inout Set<PieceManager.BlockRequest>,
        peer: PeerConnection
    ) {
        guard !choked, !peerBits.isEmpty, !pieces.isComplete else { return }
        while mine.count < maxInFlightPerPeer {
            guard let req = pieces.nextRequest(peerHas: peerBits, inFlight: globalInFlight) else {
                break
            }
            mine.insert(req)
            globalInFlight.insert(req)
            let request = PeerMessage.request(
                index: UInt32(req.index), begin: UInt32(req.begin), length: UInt32(req.length))
            // Pace requests through the download limiter, so throttling the ask throttles receipt.
            Task { [downLimiter] in
                await downLimiter?.consume(req.length)
                try? await peer.send(request)
            }
        }
    }

    private func handlePiece(
        index: Int, begin: Int, block: Data, mine: inout Set<PieceManager.BlockRequest>
    ) {
        let key = PieceManager.BlockRequest(index: index, begin: begin, length: block.count)
        mine.remove(key)
        globalInFlight.remove(key)
        switch pieces.receiveBlock(index: index, begin: begin, block: block) {
        case .pieceComplete(let pieceIndex, let data):
            // A pump suspended in receive() can resume with a buffered final block AFTER the
            // kill-switch (or the user) paused/stopped us. Don't write, announce, or flip to
            // seeding then: that would resurrect a paused torrent and leak while the VPN is down.
            guard state == .downloading else { break }
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
