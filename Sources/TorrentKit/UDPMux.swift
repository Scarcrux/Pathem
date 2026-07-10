import Foundation

#if canImport(Network)
    import Network

    /// The single owner of our shared UDP port. BitTorrent puts three things on one port: TCP peers,
    /// µTP peers (UDP), and the DHT (UDP KRPC). The two UDP users collide, so this mux binds the
    /// socket and demultiplexes every datagram:
    ///
    /// - a datagram that decodes as a µTP packet (version 1, a valid type) is µTP; a SYN starts a new
    ///   inbound peer connection, the rest feed an existing one;
    /// - anything else is a bencoded KRPC message, answered by the DHT server.
    ///
    /// The two are cleanly separable: a KRPC message starts with 'd' (0x64), whose low nibble (4)
    /// isn't a µTP version and whose type nibble (6) isn't a valid µTP type, so `UTPPacket.decode`
    /// rejects it. µTP connections are kept alive across datagrams; a lone DHT query is answered and
    /// its connection dropped (a follow-up arrives as a fresh connection), which keeps us leak-free.
    public actor UDPMux {
        private let dht: DHTServer
        private let peerID: Data
        private let onPeer: @Sendable (String, PeerConnection) async -> Void
        private var listener: NWListener?
        public private(set) var boundPort: UInt16?

        // One inbound µTP session per connection (4-tuple). A peer opening several µTP streams from
        // one port is uncommon; we handle the first.
        private var sessions: [ObjectIdentifier: UTPTransport] = [:]

        public init(
            dht: DHTServer, peerID: Data,
            onPeer: @escaping @Sendable (String, PeerConnection) async -> Void
        ) {
            self.dht = dht
            self.peerID = peerID
            self.onPeer = onPeer
        }

        /// Classify a datagram: true if it's a µTP packet, false if it should go to the DHT. Exposed
        /// for tests; the live path uses `UTPPacket.decode` directly.
        public static func isUTP(_ datagram: Data) -> Bool { UTPPacket.decode(datagram) != nil }

        /// Bind the UDP port and start demultiplexing. Pass 0 for an ephemeral port (tests).
        @discardableResult
        public func start(port desired: UInt16 = 6881, timeout: TimeInterval = 10) async throws -> UInt16 {
            if let boundPort { return boundPort }
            let endpointPort: NWEndpoint.Port =
                desired == 0 ? .any : (NWEndpoint.Port(rawValue: desired) ?? .any)
            let listener = try NWListener(using: NetworkBinding.shared.pin(.udp), on: endpointPort)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready: self.arm(conn)
                    case .failed, .cancelled:
                        conn.cancel()
                        Task { await self.removeSession(ObjectIdentifier(conn)) }
                    default: break
                    }
                }
                conn.start(queue: Self.queue)
            }

            let box = MuxPortBox()
            let port: UInt16 = try await withCheckedThrowingContinuation { cont in
                box.attach(cont)
                Self.queue.asyncAfter(deadline: .now() + timeout) { box.resume(.failure(MuxError.timedOut)) }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: box.resume(.success(listener.port?.rawValue ?? desired))
                    case .failed(let error): box.resume(.failure(MuxError.failed("\(error)")))
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
            for (_, transport) in sessions { Task { await transport.close() } }
            sessions.removeAll()
        }

        /// Read one datagram, hand it to the demux, and let the demux decide whether to keep reading.
        private nonisolated func arm(_ conn: NWConnection) {
            let remote = Self.hostPort(from: conn.currentPath?.remoteEndpoint ?? conn.endpoint)
            conn.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if error != nil {
                    conn.cancel()
                    Task { await self.removeSession(ObjectIdentifier(conn)) }
                    return
                }
                guard let data, !data.isEmpty, let remote else {
                    self.arm(conn)  // keepalive / empty read: keep listening
                    return
                }
                Task { await self.onDatagram(data, from: conn, host: remote.0, port: remote.1) }
            }
        }

        private func onDatagram(_ data: Data, from conn: NWConnection, host: String, port: UInt16) async {
            let key = ObjectIdentifier(conn)
            // An established µTP connection: demux, but everything here is almost always µTP.
            if let session = sessions[key] {
                if UTPPacket.decode(data) != nil {
                    await session.deliver(data)
                } else {
                    await respondDHT(data, on: conn, host: host, port: port)
                }
                arm(conn)  // keep the µTP connection alive
                return
            }
            // No session yet. A µTP SYN opens one; other stray µTP packets are ignored.
            if let packet = UTPPacket.decode(data) {
                if packet.type == .syn {
                    await startInbound(packet: packet, datagram: data, conn: conn, host: host, port: port)
                    arm(conn)  // keep alive for the rest of the µTP stream
                } else {
                    conn.cancel()
                }
            } else if DHT.parseMessage(data) != nil {
                await respondDHT(data, on: conn, host: host, port: port)
                conn.cancel()  // one-shot DHT connection: a follow-up query arrives on a new one
            } else {
                conn.cancel()  // neither µTP nor KRPC
            }
        }

        /// Accept an inbound µTP peer: run the SYN through a responder socket, wrap it in a transport,
        /// and drive the BitTorrent handshake before handing the peer off to the session router.
        private func startInbound(
            packet: UTPPacket, datagram: Data, conn: NWConnection, host: String, port: UInt16
        ) async {
            let sender: @Sendable (Data) async -> Void = { out in
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    conn.send(content: out, completion: .contentProcessed { _ in c.resume() })
                }
            }
            let socket = UTPSocket(role: .responder, connectionID: packet.connectionID, sendDatagram: sender)
            await socket.handle(datagram)  // the SYN: ack it and mark the socket connected
            let transport = UTPTransport(inbound: socket, conn: conn, remoteHost: host)
            sessions[ObjectIdentifier(conn)] = transport
            let peer = PeerConnection(incomingUTP: transport, peerID: peerID, host: host, port: port)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let infoHash = try await peer.acceptHandshake()
                    let hex = infoHash.map { String(format: "%02x", $0) }.joined()
                    await self.onPeer(hex, peer)
                } catch {
                    await peer.close()
                    await self.removeSession(ObjectIdentifier(conn))
                }
            }
        }

        private func respondDHT(_ data: Data, on conn: NWConnection, host: String, port: UInt16) async {
            guard let message = DHT.parseMessage(data),
                let reply = await dht.respond(to: message, fromHost: host, fromPort: port, now: Date())
            else { return }
            conn.send(content: reply, completion: .contentProcessed { _ in })
        }

        private func removeSession(_ key: ObjectIdentifier) { sessions[key] = nil }

        public enum MuxError: Error, Equatable { case timedOut, failed(String) }

        private static func hostPort(from endpoint: NWEndpoint?) -> (String, UInt16)? {
            guard case .hostPort(let host, let port)? = endpoint else { return nil }
            let h: String
            switch host {
            case .ipv4(let a):
                let b = [UInt8](a.rawValue)
                guard b.count == 4 else { return nil }
                h = "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
            case .ipv6(let a):
                h = "\(a)"
            case .name(let n, _):
                h = n
            @unknown default:
                return nil
            }
            return (h, port.rawValue)
        }

        private static let queue = DispatchQueue(label: "com.pathem.torrent.udpmux", attributes: .concurrent)
    }

    /// One-shot resume guard for the mux listener-ready continuation.
    private final class MuxPortBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<UInt16, Error>?
        private var done = false
        func attach(_ c: CheckedContinuation<UInt16, Error>) { lock.lock(); cont = c; lock.unlock() }
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
