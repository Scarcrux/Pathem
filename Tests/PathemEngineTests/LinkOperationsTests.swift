import Foundation
import Testing

@testable import PathemEngine

@Suite struct LinkOperationsTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(arguments: FileOperations.LinkKind.allCases) func redoRecreatesLink(
        kind: FileOperations.LinkKind
    ) throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("pathem-link-redo-\(UUID())")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: directory) }
        let source = directory.appendingPathComponent("payload")
        try Data("fixture".utf8).write(to: source)
        let original = FileOperations.makeLinks([source], kind: kind)
        let created = try #require(original.performed.first)
        try fm.removeItem(at: created.destination)
        let replayed = FileOperations.redo([created])
        #expect(replayed.failures.isEmpty)
        #expect(replayed.performed.count == 1)
        switch kind {
        case .symlink:
            #expect(
                try fm.destinationOfSymbolicLink(atPath: created.destination.path) == source.path)
        case .hardlink:
            var a = stat()
            var b = stat()
            try #require(lstat(source.path, &a) == 0)
            try #require(lstat(created.destination.path, &b) == 0)
            #expect(a.st_ino == b.st_ino)
        case .alias:
            let resolved = try URL(resolvingAliasFileAt: created.destination)
                .resolvingSymlinksInPath()
            #expect(resolved.path == source.resolvingSymlinksInPath().path)
        }
    }

    @Test func symlinkPointsAtOriginal() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("report.pdf")
        try Data("hi".utf8).write(to: file)

        let outcome = FileOperations.makeLinks([file], kind: .symlink)
        #expect(outcome.performed.count == 1)
        let link = dir.appendingPathComponent("report symlink.pdf")
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(dest == file.path)
    }

    @Test func hardlinkSharesContentForFileAndFolder() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("data.bin")
        try Data("x".utf8).write(to: file)
        let outcome = FileOperations.makeLinks([file], kind: .hardlink)
        #expect(outcome.performed.count == 1)
        // A hardlink shares the inode: writing through one is seen through the other.
        let link = dir.appendingPathComponent("data hardlink.bin")
        try Data("changed".utf8).write(to: link)
        #expect(try Data(contentsOf: file) == Data("changed".utf8))

        // A folder hardlink recursively hardlinks its contents (shared-inode clone).
        let sub = dir.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let inner = sub.appendingPathComponent("inner.txt")
        try Data("orig".utf8).write(to: inner)
        let dirOutcome = FileOperations.makeLinks([sub], kind: .hardlink)
        #expect(dirOutcome.performed.count == 1)
        try Data("edited".utf8).write(to: dir.appendingPathComponent("folder hardlink/inner.txt"))
        #expect(try Data(contentsOf: inner) == Data("edited".utf8))
    }

    @Test func aliasResolvesBackToOriginal() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("photo.png")
        try Data("img".utf8).write(to: file)
        let outcome = FileOperations.makeLinks([file], kind: .alias)
        #expect(outcome.performed.count == 1)
        let alias = dir.appendingPathComponent("photo alias.png")
        var stale = false
        let resolved = try URL(resolvingAliasFileAt: alias, options: []).standardizedFileURL
        _ = stale
        #expect(resolved.path == file.standardizedFileURL.path)
    }

    @Test func repeatedLinksGetUniqueNames() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try Data("n".utf8).write(to: file)
        _ = FileOperations.makeLinks([file], kind: .symlink)
        _ = FileOperations.makeLinks([file], kind: .symlink)
        #expect(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("note symlink.txt").path))
        #expect(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("note symlink 2.txt").path))
    }
}
