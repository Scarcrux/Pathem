import Foundation
import Testing

@testable import PathomEngine

@Suite struct ViewFormatTests {
    private func entry(
        _ name: String, dir: Bool = false, size: Int64 = 0, seconds: TimeInterval = 0
    ) -> FileEntry {
        FileEntry(
            name: name, isDirectory: dir, size: size,
            modificationDate: Date(timeIntervalSince1970: seconds))
    }

    @Test func nameAscendingWithFoldersFirst() {
        let format = ViewFormat(sortKey: .name, ascending: true)
        let input = [entry("b.txt"), entry("Docs", dir: true), entry("a.txt")]
        #expect(format.sorted(input).map(\.name) == ["Docs", "a.txt", "b.txt"])
    }

    @Test func sizeDescending() {
        let format = ViewFormat(sortKey: .size, ascending: false)
        let input = [entry("a", size: 10), entry("b", size: 30), entry("c", size: 20)]
        #expect(format.sorted(input).map(\.name) == ["b", "c", "a"])
    }

    @Test func dateAscending() {
        let format = ViewFormat(sortKey: .date, ascending: true)
        let input = [entry("new", seconds: 300), entry("old", seconds: 100), entry("mid", seconds: 200)]
        #expect(format.sorted(input).map(\.name) == ["old", "mid", "new"])
    }

    @Test func foldersStayFirstRegardlessOfDirection() {
        let format = ViewFormat(sortKey: .name, ascending: false)
        let input = [entry("a.txt"), entry("Docs", dir: true)]
        #expect(format.sorted(input).first?.name == "Docs")
    }

    @Test func foldersFirstCanBeDisabled() {
        let format = ViewFormat(sortKey: .name, ascending: true, foldersFirst: false)
        let input = [entry("b.txt"), entry("Docs", dir: true)]
        #expect(format.sorted(input).map(\.name) == ["b.txt", "Docs"])
    }

    @Test func codableRoundTrip() throws {
        let format = ViewFormat(sortKey: .date, ascending: false, showHidden: true, foldersFirst: false)
        let data = try JSONEncoder().encode(format)
        #expect(try JSONDecoder().decode(ViewFormat.self, from: data) == format)
    }
}
