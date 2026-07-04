import Foundation
import Testing

@testable import PathemEngine

@Suite struct BackupTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func backsUpToDestinationKeepingOriginals() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        let dest = dir.appendingPathComponent("Backup")

        let result = Backup.backup([a, b], to: dest)
        #expect(result.failures.isEmpty)
        #expect(Set(result.succeeded) == ["a.txt", "b.txt"])
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.txt").path))
        #expect(FileManager.default.fileExists(atPath: a.path))  // originals kept
    }

    @Test func plainFileIsNotOffloadable() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("local.txt")
        try Data("x".utf8).write(to: file)
        #expect(!Backup.isOffloadable(file))  // not an iCloud item
    }

    @Test func offloadingANonICloudItemFails() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("local.txt")
        try Data("x".utf8).write(to: file)
        // evictUbiquitousItem rejects a non-ubiquitous file; it's a recorded failure, not a crash.
        let result = Backup.offload([file])
        #expect(result.succeeded.isEmpty)
        #expect(result.failures.count == 1)
    }
}
