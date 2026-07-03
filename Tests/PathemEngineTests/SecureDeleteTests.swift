import Foundation
import Testing

@testable import PathemEngine

@Suite struct SecureDeleteTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-shred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func overwriteReplacesContentKeepingLength() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("secret.txt")
        let original = Data(repeating: 0x41, count: 4096)  // "AAAA..."
        try original.write(to: file)
        try SecureDelete.overwrite(file, passes: 2)
        let after = try Data(contentsOf: file)
        #expect(after.count == original.count)  // same length
        #expect(after != original)  // but not the original bytes
    }

    @Test func shredRemovesFilesAndReports() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("data.bin")
        try Data(repeating: 7, count: 1000).write(to: file)
        let result = SecureDelete.shred([file])
        #expect(result.deleted == ["data.bin"])
        #expect(result.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func shredRecursesIntoFolders() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("box")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: folder.appendingPathComponent("b.txt"))
        let result = SecureDelete.shred([folder])
        #expect(result.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func shredSymlinkLeavesTargetAlone() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.txt")
        try Data("keep me".utf8).write(to: target)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let result = SecureDelete.shred([link])
        #expect(result.deleted == ["link"])
        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect(try Data(contentsOf: target) == Data("keep me".utf8))  // target untouched
    }
}
