import Foundation
import Testing

@testable import PathemEngine

@Suite struct FoundationEnumeratorTests {
    /// Helper: a fresh temp directory, cleaned up after the test body.
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-test-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try body(dir)
    }

    @Test func listsRealTempDirectory() throws {
        try withTempDir { dir in
            try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))
            try Data().write(to: dir.appendingPathComponent("b.txt"))
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)

            let entries = try FoundationEnumerator().entries(of: dir, includingHidden: false)
            let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

            #expect(entries.count == 3)
            #expect(byName["a.txt"]?.isDirectory == false)
            #expect(byName["a.txt"]?.size == 5)
            #expect(byName["sub"]?.isDirectory == true)
        }
    }

    @Test func skipsHiddenByDefaultButReturnsThemWhenRequested() throws {
        try withTempDir { dir in
            try Data().write(to: dir.appendingPathComponent("visible.txt"))
            try Data().write(to: dir.appendingPathComponent(".hidden"))

            let visible = try FoundationEnumerator().entries(of: dir, includingHidden: false)
            let all = try FoundationEnumerator().entries(of: dir, includingHidden: true)

            #expect(visible.contains { $0.name == "visible.txt" })
            #expect(!visible.contains { $0.name == ".hidden" })
            #expect(all.contains { $0.name == ".hidden" })
        }
    }
}
