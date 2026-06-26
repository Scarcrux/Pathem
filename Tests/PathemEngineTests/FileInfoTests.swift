import Foundation
import Testing

@testable import PathemEngine

@Suite struct FileInfoTests {
    @Test func rwxStringFormatsModeBits() {
        #expect(FileInfo.rwxString(0o755) == "rwxr-xr-x")
        #expect(FileInfo.rwxString(0o644) == "rw-r--r--")
        #expect(FileInfo.rwxString(0o600) == "rw-------")
        #expect(FileInfo.rwxString(0o000) == "---------")
    }

    @Test func setPosixModeRoundTrips() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-chmod-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("script.sh")
        try Data("#!/bin/sh\n".utf8).write(to: file)

        try FileInfo.setPosixMode(0o700, on: file)
        #expect(FileInfo.gather(for: file)?.posixMode == 0o700)
        try FileInfo.setPosixMode(0o644, on: file)
        let info = FileInfo.gather(for: file)
        #expect(info?.posixMode == 0o644)
        #expect(info?.permissions == "rw-r--r--")
    }

    @Test func gatherReadsRichMetadataAndLockToggles() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-rich-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for name in ["a.txt", "b.txt", "c.txt"] {
            try Data("hello".utf8).write(to: dir.appendingPathComponent(name))
        }
        // A folder reports its child count.
        #expect(FileInfo.gather(for: dir)?.itemCount == 3)

        let file = dir.appendingPathComponent("a.txt")
        let info = FileInfo.gather(for: file)
        #expect(info?.allocatedSize ?? 0 > 0)  // on-disk size populated
        #expect(info?.accessed != nil)

        // Lock toggles round-trip.
        try FileInfo.setLocked(true, on: file)
        #expect(FileInfo.gather(for: file)?.isLocked == true)
        try FileInfo.setLocked(false, on: file)
        #expect(FileInfo.gather(for: file)?.isLocked == false)
    }

    @Test func gatherReadsFileMetadata() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-info-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: file)

        let info = try #require(FileInfo.gather(for: file))
        #expect(info.name == "note.txt")
        #expect(info.path == file.path)
        #expect(info.isDirectory == false)
        #expect(info.size == 5)
        #expect(info.modified != nil)
        #expect(info.permissions.count == 9)
    }

    @Test func gatherMarksDirectories() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-info-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let info = try #require(FileInfo.gather(for: dir))
        #expect(info.isDirectory == true)
    }
}
