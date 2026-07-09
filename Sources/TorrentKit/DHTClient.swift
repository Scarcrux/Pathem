import Foundation

#if canImport(Network)
    import Network

    /// A minimal, lookup-only DHT node (BEP 5): given an info hash, it bootstraps from the
    /// well-known routers and iteratively sends `get_peers` to the closest nodes it learns about
    /// until it collects peers or runs out of closer nodes. Enough to find peers for a trackerless
    /// magnet; it doesn't yet serve queries or keep a persistent routing table.
    public actor DHTClient {
        private let nodeID = DHT.randomID()
        private var txnCounter: UInt16 = 0

        public init() {}

        /// Find peers for `infoHash`. Returns as soon as it has `maxPeers` or the search converges.
        public func findPeers(
            infoHash: Data, maxPeers: Int = 50, timeout: TimeInterval = 25
        ) async -> [Tracker.Peer] {
            var candidates: [DHT.Node] = DHT.bootstrapNodes.map {
                DHT.Node(id: Data(count: DHT.idLength), host: $0.host, port: $0.port)
            }
            var seen = Set(candidates.map(key))  // candidate keys, so we never enqueue a dup
            var queried = Set<String>()
            var found = Set<Tracker.Peer>()
            var queriesLeft = 80  // hard cap on total UDP queries per lookup

            while !candidates.isEmpty, found.count < maxPeers, queriesLeft > 0 {
                // Query the alpha closest un-queried candidates concurrently.
                let batch = candidates
                    .filter { !queried.contains(key($0)) }
                    .sorted { DHT.closer($0.id, than: $1.id, to: infoHash) < 0 }
                    .prefix(3)
                if batch.isEmpty { break }
                for node in batch { queried.insert(key(node)) }
                queriesLeft -= batch.count

                let results = await withTaskGroup(of: DHT.GetPeersResult?.self) { group in
                    for node in batch {
                        group.addTask { await self.getPeers(from: node, infoHash: infoHash, timeout: 4) }
                    }
                    var out: [DHT.GetPeersResult] = []
                    for await r in group { if let r { out.append(r) } }
                    return out
                }

                for result in results {
                    for peer in result.peers { found.insert(peer) }
                    for node in result.nodes where seen.insert(key(node)).inserted {
                        candidates.append(node)  // only genuinely new nodes
                    }
                }
                // Keep only the closest candidates so the frontier stays bounded.
                candidates = Array(
                    candidates.sorted { DHT.closer($0.id, than: $1.id, to: infoHash) < 0 }.prefix(48))
            }
            return Array(found.prefix(maxPeers))
        }

        private func key(_ node: DHT.Node) -> String { "\(node.host):\(node.port)" }

        private func nextTransaction() -> Data {
            txnCounter &+= 1
            return Data([UInt8(txnCounter >> 8), UInt8(txnCounter & 0xff)])
        }

        /// Send one get_peers query to a node and parse the response.
        private func getPeers(from node: DHT.Node, infoHash: Data, timeout: TimeInterval) async
            -> DHT.GetPeersResult?
        {
            let query = DHT.getPeersQuery(
                transaction: nextTransaction(), nodeID: nodeID, infoHash: infoHash)
            guard let reply = await Self.udpQuery(host: node.host, port: node.port, payload: query, timeout: timeout),
                let message = DHT.parseMessage(reply),
                case .response(let response) = message.kind
            else { return nil }
            return DHT.parseGetPeersResponse(response)
        }

        /// One UDP request/response: send `payload` to host:port, return the first datagram back.
        private static func udpQuery(host: String, port: UInt16, payload: Data, timeout: TimeInterval)
            async -> Data?
        {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
            let conn = NWConnection(host: .init(host), port: nwPort, using: .udp)
            let box = DatagramBox()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: payload, completion: .contentProcessed { _ in })
                    conn.receiveMessage { data, _, _, _ in box.resume(data) }
                case .failed, .cancelled:
                    box.resume(nil)
                default:
                    break
                }
            }
            Self.queue.asyncAfter(deadline: .now() + timeout) { box.resume(nil) }
            conn.start(queue: Self.queue)
            let result = await box.value()
            conn.cancel()
            return result
        }

        private static let queue = DispatchQueue(label: "com.pathem.torrent.dht", attributes: .concurrent)
    }

    /// One-shot async box for a single UDP datagram (resumes with nil on timeout/failure).
    private final class DatagramBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        private var settled = false
        private var pending: Data??  // outer optional: was a value delivered before value() awaited

        func value() async -> Data? {
            await withCheckedContinuation { cont in
                lock.lock()
                if let pending {
                    lock.unlock()
                    cont.resume(returning: pending)
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        }

        func resume(_ data: Data?) {
            lock.lock()
            if settled { lock.unlock(); return }
            settled = true
            let cont = continuation
            continuation = nil
            if cont == nil { pending = .some(data) }
            lock.unlock()
            cont?.resume(returning: data)
        }
    }
#endif
