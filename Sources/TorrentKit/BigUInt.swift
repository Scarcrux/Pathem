import Foundation

/// A minimal fixed-purpose unsigned big integer: just enough for the MSE Diffie-Hellman exchange
/// (768-bit modular exponentiation). Correctness over speed - it runs once per encrypted
/// connection, not per packet. Little-endian 32-bit limbs. Not constant-time; the MSE keys are
/// ephemeral and the threat model is ISP obfuscation, not resisting a local timing attacker.
public struct BigUInt: Equatable {
    private(set) var limbs: [UInt32]  // little-endian, no trailing zero limbs (except value 0 -> [])

    public init() { limbs = [] }

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    public init(_ value: UInt32) { self.init(limbs: [value]) }

    /// Big-endian bytes -> value.
    public init(bytes: Data) {
        var limbs: [UInt32] = []
        let bytes = [UInt8](bytes)
        var i = bytes.count
        while i > 0 {
            var limb: UInt32 = 0
            for shift in stride(from: 0, to: 32, by: 8) {
                i -= 1
                guard i >= 0 else { break }
                limb |= UInt32(bytes[i]) << shift
            }
            limbs.append(limb)
        }
        self.init(limbs: limbs)
    }

    /// Big-endian bytes, left-zero-padded to `count` bytes (truncates high bytes if too small).
    public func bytes(count: Int) -> Data {
        var out = [UInt8](repeating: 0, count: count)
        for byteIndex in 0..<count {
            let limbIndex = byteIndex / 4
            let shift = (byteIndex % 4) * 8
            let value = limbIndex < limbs.count ? UInt8((limbs[limbIndex] >> shift) & 0xff) : 0
            out[count - 1 - byteIndex] = value
        }
        return Data(out)
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    public var isZero: Bool { limbs.isEmpty }

    // MARK: comparison / arithmetic

    static func compare(_ a: BigUInt, _ b: BigUInt) -> Int {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count ? -1 : 1 }
        for i in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[i] != b.limbs[i] {
            return a.limbs[i] < b.limbs[i] ? -1 : 1
        }
        return 0
    }

    /// a - b, requires a >= b.
    static func subtract(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        var result = [UInt32](repeating: 0, count: a.limbs.count)
        var borrow: UInt64 = 0
        for i in 0..<a.limbs.count {
            let bi = i < b.limbs.count ? UInt64(b.limbs[i]) : 0
            let diff = UInt64(a.limbs[i]) &- bi &- borrow
            result[i] = UInt32(truncatingIfNeeded: diff)
            borrow = (diff >> 63) & 1  // set when it underflowed
        }
        return BigUInt(limbs: result)
    }

    static func multiply(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        if a.isZero || b.isZero { return BigUInt() }
        var result = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            let ai = UInt64(a.limbs[i])
            for j in 0..<b.limbs.count {
                let sum = ai * UInt64(b.limbs[j]) + UInt64(result[i + j]) + carry
                result[i + j] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }
            result[i + b.limbs.count] += UInt32(truncatingIfNeeded: carry)
        }
        return BigUInt(limbs: result)
    }

    /// The high bit position (number of significant bits), 0 for zero.
    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 32, offset = index % 32
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> offset) & 1 == 1
    }

    /// Shift left by one bit.
    func shiftedLeftByOne() -> BigUInt {
        var result = [UInt32](repeating: 0, count: limbs.count + 1)
        var carry: UInt32 = 0
        for i in 0..<limbs.count {
            result[i] = (limbs[i] << 1) | carry
            carry = limbs[i] >> 31
        }
        result[limbs.count] = carry
        return BigUInt(limbs: result)
    }

    /// self mod modulus. Fast path via base-2^32 long division (Knuth Algorithm D); the simple
    /// bit-by-bit version is kept as `modSlow` to cross-check it in tests.
    func mod(_ modulus: BigUInt) -> BigUInt {
        guard !modulus.isZero else { return BigUInt() }
        if BigUInt.compare(self, modulus) < 0 { return self }
        if modulus.limbs.count == 1 { return BigUInt(modByWord(modulus.limbs[0])) }
        return divMod(modulus).remainder
    }

    /// self mod a single-limb value.
    private func modByWord(_ d: UInt32) -> UInt32 {
        var rem: UInt64 = 0
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            rem = ((rem << 32) | UInt64(limbs[i])) % UInt64(d)
        }
        return UInt32(rem)
    }

    /// Knuth Algorithm D: return quotient and remainder of self / divisor (divisor has >= 2 limbs).
    func divMod(_ divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        if BigUInt.compare(self, divisor) < 0 { return (BigUInt(), self) }
        let n = divisor.limbs.count
        // Normalize so the divisor's top limb has its high bit set.
        let shift = divisor.limbs[n - 1].leadingZeroBitCount
        let v = divisor.shiftedLeft(bits: shift).limbs
        var u = shiftedLeft(bits: shift).limbs
        let m = u.count - n
        u.append(0)  // guard limb for the leading digit

        let base: UInt64 = 1 << 32
        var quotient = [UInt32](repeating: 0, count: m + 1)
        for j in stride(from: m, through: 0, by: -1) {
            let top = (UInt64(u[j + n]) << 32) | UInt64(u[j + n - 1])
            var qhat = top / UInt64(v[n - 1])
            var rhat = top % UInt64(v[n - 1])
            while qhat >= base || qhat * UInt64(v[n - 2]) > (rhat << 32) | UInt64(u[j + n - 2]) {
                qhat -= 1
                rhat += UInt64(v[n - 1])
                if rhat >= base { break }
            }
            // u[j..j+n] -= qhat * v
            var borrow: Int64 = 0
            var carry: UInt64 = 0
            for i in 0..<n {
                let product = qhat * UInt64(v[i]) + carry
                carry = product >> 32
                let sub = Int64(u[j + i]) - Int64(product & 0xffff_ffff) - borrow
                u[j + i] = UInt32(truncatingIfNeeded: sub)
                borrow = sub < 0 ? 1 : 0
            }
            let sub = Int64(u[j + n]) - Int64(carry) - borrow
            u[j + n] = UInt32(truncatingIfNeeded: sub)
            if sub < 0 {
                // Overestimated: add the divisor back and decrement the quotient digit.
                qhat -= 1
                var add: UInt64 = 0
                for i in 0..<n {
                    let s = UInt64(u[j + i]) + UInt64(v[i]) + add
                    u[j + i] = UInt32(truncatingIfNeeded: s)
                    add = s >> 32
                }
                u[j + n] = UInt32(truncatingIfNeeded: UInt64(u[j + n]) + add)
            }
            quotient[j] = UInt32(truncatingIfNeeded: qhat)
        }
        // Remainder is the low n limbs of u, de-normalized (shifted right).
        let remainder = BigUInt(limbs: Array(u.prefix(n))).shiftedRight(bits: shift)
        return (BigUInt(limbs: quotient), remainder)
    }

    /// Shift left by `bits` (0...31 within the low limb boundaries plus whole-limb handling).
    func shiftedLeft(bits: Int) -> BigUInt {
        guard bits > 0 else { return self }
        let wordShift = bits / 32, bitShift = bits % 32
        var result = [UInt32](repeating: 0, count: limbs.count + wordShift + 1)
        for i in 0..<limbs.count {
            let value = UInt64(limbs[i]) << bitShift
            result[i + wordShift] |= UInt32(truncatingIfNeeded: value)
            result[i + wordShift + 1] |= UInt32(truncatingIfNeeded: value >> 32)
        }
        return BigUInt(limbs: result)
    }

    func shiftedRight(bits: Int) -> BigUInt {
        guard bits > 0 else { return self }
        let wordShift = bits / 32, bitShift = bits % 32
        guard wordShift < limbs.count else { return BigUInt() }
        var result = [UInt32](repeating: 0, count: limbs.count - wordShift)
        for i in 0..<result.count {
            var value = UInt64(limbs[i + wordShift]) >> bitShift
            if bitShift > 0, i + wordShift + 1 < limbs.count {
                value |= UInt64(limbs[i + wordShift + 1]) << (32 - bitShift)
            }
            result[i] = UInt32(truncatingIfNeeded: value)
        }
        return BigUInt(limbs: result)
    }

    /// The simple, obviously-correct bit-by-bit remainder, used to cross-check `mod` in tests.
    func modSlow(_ modulus: BigUInt) -> BigUInt {
        guard !modulus.isZero else { return BigUInt() }
        if BigUInt.compare(self, modulus) < 0 { return self }
        var remainder = BigUInt()
        for i in stride(from: bitWidth - 1, through: 0, by: -1) {
            remainder = remainder.shiftedLeftByOne()
            if bit(i) {
                if remainder.limbs.isEmpty { remainder.limbs = [1] } else { remainder.limbs[0] |= 1 }
            }
            if BigUInt.compare(remainder, modulus) >= 0 {
                remainder = BigUInt.subtract(remainder, modulus)
            }
        }
        return remainder
    }

    /// (self ^ exponent) mod modulus, by square-and-multiply.
    public func modPow(_ exponent: BigUInt, _ modulus: BigUInt) -> BigUInt {
        guard !modulus.isZero else { return BigUInt() }
        var result = BigUInt(1).mod(modulus)
        var base = self.mod(modulus)
        for i in 0..<exponent.bitWidth {
            if exponent.bit(i) {
                result = BigUInt.multiply(result, base).mod(modulus)
            }
            base = BigUInt.multiply(base, base).mod(modulus)
        }
        return result
    }
}
