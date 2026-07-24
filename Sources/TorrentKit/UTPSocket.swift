import Foundation

/// A uTP connection (BEP 29): reliable, in-order delivery over unreliable datagrams, with sequence
/// numbers, cumulative acks, and timeout retransmission. Transport-agnostic (it's handed a
/// datagram-send closure and fed incoming datagrams), so it can run over UDP or be tested over a
/// lossy in-memory channel. Congestion control is delay-based LEDBAT (RFC 6817): the window grows
/// while the measured one-way queuing delay is under a 100 ms target and shrinks above it (see
/// `grow(bytesAcked:)`), with a multiplicative cut on loss/timeout, so uTP yields to TCP.
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

    // Send-side flow control + LEDBAT congestion control (BEP 29 / RFC 6817). Application bytes are
    // buffered and released into DATA packets only as the window allows; the congestion window grows
    // when the measured one-way queuing delay is below TARGET and shrinks above it, so µTP yields to
    // interactive traffic instead of filling the bottleneck queue the way loss-based TCP does.
    private var sendBuffer = Data()            // app bytes not yet packetized
    private var wantFin = false                // finish() requested; the FIN goes out once buffer drains
    private var finSent = false
    private var bytesInFlight = 0              // unacked DATA payload bytes (what the window caps)
    private var unackedSize: [UInt16: Int] = [:]  // seq -> payload size, to maintain bytesInFlight
    private var sentAt: [UInt16: UInt64] = [:]     // seq -> send time (micros), for RTT sampling
    private var cwnd = 4000                     // congestion window in bytes (~4 packets to start)
    private let minWindow = 1000               // never below one packet (avoids a stalled window)
    private let maxWindow = 2 * 1024 * 1024
    private var peerWindow = 1 << 20           // receiver's advertised window (flow control)
    private let target = 100_000.0             // 100 ms queuing-delay target, in microseconds
    private let gain = 1.0
    private var currentDelays: [UInt32] = []    // recent delay samples, min-filtered to reject noise
    private var baseDelays: [UInt32] = []       // per-epoch minima: the propagation-delay estimate
    private var currentEpochMin: UInt32 = .max
    private var epochStart: UInt64 = 0
    private let epochLength: UInt64 = 60_000_000  // rotate the base-delay estimate every 60 s
    private var theirDelay: UInt32 = 0          // delay we last measured for their packets (we echo it)
    private var rttMicros = 0.0
    private var lastLossReduce: UInt64 = 0

    /// The current congestion window and in-flight bytes (exposed for status and tests).
    public var congestionWindow: Int { cwnd }
    public var bytesInFlightNow: Int { bytesInFlight }

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
        let syn = UTPPacket(
            type: .syn, connectionID: connIdRecv, timestampMicros: Self.nowMicros32(), seqNr: seqNr, ackNr: ackNr)
        unacked[seqNr] = syn.encoded
        sentAt[seqNr] = Self.nowMicros64()
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

    /// Reliably send application data. The bytes are buffered and released into DATA packets only as
    /// the congestion window allows (see pumpSends).
    public func write(_ data: Data) async {
        sendBuffer.append(data)
        await pumpSends()
    }

    /// Signal we're done writing. The FIN is sent after every buffered byte has gone out, so it keeps
    /// its place at the end of the sequence even when the window throttled the data ahead of it.
    public func finish() async {
        wantFin = true
        await pumpSends()
    }

    /// Release buffered bytes into DATA packets, capped at the smaller of our congestion window and
    /// the peer's advertised receive window; then emit the FIN once the buffer is empty. Called after
    /// write/finish and again whenever an incoming ack frees window space.
    private func pumpSends() async {
        guard state != .closed else { return }
        let window = min(cwnd, max(peerWindow, minWindow))
        while !sendBuffer.isEmpty {
            let size = min(maxPayload, sendBuffer.count)
            // Cap in-flight bytes at the window, but always allow one packet so a window smaller than
            // a full packet can't deadlock the connection.
            if bytesInFlight > 0, bytesInFlight + size > window { break }
            let chunk = Data(sendBuffer.prefix(size))
            sendBuffer.removeFirst(size)
            await sendData(chunk)
        }
        if sendBuffer.isEmpty, wantFin, !finSent {
            finSent = true
            await sendFin()
        }
    }

    private func sendData(_ payload: Data) async {
        let packet = UTPPacket(
            type: .data, connectionID: connIdSend, timestampMicros: Self.nowMicros32(),
            timestampDiffMicros: theirDelay, windowSize: 1 << 20, seqNr: seqNr, ackNr: ackNr,
            payload: payload)
        unacked[seqNr] = packet.encoded
        unackedSize[seqNr] = payload.count
        sentAt[seqNr] = Self.nowMicros64()
        bytesInFlight += payload.count
        seqNr &+= 1
        await sendDatagram(packet.encoded)
    }

    private func sendFin() async {
        let fin = UTPPacket(
            type: .fin, connectionID: connIdSend, timestampMicros: Self.nowMicros32(),
            timestampDiffMicros: theirDelay, windowSize: 1 << 20, seqNr: seqNr, ackNr: ackNr)
        unacked[seqNr] = fin.encoded
        sentAt[seqNr] = Self.nowMicros64()
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
        // Cancellation-aware: recv() races this against a timeout and cancels the loser. Without a
        // cancellation handler the parked continuation would never resume, and the throwing task
        // group would hang waiting for this child, so the timeout could never actually fire.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if consumed < delivered.count || state == .closed || finReceived {
                    cont.resume(returning: take())
                } else {
                    reader = cont
                }
            }
        } onCancel: {
            Task { await self.cancelRead() }
        }
    }

    /// Resume a parked reader with whatever is buffered (empty on none), so a cancelled
    /// readAvailable completes promptly. Guarded by niling `reader` first (the actor serializes
    /// this with wakeReader, so the continuation is never resumed twice).
    private func cancelRead() {
        guard let r = reader else { return }
        reader = nil
        r.resume(returning: take())
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
        // Delay bookkeeping (RFC 6817): remember how long THIS packet took (echoed back to the
        // sender), and feed the delay THEY measured for our packets into the congestion controller.
        theirDelay = Self.nowMicros32() &- packet.timestampMicros
        if packet.timestampDiffMicros != 0 { recordDelay(packet.timestampDiffMicros) }
        if packet.windowSize > 0 { peerWindow = Int(packet.windowSize) }  // honor their flow-control window
        // Any packet acks everything up to and including its ack_nr; a fresh ack grows the window.
        let ackedBytes = acknowledge(upTo: packet.ackNr)
        if ackedBytes > 0 { grow(bytesAcked: ackedBytes) }

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
        await pumpSends()  // a freed window may let more buffered bytes go out
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
        let ack = UTPPacket(
            type: .state, connectionID: connIdSend, timestampMicros: Self.nowMicros32(),
            timestampDiffMicros: theirDelay, windowSize: 1 << 20, seqNr: seqNr, ackNr: ackNr)
        await sendDatagram(ack.encoded)
    }

    /// Drop every unacked sequence at or before `ack` (wrap-around order: ack - seq < 2^15) and
    /// return how many DATA payload bytes those newly-acked packets carried, updating in-flight and
    /// the RTT estimate. The byte count drives the LEDBAT window growth.
    @discardableResult
    private func acknowledge(upTo ack: UInt16) -> Int {
        var ackedBytes = 0
        let now = Self.nowMicros64()
        // Snapshot the keys so we're not mutating the dictionary we're iterating.
        for seq in Array(unacked.keys) where (ack &- seq) < 0x8000 {
            unacked[seq] = nil
            if let size = unackedSize.removeValue(forKey: seq) {
                ackedBytes += size
                bytesInFlight -= size
            }
            if let sent = sentAt.removeValue(forKey: seq) { updateRTT(Double(now &- sent)) }
        }
        if bytesInFlight < 0 { bytesInFlight = 0 }
        return ackedBytes
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
        // Outstanding packets past the retransmit timer signal loss: back the window off
        // multiplicatively (TCP-style), but at most once per interval so a burst isn't over-punished.
        let now = Self.nowMicros64()
        if now &- lastLossReduce > 200_000 {
            cwnd = max(minWindow, cwnd / 2)
            lastLossReduce = now
        }
        for packet in unacked.values { await sendDatagram(packet) }
    }

    // MARK: LEDBAT congestion control (RFC 6817)

    /// Fold one one-way-delay sample into the base (propagation) estimate and the short current-delay
    /// filter. The base is the minimum over a rolling set of per-minute minima, so it tracks the true
    /// propagation delay while shedding a stale minimum after the route changes.
    func recordDelay(_ delay: UInt32) {
        let now = Self.nowMicros64()
        if epochStart == 0 {
            epochStart = now
            currentEpochMin = delay
        } else if now &- epochStart >= epochLength {
            baseDelays.append(currentEpochMin)
            if baseDelays.count > 13 { baseDelays.removeFirst() }
            currentEpochMin = delay
            epochStart = now
        } else {
            currentEpochMin = min(currentEpochMin, delay)
        }
        currentDelays.append(delay)
        if currentDelays.count > 3 { currentDelays.removeFirst() }  // min-filter over the last few
    }

    private func baseDelay() -> UInt32 { (baseDelays + [currentEpochMin]).min() ?? currentEpochMin }

    /// Adjust the congestion window for `bytesAcked` newly acknowledged bytes the LEDBAT way: the
    /// window drifts toward holding the queuing delay at TARGET. Below target it grows; above it
    /// shrinks; the step is proportional to how far off target we are and how much was acked.
    func grow(bytesAcked: Int) {
        guard bytesAcked > 0 else { return }
        let current = currentDelays.min() ?? 0
        let base = baseDelay()
        let queuing = current > base ? Double(current &- base) : 0
        let offTarget = (target - queuing) / target  // 1 at zero delay, negative once past target
        let step = gain * offTarget * Double(bytesAcked) * Double(maxPayload) / Double(max(1, cwnd))
        cwnd = min(maxWindow, max(minWindow, cwnd + Int(step)))
    }

    private func updateRTT(_ sample: Double) {
        rttMicros = rttMicros == 0 ? sample : rttMicros * 0.875 + sample * 0.125
    }

    private static func nowMicros64() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }
    private static func nowMicros32() -> UInt32 { UInt32(truncatingIfNeeded: nowMicros64()) }
}
