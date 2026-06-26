import Foundation
import Testing

@testable import PathemEngine

@Suite struct ViewFormatTests {
    private func entry(
        _ name: String, dir: Bool = false, size: Int64 = 0, seconds: TimeInterval = 0
    ) -> FileEntry {
        FileEntry(
            name: name, isDirectory: dir, size: size,
            modificationDate: Date(timeIntervalSince1970: seconds))
    }

    @Test func sortsByCreationAndAccessDates() {
        let a = FileEntry(
            name: "a", isDirectory: false, size: 0, modificationDate: nil,
            creationDate: Date(timeIntervalSince1970: 300), accessDate: Date(timeIntervalSince1970: 100))
        let b = FileEntry(
            name: "b", isDirectory: false, size: 0, modificationDate: nil,
            creationDate: Date(timeIntervalSince1970: 100), accessDate: Date(timeIntervalSince1970: 300))
        let byCreated = ViewFormat(sortKey: .dateCreated, ascending: true, foldersFirst: false).sorted([a, b])
        #expect(byCreated.map(\.name) == ["b", "a"])  // b created earlier
        let byAccessed = ViewFormat(sortKey: .dateAccessed, ascending: true, foldersFirst: false).sorted([a, b])
        #expect(byAccessed.map(\.name) == ["a", "b"])  // a accessed earlier
    }

    @Test func decodesLegacyJSONWithoutViewMode() throws {
        // Older formats.json had no viewMode; it must still decode (defaulting to
        // .list) rather than failing and wiping every saved format.
        let json = #"{"sortKey":"size","ascending":false,"showHidden":true,"foldersFirst":false}"#
        let format = try JSONDecoder().decode(ViewFormat.self, from: Data(json.utf8))
        #expect(format.sortKey == .size)
        #expect(format.viewMode == .list)
        #expect(format.showHidden == true)
    }

    @Test func viewModeRoundTrips() throws {
        let format = ViewFormat(viewMode: .icon)
        let back = try JSONDecoder().decode(ViewFormat.self, from: JSONEncoder().encode(format))
        #expect(back.viewMode == .icon)
        #expect(back == format)
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
