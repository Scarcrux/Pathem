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
        private var goodNodes: [DHT.Node] = []  // nodes that have answered us (the routing table)
        private let maxGoodNodes = 400

        public init() {}

        /// Serialize the routing table (good nodes) so it can be persisted and reloaded, warm-
        /// starting future lookups instead of always hammering the bootstrap routers.
        public func routingTableData() -> Data { DHT.encodeCompactNodes(goodNodes) }

        public func loadRoutingTable(_ data: Data) {
            for node in DHT.parseCompactNodes(data) where !node.id.allSatisfy({ $0 == 0 }) {
                remember(node)
            }
        }

        public var routingTableSize: Int { goodNodes.count }

        private func remember(_ node: DHT.Node) {
            guard !goodNodes.contains(where: { $0.host == node.host && $0.port == node.port }) else { return }
            goodNodes.append(node)
            if goodNodes.count > maxGoodNodes { goodNodes.removeFirst(goodNodes.count - maxGoodNodes) }
        }

        /// Find peers for `infoHash`. Returns as soon as it has `maxPeers` or the search converges.
        public func findPeers(
            infoHash: Data, maxPeers: Int = 50, timeout: TimeInterval = 25
        ) async -> [Tracker.Peer] {
            // Start from remembered good nodes (warm start) plus the bootstrap routers.
            var candidates: [DHT.Node] = goodNodes + DHT.bootstrapNodes.map {
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

                let responses = await withTaskGroup(of: (DHT.Node, DHT.GetPeersResult?).self) { group in
                    for node in batch {
                        group.addTask { (node, await self.getPeers(from: node, infoHash: infoHash, timeout: 4)) }
                    }
                    var out: [(DHT.Node, DHT.GetPeersResult?)] = []
                    for await r in group { out.append(r) }
                    return out
                }

                for (node, result) in responses {
                    guard let result else { continue }
                    remember(node)  // it answered: keep it in the routing table
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
            guard let reply = await UDP.query(host: node.host, port: node.port, payload: query, timeout: timeout),
                let message = DHT.parseMessage(reply),
                case .response(let response) = message.kind
            else { return nil }
            return DHT.parseGetPeersResponse(response)
        }
    }
#endif
