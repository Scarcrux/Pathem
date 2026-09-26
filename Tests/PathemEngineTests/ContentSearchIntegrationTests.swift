import Foundation
import Testing

@testable import PathemEngine

@Suite struct ContentSearchIntegrationTests {
    @Test func extendedRegexWorksThroughSystemSearchTool() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "pathem-grep-regex-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "alpha one\nbeta two\ngamma three\n".write(
            to: dir.appendingPathComponent("values.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: dir) }

        // Parentheses and alternation require grep -E on the macOS fallback.
        let matches = await ContentSearch.search(
            #"(alpha|beta) (one|two)"#, in: dir, regex: true, caseSensitive: true)
        #expect(matches.map(\.line) == [1, 2])
    }
}
