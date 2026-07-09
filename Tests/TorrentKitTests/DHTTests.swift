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
