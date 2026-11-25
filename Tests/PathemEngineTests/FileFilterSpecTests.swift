import Foundation
import Testing

@testable import PathemEngine

@Suite struct FileFilterSpecTests {
    // MARK: patterns and matching

    @Test func patternsSplitOnSemicolonsAndNewlines() {
        #expect(
            FileFilterSpec.splitPatterns(" *.jpg; *.PNG ;;\n draft* ") == [
                "*.jpg", "*.PNG", "draft*",
            ])
        #expect(FileFilterSpec.splitPatterns("  ").isEmpty)
    }

    private func m(
        _ spec: FileFilterSpec, _ name: String, rel: String? = nil, dir: Bool = false,
        size: Int64 = 10, modified: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Bool {
        spec.matches(
            name: name, relativePath: rel ?? name, isDirectory: dir, size: size, modified: modified)
    }

    @Test func includeAndExcludeGlobsAreCaseInsensitive() {
        let spec = FileFilterSpec(
            includePatterns: ["*.jpg", "img_?.png"], excludePatterns: ["*-draft.*"])
        #expect(m(spec, "Photo.JPG"))
        #expect(m(spec, "IMG_1.png"))
        #expect(!m(spec, "IMG_12.png"))
        #expect(!m(spec, "photo-draft.jpg"))
        #expect(!m(spec, "notes.txt"))
        #expect(m(FileFilterSpec(), "anything.bin"))
    }

    @Test func aGlobWithASlashMatchesTheRelativePath() {
        let spec = FileFilterSpec(includePatterns: ["Photos/2024/*"])
        #expect(m(spec, "a.jpg", rel: "Photos/2024/a.jpg"))
        #expect(!m(spec, "a.jpg", rel: "Photos/2023/a.jpg"))
    }

    @Test func kindsKeepOnlyTheChosenOnes() {
        let spec = FileFilterSpec(kinds: [.image, .video])
        #expect(m(spec, "a.heic"))
        #expect(m(spec, "b.MOV"))
        #expect(!m(spec, "c.pdf"))
        #expect(!m(spec, "folder", dir: true))
        #expect(m(FileFilterSpec(kinds: [.folder]), "folder", dir: true))
    }

    @Test func sizeBoundsAreInclusiveAndSkipFolders() {
        let spec = FileFilterSpec(minBytes: 100, maxBytes: 200)
        #expect(m(spec, "a", size: 100))
        #expect(m(spec, "a", size: 200))
        #expect(!m(spec, "a", size: 99))
        #expect(!m(spec, "a", size: 201))
        #expect(m(spec, "dir", dir: true, size: 0))
    }

    @Test func dateBoundsAreInclusiveAndRejectUndatedItems() {
        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let spec = FileFilterSpec(modifiedAfter: base, modifiedBefore: base.addingTimeInterval(day))
        #expect(m(spec, "a", modified: base))
        #expect(m(spec, "a", modified: base.addingTimeInterval(day)))
        #expect(!m(spec, "a", modified: base.addingTimeInterval(-1)))
        #expect(!m(spec, "a", modified: base.addingTimeInterval(day + 1)))
        #expect(!m(spec, "a", modified: nil))
    }

    @Test func specRoundTripsAndOldFiltersDecodeWithDefaults() throws {
        let spec = FileFilterSpec(
            includePatterns: ["*.pdf"], excludePatterns: ["tmp*"], kinds: [.document, .image],
            minBytes: 5, maxBytes: 9, modifiedAfter: Date(timeIntervalSince1970: 100),
            recurse: false, keepStructure: false, includeHidden: true)
        let data = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(FileFilterSpec.self, from: data) == spec)
        let old = try JSONDecoder().decode(
            FileFilterSpec.self, from: Data(#"{"includePatterns":["*.txt"]}"#.utf8))
        #expect(old.includePatterns == ["*.txt"])
        #expect(old.recurse && old.keepStructure && !old.includeHidden && old.kinds.isEmpty)
    }

    // MARK: enumeration (real files)

    /// root/Photos/{a.jpg 100B, b.png 50B, 2024/c.jpg 300B, 2024/notes.txt, .cache/d.jpg}, root/loose.jpg, root/node_modules/x.jpg
    private func tree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("filterspec-\(UUID().uuidString)")
        func put(_ path: String, _ bytes: Int) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url)
        }
        try put("Photos/a.jpg", 100)
        try put("Photos/b.png", 50)
        try put("Photos/2024/c.jpg", 300)
        try put("Photos/2024/notes.txt", 7)
        try put("Photos/.cache/d.jpg", 9)
        try put("loose.jpg", 20)
        try put("node_modules/x.jpg", 5)
        return root
    }

    private func names(_ r: FileFilterEnumerator.Result) -> [String] {
        r.matches.map(\.relativePath).sorted()
    }

    @Test func recursingASelectedFolderFindsMatchesWithRelativePaths() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let spec = FileFilterSpec(includePatterns: ["*.jpg"])
        let r = FileFilterEnumerator.run(
            spec,
            sources: [
                root.appendingPathComponent("Photos"), root.appendingPathComponent("loose.jpg"),
            ])
        #expect(names(r) == ["Photos/2024/c.jpg", "Photos/a.jpg", "loose.jpg"])  // .cache skipped (hidden)
        #expect(r.totalBytes == 420)
        #expect(!r.truncated && !r.cancelled)
    }

    @Test func hiddenEntriesAreIncludedOnlyOnRequest() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        var spec = FileFilterSpec(includePatterns: ["*.jpg"], includeHidden: true)
        let r = FileFilterEnumerator.run(spec, sources: [root.appendingPathComponent("Photos")])
        #expect(names(r).contains("Photos/.cache/d.jpg"))
        spec.includeHidden = false
        #expect(
            !names(FileFilterEnumerator.run(spec, sources: [root.appendingPathComponent("Photos")]))
                .contains("Photos/.cache/d.jpg"))
    }

    @Test func notRecursingTestsAFolderAsOneItem() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Photos")
        // Not recursing: the folder is an item; its name does not match *.jpg, so nothing matches.
        var spec = FileFilterSpec(includePatterns: ["*.jpg"], recurse: false)
        #expect(FileFilterEnumerator.run(spec, sources: [photos]).matches.isEmpty)
        spec = FileFilterSpec(includePatterns: ["Photos"], recurse: false)
        let r = FileFilterEnumerator.run(spec, sources: [photos])
        #expect(r.matches.count == 1 && r.folderCount == 1 && r.fileCount == 0)
    }

    @Test func anExcludedFolderIsNotEntered() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let spec = FileFilterSpec(
            includePatterns: ["*.jpg"], excludePatterns: ["node_modules", "2024"])
        let r = FileFilterEnumerator.run(spec, sources: [root])
        #expect(
            names(r).sorted() == [
                root.lastPathComponent + "/Photos/a.jpg", root.lastPathComponent + "/loose.jpg",
            ])
    }

    @Test func sizeAndKindFiltersApplyDuringTheWalk() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let spec = FileFilterSpec(kinds: [.image], minBytes: 60)
        let r = FileFilterEnumerator.run(spec, sources: [root.appendingPathComponent("Photos")])
        #expect(names(r) == ["Photos/2024/c.jpg", "Photos/a.jpg"])
    }

    @Test func aMatchedFolderIsTakenWholeAndNotDescended() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let spec = FileFilterSpec(includePatterns: ["2024"], kinds: [.folder])
        let r = FileFilterEnumerator.run(spec, sources: [root.appendingPathComponent("Photos")])
        #expect(names(r) == ["Photos/2024"])
        #expect(r.folderCount == 1)
    }

    @Test func theWalkStopsAtTheVisitCapAndReportsIt() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = FileFilterEnumerator.run(FileFilterSpec(), sources: [root], maxVisited: 3)
        #expect(r.truncated)
        #expect(r.visited <= 4)
        let capped = FileFilterEnumerator.run(FileFilterSpec(), sources: [root], maxMatches: 2)
        #expect(capped.truncated && capped.matches.count == 2)
    }

    @Test func theWalkIsCancellable() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let r = FileFilterEnumerator.run(FileFilterSpec(), sources: [root]) {
            calls += 1
            return calls > 2
        }
        #expect(r.cancelled)
        #expect(r.matches.count < 6)
        let immediate = FileFilterEnumerator.run(FileFilterSpec(), sources: [root]) { true }
        #expect(immediate.cancelled && immediate.matches.isEmpty)
    }

    @Test func aSymlinkToAFolderIsAFileNotAWalk() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: root.appendingPathComponent("Photos"))
        let r = FileFilterEnumerator.run(FileFilterSpec(), sources: [link])
        #expect(r.matches.count == 1 && r.folderCount == 0)
    }

    // MARK: destination mapping

    private func match(_ rel: String, under root: String = "/src") -> FileFilterEnumerator.Match {
        .init(
            url: URL(fileURLWithPath: root + "/" + rel), relativePath: rel, size: 1,
            isDirectory: false)
    }

    @Test func keepStructureGroupsByRelativeFolderAndCreatesNothingElse() {
        let dest = URL(fileURLWithPath: "/dst")
        let groups = FileFilterPlan.groups(
            for: [
                match("Photos/a.jpg"), match("Photos/2024/c.jpg"), match("Photos/2024/d.jpg"),
                match("loose.jpg"),
            ],
            into: dest, keepStructure: true)
        #expect(groups.map(\.directory.path) == ["/dst/Photos", "/dst/Photos/2024", "/dst"])
        #expect(groups[1].urls.map(\.lastPathComponent) == ["c.jpg", "d.jpg"])
        #expect(groups.allSatisfy { !$0.keepBoth })
    }

    @Test func flatPlacementPutsEverythingInOneFolderAndLayersNameClashes() {
        let dest = URL(fileURLWithPath: "/dst")
        let groups = FileFilterPlan.groups(
            for: [match("A/x.txt"), match("B/x.txt"), match("B/y.txt"), match("C/X.TXT")],
            into: dest, keepStructure: false)
        #expect(groups.count == 3)
        #expect(groups.allSatisfy { $0.directory == dest })
        #expect(
            groups[0].urls.map(\.path) == ["/src/A/x.txt", "/src/B/y.txt"] && !groups[0].keepBoth)
        #expect(groups[1].urls.map(\.path) == ["/src/B/x.txt"] && groups[1].keepBoth)
        #expect(groups[2].urls.map(\.path) == ["/src/C/X.TXT"] && groups[2].keepBoth)
        #expect(FileFilterPlan.groups(for: [], into: dest, keepStructure: true).isEmpty)
    }

    // MARK: presets

    @Test func presetsSaveReplaceAndRemoveByCaseInsensitiveName() throws {
        var presets = FileFilterPresets()
        presets.save(FileFilterSpec(includePatterns: ["*.pdf"]), as: " PDFs ")
        presets.save(FileFilterSpec(includePatterns: ["*.png"]), as: "pdfs")
        #expect(presets.presets.count == 1 && presets.presets[0].spec.includePatterns == ["*.png"])
        presets.save(FileFilterSpec(), as: "   ")
        #expect(presets.presets.count == 1)
        presets.last = FileFilterSpec(minBytes: 3)
        let round = try JSONDecoder().decode(
            FileFilterPresets.self, from: JSONEncoder().encode(presets))
        #expect(round == presets)
        presets.remove("PDFS")
        #expect(presets.presets.isEmpty)
    }
}
