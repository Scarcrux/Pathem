import CryptoKit
import Foundation

/// The MSE/PE obfuscated handshake (the "vuze" encryption). Runs the Diffie-Hellman exchange, the
/// hash-sync + crypto negotiation, and returns the RC4 ciphers for the rest of the connection.
/// Written against an abstract duplex byte stream so it can be verified initiator-vs-responder over
/// an in-memory pipe (see the tests) as well as driven over a real socket.
public enum MSEHandshake {
    public enum Method: Equatable, Sendable { case plaintext, rc4 }

    public struct Result: Sendable {
        public var send: RC4       // cipher for our outgoing bytes
        public var recv: RC4       // cipher for the peer's incoming bytes
        public var method: Method
        public var initialData: Data  // any payload the peer sent inside the handshake (IA)
    }

    public enum HandshakeError: Error { case syncFailed, verificationFailed, unknownTorrent, closed }

    private static let verificationConstant = Data(count: 8)  // VC: 8 zero bytes
    private static let cryptoRC4: UInt32 = 0x02
    private static let cryptoPlaintext: UInt32 = 0x01

    /// A buffered reader/writer over async raw byte primitives.
    public actor Stream {
        let sink: @Sendable (Data) async throws -> Void
        let source: @Sendable () async throws -> Data  // next chunk (>=1 byte), throws on EOF
        private var buffer = Data()

        public init(
            send: @escaping @Sendable (Data) async throws -> Void,
            recv: @escaping @Sendable () async throws -> Data
        ) {
            self.sink = send
            self.source = recv
        }

        func write(_ data: Data) async throws { try await sink(data) }

        func readExact(_ count: Int) async throws -> Data {
            while buffer.count < count { buffer.append(try await source()) }
            let out = buffer.prefix(count)
            buffer.removeFirst(count)
            return Data(out)
        }

        /// Any bytes read past the handshake, to hand back to the connection's normal reader.
        func drainBuffer() -> Data {
            let out = buffer
            buffer = Data()
            return out
        }

        /// Read and discard bytes until `pattern` appears; return the bytes AFTER the pattern that
        /// were already buffered (usually none). Fails after scanning `maxExtra` bytes.
        func syncTo(_ pattern: Data, maxExtra: Int) async throws {
            while true {
                if let range = buffer.range(of: pattern) {
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    return
                }
                if buffer.count > maxExtra + pattern.count { throw HandshakeError.syncFailed }
                buffer.append(try await source())
            }
        }
    }

    /// Initiator (outgoing connection). Runs the handshake for a known info hash. `initialPayload`
    /// (IA) is sent encrypted inside the handshake, or empty to send it afterwards.
    public static func initiate(infoHash: Data, initialPayload: Data = Data(), over stream: Stream) async throws -> Result {
        let keys = MSE.generateKeyPair()
        try await stream.write(keys.publicKeyBytes + randomPad())

        let yb = try await stream.readExact(MSE.keyLength)
        let secret = MSE.sharedSecret(ourPrivate: keys.priv, peerPublic: yb)
        var send = rc4(label: "keyA", secret: secret, infoHash: infoHash)  // initiator encrypts with keyA
        var recv = rc4(label: "keyB", secret: secret, infoHash: infoHash)

        // Step 3: req1 + (req2 xor req3) + ENCRYPT(VC, provide, len(padC)=0, len(IA), IA).
        let req1 = sha1("req1", secret)
        let req23 = xor(sha1("req2", infoHash), sha1("req3", secret))
        var plaintext = verificationConstant
        plaintext.append(be32(cryptoRC4))
        plaintext.append(be16(0))                        // len(padC)
        plaintext.append(be16(UInt16(initialPayload.count)))
        plaintext.append(initialPayload)
        try await stream.write(req1 + req23 + send.process(plaintext))

        // Step 4: sync on ENCRYPT(VC), then read crypto_select + padD.
        var vcProbe = seededRC4(label: "keyB", secret: secret, infoHash: infoHash)
        let expectedVC = vcProbe.process(verificationConstant)
        try await stream.syncTo(expectedVC, maxExtra: 640)
        _ = recv.process(verificationConstant)           // advance our recv cipher past the VC
        let select = be32(from: recv.process(try await stream.readExact(4)))
        let padDLen = be16(from: recv.process(try await stream.readExact(2)))
        if padDLen > 0 { _ = recv.process(try await stream.readExact(Int(padDLen))) }

        return Result(send: send, recv: recv, method: select == cryptoRC4 ? .rc4 : .plaintext, initialData: Data())
    }

    /// Responder (incoming connection). `torrentFor` maps a recovered req2 hash to the info hash of
    /// a torrent we host, or nil if we don't have it.
    public static func respond(
        torrentFor: @Sendable (_ req2Hash: Data) -> Data?, over stream: Stream
    ) async throws -> (infoHash: Data, result: Result) {
        let ya = try await stream.readExact(MSE.keyLength)
        let keys = MSE.generateKeyPair()
        try await stream.write(keys.publicKeyBytes + randomPad())
        let secret = MSE.sharedSecret(ourPrivate: keys.priv, peerPublic: ya)

        // Sync on req1 (sent plain), then recover the torrent from (req2 xor req3).
        try await stream.syncTo(sha1("req1", secret), maxExtra: 640)
        let req23 = try await stream.readExact(20)
        let req2 = xor(req23, sha1("req3", secret))
        guard let infoHash = torrentFor(req2) else { throw HandshakeError.unknownTorrent }

        var recv = rc4(label: "keyA", secret: secret, infoHash: infoHash)  // peer (initiator) used keyA
        var send = rc4(label: "keyB", secret: secret, infoHash: infoHash)

        // Decrypt the initiator's crypto payload.
        guard recv.process(try await stream.readExact(8)) == verificationConstant else {
            throw HandshakeError.verificationFailed
        }
        let provide = be32(from: recv.process(try await stream.readExact(4)))
        let padCLen = be16(from: recv.process(try await stream.readExact(2)))
        if padCLen > 0 { _ = recv.process(try await stream.readExact(Int(padCLen))) }
        let iaLen = be16(from: recv.process(try await stream.readExact(2)))
        let ia = iaLen > 0 ? recv.process(try await stream.readExact(Int(iaLen))) : Data()

        // Choose RC4 if offered, else plaintext, and send our reply: ENCRYPT(VC, select, len(padD)=0).
        let method: Method = (provide & cryptoRC4) != 0 ? .rc4 : .plaintext
        let select = method == .rc4 ? cryptoRC4 : cryptoPlaintext
        var reply = verificationConstant
        reply.append(be32(select))
        reply.append(be16(0))
        try await stream.write(send.process(reply))

        return (infoHash, Result(send: send, recv: recv, method: method, initialData: ia))
    }

    // MARK: helpers

    private static func rc4(label: String, secret: Data, infoHash: Data) -> RC4 {
        seededRC4(label: label, secret: secret, infoHash: infoHash)
    }

    /// A fresh RC4 keyed by HASH(label, S, SKEY) with the mandatory 1024-byte keystream discard.
    private static func seededRC4(label: String, secret: Data, infoHash: Data) -> RC4 {
        var cipher = RC4(key: MSE.rc4Key(label: label, secret: secret, infoHash: infoHash))
        cipher.discard(1024)
        return cipher
    }

    private static func sha1(_ label: String, _ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: Data(label.utf8) + data))
    }

    private static func xor(_ a: Data, _ b: Data) -> Data {
        Data(zip(a, b).map { $0 ^ $1 })
    }

    private static func randomPad() -> Data {
        let count = Int.random(in: 0...200)
        return Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private static func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }
    private static func be32(from d: Data) -> UInt32 {
        let b = [UInt8](d)
        guard b.count >= 4 else { return 0 }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
    private static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xff)]) }
    private static func be16(from d: Data) -> UInt16 {
        let b = [UInt8](d)
        guard b.count >= 2 else { return 0 }
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }
}
