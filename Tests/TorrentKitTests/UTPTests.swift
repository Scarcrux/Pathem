import Foundation
import Testing

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
}
