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
            if case .bytes(let d)? = args["id"] { #expect(d == nodeID) } else { Issue.record("no id") }
        } else {
            Issue.record("ping did not parse as a query")
        }
        #expect(ping?.transaction == txn)

        let getPeers = DHT.parseMessage(DHT.getPeersQuery(transaction: txn, nodeID: nodeID, infoHash: infoHash))
        if case .query(let method, let args)? = getPeers?.kind {
            #expect(method == "get_peers")
            if case .bytes(let h)? = args["info_hash"] { #expect(h == infoHash) } else { Issue.record("no info_hash") }
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
        guard case .response(let r)? = parsed?.kind else { Issue.record("not a response"); return }
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
            Issue.record("not a response"); return
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
            Issue.record("not an error"); return
        }
        #expect(code == 201)
        #expect(text == "A Generic Error")
    }

    #if canImport(Network)
        /// A live end-to-end DHT lookup against the real network, opt-in via PATHEM_DHT_LIVE=1 so
        /// normal/offline test runs skip it. Bootstraps and finds peers for a well-seeded
        /// public-domain torrent (Big Buck Bunny).
        @Test func liveDHTFindsPeers() async {
            guard ProcessInfo.processInfo.environment["PATHEM_DHT_LIVE"] != nil else { return }
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
        let request = NATPMP.mapRequest(internalPort: 6881, suggestedExternalPort: 6881, tcp: true, lifetime: 3600)
        #expect([UInt8](request) == [
            0, 2, 0, 0,  // version 0, opcode 2 (TCP), 2 reserved
            0x1a, 0xe1,  // internal port 6881
            0x1a, 0xe1,  // suggested external port 6881
            0, 0, 0x0e, 0x10,  // lifetime 3600
        ])
        // UDP mapping uses opcode 1.
        #expect([UInt8](NATPMP.mapRequest(internalPort: 1, suggestedExternalPort: 1, tcp: false))[1] == 1)
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
        #expect(peers == [.init(host: "10.0.0.1", port: 6881), .init(host: "192.168.0.5", port: 51413)])
    }

    @Test func toleratesMissingAdded() {
        #expect(PEX.parseAddedPeers(Bencode.dict([("dropped", .bytes(Data()))]).encoded).isEmpty)
        #expect(PEX.parseAddedPeers(Data("garbage".utf8)).isEmpty)
    }
}
