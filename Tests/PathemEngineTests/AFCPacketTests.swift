import Foundation
import Testing

@testable import PathemEngine

@Suite struct AFCPacketTests {
    @Test func encodesAndDecodesHeader() {
        let payload = AFCPacket.pathPayload("/DCIM")
        let packet = AFCPacket.encode(.readDir, packetNum: 5, payload: payload)
        #expect(packet.prefix(8) == AFCPacket.magic)
        let header = AFCPacket.decodeHeader(packet)
        #expect(header?.operation == AFCPacket.Op.readDir.rawValue)
        #expect(header?.packetNum == 5)
        #expect(header?.entireLength == UInt64(AFCPacket.headerSize + payload.count))
        #expect(header?.thisLength == header?.entireLength)
        // The payload is a null-terminated path.
        #expect(packet.suffix(payload.count) == payload)
    }

    @Test func rejectsBadMagic() {
        var bytes = Data(repeating: 0, count: 40)
        bytes.replaceSubrange(0..<8, with: Data("NOTAFCXX".utf8))
        #expect(AFCPacket.decodeHeader(bytes) == nil)
        #expect(AFCPacket.decodeHeader(Data([1, 2, 3])) == nil)  // too short
    }

    @Test func parsesDirectoryEntries() {
        // READ_DIR DATA payload: null-separated names including . and ..
        let bytes = nullJoined([".", "..", "DCIM", "Photos", "trace.log"])
        let entries = AFCPacket.directoryEntries(bytes)
        #expect(entries == ["DCIM", "Photos", "trace.log"])  // . and .. dropped
    }

    @Test func parsesFileInfoAndType() {
        let dir = AFCPacket.fileInfo(
            nullJoined(["st_size", "4096", "st_ifmt", "S_IFDIR", "st_mtime", "1700000000000000000"]))
        #expect(AFCPacket.isDirectory(dir))
        #expect(AFCPacket.size(dir) == 4096)

        let file = AFCPacket.fileInfo(nullJoined(["st_size", "1024", "st_ifmt", "S_IFREG"]))
        #expect(!AFCPacket.isDirectory(file))
        #expect(AFCPacket.size(file) == 1024)
    }

    @Test func parsesStatusCode() {
        var ok = Data()
        AFCPacket.appendUInt64(&ok, 0)
        #expect(AFCPacket.status(ok) == 0)
        var err = Data()
        AFCPacket.appendUInt64(&err, 8)
        #expect(AFCPacket.status(err) == 8)
    }

    @Test func renamePayloadHasTwoNullTerminatedPaths() {
        let payload = AFCPacket.renamePayload(from: "/a.txt", to: "/b.txt")
        let parts = AFCPacket.nullSeparatedStrings(payload)
        #expect(parts == ["/a.txt", "/b.txt"])
    }

    /// Build a null-separated, null-terminated buffer like AFC returns.
    private func nullJoined(_ strings: [String]) -> Data {
        var data = Data()
        for string in strings {
            data.append(contentsOf: string.utf8)
            data.append(0)
        }
        return data
    }
}
