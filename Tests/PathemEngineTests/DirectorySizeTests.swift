import Foundation
import Testing

@testable import PathemEngine

@Suite struct DirectorySizeTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathem-dirsize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func sumsFilesRecursivelyIncludingHidden() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 100).write(to: root.appendingPathComponent("a.bin"))
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(count: 200).write(to: sub.appendingPathComponent("b.bin"))
        try Data(count: 50).write(to: root.appendingPathComponent(".hidden"))  // must be counted

        let measure = DirectorySize.total(of: root)
        #expect(measure.bytes == 350)
        #expect(measure.complete)  // nothing was unreadable
    }

    @Test func emptyFolderIsZero() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let measure = DirectorySize.total(of: root)
        #expect(measure.bytes == 0)
        #expect(measure.complete)
    }

    @Test func unreadableSubtreeMarksResultIncomplete() throws {
        let root = try tempDir()
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(count: 100).write(to: root.appendingPathComponent("a.bin"))
        try Data(count: 200).write(to: locked.appendingPathComponent("secret.bin"))
        // Make the subtree unreadable, then always restore so cleanup can delete it.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        let measure = DirectorySize.total(of: root)
        #expect(measure.complete == false)  // the locked subtree couldn't be read
        #expect(measure.bytes >= 100)  // still counts what it could reach (a lower bound)
        #expect(measure.bytes < 300)  // the locked file's bytes are not included
    }
}
