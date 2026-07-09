import Foundation

#if canImport(Network)
    import Network

    /// Accepts incoming peer connections so we can seed to peers that dial us (not just the ones we
    /// dial out to). For each connection it reads the peer's handshake, learns which torrent they
    /// want, and hands the connection to the owner via `onPeer`, which routes it to the matching
    /// session (or closes it). One listener per engine.
    ///
    /// Reachability behind NAT needs port mapping (UPnP/NAT-PMP), which isn't built yet, so inbound
    /// peers arrive on open networks and LANs; outbound connections (and seeding over them) always
    /// work.
    public actor PeerListener {
        private let peerID: Data
        private let onPeer: @Sendable (String, PeerConnection) async -> Void
        private var listener: NWListener?
        public private(set) var boundPort: UInt16?

        public init(peerID: Data, onPeer: @escaping @Sendable (String, PeerConnection) async -> Void) {
            self.peerID = peerID
            self.onPeer = onPeer
        }

        /// Start listening. Pass 0 for an ephemeral port (tests). Returns the actual bound port.
        @discardableResult
        public func start(port desired: UInt16 = 6881, timeout: TimeInterval = 10) async throws -> UInt16 {
            if let boundPort { return boundPort }
            let endpointPort: NWEndpoint.Port = desired == 0 ? .any : (NWEndpoint.Port(rawValue: desired) ?? .any)
            let listener = try NWListener(using: .tcp, on: endpointPort)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] conn in
                Task { await self?.handle(conn) }
            }

            let box = PortBox()
            let port: UInt16 = try await withCheckedThrowingContinuation { cont in
                box.attach(cont)
                Self.timerQueue.asyncAfter(deadline: .now() + timeout) { box.resume(.failure(ListenError.timedOut)) }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: box.resume(.success(listener.port?.rawValue ?? desired))
                    case .failed(let error): box.resume(.failure(ListenError.failed("\(error)")))
                    default: break
                    }
                }
                listener.start(queue: Self.queue)
            }
            boundPort = port
            return port
        }

        public func stop() {
            listener?.cancel()
            listener = nil
            boundPort = nil
        }

        private func handle(_ conn: NWConnection) async {
            let peer = PeerConnection(incoming: conn, peerID: peerID)
            guard let infoHash = try? await peer.acceptHandshake() else {
                await peer.close()
                return
            }
            let hex = infoHash.map { String(format: "%02x", $0) }.joined()
            await onPeer(hex, peer)
        }

        public enum ListenError: Error, Equatable { case timedOut, failed(String) }

        private static let queue = DispatchQueue(label: "com.pathem.torrent.listener")
        private static let timerQueue = DispatchQueue(label: "com.pathem.torrent.listener.timer")
    }

    /// One-shot resume guard for the listener-ready continuation.
    private final class PortBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<UInt16, Error>?
        private var done = false
        func attach(_ c: CheckedContinuation<UInt16, Error>) {
            lock.lock(); cont = c; lock.unlock()
        }
        func resume(_ result: Result<UInt16, Error>) {
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
