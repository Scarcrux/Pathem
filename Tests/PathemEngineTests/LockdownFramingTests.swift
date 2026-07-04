import Foundation
import Testing

@testable import PathemEngine

@Suite struct LockdownFramingTests {
    @Test func framePrefixesBigEndianLength() {
        let payload = Data("hello".utf8)  // 5 bytes
        let framed = LockdownFraming.frame(payload)
        #expect(Array(framed.prefix(4)) == [0, 0, 0, 5])  // 4-byte big-endian length
        #expect(framed.dropFirst(4) == payload)
    }

    @Test func payloadLengthDecodesBigEndian() {
        #expect(LockdownFraming.payloadLength([0, 0, 0, 5]) == 5)
        #expect(LockdownFraming.payloadLength([0, 0, 1, 0]) == 256)
        #expect(LockdownFraming.payloadLength([1, 0, 0, 0]) == 16_777_216)
        #expect(LockdownFraming.payloadLength([0xFF, 0xFF, 0xFF, 0xFF]) == 4_294_967_295)
    }

    @Test func frameAndLengthRoundTrip() {
        for size in [0, 1, 255, 256, 65_535, 100_000] {
            let framed = LockdownFraming.frame(Data(repeating: 0x41, count: size))
            #expect(LockdownFraming.payloadLength(Array(framed.prefix(4))) == size)
            #expect(framed.count == size + 4)
        }
    }

    @Test func isTrueCoercesBoolAndInt() {
        #expect(LockdownFraming.isTrue(true))
        #expect(LockdownFraming.isTrue(1))
        #expect(LockdownFraming.isTrue(42))
        #expect(!LockdownFraming.isTrue(false))
        #expect(!LockdownFraming.isTrue(0))
        #expect(!LockdownFraming.isTrue(nil))
        #expect(!LockdownFraming.isTrue("true"))  // a string is not a truthy lockdown value
    }
}
