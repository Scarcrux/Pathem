import Foundation
import Testing

@testable import PathemEngine

@Suite struct SelectionQueryTests {
    private func file(_ name: String) -> FileEntry {
        FileEntry(name: name, isDirectory: false, size: 0, modificationDate: nil)
    }
    private func folder(_ name: String) -> FileEntry {
        FileEntry(name: name, isDirectory: true, size: 0, modificationDate: nil)
    }
    private func matches(_ query: SelectionQuery, _ entries: [FileEntry]) -> [String] {
        let p = query.predicate()
        return entries.filter(p).map(\.name)
    }

    @Test func globStarMatchesExtension() {
        let entries = [file("a.log"), file("b.log"), file("c.txt"), folder("logs")]
        #expect(matches(SelectionQuery(pattern: "*.log"), entries) == ["a.log", "b.log"])
    }

    @Test func globQuestionMarkIsSingleChar() {
        let entries = [file("a1.txt"), file("ab.txt"), file("abc.txt")]
        #expect(matches(SelectionQuery(pattern: "a?.txt"), entries) == ["a1.txt", "ab.txt"])
    }

    @Test func globDotIsLiteralNotAnyChar() {
        // In a glob, "." is a literal, so "a.b" must not match "axb".
        let entries = [file("a.b"), file("axb")]
        #expect(matches(SelectionQuery(pattern: "a.b"), entries) == ["a.b"])
    }

    @Test func globCharacterClass() {
        let entries = [file("img1.jpg"), file("img2.jpg"), file("imgX.jpg")]
        #expect(matches(SelectionQuery(pattern: "img[0-9].jpg"), entries) == ["img1.jpg", "img2.jpg"])
    }

    @Test func caseInsensitiveByDefaultButRespectsFlag() {
        let entries = [file("Report.LOG"), file("data.log")]
        #expect(matches(SelectionQuery(pattern: "*.log"), entries) == ["Report.LOG", "data.log"])
        #expect(
            matches(SelectionQuery(pattern: "*.log", caseSensitive: true), entries) == ["data.log"])
    }

    @Test func regexMode() {
        let entries = [file("123"), file("12a"), file("999")]
        #expect(
            matches(SelectionQuery(pattern: "^[0-9]+$", match: .regex), entries) == ["123", "999"])
    }

    @Test func invalidRegexSelectsNothing() {
        let entries = [file("a"), file("b")]
        #expect(matches(SelectionQuery(pattern: "(", match: .regex), entries).isEmpty)
    }

    @Test func substringMode() {
        let entries = [file("annual-report.pdf"), file("notes.txt"), file("REPORT.doc")]
        #expect(
            matches(SelectionQuery(pattern: "report", match: .substring), entries)
                == ["annual-report.pdf", "REPORT.doc"])
    }

    @Test func kindFilter() {
        let entries = [file("a.txt"), folder("docs"), file("b.txt"), folder("logs")]
        #expect(matches(SelectionQuery(pattern: "*", kind: .folders), entries) == ["docs", "logs"])
        #expect(matches(SelectionQuery(pattern: "*", kind: .files), entries) == ["a.txt", "b.txt"])
    }

    @Test func emptyPatternMatchesAllOfKind() {
        let entries = [file("a"), folder("b"), file("c")]
        #expect(matches(SelectionQuery(pattern: "", kind: .folders), entries) == ["b"])
        #expect(matches(SelectionQuery(pattern: "   ", kind: .any), entries) == ["a", "b", "c"])
    }
}
