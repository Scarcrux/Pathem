import CryptoKit
import Foundation

#if canImport(Network)
    import Network

    /// A DHT peer store: which peers have announced themselves for each info hash, with a TTL so
    /// stale entries fall out (nodes re-announce about every 15 minutes; BEP 5 uses a longer grace).
    /// Mutating on prune so a lookup also garbage-collects. Pure and unit-tested.
    struct DHTPeerStore {
        private struct Entry {
            let host: String
            let port: Int
            var expiry: Date
        }
        private var byHash: [Data: [Entry]] = [:]
        let ttl: TimeInterval
        let maxPerHash: Int

        init(ttl: TimeInterval = 30 * 60, maxPerHash: Int = 200) {
            self.ttl = ttl
            self.maxPerHash = maxPerHash
        }

        mutating func add(infoHash: Data, peer: Tracker.Peer, now: Date) {
            var list = (byHash[infoHash] ?? []).filter { $0.expiry > now }
            if let idx = list.firstIndex(where: { $0.host == peer.host && $0.port == peer.port }) {
                list[idx].expiry = now + ttl  // refresh
            } else {
                list.append(Entry(host: peer.host, port: peer.port, expiry: now + ttl))
                if list.count > maxPerHash { list.removeFirst(list.count - maxPerHash) }
            }
            byHash[infoHash] = list
        }

        mutating func peers(infoHash: Data, now: Date, limit: Int = 50) -> [Tracker.Peer] {
            guard let raw = byHash[infoHash] else { return [] }
            let live = raw.filter { $0.expiry > now }
            byHash[infoHash] = live.isEmpty ? nil : live
            return live.prefix(limit).map { Tracker.Peer(host: $0.host, port: $0.port) }
        }
    }

    /// Write-token manager (BEP 5): a get_peers response hands out an opaque token that the peer
    /// must echo in its announce_peer, proving it can receive at the address it claims (anti-spoof).
    /// The token is `SHA1(secret || ip)`; the secret rotates so old tokens expire, and we accept the
    /// previous secret too so a token issued just before a rotation still validates. Pure and tested.
    struct DHTTokens {
        private var current: Data
        private var previous: Data
        private var rotatedAt: Date
        let interval: TimeInterval

        init(now: Date, interval: TimeInterval = 5 * 60) {
            current = Self.randomSecret()
            previous = Self.randomSecret()
            rotatedAt = now
            self.interval = interval
        }

        mutating func issue(host: String, now: Date) -> Data {
            rotateIfNeeded(now: now)
            return Self.token(secret: current, host: host)
        }

        mutating func validate(_ token: Data, host: String, now: Date) -> Bool {
            rotateIfNeeded(now: now)
            return token == Self.token(secret: current, host: host)
                || token == Self.token(secret: previous, host: host)
        }

        private mutating func rotateIfNeeded(now: Date) {
            guard now.timeIntervalSince(rotatedAt) >= interval else { return }
            previous = current
            current = Self.randomSecret()
            rotatedAt = now
        }

        private static func token(secret: Data, host: String) -> Data {
            Data(Insecure.SHA1.hash(data: secret + Data(host.utf8)))
        }

        private static func randomSecret() -> Data {
            var d = Data(count: 16)
            for i in 0..<d.count { d[i] = UInt8.random(in: 0...255) }
            return d
        }
    }

    /// A full DHT node's server half (BEP 5): it binds a UDP port and answers the queries other
    /// nodes send us -- ping, find_node, get_peers, announce_peer -- so we're a real participant in
    /// the DHT, not just a client that takes from it. Identity and the routing table are shared with
    /// the `DHTClient` (one node id, one table), so nodes that query us also warm our lookups. The
    /// peer store and write tokens live here. The `respond` heart is pure and unit-tested; only the
    /// socket plumbing needs the network.
    public actor DHTServer {
        private let client: DHTClient
        private var store: DHTPeerStore
        private var tokens: DHTTokens
        private var listener: NWListener?
        public private(set) var boundPort: UInt16?

        public init(client: DHTClient, now: Date = Date()) {
            self.client = client
            self.store = DHTPeerStore()
            self.tokens = DHTTokens(now: now)
        }

        /// Bind the UDP port and start answering queries. Pass 0 for an ephemeral port (tests).
        @discardableResult
        public func start(port desired: UInt16 = 6881, timeout: TimeInterval = 10) async throws -> UInt16 {
            if let boundPort { return boundPort }
            let endpointPort: NWEndpoint.Port =
                desired == 0 ? .any : (NWEndpoint.Port(rawValue: desired) ?? .any)
            let listener = try NWListener(using: .udp, on: endpointPort)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready: self.arm(conn)
                    case .failed, .cancelled: conn.cancel()
                    default: break
                    }
                }
                conn.start(queue: Self.queue)
            }

            let box = DHTPortBox()
            let port: UInt16 = try await withCheckedThrowingContinuation { cont in
                box.attach(cont)
                Self.queue.asyncAfter(deadline: .now() + timeout) { box.resume(.failure(ListenError.timedOut)) }
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

        /// Read one datagram off a freshly-accepted UDP connection, answer it, and close. A DHT node
        /// sends a query and awaits a single reply, so one-shot per connection keeps us leak-free (a
        /// follow-up query arrives as a new connection).
        private nonisolated func arm(_ conn: NWConnection) {
            let remote = Self.hostPort(from: conn.currentPath?.remoteEndpoint ?? conn.endpoint)
            conn.receiveMessage { [weak self] data, _, _, _ in
                guard let self, let data, !data.isEmpty, let (host, port) = remote else {
                    conn.cancel()
                    return
                }
                Task {
                    if let reply = await self.reply(to: data, fromHost: host, fromPort: port) {
                        conn.send(content: reply, completion: .contentProcessed { _ in conn.cancel() })
                    } else {
                        conn.cancel()
                    }
                }
            }
        }

        private func reply(to data: Data, fromHost: String, fromPort: UInt16) async -> Data? {
            guard let message = DHT.parseMessage(data) else { return nil }
            return await respond(to: message, fromHost: fromHost, fromPort: fromPort, now: Date())
        }

        /// Answer one KRPC query as a DHT server. Pure apart from the shared routing table: returns
        /// the datagram to send back, or nil if the message isn't a query we serve. Unit-tested.
        public func respond(
            to message: DHT.Message, fromHost: String, fromPort: UInt16, now: Date
        ) async -> Data? {
            guard case .query(let method, let args) = message.kind else { return nil }
            let txn = message.transaction
            let selfID = client.nodeID
            // Any node that queries us is a live node worth remembering for our own lookups.
            if case .bytes(let qid)? = args["id"], qid.count == DHT.idLength {
                await client.note(DHT.Node(id: qid, host: fromHost, port: fromPort))
            }

            switch method {
            case "ping":
                return DHT.pingResponse(transaction: txn, nodeID: selfID)

            case "find_node":
                guard case .bytes(let target)? = args["target"], target.count == DHT.idLength else {
                    return DHT.errorResponse(transaction: txn, code: 203, message: "bad target")
                }
                let nodes = await client.closestNodes(to: target, count: 8)
                return DHT.findNodeResponse(transaction: txn, nodeID: selfID, nodes: nodes)

            case "get_peers":
                guard case .bytes(let infoHash)? = args["info_hash"], infoHash.count == DHT.idLength else {
                    return DHT.errorResponse(transaction: txn, code: 203, message: "bad info_hash")
                }
                let token = tokens.issue(host: fromHost, now: now)
                let peers = store.peers(infoHash: infoHash, now: now)
                let nodes = peers.isEmpty ? await client.closestNodes(to: infoHash, count: 8) : []
                return DHT.getPeersResponse(
                    transaction: txn, nodeID: selfID, token: token, peers: peers, nodes: nodes)

            case "announce_peer":
                guard case .bytes(let infoHash)? = args["info_hash"], infoHash.count == DHT.idLength,
                    case .bytes(let token)? = args["token"]
                else {
                    return DHT.errorResponse(transaction: txn, code: 203, message: "missing args")
                }
                guard tokens.validate(token, host: fromHost, now: now) else {
                    return DHT.errorResponse(transaction: txn, code: 203, message: "bad token")
                }
                // implied_port (BEP 5): when set, ignore the stated port and use the query's source
                // UDP port, which is the address we already know reaches the announcer.
                let implied = (args["implied_port"]?.intValue ?? 0) != 0
                let port = implied ? Int(fromPort) : Int(args["port"]?.intValue ?? 0)
                if port > 0, port <= 0xffff {
                    store.add(infoHash: infoHash, peer: Tracker.Peer(host: fromHost, port: port), now: now)
                }
                return DHT.pingResponse(transaction: txn, nodeID: selfID)

            default:
                return DHT.errorResponse(transaction: txn, code: 204, message: "method unknown")
            }
        }

        /// Test seam: announce a peer directly into the store (bypasses the socket).
        func storePeer(infoHash: Data, peer: Tracker.Peer, now: Date) {
            store.add(infoHash: infoHash, peer: peer, now: now)
        }

        public enum ListenError: Error, Equatable { case timedOut, failed(String) }

        /// Pull a clean host string and port out of an endpoint. Only IPv4 dotted-quad and named
        /// hosts are returned in a form we re-encode; IPv6 keeps its textual form (compact-peer
        /// encoding will simply skip it, which is correct for our IPv4 `values`).
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

        private static let queue = DispatchQueue(label: "com.pathem.torrent.dht.server")
    }

    /// One-shot resume guard for the DHT listener-ready continuation (mirrors PeerListener's).
    private final class DHTPortBox: @unchecked Sendable {
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
