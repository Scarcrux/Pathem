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
            creationDate: Date(timeIntervalSince1970: 300),
            accessDate: Date(timeIntervalSince1970: 100))
        let b = FileEntry(
            name: "b", isDirectory: false, size: 0, modificationDate: nil,
            creationDate: Date(timeIntervalSince1970: 100),
            accessDate: Date(timeIntervalSince1970: 300))
        let byCreated = ViewFormat(sortKey: .dateCreated, ascending: true, foldersFirst: false)
            .sorted([a, b])
        #expect(byCreated.map(\.name) == ["b", "a"])  // b created earlier
        let byAccessed = ViewFormat(sortKey: .dateAccessed, ascending: true, foldersFirst: false)
            .sorted([a, b])
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
        let input = [
            entry("new", seconds: 300), entry("old", seconds: 100), entry("mid", seconds: 200),
        ]
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
        let format = ViewFormat(
            sortKey: .date, ascending: false, showHidden: true, foldersFirst: false)
        let data = try JSONEncoder().encode(format)
        #expect(try JSONDecoder().decode(ViewFormat.self, from: data) == format)
    }

    @Test func finderKeysHaveStableOrderAndLegacyRawValues() throws {
        #expect(
            ViewFormat.SortKey.allCases.map(\.rawValue) == [
                "name", "kind", "dateAccessed", "dateAdded", "date", "dateCreated", "size", "tags",
                "dimensions", "dateTaken", "camera", "duration", "artist", "album", "pages",
                "codec",
                "bitRate",
            ])
        #expect(
            ViewFormat.GroupKey.allCases.map(\.rawValue) == [
                "none", "name", "kind", "application", "dateAccessed", "dateAdded", "dateModified",
                "dateCreated", "size", "tag",
            ])
        for raw in ["name", "size", "date", "dateCreated", "dateAccessed"] {
            let json = "{\"sortKey\":\"\(raw)\"}"
            let format = try JSONDecoder().decode(ViewFormat.self, from: Data(json.utf8))
            #expect(format.sortKey.rawValue == raw)
        }
        for raw in ["none", "kind", "size", "dateModified", "tag"] {
            let json = "{\"groupKey\":\"\(raw)\"}"
            let format = try JSONDecoder().decode(ViewFormat.self, from: Data(json.utf8))
            #expect(format.groupKey.rawValue == raw)
        }
        for sort in ViewFormat.SortKey.allCases {
            for group in ViewFormat.GroupKey.allCases {
                let format = ViewFormat(sortKey: sort, groupKey: group)
                #expect(
                    try JSONDecoder().decode(ViewFormat.self, from: JSONEncoder().encode(format))
                        == format)
            }
        }
    }

    @Test func finderSortsUsePreparedValuesWithAscendingNameTiesInEitherDirection() {
        let cases: [(ViewFormat.SortKey, FileViewMetadata, FileViewMetadata)] = [
            (.kind, FileViewMetadata(kind: "Archive"), FileViewMetadata(kind: "Text")),
            (
                .dateAdded, FileViewMetadata(dateAdded: Date(timeIntervalSince1970: 100)),
                FileViewMetadata(dateAdded: Date(timeIntervalSince1970: 300))
            ),
            (
                .tags, FileViewMetadata(tagNames: ["Client Alpha"]),
                FileViewMetadata(tagNames: ["Project Zebra"])
            ),
        ]
        for (key, earlier, later) in cases {
            var first = entry("z-first")
            first.viewMetadata = earlier
            var tieB = entry("b-tie")
            tieB.viewMetadata = later
            var tieA = entry("a-tie")
            tieA.viewMetadata = later
            var folder = entry("Folder", dir: true)
            folder.viewMetadata = later
            let input = [tieB, first, folder, tieA]
            #expect(
                ViewFormat(sortKey: key).sorted(input).map(\.name) == [
                    "Folder", "z-first", "a-tie", "b-tie",
                ])
            #expect(
                ViewFormat(sortKey: key, ascending: false).sorted(input).map(\.name) == [
                    "Folder", "a-tie", "b-tie", "z-first",
                ])
            #expect(
                ViewFormat(sortKey: key, foldersFirst: false).sorted(input).first?.name == "z-first"
            )
        }
    }

    @Test func tagSortUsesAllNamedTagsInCanonicalOrder() {
        var untagged = entry("z-untagged")
        untagged.viewMetadata = FileViewMetadata()
        var first = entry("y-first")
        first.viewMetadata = FileViewMetadata(tagNames: ["Work", "Client Alpha", "Work"])
        var second = entry("x-second")
        second.viewMetadata = FileViewMetadata(tagNames: ["Client Alpha", "Zebra"])
        var prefix = entry("w-prefix")
        prefix.viewMetadata = FileViewMetadata(tagNames: ["Client Alpha"])
        let input = [second, untagged, first, prefix]
        #expect(
            ViewFormat(sortKey: .tags).sorted(input).map(\.name) == [
                "z-untagged", "w-prefix", "y-first", "x-second",
            ])
        #expect(
            ViewFormat(sortKey: .tags, ascending: false).sorted(input).map(\.name) == [
                "x-second", "y-first", "w-prefix", "z-untagged",
            ])
        #expect(first.viewMetadata?.tagNames == ["Client Alpha", "Work"])
    }

    @Test func gatheredUnknownLastOpenedDoesNotMasqueradeAsFilesystemAccess() {
        var unknown = FileEntry(
            name: "unknown", isDirectory: false, size: 0, modificationDate: nil,
            accessDate: Date(timeIntervalSince1970: 999))
        unknown.viewMetadata = FileViewMetadata()
        var opened = entry("opened")
        opened.viewMetadata = FileViewMetadata(lastOpenedDate: Date(timeIntervalSince1970: 100))
        #expect(
            ViewFormat(sortKey: .dateAccessed).sorted([opened, unknown]).map(\.name) == [
                "unknown", "opened",
            ])
        #expect(
            ViewFormat(sortKey: .dateAccessed, ascending: false).sorted([unknown, opened]).map(
                \.name) == ["opened", "unknown"])
    }

    @Test func metadataRequirementsAreMinimalAndUnionSortWithGroup() {
        for sort in [ViewFormat.SortKey.name, .size, .date, .dateCreated] {
            for group in [ViewFormat.GroupKey.none, .name, .size, .dateModified, .dateCreated] {
                #expect(ViewFormat(sortKey: sort, groupKey: group).metadataRequirements.isEmpty)
            }
        }
        #expect(ViewFormat(sortKey: .kind, groupKey: .tag).metadataRequirements == [.kind, .tags])
        #expect(
            ViewFormat(sortKey: .dateAccessed, groupKey: .application).metadataRequirements == [
                .lastOpened, .application,
            ])
        #expect(
            ViewFormat(sortKey: .tags, groupKey: .dateAdded).metadataRequirements == [
                .tags, .dateAdded,
            ])
        #expect(ViewFormat(groupKey: .dateAccessed).metadataRequirements == .lastOpened)
        #expect(ViewFormat(groupKey: .kind).metadataRequirements == .kind)
        #expect(ViewFormat(sortKey: .dateAdded).metadataRequirements == .dateAdded)
    }
}
