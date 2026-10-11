import Testing

@testable import TorrentKit

@Suite struct CStringBufferTests {
    private func chars(_ bytes: [UInt8]) -> [CChar] {
        bytes.map { CChar(bitPattern: $0) }
    }

    @Test func emptyBuffers() {
        #expect(decodeCStringBuffer([]) == "")
        #expect(decodeCStringBuffer([0, 65, 66]) == "")
    }

    @Test func paddedNumericAddressStopsAtFirstNull() {
        let address = Array("192.0.2.9".utf8)
        #expect(decodeCStringBuffer(chars(address + [0, 65, 66, 0])) == "192.0.2.9")
    }

    @Test func missingTerminatorStaysWithinBuffer() {
        #expect(decodeCStringBuffer(chars(Array("utun7".utf8))) == "utun7")
    }

    @Test func signedBytesPreserveUTF8() {
        #expect(decodeCStringBuffer(chars(Array("é界".utf8) + [0, 65])) == "é界")
    }

    @Test func malformedUTF8UsesReplacement() {
        #expect(decodeCStringBuffer(chars([255, 65, 0, 66])) == "�A")
    }
}
