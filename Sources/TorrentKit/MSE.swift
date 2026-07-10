import CryptoKit
import Foundation

/// RC4 stream cipher, as used by MSE/PE. RC4 is cryptographically weak, but MSE only uses it for
/// connection obfuscation (evading naive traffic shaping), not real confidentiality, and the spec
/// mandates it. Not provided by CryptoKit, so implemented here.
public struct RC4: Sendable {
    private var s: [UInt8]
    private var i = 0
    private var j = 0

    public init(key: Data) {
        s = Array(0...255)
        var j = 0
        let key = [UInt8](key)
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % key.count])) & 0xff
            s.swapAt(i, j)
        }
    }

    /// XOR `data` with the next keystream bytes (encryption and decryption are the same op).
    public mutating func process(_ data: Data) -> Data {
        var out = [UInt8](data)
        for k in 0..<out.count {
            i = (i + 1) & 0xff
            j = (j + Int(s[i])) & 0xff
            s.swapAt(i, j)
            out[k] ^= s[(Int(s[i]) + Int(s[j])) & 0xff]
        }
        return Data(out)
    }

    /// Discard the first `count` keystream bytes (MSE discards 1024 to sidestep the RC4 key bias).
    public mutating func discard(_ count: Int) {
        _ = process(Data(repeating: 0, count: count))
    }
}

/// Message Stream Encryption / Protocol Encryption (MSE/PE) primitives: the fixed Diffie-Hellman
/// group, the ephemeral key exchange, and the RC4 key derivation. The handshake state machine that
/// drives these over a socket lives in the connection layer.
public enum MSE {
    /// The 768-bit MSE prime (well-known) and generator G = 2.
    public static let primeHex =
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"
        + "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437"
        + "4FE1356D6D51C245E485B576625E7EC6F44C42E9A63A3620FFFFFFFFFFFFFFFF"

    public static var prime: BigUInt { BigUInt(bytes: hexToData(primeHex)) }
    public static let keyLength = 96  // 768 bits

    /// One side of the exchange: a random private key and the public key G^private mod P.
    public struct KeyPair {
        public let priv: BigUInt
        public let pub: BigUInt
        public var publicKeyBytes: Data { pub.bytes(count: keyLength) }
    }

    /// Generate an ephemeral DH key pair. The private key is 160 random bits (per the spec).
    public static func generateKeyPair() -> KeyPair {
        var privBytes = Data(count: 20)
        for i in 0..<20 { privBytes[i] = UInt8.random(in: 0...255) }
        let priv = BigUInt(bytes: privBytes)
        let pub = BigUInt(2).modPow(priv, prime)
        return KeyPair(priv: priv, pub: pub)
    }

    /// The shared secret S = peerPublic^ourPrivate mod P, as 96 big-endian bytes.
    public static func sharedSecret(ourPrivate: BigUInt, peerPublic: Data) -> Data {
        let peer = BigUInt(bytes: peerPublic)
        return peer.modPow(ourPrivate, prime).bytes(count: keyLength)
    }

    /// The RC4 key for one direction: SHA-1(label, S, SKEY) where label is "keyA"/"keyB" and SKEY
    /// is the info hash. The initiator encrypts with keyA and decrypts with keyB.
    public static func rc4Key(label: String, secret: Data, infoHash: Data) -> Data {
        var data = Data(label.utf8)
        data.append(secret)
        data.append(infoHash)
        return Data(Insecure.SHA1.hash(data: data))
    }

    static func hexToData(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<next], radix: 16) { data.append(byte) }
            index = next
        }
        return data
    }
}
