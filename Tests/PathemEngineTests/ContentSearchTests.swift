import Foundation
import Testing

@testable import PathemEngine

@Suite struct ContentSearchTests {
    @Test func parsesPathLineText() {
        let out =
            "/fixture/home/proj/src/main.swift\u{0}42:    let answer = 42\n"
            + "/fixture/home/proj/a:b.txt\u{0}7:has a colon in the path\nnot a match line\n"
        let matches = ContentSearch.parse(out, limit: 100)
        #expect(matches.count == 2)
        #expect(matches[0].path == "/fixture/home/proj/src/main.swift")
        #expect(matches[0].line == 42)
        #expect(matches[0].text == "    let answer = 42")
        #expect(matches[1].path == "/fixture/home/proj/a:b.txt")
        #expect(matches[1].line == 7)
    }

    @Test func respectsLimit() {
        let out = (1...50).map { "/f.txt\u{0}\($0):line \($0)" }.joined(separator: "\n")
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
            to: "v1 v2 v3", query: #"v(\d)"#, replacement: "version$1", regex: true,
            caseSensitive: true)
        #expect(regex == "version1 version2 version3")
        #expect(n3 == 3)
    }

    @Test func replaceAllRewritesMatchingFiles() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-rep-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "alpha beta alpha\n".write(
            to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "gamma\n".write(
            to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
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
        try fm.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "hello WORLD\nsecond line\n".write(
            to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "nothing here\n".write(
            to: dir.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: dir) }

        let matches = await ContentSearch.search(
            "world", in: dir, regex: false, caseSensitive: false)
        #expect(matches.contains { $0.path.hasSuffix("a.txt") && $0.line == 1 })
        #expect(!matches.contains { $0.path.hasSuffix("b.txt") })
    }

    /// A folder name containing ":<digits>:" used to be parsed as the path/line boundary, so
    /// Replace All rewrote an outside sibling (docs/MISSION_53_AUDIT.md).
    @Test func replaceAllStaysInsideANumericColonFolder() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-cs-\(UUID().uuidString)")
        let scope = base.appendingPathComponent("scope:12:folder")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let inside = scope.appendingPathComponent("note.txt")
        let outside = base.appendingPathComponent("scope")
        try "needle INSIDE\nsecond 7:needle:9 line\n".write(
            to: inside, atomically: true, encoding: .utf8)
        try "needle OUTSIDE\n".write(to: outside, atomically: true, encoding: .utf8)

        let matches = await ContentSearch.search("needle", in: scope)
        #expect(matches.map(\.path) == [inside.path, inside.path])
        #expect(matches.map(\.line) == [1, 2])
        #expect(matches.last?.text == "second 7:needle:9 line")

        let result = await ContentSearch.replaceAll("needle", with: "REPLACED", in: scope)
        #expect(result == .init(filesChanged: 1, replacements: 2))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "needle OUTSIDE\n")
        #expect(
            try String(contentsOf: inside, encoding: .utf8)
                == "REPLACED INSIDE\nsecond 7:REPLACED:9 line\n")
    }

    @Test func parsesNulSeparatedRecordsIncludingNewlinePaths() {
        let out = "/a/b:3:c/x.txt\u{0}12:hello: 4:world\n/a/new\nline.txt\u{0}7:second\n"
        let matches = ContentSearch.parse(out, limit: 10)
        #expect(
            matches == [
                .init(path: "/a/b:3:c/x.txt", line: 12, text: "hello: 4:world"),
                .init(path: "/a/new\nline.txt", line: 7, text: "second"),
            ])
        // Output without the NUL contract is refused rather than guessed at.
        #expect(ContentSearch.parse("/a/b.txt:3:text\n", limit: 10).isEmpty)
    }

    @Test func writeScopeRejectsPathsOutsideTheFolder() {
        let folder = URL(fileURLWithPath: "/tmp/scope dir")
        #expect(ContentSearch.isInside("/tmp/scope dir/a/b.txt", folder))
        #expect(!ContentSearch.isInside("/tmp/scope", folder))
        #expect(!ContentSearch.isInside("/tmp/scope dir2/b.txt", folder))
        #expect(!ContentSearch.isInside("/tmp/scope dir/../other.txt", folder))
    }
}
