import Foundation
import Testing

@testable import PathemEngine

@Suite struct DiskUsageTests {
    @Test func ranksChildrenBySizeLargestFirst() throws {
        let dir = try makeTree()
        defer { try? FileManager.default.removeItem(at: dir) }

        let items = DiskUsage.rankedChildren(of: dir)
        // big/ (300 bytes recursive) > medium.bin (100) > small.txt (10).
        #expect(items.map(\.name) == ["big", "medium.bin", "small.txt"])
        #expect(items[0].isDirectory)
        #expect(items[0].bytes == 300)
        #expect(items[0].complete)
        #expect(items[1].bytes == 100)
        #expect(items[2].bytes == 10)
    }

    @Test func hiddenItemsCountByDefaultButCanBeExcluded() throws {
        let dir = try makeTree()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 50).write(to: dir.appendingPathComponent(".cache"))

        let withHidden = DiskUsage.rankedChildren(of: dir)
        #expect(withHidden.contains { $0.name == ".cache" })
        let withoutHidden = DiskUsage.rankedChildren(of: dir, includingHidden: false)
        #expect(!withoutHidden.contains { $0.name == ".cache" })
    }

    @Test func symlinkToDirectoryIsNotFollowedOrOvercounted() throws {
        let dir = try makeTree()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A symlink pointing at the heavy subtree must rank by its own tiny size, not big/'s.
        let link = dir.appendingPathComponent("shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("big"))

        let items = DiskUsage.rankedChildren(of: dir)
        let shortcut = try #require(items.first { $0.name == "shortcut" })
        #expect(!shortcut.isDirectory)
        #expect(shortcut.bytes < 300)  // its own link size, nowhere near the 300-byte target
    }

    /// small.txt (10 bytes), medium.bin (100 bytes), and big/ (a + b = 300 bytes).
    private func makeTree() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pathem-du-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 10).write(to: dir.appendingPathComponent("small.txt"))
        try Data(count: 100).write(to: dir.appendingPathComponent("medium.bin"))
        let big = dir.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        try Data(count: 200).write(to: big.appendingPathComponent("a.dat"))
        try Data(count: 100).write(to: big.appendingPathComponent("b.dat"))
        return dir
    }
}
