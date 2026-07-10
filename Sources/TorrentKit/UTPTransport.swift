import Foundation

#if canImport(Network)
    import Network

    /// A µTP (BEP 29) transport for a single peer: a UDP socket carrying a `UTPSocket`, exposing the
    /// same `send` / `recv` byte-stream that PeerConnection drives over TCP, so the BitTorrent
    /// handshake, MSE, and wire messages all flow through it unchanged.
    ///
    /// Two shapes: an *outbound* transport owns its own connected UDP socket and pumps it itself; an
    /// *inbound* transport wraps a connection the UDPMux owns and is fed datagrams via `deliver`,
    /// because inbound µTP shares the DHT's UDP port and the mux does the per-datagram demux.
    actor UTPTransport {
        private let host: String
        private let port: UInt16
        private let inbound: Bool
        private var conn: NWConnection?
        private var socket: UTPSocket?
        private var running = false

        init(host: String, port: UInt16) {
            self.host = host
            self.port = port
            self.inbound = false
        }

        /// Inbound/responder transport. The mux has already run the µTP SYN through `socket` (so it's
        /// connected) and owns `conn`; it demuxes the shared socket and hands us µTP datagrams via
        /// `deliver`. We never arm our own receive pump here.
        init(inbound socket: UTPSocket, conn: NWConnection, remoteHost: String) {
            self.host = remoteHost
            self.port = 0
            self.inbound = true
            self.socket = socket
            self.conn = conn
            self.running = true
        }

        /// Feed one incoming µTP datagram into the state machine (inbound path only).
        func deliver(_ datagram: Data) async { await socket?.handle(datagram) }

        var remoteHost: String { host }

        /// Open the UDP socket and complete the µTP handshake (SYN/ACK). Throws on timeout.
        func start(timeout: TimeInterval) async throws {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw PeerConnection.PeerError.connectionFailed("bad port")
            }
            let conn = NWConnection(host: .init(host), port: nwPort, using: .udp)
            self.conn = conn
            try await waitReady(conn, timeout: timeout)

            // The datagram sender the µTP state machine writes through.
            let sender: @Sendable (Data) async -> Void = { data in
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    conn.send(content: data, completion: .contentProcessed { _ in cont.resume() })
                }
            }
            let socket = UTPSocket(
                role: .initiator, connectionID: UInt16.random(in: 0...UInt16.max), sendDatagram: sender)
            self.socket = socket
            running = true
            arm()  // start pulling datagrams into the µTP socket
            await socket.connect()  // send SYN, begin retransmission

            // Wait for the responder's ACK to move us to `connected`, bounded by the timeout.
            let deadline = Date().addingTimeInterval(timeout)
            while await !socket.isConnected {
                if Date() >= deadline { throw PeerConnection.PeerError.timedOut }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        func send(_ data: Data) async throws {
            guard let socket, running else { throw PeerConnection.PeerError.closed }
            await socket.write(data)
        }

        /// Read the next chunk of in-order bytes, honoring `timeout`. Empty means end of stream,
        /// surfaced as a normal close so PeerConnection's read loop terminates.
        func recv(timeout: TimeInterval) async throws -> Data {
            guard let socket, running else { throw PeerConnection.PeerError.closed }
            let data = try await withThrowingTaskGroup(of: Data?.self) { group in
                group.addTask { await socket.readAvailable() }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return nil  // timeout sentinel
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let data else { throw PeerConnection.PeerError.timedOut }
            if data.isEmpty { throw PeerConnection.PeerError.closed }
            return data
        }

        func close() async {
            running = false
            await socket?.close()
            socket = nil
            conn?.cancel()
            conn = nil
        }

        /// Pump: read one datagram off the UDP socket into the µTP state machine, then re-arm.
        private func arm() {
            guard running, let conn, let socket else { return }
            conn.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if let data, !data.isEmpty { Task { await socket.handle(data) } }
                if error == nil {
                    Task { await self.arm() }
                } else {
                    Task { await self.close() }
                }
            }
        }

        private func waitReady(_ conn: NWConnection, timeout: TimeInterval) async throws {
            let box = UTPReadyBox()
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                box.attach(cont)
                Self.queue.asyncAfter(deadline: .now() + timeout) {
                    box.resume(.failure(PeerConnection.PeerError.timedOut))
                }
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready: box.resume(.success(()))
                    case .failed(let error): box.resume(.failure(PeerConnection.PeerError.connectionFailed("\(error)")))
                    case .cancelled: box.resume(.failure(PeerConnection.PeerError.closed))
                    default: break
                    }
                }
                conn.start(queue: Self.queue)
            }
        }

        private static let queue = DispatchQueue(label: "com.pathem.torrent.utp", attributes: .concurrent)
    }

    /// One-shot resume guard for the µTP UDP-ready continuation.
    private final class UTPReadyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Void, Error>?
        private var done = false
        func attach(_ c: CheckedContinuation<Void, Error>) { lock.lock(); cont = c; lock.unlock() }
        func resume(_ result: Result<Void, Error>) {
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
