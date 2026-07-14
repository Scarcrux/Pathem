import Foundation
import Testing

@testable import PathemEngine

@Suite struct FinderFavoritesTests {
    /// Finder stores each favorite as a bookmark inside an NSKeyedArchiver plist. Build one the same
    /// shape (a `$objects` array holding real bookmark blobs) and check we pull the folders back out.
    @Test func resolvesBookmarksOutOfAnArchive() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathem-fav-\(UUID().uuidString)")
        let a = root.appendingPathComponent("Alpha")
        let b = root.appendingPathComponent("Beta")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let archive: [String: Any] = [
            "$archiver": "NSKeyedArchiver",
            "$objects": [
                "$null",
                try a.bookmarkData(),
                "Alpha",
                try b.bookmarkData(),
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)

        let folders = FinderFavorites.folders(inArchive: data)
        let paths = folders.map(\.standardizedFileURL.path)
        #expect(paths.contains(a.standardizedFileURL.path))
        #expect(paths.contains(b.standardizedFileURL.path))
    }

    @Test func skipsFoldersThatNoLongerExist() throws {
        let fm = FileManager.default
        let gone = fm.temporaryDirectory.appendingPathComponent("pathem-gone-\(UUID().uuidString)")
        try fm.createDirectory(at: gone, withIntermediateDirectories: true)
        let bookmark = try gone.bookmarkData()
        try fm.removeItem(at: gone)  // the favorite now dangles, like an unplugged disk

        let archive: [String: Any] = ["$objects": ["$null", bookmark]]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        #expect(FinderFavorites.folders(inArchive: data).isEmpty)
    }

    @Test func ignoresGarbage() throws {
        #expect(FinderFavorites.folders(inArchive: Data("not a plist".utf8)).isEmpty)
        let noObjects = try PropertyListSerialization.data(
            fromPropertyList: ["$archiver": "NSKeyedArchiver"], format: .binary, options: 0)
        #expect(FinderFavorites.folders(inArchive: noObjects).isEmpty)
    }

    @Test func suggestsIconsMatchingTheDefaults() {
        let home = URL(fileURLWithPath: "/Users/x")
        #expect(Sidebar.suggestedIcon(for: home, home: home) == "house")
        #expect(Sidebar.suggestedIcon(for: home.appendingPathComponent("Downloads"), home: home) == "arrow.down.circle")
        #expect(Sidebar.suggestedIcon(for: URL(fileURLWithPath: "/Applications"), home: home) == "square.grid.2x2")
        #expect(Sidebar.suggestedIcon(for: home.appendingPathComponent("Whatever"), home: home) == "folder")
    }
}
