import CryptoKit
import Foundation
import Testing

@testable import TorrentKit

@Suite struct BigUIntTests {
    @Test func bytesRoundTrip() {
        let data = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef])
        #expect(BigUInt(bytes: data).bytes(count: 8) == data)
    }

    @Test func modOfSmallValues() {
        #expect(BigUInt(1000).mod(BigUInt(7)) == BigUInt(1000 % 7))
        #expect(BigUInt(bytes: Data([0x10, 0x00])).mod(BigUInt(255)) == BigUInt(UInt32(0x1000 % 255)))
    }

    @Test func modPowMatchesKnownValues() {
        // 2^10 mod 1000 = 1024 mod 1000 = 24.
        #expect(BigUInt(2).modPow(BigUInt(10), BigUInt(1000)) == BigUInt(24))
        // 4^13 mod 497 = 445 (a classic RSA-textbook example).
        #expect(BigUInt(4).modPow(BigUInt(13), BigUInt(497)) == BigUInt(445))
        // 3^0 mod 7 = 1.
        #expect(BigUInt(3).modPow(BigUInt(0), BigUInt(7)) == BigUInt(1))
    }

    @Test func multiplyIsCorrect() {
        let a = BigUInt(bytes: Data([0xff, 0xff, 0xff, 0xff]))  // 4294967295
        let product = BigUInt.multiply(a, a)  // 18446744065119617025
        #expect(product.bytes(count: 8) == Data([0xff, 0xff, 0xff, 0xfe, 0x00, 0x00, 0x00, 0x01]))
    }

    // The fast Knuth-D `mod` must agree with the obviously-correct bit-by-bit `modSlow` over a
    // range of multi-limb dividends and divisors (this is what makes the fast path trustworthy).
    @Test func fastModAgreesWithReference() {
        func big(_ seed: UInt64, _ limbs: Int) -> BigUInt {
            var x = seed
            var data = Data()
            for _ in 0..<(limbs * 4) {
                x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407  // LCG
                data.append(UInt8(truncatingIfNeeded: x >> 33))
            }
            return BigUInt(bytes: data)
        }
        for seed in UInt64(1)...20 {
            let a = big(seed, 8)          // ~256-bit dividend
            let m = big(seed * 7 + 3, 3)  // ~96-bit divisor (multi-limb)
            #expect(a.mod(m) == a.modSlow(m))
        }
    }

    @Test func divModReconstructsDividend() {
        // quotient * divisor + remainder == dividend, and remainder < divisor.
        let a = BigUInt(bytes: Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 5) }))
        let d = BigUInt(bytes: Data((0..<12).map { UInt8(truncatingIfNeeded: $0 &* 91 &+ 1) }))
        let (q, r) = a.divMod(d)
        #expect(BigUInt.compare(r, d) < 0)
        #expect(addBig(BigUInt.multiply(q, d), r) == a)  // q*d + r == a
    }

    private func addBig(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        // Test-only add via the subtract identity would be awkward; use bytes round-trip instead.
        let n = max(a.bytes(count: 64).count, b.bytes(count: 64).count)
        let ab = [UInt8](a.bytes(count: 64)), bb = [UInt8](b.bytes(count: 64))
        var out = [UInt8](repeating: 0, count: 64)
        var carry = 0
        for i in stride(from: 63, through: 0, by: -1) {
            let s = Int(ab[i]) + Int(bb[i]) + carry
            out[i] = UInt8(s & 0xff)
            carry = s >> 8
        }
        _ = n
        return BigUInt(bytes: Data(out))
    }
}

@Suite struct RC4Tests {
    // RC4 test vector (RFC 6229 style): key "Key", plaintext "Plaintext" -> BBF316E8D940AF0AD3.
    @Test func matchesKnownVector() {
        var rc4 = RC4(key: Data("Key".utf8))
        let out = rc4.process(Data("Plaintext".utf8))
        #expect(out.map { String(format: "%02X", $0) }.joined() == "BBF316E8D940AF0AD3")
    }

    @Test func encryptDecryptRoundTrips() {
        let key = Data("secret".utf8)
        var enc = RC4(key: key)
        var dec = RC4(key: key)
        let message = Data("the quick brown fox".utf8)
        #expect(dec.process(enc.process(message)) == message)
    }
}

@Suite struct MSEKeyExchangeTests {
    @Test func bothSidesAgreeOnSharedSecret() {
        // A full DH exchange over the real MSE prime: both sides must derive the same secret.
        let alice = MSE.generateKeyPair()
        let bob = MSE.generateKeyPair()
        let aliceSecret = MSE.sharedSecret(ourPrivate: alice.priv, peerPublic: bob.publicKeyBytes)
        let bobSecret = MSE.sharedSecret(ourPrivate: bob.priv, peerPublic: alice.publicKeyBytes)
        #expect(aliceSecret == bobSecret)
        #expect(aliceSecret.count == 96)
    }

    @Test func rc4KeysAreDirectional() {
        let secret = Data(repeating: 0xAB, count: 96)
        let infoHash = Data(repeating: 0x11, count: 20)
        let keyA = MSE.rc4Key(label: "keyA", secret: secret, infoHash: infoHash)
        let keyB = MSE.rc4Key(label: "keyB", secret: secret, infoHash: infoHash)
        #expect(keyA.count == 20)
        #expect(keyA != keyB)  // the two directions use different keys

        // The initiator's send-key (keyA) must equal the receiver's receive-key (keyA).
        let receiverDecryptKey = MSE.rc4Key(label: "keyA", secret: secret, infoHash: infoHash)
        #expect(keyA == receiverDecryptKey)
    }

    @Test func publicKeyIs96Bytes() {
        #expect(MSE.generateKeyPair().publicKeyBytes.count == 96)
    }
}
