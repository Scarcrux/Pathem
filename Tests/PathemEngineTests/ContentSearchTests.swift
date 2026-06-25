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

    @Test func applyReplaceLiteralAndRegex() {
        let (literal, n1) = ContentSearch.applyReplace(
            to: "foo Foo FOO", query: "foo", replacement: "bar", regex: false, caseSensitive: false)
        #expect(literal == "bar bar bar")
        #expect(n1 == 3)

        let (cased, n2) = ContentSearch.applyReplace(
            to: "foo Foo", query: "foo", replacement: "bar", regex: false, caseSensitive: true)
        #expect(cased == "bar Foo")
        #expect(n2 == 1)

        let (regex, n3) = ContentSearch.applyReplace(
            to: "v1 v2 v3", query: #"v(\d)"#, replacement: "version$1", regex: true, caseSensitive: true)
        #expect(regex == "version1 version2 version3")
        #expect(n3 == 3)
    }

    @Test func replaceAllRewritesMatchingFiles() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-rep-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "alpha beta alpha\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "gamma\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: dir) }

        let result = await ContentSearch.replaceAll("alpha", with: "ALPHA", in: dir)
        #expect(result.filesChanged == 1)
        #expect(result.replacements == 2)
        let updated = try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(updated == "ALPHA beta ALPHA\n")
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
