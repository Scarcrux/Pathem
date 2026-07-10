import Foundation

/// A uTP connection (BEP 29): reliable, in-order delivery over unreliable datagrams, with sequence
/// numbers, cumulative acks, and timeout retransmission. Transport-agnostic (it's handed a
/// datagram-send closure and fed incoming datagrams), so it can run over UDP or be tested over a
/// lossy in-memory channel. Congestion control is a simple fixed window; full LEDBAT delay-based
/// control is a further refinement.
public actor UTPSocket {
    public enum Role: Sendable { case initiator, responder }
    public enum State: Sendable { case connecting, connected, closed }

    private let sendDatagram: @Sendable (Data) async -> Void
    private let connIdSend: UInt16
    private let connIdRecv: UInt16

    private(set) var state: State = .connecting
    private var seqNr: UInt16                 // next sequence number to send
    private var ackNr: UInt16                 // last in-order sequence we've received
    private var unacked: [UInt16: Data] = [:]  // seq -> encoded packet, awaiting ack
    private var reorderBuffer: [UInt16: (payload: Data, isFin: Bool)] = [:]  // future seq -> data
    private let maxReorder = 2048  // cap buffered future packets (bounds memory under a stalling peer)
    private var delivered = Data()             // in-order payload delivered to the app
    private var consumed = 0                    // how much of `delivered` a streaming reader took
    private var reader: CheckedContinuation<Data, Never>?  // a recv() awaiting more bytes
    private var finReceived = false
    private var retransmitTask: Task<Void, Never>?

    private let maxPayload = 1000

    public init(role: Role, connectionID: UInt16, sendDatagram: @escaping @Sendable (Data) async -> Void) {
        self.sendDatagram = sendDatagram
        // uTP convention: the initiator uses id for recv and id+1 for send; the responder swaps.
        switch role {
        case .initiator:
            connIdRecv = connectionID
            connIdSend = connectionID &+ 1
        case .responder:
            connIdRecv = connectionID &+ 1
            connIdSend = connectionID
        }
        seqNr = 1
        ackNr = 0
    }

    /// Initiator: send SYN and start retransmission. (For the responder, the SYN is handled in
    /// `handle`.) Returns once the connection is set up locally.
    public func connect() async {
        let syn = UTPPacket(type: .syn, connectionID: connIdRecv, seqNr: seqNr, ackNr: ackNr)
        unacked[seqNr] = syn.encoded
        seqNr &+= 1
        await sendDatagram(syn.encoded)
        startRetransmit()
    }

    /// Mark the responder connected (it received a SYN out of band) and start retransmission.
    public func accept(synSeq: UInt16) async {
        ackNr = synSeq
        state = .connected
        seqNr = 1
        startRetransmit()
        await sendState()  // ack the SYN
    }

    /// Reliably send application data, split into uTP DATA packets.
    public func write(_ data: Data) async {
        var offset = 0
        while offset < data.count {
            let end = min(offset + maxPayload, data.count)
            let packet = UTPPacket(
                type: .data, connectionID: connIdSend, windowSize: 1 << 20, seqNr: seqNr, ackNr: ackNr,
                payload: data.subdata(in: offset..<end))
            unacked[seqNr] = packet.encoded
            seqNr &+= 1
            await sendDatagram(packet.encoded)
            offset = end
        }
    }

    /// Send a FIN to signal we're done writing.
    public func finish() async {
        let fin = UTPPacket(type: .fin, connectionID: connIdSend, seqNr: seqNr, ackNr: ackNr)
        unacked[seqNr] = fin.encoded
        seqNr &+= 1
        await sendDatagram(fin.encoded)
    }

    /// All in-order bytes delivered so far.
    public func received() -> Data { delivered }
    public var isFinished: Bool { finReceived && unacked.isEmpty }
    public var isConnected: Bool { state == .connected }

    /// Streaming read: return in-order bytes not yet handed out, suspending until some arrive.
    /// Returns empty only at end of stream (the peer sent FIN, or the socket closed), which the
    /// transport translates into a normal connection close. Feeds PeerConnection's chunk reader.
    public func readAvailable() async -> Data {
        if consumed < delivered.count { return take() }
        if state == .closed || finReceived { return Data() }  // EOF
        return await withCheckedContinuation { cont in
            if consumed < delivered.count || state == .closed || finReceived {
                cont.resume(returning: take())
            } else {
                reader = cont
            }
        }
    }

    private func take() -> Data {
        guard consumed < delivered.count else { return Data() }
        let out = delivered.subdata(in: consumed..<delivered.count)
        consumed = delivered.count
        return out
    }

    private func wakeReader() {
        guard let r = reader, consumed < delivered.count || state == .closed || finReceived else { return }
        reader = nil
        r.resume(returning: take())
    }

    public func close() {
        state = .closed
        retransmitTask?.cancel()
        retransmitTask = nil
        wakeReader()  // let a suspended reader observe EOF instead of hanging
    }

    // MARK: incoming

    /// Feed one incoming datagram (from the UDP socket or the test channel).
    public func handle(_ datagram: Data) async {
        guard let packet = UTPPacket.decode(datagram) else { return }
        // Any packet acks everything up to and including its ack_nr.
        acknowledge(upTo: packet.ackNr)

        switch packet.type {
        case .syn:
            // Responder path: adopt the sender's sequence and ack it.
            if state == .connecting {
                ackNr = packet.seqNr
                state = .connected
                drainReorderBuffer()  // in case data arrived before the SYN
                if retransmitTask == nil { startRetransmit() }
            }
            await sendState()
        case .state:
            state = .connected  // an ack; nothing to deliver
        case .data:
            await ingest(seq: packet.seqNr, payload: packet.payload)
        case .fin:
            await ingest(seq: packet.seqNr, payload: Data(), isFin: true)
        case .reset:
            close()
        }
    }

    private func ingest(seq: UInt16, payload: Data, isFin: Bool = false) async {
        let expected = ackNr &+ 1
        if seq == expected {
            if !payload.isEmpty { delivered.append(payload) }
            if isFin { finReceived = true }
            ackNr = seq
            drainReorderBuffer()
        } else if seq &- expected < 0x8000, reorderBuffer.count < maxReorder {  // a future packet: buffer it
            reorderBuffer[seq] = (payload, isFin)  // keep the FIN flag, or a reordered FIN is lost
        }
        wakeReader()       // hand any newly in-order bytes (or EOF) to a waiting reader
        await sendState()  // always ack current progress
    }

    /// Deliver any buffered packets that are now the next in order.
    private func drainReorderBuffer() {
        while let next = reorderBuffer[ackNr &+ 1] {
            reorderBuffer[ackNr &+ 1] = nil
            if !next.payload.isEmpty { delivered.append(next.payload) }
            if next.isFin { finReceived = true }
            ackNr &+= 1
        }
    }

    private func sendState() async {
        let ack = UTPPacket(type: .state, connectionID: connIdSend, windowSize: 1 << 20, seqNr: seqNr, ackNr: ackNr)
        await sendDatagram(ack.encoded)
    }

    private func acknowledge(upTo ack: UInt16) {
        // Drop every unacked sequence at or before `ack` in wrap-around order (ack - seq < 2^15).
        // Snapshot the keys so we're not mutating the dictionary we're iterating.
        for seq in Array(unacked.keys) where (ack &- seq) < 0x8000 { unacked[seq] = nil }
    }

    private func startRetransmit() {
        retransmitTask?.cancel()
        retransmitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                await self.resendUnacked()
            }
        }
    }

    private func resendUnacked() async {
        guard state != .closed, !unacked.isEmpty else { return }
        for packet in unacked.values { await sendDatagram(packet) }
    }
}
