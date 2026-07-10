import Foundation

#if canImport(Network)
    import Network

    /// A minimal, lookup-only DHT node (BEP 5): given an info hash, it bootstraps from the
    /// well-known routers and iteratively sends `get_peers` to the closest nodes it learns about
    /// until it collects peers or runs out of closer nodes. Enough to find peers for a trackerless
    /// magnet; it doesn't yet serve queries or keep a persistent routing table.
    public actor DHTClient {
        public nonisolated let nodeID = DHT.randomID()
        private var txnCounter: UInt16 = 0
        private var goodNodes: [DHT.Node] = []  // nodes that have answered us (the routing table)
        private let maxGoodNodes = 400

        public init() {}

        /// The closest known nodes to a target id, for answering find_node / get_peers as a server.
        public func closestNodes(to target: Data, count: Int = 8) -> [DHT.Node] {
            Array(goodNodes.sorted { DHT.closer($0.id, than: $1.id, to: target) < 0 }.prefix(count))
        }

        /// Record a node in the routing table (e.g. one that just queried us). Public wrapper.
        public func note(_ node: DHT.Node) { remember(node) }

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
            await lookup(infoHash: infoHash, maxPeers: maxPeers).peers
        }

        /// Announce that we're a peer for `infoHash` reachable on `port`, making us discoverable to
        /// other DHT nodes (BEP 5). Runs a normal get_peers lookup to find the closest nodes and the
        /// write tokens they hand out, then sends `announce_peer` to the closest few. Returns the
        /// peers the lookup happened to find, so the caller gets discovery for free.
        @discardableResult
        public func announcePeer(
            infoHash: Data, port: Int, maxPeers: Int = 50
        ) async -> [Tracker.Peer] {
            let result = await lookup(infoHash: infoHash, maxPeers: maxPeers)
            // Announce to the closest nodes that gave us a token (up to 8, the BEP-5 convention).
            let targets = result.tokenNodes
                .sorted { DHT.closer($0.node.id, than: $1.node.id, to: infoHash) < 0 }
                .prefix(8)
            await withTaskGroup(of: Void.self) { group in
                for (node, token) in targets {
                    group.addTask {
                        let query = await DHT.announcePeerQuery(
                            transaction: self.nextTransaction(), nodeID: self.nodeID,
                            infoHash: infoHash, port: port, token: token)
                        _ = await UDP.query(host: node.host, port: node.port, payload: query, timeout: 4)
                    }
                }
            }
            return result.peers
        }

        /// The iterative get_peers search shared by findPeers and announcePeer: walk toward the
        /// info hash, collecting peers and the (node, token) pairs needed to announce back.
        private func lookup(
            infoHash: Data, maxPeers: Int
        ) async -> (peers: [Tracker.Peer], tokenNodes: [(node: DHT.Node, token: Data)]) {
            // Start from remembered good nodes (warm start) plus the bootstrap routers.
            var candidates: [DHT.Node] = goodNodes + DHT.bootstrapNodes.map {
                DHT.Node(id: Data(count: DHT.idLength), host: $0.host, port: $0.port)
            }
            var seen = Set(candidates.map(key))  // candidate keys, so we never enqueue a dup
            var queried = Set<String>()
            var found = Set<Tracker.Peer>()
            var tokenNodes: [String: (node: DHT.Node, token: Data)] = [:]
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
                    if let token = result.token { tokenNodes[key(node)] = (node, token) }
                    for peer in result.peers { found.insert(peer) }
                    for node in result.nodes where seen.insert(key(node)).inserted {
                        candidates.append(node)  // only genuinely new nodes
                    }
                }
                // Keep only the closest candidates so the frontier stays bounded.
                candidates = Array(
                    candidates.sorted { DHT.closer($0.id, than: $1.id, to: infoHash) < 0 }.prefix(48))
            }
            return (Array(found.prefix(maxPeers)), Array(tokenNodes.values))
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
