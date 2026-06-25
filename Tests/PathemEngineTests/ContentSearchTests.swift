import Foundation
import Testing

@testable import PathemEngine

@Suite struct ContentSearchTests {
    @Test func parsesPathLineText() {
        let out = """
            /Users/me/proj/src/main.swift:42:    let answer = 42
            /Users/me/proj/a:b.txt:7:has a colon in the path
            not a match line
            """
        let matches = ContentSearch.parse(out, limit: 100)
        #expect(matches.count == 2)
        #expect(matches[0].path == "/Users/me/proj/src/main.swift")
        #expect(matches[0].line == 42)
        #expect(matches[0].text == "    let answer = 42")
        // Path containing a colon still parses (anchors on :<digits>:).
        #expect(matches[1].path == "/Users/me/proj/a:b.txt")
        #expect(matches[1].line == 7)
    }

    @Test func respectsLimit() {
        let out = (1...50).map { "/f.txt:\($0):line \($0)" }.joined(separator: "\n")
        #expect(ContentSearch.parse(out, limit: 10).count == 10)
    }

    @Test func findsTextInRealFiles() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-grep-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "hello WORLD\nsecond line\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "nothing here\n".write(to: dir.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: dir) }

        let matches = await ContentSearch.search("world", in: dir, regex: false, caseSensitive: false)
        #expect(matches.contains { $0.path.hasSuffix("a.txt") && $0.line == 1 })
        #expect(!matches.contains { $0.path.hasSuffix("b.txt") })
    }
}
