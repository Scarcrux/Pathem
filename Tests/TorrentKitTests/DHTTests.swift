import Foundation
import Testing

@testable import TorrentKit

@Suite struct DHTTests {
    private func id(_ byte: UInt8) -> Data { Data(repeating: byte, count: 20) }

    @Test func xorDistanceOrders() {
        let target = id(0x00)
        // 0x01... is closer to 0x00... than 0x02... is (smaller XOR).
        #expect(DHT.closer(id(0x01), than: id(0x02), to: target) < 0)
        #expect(DHT.closer(id(0x02), than: id(0x01), to: target) > 0)
        #expect(DHT.closer(id(0x05), than: id(0x05), to: target) == 0)
        // Distance is XOR, not numeric difference: 0x00 is closest to itself.
        #expect(DHT.closer(target, than: id(0xff), to: target) < 0)
    }

    @Test func randomIDIsTwentyBytes() {
        let a = DHT.randomID()
        #expect(a.count == 20)
        #expect(a != DHT.randomID())  // astronomically unlikely to collide
    }

    @Test func encodesAndParsesCompactNodesRoundTrip() {
        let nodes = [
            DHT.Node(id: Data(repeating: 0xAB, count: 20), host: "1.2.3.4", port: 6881),
            DHT.Node(id: Data(repeating: 0xCD, count: 20), host: "10.0.0.9", port: 51413),
        ]
        let decoded = DHT.parseCompactNodes(DHT.encodeCompactNodes(nodes))
        #expect(decoded == nodes)
    }

    @Test func routingTablePersistsGoodNodes() async {
        let client = DHTClient()
        var data = Data(repeating: 0x11, count: 20)  // one node's id
        data.append(contentsOf: [8, 8, 8, 8, 0x1a, 0xe1])  // 8.8.8.8:6881
        await client.loadRoutingTable(data)
        #expect(await client.routingTableSize == 1)
        // Round-trips: exporting and re-importing keeps the same node.
        let exported = await client.routingTableSize
        let fresh = DHTClient()
        await fresh.loadRoutingTable(await client.routingTableData())
        #expect(await fresh.routingTableSize == exported)
        // All-zero ids (bootstrap placeholders) are not remembered.
        await fresh.loadRoutingTable(Data(count: 26))
        #expect(await fresh.routingTableSize == 1)
    }

    @Test func parsesCompactNodes() {
        // One node: id 0xAB*20, 1.2.3.4:6881.
        var data = Data(repeating: 0xAB, count: 20)
        data.append(contentsOf: [1, 2, 3, 4, 0x1a, 0xe1])
        // A trailing partial record is ignored.
        data.append(contentsOf: [9, 9])
        let nodes = DHT.parseCompactNodes(data)
        #expect(nodes.count == 1)
        #expect(nodes[0].id == Data(repeating: 0xAB, count: 20))
        #expect(nodes[0].host == "1.2.3.4")
        #expect(nodes[0].port == 6881)
    }

    @Test func buildsAndParsesQueries() {
        let txn = Data([0x00, 0x01])
        let nodeID = id(0x11)
        let infoHash = id(0x22)

        let ping = DHT.parseMessage(DHT.pingQuery(transaction: txn, nodeID: nodeID))
        if case .query(let method, let args)? = ping?.kind {
            #expect(method == "ping")
            if case .bytes(let d)? = args["id"] {
                #expect(d == nodeID)
            } else {
                Issue.record("no id")
            }
        } else {
            Issue.record("ping did not parse as a query")
        }
        #expect(ping?.transaction == txn)

        let getPeers = DHT.parseMessage(
            DHT.getPeersQuery(transaction: txn, nodeID: nodeID, infoHash: infoHash))
        if case .query(let method, let args)? = getPeers?.kind {
            #expect(method == "get_peers")
            if case .bytes(let h)? = args["info_hash"] {
                #expect(h == infoHash)
            } else {
                Issue.record("no info_hash")
            }
        } else {
            Issue.record("get_peers did not parse as a query")
        }
    }

    @Test func parsesResponseWithNodesAndError() {
        // Build a get_peers response by hand: {t, y:r, r:{id, token, nodes}}.
        var nodeInfo = Data(repeating: 0xCD, count: 20)
        nodeInfo.append(contentsOf: [5, 6, 7, 8, 0x1a, 0xe1])  // 5.6.7.8:6881
        let response = Bencode.dict([
            ("id", .bytes(Data(repeating: 0x11, count: 20))),
            ("token", .bytes(Data("tok".utf8))),
            ("nodes", .bytes(nodeInfo)),
        ])
        let message = Bencode.dict([
            ("t", .bytes(Data([0xAA]))),
            ("y", .bytes(Data("r".utf8))),
            ("r", response),
        ])
        let parsed = DHT.parseMessage(message.encoded)
        guard case .response(let r)? = parsed?.kind else {
            Issue.record("not a response")
            return
        }
        let result = DHT.parseGetPeersResponse(r)
        #expect(result.token == Data("tok".utf8))
        #expect(result.nodes.count == 1)
        #expect(result.nodes[0].host == "5.6.7.8")
        #expect(result.peers.isEmpty)
    }

    @Test func parsesResponseWithPeers() {
        // {r:{id, token, values:[<6-byte peer>]}}
        let peer = Data([10, 0, 0, 1, 0x1a, 0xe1])  // 10.0.0.1:6881
        let response = Bencode.dict([
            ("id", .bytes(Data(repeating: 0x11, count: 20))),
            ("token", .bytes(Data("t".utf8))),
            ("values", .list([.bytes(peer)])),
        ])
        let message = Bencode.dict([
            ("t", .bytes(Data([1]))), ("y", .bytes(Data("r".utf8))), ("r", response),
        ])
        guard case .response(let r)? = DHT.parseMessage(message.encoded)?.kind else {
            Issue.record("not a response")
            return
        }
        let result = DHT.parseGetPeersResponse(r)
        #expect(result.peers == [.init(host: "10.0.0.1", port: 6881)])
        #expect(result.nodes.isEmpty)
    }

    @Test func parsesErrorMessage() {
        let message = Bencode.dict([
            ("t", .bytes(Data([1]))),
            ("y", .bytes(Data("e".utf8))),
            ("e", .list([.int(201), .bytes(Data("A Generic Error".utf8))])),
        ])
        guard case .error(let code, let text)? = DHT.parseMessage(message.encoded)?.kind else {
            Issue.record("not an error")
            return
        }
        #expect(code == 201)
        #expect(text == "A Generic Error")
    }

    #if canImport(Network)
    /// A live end-to-end DHT lookup against the real network, opt-in via PATHEM_DHT_LIVE=1 so
    /// normal/offline test runs skip it. Bootstraps and finds peers for a well-seeded
    /// public-domain torrent (Big Buck Bunny).
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["PATHEM_DHT_LIVE"] != nil,
            "Requires PATHEM_DHT_LIVE=1 and the public mainline DHT"))
    func liveDHTFindsPeers() async {
        let infoHash = Magnet.dataFromHex("dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")!
        let client = DHTClient()
        let peers = await client.findPeers(infoHash: infoHash, maxPeers: 10, timeout: 25)
        print("DHT live: found \(peers.count) peers: \(peers.prefix(5))")
        #expect(!peers.isEmpty)
    }
    #endif
}

@Suite struct NATPMPTests {
    @Test func mapRequestHasCorrectLayout() {
        // TCP map of internal 6881 -> suggested external 6881, 1-hour lease.
        let request = NATPMP.mapRequest(
            internalPort: 6881, suggestedExternalPort: 6881, tcp: true, lifetime: 3600)
        #expect(
            [UInt8](request) == [
                0, 2, 0, 0,  // version 0, opcode 2 (TCP), 2 reserved
                0x1a, 0xe1,  // internal port 6881
                0x1a, 0xe1,  // suggested external port 6881
                0, 0, 0x0e, 0x10,  // lifetime 3600
            ])
        // UDP mapping uses opcode 1.
        #expect(
            [UInt8](NATPMP.mapRequest(internalPort: 1, suggestedExternalPort: 1, tcp: false))[1]
                == 1)
    }

    @Test func parsesMapResponse() {
        // A success response: opcode 2+128, result 0, external port 40000, lifetime 3600.
        let bytes: [UInt8] = [
            0, 130, 0, 0,  // version, opcode 130 (TCP reply), result 0
            0, 0, 0, 1,  // epoch
            0x1a, 0xe1,  // internal port 6881
            0x9c, 0x40,  // external port 40000
            0, 0, 0x0e, 0x10,  // lifetime 3600
        ]
        let result = NATPMP.parseMapResponse(Data(bytes), tcp: true)
        #expect(result?.ok == true)
        #expect(result?.internalPort == 6881)
        #expect(result?.externalPort == 40000)
        #expect(result?.lifetime == 3600)
        // Wrong protocol (asking as UDP) rejects a TCP reply.
        #expect(NATPMP.parseMapResponse(Data(bytes), tcp: false) == nil)
    }

    @Test func parsesExternalAddress() {
        let bytes: [UInt8] = [0, 128, 0, 0, 0, 0, 0, 1, 203, 0, 113, 5]  // 203.0.113.5
        #expect(NATPMP.parseExternalAddress(Data(bytes)) == "203.0.113.5")
        // A non-zero result code yields nil.
        var errorBytes = bytes
        errorBytes[3] = 3
        #expect(NATPMP.parseExternalAddress(Data(errorBytes)) == nil)
    }
}

@Suite struct PEXTests {
    @Test func handshakeAdvertisesAndParsesUtPex() {
        let payload = PEX.handshakePayload()
        // A peer advertising ut_pex=5 in its handshake.
        let peer = Bencode.dict([("m", .dict([("ut_pex", .int(5))]))]).encoded
        #expect(PEX.peerPexID(fromHandshake: peer) == 5)
        // Our own handshake advertises the id we use.
        #expect(PEX.peerPexID(fromHandshake: payload) == UInt8(PEX.utPexID))
    }

    @Test func parsesAddedPeers() {
        // Two peers in the compact `added` field; `dropped`/flags are ignored.
        var added = Data([10, 0, 0, 1, 0x1a, 0xe1])  // 10.0.0.1:6881
        added.append(contentsOf: [192, 168, 0, 5, 0xc8, 0xd5])  // 192.168.0.5:51413
        let message = Bencode.dict([
            ("added", .bytes(added)),
            ("added.f", .bytes(Data([0x00, 0x02]))),
            ("dropped", .bytes(Data([1, 1, 1, 1, 0, 80]))),
        ]).encoded
        let peers = PEX.parseAddedPeers(message)
        #expect(
            peers == [.init(host: "10.0.0.1", port: 6881), .init(host: "192.168.0.5", port: 51413)])
    }

    @Test func toleratesMissingAdded() {
        #expect(PEX.parseAddedPeers(Bencode.dict([("dropped", .bytes(Data()))]).encoded).isEmpty)
        #expect(PEX.parseAddedPeers(Data("garbage".utf8)).isEmpty)
    }

    @Test func sendSideMessageRoundTrips() {
        // A ut_pex message we build must parse back to the same added peers.
        let added: [Tracker.Peer] = [
            .init(host: "10.0.0.1", port: 6881), .init(host: "203.0.113.9", port: 51413),
        ]
        let message = PEX.message(added: added, dropped: [.init(host: "1.2.3.4", port: 80)])
        #expect(PEX.parseAddedPeers(message) == added)
        // The dropped field is present and correctly sized (6 bytes/peer), and flags match added.
        let dict = try? BencodeDecoder.decode(message)
        if case .bytes(let dropped)? = dict?["dropped"] {
            #expect(dropped.count == 6)
        } else {
            Issue.record("no dropped")
        }
        if case .bytes(let flags)? = dict?["added.f"] {
            #expect(flags.count == 2)
        } else {
            Issue.record("no flags")
        }
    }

    @Test func compactSkipsMalformedHosts() {
        // Non-IPv4 hosts are skipped rather than corrupting the stream.
        let data = PEX.compact([
            .init(host: "not.an.ip.addr", port: 1), .init(host: "8.8.8.8", port: 53),
        ])
        #expect(data.count == 6)  // only the valid one
    }
}

@Suite struct SuperSeedTests {
    @Test func offersLeastDistributedPieceThePeerLacks() {
        let complete = [true, true, true, true]  // we have all 4
        let peerHas = [true, false, false, false]  // peer already has piece 0
        // Piece 1 handed out twice, piece 2 once, piece 3 never -> offer piece 3 (least given).
        let given = [1: 2, 2: 1]
        #expect(
            SuperSeed.pick(complete: complete, peerHas: peerHas, offered: [], givenCount: given)
                == 3)
        // Once 3 is offered, the next-least among what's left (piece 2) is chosen.
        #expect(
            SuperSeed.pick(complete: complete, peerHas: peerHas, offered: [3], givenCount: given)
                == 2)
    }

    @Test func returnsNilWhenPeerHasEverythingWeCanOffer() {
        let complete = [true, true]
        // Peer has piece 0; piece 1 is already offered -> nothing left.
        #expect(
            SuperSeed.pick(
                complete: complete, peerHas: [true, false], offered: [1], givenCount: [:]) == nil)
        // We only have piece 0, peer has it -> nothing.
        #expect(
            SuperSeed.pick(
                complete: [true, false], peerHas: [true, false], offered: [], givenCount: [:])
                == nil)
    }
}

#if canImport(Network)
/// The DHT server half: peer store TTL, write-token validation, and the query responder.
@Suite struct DHTServerTests {
    private func id(_ byte: UInt8) -> Data { Data(repeating: byte, count: 20) }
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func peerStoreHoldsAndExpires() {
        var store = DHTPeerStore(ttl: 100, maxPerHash: 200)
        let ih = id(0xAA)
        store.add(infoHash: ih, peer: .init(host: "1.2.3.4", port: 6881), now: base)
        // `peers` prunes as it reads (mutating), so pull results into lets before expecting.
        let atBase = store.peers(infoHash: ih, now: base).count
        let within = store.peers(infoHash: ih, now: base.addingTimeInterval(50)).count
        let expired = store.peers(infoHash: ih, now: base.addingTimeInterval(200)).isEmpty
        #expect(atBase == 1)
        #expect(within == 1)  // within TTL
        #expect(expired)  // past TTL
        // A re-announce refreshes the entry rather than duplicating it.
        store.add(infoHash: ih, peer: .init(host: "1.2.3.4", port: 6881), now: base)
        store.add(
            infoHash: ih, peer: .init(host: "1.2.3.4", port: 6881), now: base.addingTimeInterval(10)
        )
        let deduped = store.peers(infoHash: ih, now: base.addingTimeInterval(10)).count
        #expect(deduped == 1)
    }

    @Test func tokensAreHostBoundAndRotate() {
        var tokens = DHTTokens(now: base, interval: 300)
        let tok = tokens.issue(host: "1.2.3.4", now: base)
        // `validate` rotates the secret (mutating), so evaluate in order into lets.
        let sameSecret = tokens.validate(tok, host: "1.2.3.4", now: base)
        let wrongHost = tokens.validate(tok, host: "9.9.9.9", now: base)
        let oneRotation = tokens.validate(tok, host: "1.2.3.4", now: base.addingTimeInterval(400))
        let twoRotations = tokens.validate(tok, host: "1.2.3.4", now: base.addingTimeInterval(1000))
        #expect(sameSecret)
        #expect(!wrongHost)
        #expect(oneRotation)  // previous secret still accepted across one rotation
        #expect(!twoRotations)  // gone after the secret rotates twice
    }

    @Test func respondsToPingAndRemembersQuerier() async {
        let client = DHTClient()
        let server = DHTServer(client: client, now: base)
        let ping = DHT.parseMessage(DHT.pingQuery(transaction: Data([0, 1]), nodeID: id(0x11)))!
        let reply = await server.respond(to: ping, fromHost: "1.2.3.4", fromPort: 6881, now: base)
        guard let reply, case .response(let r)? = DHT.parseMessage(reply)?.kind else {
            Issue.record("ping did not get a response")
            return
        }
        #expect(r["id"] != nil)
        // The querying node is now in the shared routing table (so serving warms our lookups).
        #expect(await client.routingTableSize == 1)
    }

    @Test func getPeersThenAnnounceRoundTrips() async {
        let client = DHTClient()
        let server = DHTServer(client: client, now: base)
        let qid = id(0x11)
        let ih = id(0xAA)

        // get_peers with nothing stored: a token, no peers yet.
        let gp = DHT.parseMessage(
            DHT.getPeersQuery(transaction: Data([0, 2]), nodeID: qid, infoHash: ih))!
        let gpReply = await server.respond(to: gp, fromHost: "1.2.3.4", fromPort: 6881, now: base)
        guard let gpReply, case .response(let gpr)? = DHT.parseMessage(gpReply)?.kind else {
            Issue.record("no get_peers response")
            return
        }
        let first = DHT.parseGetPeersResponse(gpr)
        #expect(first.token != nil)
        #expect(first.peers.isEmpty)

        // Announce with that token from the same host: accepted (a response, not an error).
        let ann = DHT.parseMessage(
            DHT.announcePeerQuery(
                transaction: Data([0, 3]), nodeID: qid, infoHash: ih, port: 6881,
                token: first.token!))!
        let annReply = await server.respond(to: ann, fromHost: "1.2.3.4", fromPort: 6881, now: base)
        guard let annReply, case .response? = DHT.parseMessage(annReply)?.kind else {
            Issue.record("announce was rejected")
            return
        }

        // Now get_peers (from a different host) returns the announced peer.
        let gp2 = DHT.parseMessage(
            DHT.getPeersQuery(transaction: Data([0, 4]), nodeID: qid, infoHash: ih))!
        let gp2Reply = await server.respond(
            to: gp2, fromHost: "5.6.7.8", fromPort: 12345, now: base)
        guard let gp2Reply, case .response(let gpr2)? = DHT.parseMessage(gp2Reply)?.kind else {
            Issue.record("no second get_peers response")
            return
        }
        let second = DHT.parseGetPeersResponse(gpr2)
        #expect(second.peers.contains { $0.host == "1.2.3.4" && $0.port == 6881 })
    }

    @Test func announceWithBadTokenIsRejected() async {
        let client = DHTClient()
        let server = DHTServer(client: client, now: base)
        let ann = DHT.parseMessage(
            DHT.announcePeerQuery(
                transaction: Data([0, 5]), nodeID: id(0x11), infoHash: id(0xAA), port: 6881,
                token: Data([9, 9, 9, 9])))!
        let reply = await server.respond(to: ann, fromHost: "5.6.7.8", fromPort: 6881, now: base)
        guard let reply, case .error? = DHT.parseMessage(reply)?.kind else {
            Issue.record("a forged token should be rejected")
            return
        }
    }

    @Test func findNodeReturnsNodesField() async {
        let client = DHTClient()
        let server = DHTServer(client: client, now: base)
        let fn = DHT.parseMessage(
            DHT.findNodeQuery(
                transaction: Data([0, 6]), nodeID: id(0x11), target: id(0x22)))!
        let reply = await server.respond(to: fn, fromHost: "1.2.3.4", fromPort: 6881, now: base)
        guard let reply, case .response(let r)? = DHT.parseMessage(reply)?.kind else {
            Issue.record("no find_node response")
            return
        }
        #expect(r["nodes"] != nil)
    }

    @Test func servesQueriesOverRealUDPSocket() async throws {
        // Exercises the socket path the pure tests skip: bind, accept a datagram, parse the
        // remote endpoint, answer it. Loopback only, so no external network is touched.
        let client = DHTClient()
        let server = DHTServer(client: client)
        let port = try await server.start(port: 0)  // ephemeral
        #expect(port != 0)
        let query = DHT.pingQuery(transaction: Data([0xAB, 0xCD]), nodeID: id(0x11))
        let reply = await UDP.query(host: "127.0.0.1", port: port, payload: query, timeout: 3)
        await server.stop()
        guard let reply, let msg = DHT.parseMessage(reply), case .response(let r) = msg.kind else {
            Issue.record("no UDP ping response")
            return
        }
        #expect(msg.transaction == Data([0xAB, 0xCD]))
        #expect(r["id"] != nil)
    }
}
#endif
