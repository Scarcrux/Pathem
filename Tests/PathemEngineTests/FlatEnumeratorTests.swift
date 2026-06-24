import Foundation
import Testing

@testable import PathemEngine

@Suite struct FlatEnumeratorTests {
    private func makeTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-flat-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("a/b", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("top.txt"))
        try Data().write(to: root.appendingPathComponent("a/mid.txt"))
        try Data().write(to: sub.appendingPathComponent("deep.txt"))
        return root
    }

    @Test func flattensEveryFileWithItsFolder() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = FlatEnumerator.entries(of: root)
        let names = Set(result.entries.map(\.name))
        #expect(names == ["top.txt", "mid.txt", "deep.txt"])  // files only by default
        #expect(result.entries.allSatisfy { $0.location != nil })  // each carries its folder
        let deep = result.entries.first { $0.name == "deep.txt" }
        #expect(deep?.location?.hasSuffix("/a/b") == true)
        #expect(result.truncated == false)
    }

    @Test func includeFoldersAddsDirectories() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = FlatEnumerator.entries(of: root, includeFolders: true)
        #expect(result.entries.contains { $0.name == "a" && $0.isDirectory })
        #expect(result.entries.contains { $0.name == "b" && $0.isDirectory })
    }

    @Test func maxDepthStopsRecursion() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        // Depth 0 reads only the root's immediate files (no descent into a/).
        let result = FlatEnumerator.entries(of: root, maxDepth: 0)
        #expect(result.entries.map(\.name) == ["top.txt"])
    }

    @Test func itemCapTruncates() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = FlatEnumerator.entries(of: root, maxItems: 1)
        #expect(result.entries.count == 1)
        #expect(result.truncated)
    }
}
