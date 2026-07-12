import Foundation
import Testing

@testable import PathemEngine

@Suite struct HexColorTests {
    @Test func parsesSixDigitWithHash() throws {
        let c = try #require(HexColor.parse("#FF8000"))
        #expect(abs(c.r - 1.0) < 0.001)
        #expect(abs(c.g - 128.0 / 255) < 0.001)
        #expect(abs(c.b - 0.0) < 0.001)
        #expect(c.a == 1.0)
    }

    @Test func parsesWithoutHash() throws {
        let c = try #require(HexColor.parse("00FF00"))
        #expect(c.r == 0)
        #expect(abs(c.g - 1.0) < 0.001)
        #expect(c.b == 0)
        #expect(c.a == 1.0)
    }

    @Test func parsesEightDigitAlpha() throws {
        let c = try #require(HexColor.parse("#11223380"))
        #expect(abs(c.r - Double(0x11) / 255) < 0.001)
        #expect(abs(c.g - Double(0x22) / 255) < 0.001)
        #expect(abs(c.b - Double(0x33) / 255) < 0.001)
        #expect(abs(c.a - Double(0x80) / 255) < 0.001)
    }

    @Test func trimsWhitespace() throws {
        let c = try #require(HexColor.parse("  #ABCDEF  "))
        #expect(abs(c.r - Double(0xAB) / 255) < 0.001)
    }

    @Test func rejectsMalformed() {
        #expect(HexColor.parse("") == nil)
        #expect(HexColor.parse("#") == nil)
        #expect(HexColor.parse("#FFF") == nil)  // 3-digit shorthand not supported
        #expect(HexColor.parse("#GGGGGG") == nil)
        #expect(HexColor.parse("#1234567") == nil)  // 7 digits
        #expect(HexColor.parse("nonsense") == nil)
    }

    @Test func formatsSixDigit() {
        #expect(HexColor.format(r: 1, g: 128.0 / 255, b: 0) == "#FF8000")
        #expect(HexColor.format(r: 0, g: 0, b: 0) == "#000000")
        #expect(HexColor.format(r: 1, g: 1, b: 1) == "#FFFFFF")
    }

    @Test func formatClampsOutOfRange() {
        #expect(HexColor.format(r: 2, g: -1, b: 0.5) == "#FF0080")
    }

    @Test func roundTrips() throws {
        for hex in ["#000000", "#FFFFFF", "#3A7BD5", "#123456"] {
            let c = try #require(HexColor.parse(hex))
            #expect(HexColor.format(r: c.r, g: c.g, b: c.b) == hex)
        }
    }
}
