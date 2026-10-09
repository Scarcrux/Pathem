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
