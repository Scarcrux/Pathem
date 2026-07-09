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
        }

        public let host: String
        public let port: UInt16
        private let infoHash: Data
        private let myPeerID: Data

        private var connection: NWConnection?
        private var inbound = Data()  // bytes read but not yet parsed into a message
        private var closed = false

        /// Peer state, updated as messages arrive (the session reads these).
        public private(set) var peerChoking = true
        public private(set) var amInterested = false
        public private(set) var peerBitfield: [Bool] = []
        public private(set) var remotePeerID: Data?

        public init(host: String, port: UInt16, infoHash: Data, peerID: Data) {
            self.host = host
            self.port = port
            self.infoHash = infoHash
            self.myPeerID = peerID
        }

        /// Open the TCP connection and exchange handshakes. Throws on failure or timeout.
        public func connect(timeout: TimeInterval = 15) async throws {
            let params = NWParameters.tcp
            let conn = NWConnection(
                host: .init(host), port: .init(rawValue: port) ?? .any, using: params)
            self.connection = conn

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

            let handshake = PeerHandshake(infoHash: infoHash, peerID: myPeerID)
            try await rawSend(handshake.encoded)
            try await readHandshake(timeout: timeout)
        }

        /// Read exactly the 68-byte handshake, validating the info hash matches.
        private func readHandshake(timeout: TimeInterval) async throws {
            while inbound.count < 68 { try await readMore(timeout: timeout) }
            guard let hs = PeerHandshake.parse(inbound), hs.infoHash == infoHash else {
                throw PeerError.handshakeMismatch
            }
            remotePeerID = hs.peerID
            inbound.removeFirst(68)
        }

        /// Wait for and return the next parsed message, applying its effect to peer state.
        public func receive(timeout: TimeInterval = 120) async throws -> PeerMessage {
            while true {
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
                if i >= peerBitfield.count { peerBitfield += Array(repeating: false, count: i - peerBitfield.count + 1) }
                peerBitfield[i] = true
            default: break
            }
        }

        private func decodeBits(_ data: Data) -> [Bool] {
            let bytes = [UInt8](data)
            var bits: [Bool] = []
            bits.reserveCapacity(bytes.count * 8)
            for byte in bytes {
                for shift in stride(from: 7, through: 0, by: -1) { bits.append((byte >> shift) & 1 == 1) }
            }
            return bits
        }

        /// Send a wire message. Tracks our own interest so the session doesn't double-send.
        public func send(_ message: PeerMessage) async throws {
            if case .interested = message { amInterested = true }
            if case .notInterested = message { amInterested = false }
            try await rawSend(message.encoded)
        }

        public func close() {
            closed = true
            connection?.cancel()
            connection = nil
        }

        // MARK: raw socket

        private static let queue = DispatchQueue(label: "com.pathem.torrent.peer", attributes: .concurrent)

        private func rawSend(_ data: Data) async throws {
            guard let conn = connection, !closed else { throw PeerError.closed }
            let _: Void = try await withThrowingContinuation(timeout: 30) { done in
                conn.send(content: data, completion: .contentProcessed { error in
                    if let error { done(.failure(PeerError.connectionFailed("\(error)"))) }
                    else { done(.success(())) }
                })
            }
        }

        /// Read one chunk from the socket into `inbound`, or throw on EOF/error/timeout.
        private func readMore(timeout: TimeInterval) async throws {
            guard let conn = connection, !closed else { throw PeerError.closed }
            let chunk: Data = try await withThrowingContinuation(timeout: timeout) { done in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error { done(.failure(PeerError.connectionFailed("\(error)"))); return }
                    if let data, !data.isEmpty { done(.success(data)); return }
                    if isComplete { done(.failure(PeerError.closed)); return }
                    done(.success(Data()))
                }
            }
            inbound.append(chunk)
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
                Self.queue.asyncAfter(deadline: .now() + timeout) { box.resume(.failure(PeerError.timedOut)) }
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
            lock.lock(); defer { lock.unlock() }
            cont = c
        }

        func resume(_ result: Result<T, Error>) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume(with: result)
        }
    }
#endif
