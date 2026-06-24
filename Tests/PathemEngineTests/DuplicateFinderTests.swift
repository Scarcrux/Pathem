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

    @Test func emptyFilesAreSkipped() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("e1"))
        try Data().write(to: root.appendingPathComponent("e2"))
        #expect(DuplicateFinder.find(in: [root]).isEmpty)  // size 0 < minSize
    }
}
