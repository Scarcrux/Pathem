import Foundation

#if canImport(Network)
import Network

/// A single peer connection over TCP (Network.framework): performs the BitTorrent handshake,
/// then exposes a message stream and a `send`. Tracks the choke/interest state and the peer's
/// bitfield, which the session uses to decide what to request. One actor per peer; the session
/// owns many.
public actor PeerConnection {
    public enum PeerError: Error, Equatable {
        case connectionFailed(String)
        case handshakeMismatch
        case closed
        case timedOut
        case oversizedMessage
    }

    /// The largest peer-wire message we'll buffer. The biggest legitimate messages are a piece
    /// block (~16 KiB) or a bitfield for a huge torrent; 2 MiB is far above both. A peer that
    /// declares more is treated as hostile and dropped, so it can't make us buffer to OOM.
    private static let maxMessageLength: UInt32 = 2 * 1024 * 1024

    public let host: String
    public let port: UInt16
    private var infoHash: Data  // for incoming connections, learned from the peer's handshake
    private let myPeerID: Data
    private let advertiseExtensions: Bool

    /// Which wire transport a peer connection runs over. TCP is the default and universal;
    /// µTP (BEP 29) is a UDP-based option that's friendlier to congestion.
    public enum Transport: Sendable { case tcp, utp }

    private var connection: NWConnection?
    private var utp: UTPTransport?  // set instead of `connection` when running over µTP
    private var inbound = Data()  // bytes read but not yet parsed into a message
    private var closed = false
    private var sendCipher: RC4?  // set after an MSE handshake; nil = plaintext
    private var recvCipher: RC4?

    /// Whether this connection negotiated MSE encryption.
    public private(set) var isEncrypted = false

    /// Peer state, updated as messages arrive (the session reads these).
    public private(set) var peerChoking = true
    public private(set) var amInterested = false
    public private(set) var peerBitfield: [Bool] = []
    public private(set) var remotePeerID: Data?

    public init(
        host: String, port: UInt16, infoHash: Data, peerID: Data, advertiseExtensions: Bool = false
    ) {
        self.host = host
        self.port = port
        self.infoHash = infoHash
        self.myPeerID = peerID
        self.advertiseExtensions = advertiseExtensions
    }

    /// Whether the peer's handshake advertised BEP 10 extension support (set after connect()).
    public private(set) var peerSupportsExtensions = false

    /// The id the peer advertised for ut_pex, and the peer set we last sent them (for delta
    /// PEX). Session bookkeeping kept here so it lives and dies with the connection.
    public private(set) var peerPexID: UInt8?
    public private(set) var lastPexSent: Set<Tracker.Peer> = []
    public func setPeerPexID(_ id: UInt8?) { peerPexID = id }
    public func setLastPexSent(_ peers: Set<Tracker.Peer>) { lastPexSent = peers }

    /// Wrap a connection accepted by a PeerListener. The info hash is not known until the peer
    /// sends its handshake (`acceptHandshake`).
    public init(incoming connection: NWConnection, peerID: Data) {
        self.host = "\(connection.endpoint)"
        self.port = 0
        self.infoHash = Data()
        self.myPeerID = peerID
        self.advertiseExtensions = false
        self.connection = connection
    }

    /// Wrap an inbound µTP connection the UDPMux accepted (its SYN handshake already complete).
    /// The peer's BitTorrent handshake arrives as µTP data, read through the transport.
    init(incomingUTP transport: UTPTransport, peerID: Data, host: String, port: UInt16) {
        self.host = host
        self.port = port
        self.infoHash = Data()
        self.myPeerID = peerID
        self.advertiseExtensions = false
        self.utp = transport
    }

    /// Open the connection and exchange handshakes. With `encrypted`, runs the MSE handshake
    /// first (carrying our BitTorrent handshake as its payload) and encrypts the rest. With
    /// `transport: .utp`, the whole exchange runs over µTP instead of TCP (outbound only).
    public func connect(
        timeout: TimeInterval = 15, encrypted: Bool = false, transport: Transport = .tcp
    ) async throws {
        switch transport {
        case .tcp:
            let conn = NWConnection(
                host: .init(host), port: .init(rawValue: port) ?? .any,
                using: NetworkBinding.shared.pin(.tcp))
            self.connection = conn
            try await waitReady(conn, timeout: timeout)
        case .utp:
            let t = UTPTransport(host: host, port: port)
            try await t.start(timeout: timeout)
            self.utp = t
        }

        let reserved = advertiseExtensions ? PeerHandshake.extensionReserved : Data(count: 8)
        let handshake = PeerHandshake(infoHash: infoHash, peerID: myPeerID, reserved: reserved)

        if encrypted {
            let stream = mseStream(timeout: timeout)
            let result = try await MSEHandshake.initiate(
                infoHash: infoHash, initialPayload: handshake.encoded, over: stream)
            sendCipher = result.send
            recvCipher = result.recv
            isEncrypted = true
            // Bytes the handshake read past its end (TCP coalescing) are still CIPHERTEXT:
            // only receiveRawChunk decrypts, and these bypassed it. recv's keystream sits
            // exactly at the first post-handshake byte, so decrypt them here or the peer's
            // BT handshake parses as garbage (the flaky handshakeMismatch).
            let leftover = await stream.drainBuffer()
            if !leftover.isEmpty { inbound.append(recvCipher!.process(leftover)) }
            try await readHandshake(timeout: timeout)  // the peer's BT handshake, now decrypted
            return
        }

        try await rawSend(handshake.encoded)
        try await readHandshake(timeout: timeout)
    }

    /// Responder side of an MSE-encrypted connection: run the MSE handshake, read the peer's
    /// BitTorrent handshake (which arrived as the MSE payload), and reply with ours. `torrentFor`
    /// maps the recovered req2 hash to one of our info hashes. Returns the matched info hash.
    public func acceptEncryptedHandshake(
        timeout: TimeInterval = 15, torrentFor: @escaping @Sendable (Data) -> Data?
    ) async throws -> Data {
        guard let conn = connection else { throw PeerError.closed }
        try await waitReady(conn, timeout: timeout)
        let stream = mseStream(timeout: timeout)
        let (hash, result) = try await MSEHandshake.respond(torrentFor: torrentFor, over: stream)
        infoHash = hash
        sendCipher = result.send
        recvCipher = result.recv
        isEncrypted = true
        inbound.append(result.initialData)  // the initiator's BT handshake (MSE payload)
        // Same as connect(): post-handshake leftovers in the stream buffer are ciphertext
        // that bypassed receiveRawChunk's decryption; recv is positioned right after IA.
        let leftover = await stream.drainBuffer()
        if !leftover.isEmpty { inbound.append(recvCipher!.process(leftover)) }
        try await readHandshake(timeout: timeout)  // validate it, set remotePeerID
        return hash
    }

    /// For an incoming connection: start it, read the peer's handshake, and return the info
    /// hash it wants (so the listener can find the matching torrent). Does not reply yet.
    public func acceptHandshake(timeout: TimeInterval = 15) async throws -> Data {
        // Over µTP the mux already completed the transport handshake; only TCP needs waitReady.
        if utp == nil {
            guard let conn = connection else { throw PeerError.closed }
            try await waitReady(conn, timeout: timeout)
        }
        while inbound.count < 68 { try await readMore(timeout: timeout) }
        guard let hs = PeerHandshake.parse(inbound) else { throw PeerError.handshakeMismatch }
        infoHash = hs.infoHash
        remotePeerID = hs.peerID
        peerSupportsExtensions = hs.supportsExtensions
        inbound.removeFirst(68)
        return hs.infoHash
    }

    /// Send our handshake back on an incoming connection (after the caller picked the torrent).
    public func replyHandshake(advertiseExtensions: Bool = false) async throws {
        let reserved = advertiseExtensions ? PeerHandshake.extensionReserved : Data(count: 8)
        let handshake = PeerHandshake(infoHash: infoHash, peerID: myPeerID, reserved: reserved)
        try await rawSend(handshake.encoded)
    }

    /// Await the connection reaching `.ready`, or throw on failure/timeout.
    private func waitReady(_ conn: NWConnection, timeout: TimeInterval) async throws {
        let _: Void = try await withThrowingContinuation(timeout: timeout) { done in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: done(.success(()))
                case .failed(let error): done(.failure(PeerError.connectionFailed("\(error)")))
                case .cancelled: done(.failure(PeerError.closed))
                default: break
                }
            }
            conn.start(queue: Self.queue)
        }
    }

    /// Read exactly the 68-byte handshake, validating the info hash matches.
    private func readHandshake(timeout: TimeInterval) async throws {
        while inbound.count < 68 { try await readMore(timeout: timeout) }
        guard let hs = PeerHandshake.parse(inbound), hs.infoHash == infoHash else {
            throw PeerError.handshakeMismatch
        }
        remotePeerID = hs.peerID
        peerSupportsExtensions = hs.supportsExtensions
        inbound.removeFirst(68)
    }

    /// Wait for and return the next parsed message, applying its effect to peer state.
    public func receive(timeout: TimeInterval = 120) async throws -> PeerMessage {
        while true {
            // Reject an absurd declared length before buffering the whole (fake) message.
            if inbound.count >= 4, readBE32([UInt8](inbound.prefix(4)), 0) > Self.maxMessageLength {
                throw PeerError.oversizedMessage
            }
            if let (message, consumed) = PeerMessage.parse(inbound) {
                inbound.removeFirst(consumed)
                apply(message)
                return message
            }
            try await readMore(timeout: timeout)
        }
    }

    private func apply(_ message: PeerMessage) {
        switch message {
        case .choke: peerChoking = true
        case .unchoke: peerChoking = false
        case .bitfield(let data):
            peerBitfield = decodeBits(data)
        case .have(let index):
            let i = Int(index)
            if i >= peerBitfield.count {
                peerBitfield += Array(repeating: false, count: i - peerBitfield.count + 1)
            }
            peerBitfield[i] = true
        default: break
        }
    }

    private func decodeBits(_ data: Data) -> [Bool] {
        let bytes = [UInt8](data)
        var bits: [Bool] = []
        bits.reserveCapacity(bytes.count * 8)
        for byte in bytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                bits.append((byte >> shift) & 1 == 1)
            }
        }
        return bits
    }

    /// Send a wire message. Tracks our own interest so the session doesn't double-send.
    public func send(_ message: PeerMessage) async throws {
        if case .interested = message { amInterested = true }
        if case .notInterested = message { amInterested = false }
        try await rawSend(message.encoded)
    }

    /// A point-in-time snapshot of this peer for the detail view (its address, decoded client,
    /// how much of the torrent it has, and whether it's choking us / encrypted).
    public func snapshot(pieceCount: Int) -> TorrentSession.PeerInfo {
        let have = pieceCount > 0 ? peerBitfield.prefix(pieceCount).lazy.filter { $0 }.count : 0
        return TorrentSession.PeerInfo(
            address: "\(host):\(port)",
            client: TorrentSession.PeerInfo.decodeClient(remotePeerID),
            progress: pieceCount > 0 ? Double(have) / Double(pieceCount) : 0,
            choked: peerChoking,
            encrypted: isEncrypted)
    }

    public func close() {
        closed = true
        connection?.cancel()
        connection = nil
        if let utp {
            self.utp = nil
            Task { await utp.close() }
        }
    }

    // MARK: raw socket

    private static let queue = DispatchQueue(
        label: "com.pathem.torrent.peer", attributes: .concurrent)

    private func rawSend(_ data: Data) async throws {
        guard !closed else { throw PeerError.closed }
        var payload = data
        if sendCipher != nil { payload = sendCipher!.process(data) }  // RC4 once encryption is on
        if let utp {
            try await utp.send(payload)
            return
        }
        guard let conn = connection else { throw PeerError.closed }
        let _: Void = try await withThrowingContinuation(timeout: 30) { done in
            conn.send(
                content: payload,
                completion: .contentProcessed { error in
                    if let error {
                        done(.failure(PeerError.connectionFailed("\(error)")))
                    } else {
                        done(.success(()))
                    }
                })
        }
    }

    /// Read (and decrypt, if encrypted) one chunk from the socket.
    private func receiveRawChunk(timeout: TimeInterval) async throws -> Data {
        guard !closed else { throw PeerError.closed }
        let chunk: Data
        if let utp {
            chunk = try await utp.recv(timeout: timeout)
        } else {
            guard let conn = connection else { throw PeerError.closed }
            chunk = try await withThrowingContinuation(timeout: timeout) { done in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                    data, _, isComplete, error in
                    if let error {
                        done(.failure(PeerError.connectionFailed("\(error)")))
                        return
                    }
                    if let data, !data.isEmpty {
                        done(.success(data))
                        return
                    }
                    if isComplete {
                        done(.failure(PeerError.closed))
                        return
                    }
                    done(.success(Data()))
                }
            }
        }
        if recvCipher != nil { return recvCipher!.process(chunk) }
        return chunk
    }

    /// Read one chunk from the socket into `inbound`, or throw on EOF/error/timeout.
    private func readMore(timeout: TimeInterval) async throws {
        inbound.append(try await receiveRawChunk(timeout: timeout))
    }

    /// A byte-stream adapter over this connection for driving the MSE handshake (which runs
    /// while the ciphers are still nil, so its reads/writes are plaintext on the wire).
    private func mseStream(timeout: TimeInterval) -> MSEHandshake.Stream {
        MSEHandshake.Stream(
            send: { [weak self] data in try await self?.rawSend(data) },
            recv: { [weak self] in try await self?.receiveRawChunk(timeout: timeout) ?? Data() })
    }

    // MARK: continuation with timeout

    /// Bridge a callback-style operation to async, failing with `.timedOut` if `body` never
    /// calls its `done`. Guards against a double-resume if both the op and the timer fire.
    private func withThrowingContinuation<T: Sendable>(
        timeout: TimeInterval,
        _ body: @escaping (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let box = ResumeBox<T>()
        return try await withCheckedThrowingContinuation { cont in
            box.attach(cont)
            Self.queue.asyncAfter(deadline: .now() + timeout) {
                box.resume(.failure(PeerError.timedOut))
            }
            body { result in box.resume(result) }
        }
    }
}

/// Ensures a checked continuation is resumed exactly once across racing callbacks/timers.
private final class ResumeBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var done = false

    func attach(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        cont = c
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
#endif
