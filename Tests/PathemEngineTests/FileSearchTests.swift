import Foundation
import Testing

@testable import PathemEngine

@Suite struct FileSearchTests {
    private func search(_ request: FileSearch.Request, limit: Int = 500) async
        -> FileSearch.Response
    {
        await FileSearch.search(request, limit: limit, indexedSearch: { _, _, _ in .init() })
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pathem-literal-search-\(UUID())")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "unrelated words".write(
            to: root.appendingPathComponent("Plants[1]*.txt"), atomically: true, encoding: .utf8)
        try "house PLANTS grow here".write(
            to: root.appendingPathComponent("neutral.txt"), atomically: true, encoding: .utf8)
        try "plants".write(
            to: root.appendingPathComponent("nested/plants.md"), atomically: true, encoding: .utf8)
        try Data([0] + Array("plants".utf8)).write(to: root.appendingPathComponent("binary.dat"))
        try "plants".write(
            to: root.appendingPathComponent(".hidden.txt"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func filenameAndContentsAreDifferentLiteralSearches() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = await search(
            .init(keyword: "plants", mode: .filename, scope: .folder(root, recursive: false)))
        #expect(names.urls.map(\.lastPathComponent) == ["Plants[1]*.txt"])
        let contents = await search(
            .init(keyword: "plants", mode: .contents, scope: .folder(root, recursive: false)))
        #expect(contents.urls.map(\.lastPathComponent) == ["neutral.txt"])
        let literal = await search(
            .init(keyword: "[1]*", mode: .filename, scope: .folder(root, recursive: true)))
        #expect(literal.urls.map(\.lastPathComponent) == ["Plants[1]*.txt"])
    }

    @Test func scopeAndRecursionDoNotLeak() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recursive = await search(
            .init(keyword: "plants", mode: .filename, scope: .folder(root, recursive: true)))
        #expect(Set(recursive.urls.map(\.lastPathComponent)) == ["Plants[1]*.txt", "plants.md"])
        let nested = await search(
            .init(
                keyword: "plants", mode: .filename,
                scope: .folder(root.appendingPathComponent("nested"), recursive: true)))
        #expect(nested.urls.map(\.lastPathComponent) == ["plants.md"])
        let blank = await search(
            .init(keyword: " \n ", mode: .contents, scope: .folder(root, recursive: true)))
        #expect(blank.urls.isEmpty && blank.error == nil)
    }

    @Test func reportsLimitsAndMissingRootInsteadOfPretendingNoMatches() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let limited = await search(
            .init(keyword: "plants", mode: .filename, scope: .folder(root, recursive: true)),
            limit: 1)
        #expect(limited.urls.count == 1 && limited.truncated)
        let missing = await search(
            .init(
                keyword: "plants", mode: .filename,
                scope: .folder(root.appendingPathComponent("absent"), recursive: true)))
        #expect(missing.urls.isEmpty && missing.error != nil)
    }

    @Test func doesNotFollowSymlinkCyclesOrReadOutsideScope() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("nested/loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.txt"),
            withDestinationURL: root.appendingPathComponent("neutral.txt"))
        let result = await search(
            .init(keyword: "plants", mode: .contents, scope: .folder(root, recursive: true)))
        #expect(result.urls.count == 2 && !result.truncated)
        #expect(!result.urls.contains { $0.lastPathComponent == "linked.txt" })
    }

    @Test func readsBeyondSnippetAndAcrossBufferBoundary() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("boundary.txt")
        try (String(repeating: "x", count: 65_534) + "PLANTS" + String(repeating: "x", count: 100))
            .write(to: url, atomically: true, encoding: .utf8)
        let result = await search(
            .init(keyword: "plants", mode: .contents, scope: .folder(root, recursive: false)))
        #expect(result.urls.contains(url))
    }

    @Test func wholeMacQueryChoosesAttributeAndEscapesUserInput() {
        let names = FileSearch.Request(keyword: "Plants", mode: .filename, scope: .mac)
        let contents = FileSearch.Request(keyword: "Plants", mode: .contents, scope: .mac)
        #expect(SpotlightSearch.fileSearchQuery(names) == "kMDItemFSName == \"*Plants*\"cd")
        #expect(SpotlightSearch.fileSearchQuery(contents) == "kMDItemTextContent == \"*Plants*\"cd")
        let literal = SpotlightSearch.fileSearchQuery(
            .init(keyword: "a*?\"\\b", mode: .filename, scope: .mac))
        #expect(literal == "kMDItemFSName == \"*a\\*\\?\\\"\\\\b*\"cd")
    }

    @Test func indexedDocumentMatchesAreMergedDeduplicatedAndConfined() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("indexed.pdf")
        let neutral = root.appendingPathComponent("neutral.txt")
        let child = root.appendingPathComponent("nested/indexed.pdf")
        let hidden = root.appendingPathComponent(".hidden.pdf")
        let outside = root.deletingLastPathComponent().appendingPathComponent("out-of-scope.pdf")
        let request = FileSearch.Request(
            keyword: "plants", mode: .contents, scope: .folder(root, recursive: false))
        let result = await FileSearch.search(
            request,
            indexedSearch: { _, scope, _ in
                #expect(scope == root)
                return .init(urls: [document, neutral, child, hidden, outside])
            })
        #expect(Set(result.urls) == [document, neutral])
        #expect(!result.indexedDocumentsUnavailable)
        let unavailable = await FileSearch.search(
            request, indexedSearch: { _, _, _ in .init(error: "index offline") })
        #expect(
            unavailable.urls == [neutral] && unavailable.error == nil
                && unavailable.indexedDocumentsUnavailable)
    }

    @Test func unicodeAndPunctuationRemainLiteralAcrossReadBoundaries() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "Résumé [draft]*?.txt"
        let url = root.appendingPathComponent(name)
        try (String(repeating: "x", count: 65_535) + "🐈 CAFÉ [draft]*?")
            .write(to: url, atomically: true, encoding: .utf8)
        let names = await search(
            .init(
                keyword: "resume [draft]*?", mode: .filename, scope: .folder(root, recursive: true))
        )
        #expect(names.urls == [url])
        let contents = await search(
            .init(
                keyword: "🐈 cafe [draft]*?", mode: .contents, scope: .folder(root, recursive: false)
            ))
        #expect(contents.urls == [url])
        let negative = await search(
            .init(keyword: "[draft].*", mode: .filename, scope: .folder(root, recursive: true)))
        #expect(negative.urls.isEmpty)
    }

    @Test func indexedResultsRespectPackageAndSymlinkAncestorBoundaries() async throws {
        let root = try fixture()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let packageFile = root.appendingPathComponent("Sample.app/Contents/plants.txt")
        try fm.createDirectory(
            at: packageFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "plants".write(to: packageFile, atomically: true, encoding: .utf8)
        let linkedFolder = root.appendingPathComponent("linked-folder")
        try fm.createSymbolicLink(
            at: linkedFolder, withDestinationURL: root.appendingPathComponent("nested"))
        let indexedLink = linkedFolder.appendingPathComponent("plants.md")
        let ordinary = root.appendingPathComponent("nested/plants.md")
        let request = FileSearch.Request(
            keyword: "plants", mode: .contents, scope: .folder(root, recursive: true))
        let scanned = await search(request)
        #expect(!scanned.urls.contains(packageFile) && !scanned.urls.contains(indexedLink))
        let indexed = await FileSearch.search(
            request,
            indexedSearch: { _, _, _ in .init(urls: [packageFile, indexedLink, ordinary]) })
        #expect(Set(indexed.urls) == Set(scanned.urls))
        // Explicitly selecting a package as the search root is allowed; only its
        // internals when encountered during another folder's traversal are excluded.
        let explicit = await search(
            .init(
                keyword: "plants", mode: .contents,
                scope: .folder(packageFile.deletingLastPathComponent(), recursive: true)))
        #expect(explicit.urls == [packageFile])
    }

    @Test func zeroLimitAndOversizeContentReportOmissions() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let zero = await search(
            .init(keyword: "plants", mode: .filename, scope: .folder(root, recursive: true)),
            limit: 0)
        #expect(zero.urls.isEmpty && zero.truncated)
        let url = root.appendingPathComponent("oversize.txt")
        let handle = FileManager.default.createFile(atPath: url.path, contents: nil)
        #expect(handle)
        let output = try FileHandle(forWritingTo: url)
        // Sparse fixture: no large allocation or user files, and the match is beyond the cap.
        try output.truncate(atOffset: 32 * 1024 * 1024 + 16)
        try output.seek(toOffset: 32 * 1024 * 1024 + 1)
        try output.write(contentsOf: Data("plants".utf8))
        try output.close()
        // Non-NUL padding exercises the byte cap rather than the binary-file rejection.
        let padded = root.appendingPathComponent("padded.txt")
        _ = FileManager.default.createFile(atPath: padded.path, contents: nil)
        let writer = try FileHandle(forWritingTo: padded)
        for _ in 0..<512 { try writer.write(contentsOf: Data(repeating: 120, count: 65_536)) }
        try writer.write(contentsOf: Data("plants".utf8))
        try writer.close()
        let response = await search(
            .init(keyword: "plants", mode: .contents, scope: .folder(root, recursive: false)))
        #expect(!response.urls.contains(url) && !response.urls.contains(padded))
        #expect(response.skipped == 1)
    }

    @Test func unreadableContentIsReportedNotSilentlyComplete() async throws {
        let root = try fixture()
        let fm = FileManager.default
        let secret = root.appendingPathComponent("unreadable.txt")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
            try? fm.removeItem(at: root)
        }
        try "plants".write(to: secret, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: secret.path)
        try #require(
            !fm.isReadableFile(atPath: secret.path),
            "Requires a non-root test process; unreadability must actually be delivered")
        let response = await search(
            .init(keyword: "plants", mode: .contents, scope: .folder(root, recursive: false)))
        #expect(response.urls.map(\.lastPathComponent) == ["neutral.txt"] && response.skipped == 1)
    }

    @Test func cancelledFolderSearchDoesNotPublishPartialMatches() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await search(
                .init(keyword: "plants", mode: .filename, scope: .folder(root, recursive: true)))
        }
        let response = await task.value
        #expect(response.urls.isEmpty && response.error == nil)
        // Uncancelled control proves the folder and keyword actually produce matches.
        let control = await search(
            .init(keyword: "plants", mode: .filename, scope: .folder(root, recursive: true)))
        #expect(control.urls.count == 2)
    }

    @Test func wholeMacEnforcesLimitEvenIfIndexIgnoresIt() async {
        let result = await FileSearch.search(
            .init(keyword: "plants", mode: .filename, scope: .mac), limit: 1,
            indexedSearch: { _, _, _ in
                .init(urls: [
                    URL(fileURLWithPath: "/fixture/b.txt"), URL(fileURLWithPath: "/fixture/a.txt"),
                ])
            })
        #expect(result.urls.map(\.lastPathComponent) == ["a.txt"] && result.truncated)
    }

    @Test func wholeMacInvokesIndexWithoutFolderScan() async {
        let result = await FileSearch.search(
            .init(keyword: "plants", mode: .filename, scope: .mac),
            indexedSearch: { request, scope, _ in
                #expect(request.mode == .filename && request.keyword == "plants" && scope == nil)
                return .init(urls: [URL(fileURLWithPath: "/fixture/plants.txt")])
            })
        #expect(result.urls.map(\.lastPathComponent) == ["plants.txt"])
    }
}
