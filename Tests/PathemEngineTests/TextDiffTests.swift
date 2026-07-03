import Foundation
import Testing

@testable import PathemEngine

@Suite struct TextDiffTests {
    @Test func identicalTextIsAllEqual() {
        let result = TextDiff.diff("a\nb\nc", "a\nb\nc")
        #expect(result.added == 0)
        #expect(result.removed == 0)
        #expect(result.lines.allSatisfy { $0.kind == .equal })
        #expect(result.lines.count == 3)
    }

    @Test func detectsInsertAndDelete() {
        // Left has "b"; right replaces it with "x" and appends "d".
        let result = TextDiff.diff("a\nb\nc", "a\nx\nc\nd")
        #expect(result.removed == 1)  // b removed
        #expect(result.added == 2)  // x and d added
        // The unchanged lines stay aligned as equal.
        #expect(result.lines.contains { $0.kind == .equal && $0.left == "a" })
        #expect(result.lines.contains { $0.kind == .equal && $0.left == "c" })
        #expect(result.lines.contains { $0.kind == .delete && $0.left == "b" })
        #expect(result.lines.contains { $0.kind == .insert && $0.right == "d" })
    }

    @Test func lineNumbersTrackEachSide() {
        let result = TextDiff.diff("keep\nold", "keep\nnew")
        let del = try! #require(result.lines.first { $0.kind == .delete })
        let ins = try! #require(result.lines.first { $0.kind == .insert })
        #expect(del.leftNumber == 2)
        #expect(ins.rightNumber == 2)
    }

    @Test func truncatesBeyondMaxLines() {
        let big = (0..<50).map(String.init).joined(separator: "\n")
        let result = TextDiff.diff(big, big, maxLines: 10)
        #expect(result.truncated)
        #expect(result.lines.count == 10)
    }
}
