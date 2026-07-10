import Foundation
import Testing

#if canImport(Network)
    import Network
#endif

@testable import TorrentKit

@Suite struct UTPPacketTests {
    @Test func headerRoundTrips() {
        let packet = UTPPacket(
            type: .data, connectionID: 0x1234, timestampMicros: 111, timestampDiffMicros: 222,
            windowSize: 1 << 20, seqNr: 7, ackNr: 6, payload: Data([1, 2, 3, 4]))
        let decoded = UTPPacket.decode(packet.encoded)
        #expect(decoded == packet)
    }

    @Test func encodesTypeAndVersion() {
        let syn = UTPPacket(type: .syn, connectionID: 1, seqNr: 1, ackNr: 0)
        let bytes = [UInt8](syn.encoded)
        #expect(bytes[0] == (4 << 4 | 1))  // ST_SYN, version 1
        #expect(bytes.count == UTPPacket.headerLength)
    }

    @Test func rejectsMalformed() {
        #expect(UTPPacket.decode(Data([0x11, 0x00])) == nil)  // too short
        #expect(UTPPacket.decode(Data(repeating: 0, count: 20)) == nil)  // version 0
    }

    @Test func skipsExtensions() {
        // A packet with a selective-ack extension (type 1, len 4) before the payload.
        var data = UTPPacket(type: .state, connectionID: 1, seqNr: 1, ackNr: 1).encoded
        data[1] = 1  // first extension = selective ack
        data.append(contentsOf: [0, 4, 0, 0, 0, 0])  // next-ext=0, len=4, 4 bytes
        data.append(contentsOf: [0xAA, 0xBB])  // payload
        let decoded = UTPPacket.decode(data)
        #expect(decoded?.payload == Data([0xAA, 0xBB]))
    }
}

/// A bidirectional datagram channel that can drop and reorder, to stress the reliability logic.
private actor LossyChannel {
    private var aHandler: (@Sendable (Data) async -> Void)?
    private var bHandler: (@Sendable (Data) async -> Void)?
    private var counter = 0
    private let dropEvery: Int  // drop 1 in N datagrams (0 = never)

    init(dropEvery: Int) { self.dropEvery = dropEvery }

    func setHandlers(a: @escaping @Sendable (Data) async -> Void, b: @escaping @Sendable (Data) async -> Void) {
        aHandler = a
        bHandler = b
    }

    // A sends -> B receives.
    func aToB(_ data: Data) async {
        counter += 1
        if dropEvery > 0 && counter % dropEvery == 0 { return }  // drop it; retransmission recovers
        await bHandler?(data)
    }

    func bToA(_ data: Data) async {
        counter += 1
        if dropEvery > 0 && counter % dropEvery == 0 { return }
        await aHandler?(data)
    }
}

@Suite struct UTPSocketTests {
    private func transfer(dropEvery: Int) async -> (Data, Bool) {
        let channel = LossyChannel(dropEvery: dropEvery)
        let initiator = UTPSocket(role: .initiator, connectionID: 0x4242, sendDatagram: { await channel.aToB($0) })
        let responder = UTPSocket(role: .responder, connectionID: 0x4242, sendDatagram: { await channel.bToA($0) })
        await channel.setHandlers(
            a: { await initiator.handle($0) }, b: { await responder.handle($0) })

        await initiator.connect()
        let payload = Data((0..<8000).map { UInt8(($0 &* 17 &+ 3) & 0xff) })  // 8 KB -> multiple packets
        await initiator.write(payload)
        await initiator.finish()

        // Wait (bounded) for the responder to receive everything, letting retransmission run.
        var finished = false
        for _ in 0..<200 {
            if await responder.isFinished { finished = true; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let got = await responder.received()
        await initiator.close()
        await responder.close()
        return (got, finished)
    }

    @Test func reliableTransferNoLoss() async {
        let payload = Data((0..<8000).map { UInt8(($0 &* 17 &+ 3) & 0xff) })
        let (got, finished) = await transfer(dropEvery: 0)
        #expect(got == payload)  // in-order, complete
        #expect(finished)        // FIN received -> connection marked finished
    }

    @Test func recoversFromPacketLoss() async {
        // Drop 1 in 4 datagrams; retransmission + reordering must still deliver every byte in order
        // AND mark the connection finished (a reordered FIN must not lose its FIN semantics).
        let payload = Data((0..<8000).map { UInt8(($0 &* 17 &+ 3) & 0xff) })
        let (got, finished) = await transfer(dropEvery: 4)
        #expect(got == payload)
        #expect(finished)
    }

    @Test func congestionWindowGrowsBelowTargetShrinksAbove() async {
        // The LEDBAT rule: below the queuing-delay target the window grows; sustained delay above it
        // shrinks the window. Drive the controller directly with delay samples and acks.
        let socket = UTPSocket(role: .initiator, connectionID: 1, sendDatagram: { _ in })
        let start = await socket.congestionWindow
        for _ in 0..<3 { await socket.recordDelay(1000) }   // base 1000, current 1000 -> queuing ~0
        await socket.grow(bytesAcked: 1000)
        let grown = await socket.congestionWindow
        for _ in 0..<3 { await socket.recordDelay(1_000_000) }  // base stays 1000, current ~1s -> way over target
        await socket.grow(bytesAcked: 1000)
        let shrunk = await socket.congestionWindow
        #expect(grown > start)
        #expect(shrunk < grown)
    }

    @Test func congestionWindowOpensOverACleanTransfer() async {
        // A real (lossless, low-delay) transfer should deliver every byte through the window AND end
        // with the window wider than it started and nothing left in flight.
        let channel = LossyChannel(dropEvery: 0)
        let initiator = UTPSocket(role: .initiator, connectionID: 0x99, sendDatagram: { await channel.aToB($0) })
        let responder = UTPSocket(role: .responder, connectionID: 0x99, sendDatagram: { await channel.bToA($0) })
        await channel.setHandlers(a: { await initiator.handle($0) }, b: { await responder.handle($0) })

        let before = await initiator.congestionWindow
        await initiator.connect()
        let payload = Data((0..<16000).map { UInt8(($0 &* 5 &+ 2) & 0xff) })  // ~16 packets -> ~16 acks
        await initiator.write(payload)
        await initiator.finish()

        let got = await responder.received()
        let after = await initiator.congestionWindow
        let inflight = await initiator.bytesInFlightNow
        await initiator.close()
        await responder.close()

        #expect(got == payload)   // windowed sending still delivers everything in order
        #expect(after > before)   // low delay -> the window opened up
        #expect(inflight == 0)    // every DATA packet was acknowledged
    }

    @Test func streamingReadDeliversBytesThenEOF() async {
        // The streaming reader PeerConnection drives: readAvailable() yields in-order bytes and then
        // signals end-of-stream (empty) once the FIN is in and everything is drained.
        let channel = LossyChannel(dropEvery: 0)
        let initiator = UTPSocket(role: .initiator, connectionID: 0x55, sendDatagram: { await channel.aToB($0) })
        let responder = UTPSocket(role: .responder, connectionID: 0x55, sendDatagram: { await channel.bToA($0) })
        await channel.setHandlers(a: { await initiator.handle($0) }, b: { await responder.handle($0) })

        await initiator.connect()
        let payload = Data((0..<3000).map { UInt8(($0 &* 7 &+ 1) & 0xff) })
        await initiator.write(payload)
        await initiator.finish()  // over a lossless channel, everything is delivered synchronously

        let chunk = await responder.readAvailable()   // all in-order bytes so far
        let eof = await responder.readAvailable()      // FIN observed + drained -> EOF
        #expect(chunk == payload)
        #expect(eof.isEmpty)
    }
}

#if canImport(Network)
    /// A tiny UDP server that runs one responder-side uTP socket and echoes back whatever it
    /// receives, so a real UTPTransport (initiator) can be driven over an actual socket.
    private actor UTPEchoServer {
        private var listener: NWListener?
        private var responder: UTPSocket?
        nonisolated let queue = DispatchQueue(label: "com.pathem.test.utpecho", attributes: .concurrent)

        func start() async throws -> UInt16 {
            let listener = try NWListener(using: .udp, on: .any)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                conn.stateUpdateHandler = { state in
                    if case .ready = state { self.armReceive(conn) }
                }
                conn.start(queue: self.queue)
            }
            let port: UInt16 = try await withCheckedThrowingContinuation { cont in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: cont.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let e): cont.resume(throwing: e)
                    default: break
                    }
                }
                listener.start(queue: self.queue)
            }
            return port
        }

        func stop() { listener?.cancel(); listener = nil }

        private nonisolated func armReceive(_ conn: NWConnection) {
            conn.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if let data, !data.isEmpty { Task { await self.onDatagram(data, from: conn) } }
                if error == nil { self.armReceive(conn) }
            }
        }

        private func onDatagram(_ data: Data, from conn: NWConnection) async {
            if responder == nil, let packet = UTPPacket.decode(data) {
                let socket = UTPSocket(role: .responder, connectionID: packet.connectionID, sendDatagram: { out in
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        conn.send(content: out, completion: .contentProcessed { _ in c.resume() })
                    }
                })
                responder = socket
                Task {  // echo loop: whatever the initiator sends, send straight back
                    while true {
                        let chunk = await socket.readAvailable()
                        if chunk.isEmpty { break }
                        await socket.write(chunk)
                    }
                }
            }
            await responder?.handle(data)
        }
    }

    @Suite struct UTPTransportTests {
        @Test func handshakesAndStreamsOverRealUDP() async throws {
            let server = UTPEchoServer()
            let port = try await server.start()
            #expect(port != 0)

            let transport = UTPTransport(host: "127.0.0.1", port: port)
            try await transport.start(timeout: 5)   // completes the uTP SYN/ACK over the socket
            try await transport.send(Data("hello µTP".utf8))
            let echoed = try await transport.recv(timeout: 5)
            await transport.close()
            await server.stop()

            #expect(echoed == Data("hello µTP".utf8))
        }
    }
#endif

#if canImport(Network)
    /// Captures the info hash the mux routes, bridging the onPeer callback to the test.
    private actor AcceptedBox {
        private var hex: String?
        private var cont: CheckedContinuation<String, Never>?
        func set(_ value: String) {
            if let cont { cont.resume(returning: value); self.cont = nil } else { hex = value }
        }
        func get() async -> String {
            if let hex { return hex }
            return await withCheckedContinuation { cont = $0 }
        }
    }

    @Suite struct UDPMuxTests {
        @Test func classifiesUTPVersusKRPC() {
            let syn = UTPPacket(type: .syn, connectionID: 1, seqNr: 1, ackNr: 0).encoded
            let krpc = DHT.pingQuery(transaction: Data([0, 1]), nodeID: Data(repeating: 0x11, count: 20))
            #expect(UDPMux.isUTP(syn))          // a real µTP packet
            #expect(!UDPMux.isUTP(krpc))        // bencode 'd...' isn't a valid µTP packet
            #expect(!UDPMux.isUTP(Data()))      // empty
            #expect(!UDPMux.isUTP(Data([0x64, 0x65])))  // 'de' (empty dict) -> DHT, not µTP
        }

        @Test func acceptsInboundUTPPeerAndCompletesHandshake() async throws {
            let infoHash = Data(repeating: 0xB1, count: 20)
            let serverPeerID = Tracker.makePeerID()
            let clientPeerID = Tracker.makePeerID()
            let accepted = AcceptedBox()

            let mux = UDPMux(dht: DHTServer(client: DHTClient()), peerID: serverPeerID) { hex, peer in
                try? await peer.replyHandshake()  // answer so the initiator's connect() can finish
                await accepted.set(hex)
            }
            let port = try await mux.start(port: 0)

            // Dial the mux over µTP; connect() runs the µTP handshake AND the BitTorrent handshake.
            let client = PeerConnection(host: "127.0.0.1", port: port, infoHash: infoHash, peerID: clientPeerID)
            try await client.connect(timeout: 5, transport: .utp)

            let routedHex = await accepted.get()
            let serverID = await client.remotePeerID
            await client.close()
            await mux.stop()

            #expect(routedHex == infoHash.map { String(format: "%02x", $0) }.joined())
            #expect(serverID == serverPeerID)  // the mux's peer replied with its id over µTP
        }
    }
#endif
