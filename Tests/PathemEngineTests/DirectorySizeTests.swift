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

        #expect(DirectorySize.total(of: root) == 350)
    }

    @Test func emptyFolderIsZero() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(DirectorySize.total(of: root) == 0)
    }
}
