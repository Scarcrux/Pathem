import Foundation
import Testing

@testable import PathemEngine

@Suite struct DuplicateFinderTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-dup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func findsIdenticalContentAcrossFolders() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("same".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("same".utf8).write(to: sub.appendingPathComponent("copy.txt"))  // dup, different name+folder
        try Data("unique".utf8).write(to: root.appendingPathComponent("b.txt"))

        let groups = DuplicateFinder.find(in: [root])
        #expect(groups.count == 1)
        #expect(Set(groups[0].files.map(\.name)) == ["a.txt", "copy.txt"])
    }

    @Test func sameSizeDifferentContentIsNotADuplicate() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("abcd".utf8).write(to: root.appendingPathComponent("x.txt"))
        try Data("wxyz".utf8).write(to: root.appendingPathComponent("y.txt"))  // same size, different bytes
        #expect(DuplicateFinder.find(in: [root]).isEmpty)
    }

    @Test func differByTailOnlyIsNotADuplicate() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // Identical first 64 KB (the prefilter head is all zeros), differing only in the very
        // last byte: the head hash collides, so the full hash must still run to reject them.
        var a = Data(count: 70_000)
        a[69_999] = 1
        var b = Data(count: 70_000)
        b[69_999] = 2
        try a.write(to: root.appendingPathComponent("a.bin"))
        try b.write(to: root.appendingPathComponent("b.bin"))
        #expect(DuplicateFinder.find(in: [root]).isEmpty)
    }

    @Test func identicalLargeFilesPastTheHeadAreGrouped() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<70_000).map { UInt8($0 % 251) })  // bigger than the 64 KB head
        try payload.write(to: root.appendingPathComponent("a.bin"))
        try payload.write(to: root.appendingPathComponent("b.bin"))
        let groups = DuplicateFinder.find(in: [root])
        #expect(groups.count == 1)
        #expect(Set(groups[0].files.map(\.name)) == ["a.bin", "b.bin"])
    }

    @Test func cancellationReturnsEarly() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("same".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("same".utf8).write(to: root.appendingPathComponent("b.txt"))  // would group if not cancelled
        #expect(DuplicateFinder.find(in: [root], isCancelled: { true }).isEmpty)
    }

    @Test func emptyFilesAreSkipped() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("e1"))
        try Data().write(to: root.appendingPathComponent("e2"))
        #expect(DuplicateFinder.find(in: [root]).isEmpty)  // size 0 < minSize
    }
}
