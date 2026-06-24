import Foundation
import Testing

@testable import PathemEngine

@Suite struct SemanticSearcherTests {
    /// Content-aware ranking: files with neutral NAMES ("a.txt"/"b.txt") but
    /// distinguishing CONTENTS should rank by meaning of the content. Skips
    /// gracefully if the on-device model asset isn't present.
    @Test func ranksByContentNotJustName() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-search-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try "cats kittens felines pets purring".write(
            to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "automobiles engines cars vehicles driving".write(
            to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let entries = (try? BulkEnumerator().entries(of: dir, includingHidden: false)) ?? []
        let index = SemanticSearcher.index(entries, in: dir)
        guard !index.isEmpty else { return }  // model asset unavailable; skip

        let order = SemanticSearcher.rank(query: "kitten", in: index)
        let ranked = order.compactMap { $0 < entries.count ? entries[$0].name : nil }
        // Required, not conditional: once the model is present both files must rank,
        // so a regression that drops one fails loudly instead of passing vacuously.
        let aPos = try #require(ranked.firstIndex(of: "a.txt"))
        let bPos = try #require(ranked.firstIndex(of: "b.txt"))
        #expect(aPos < bPos)  // the cat-content file ranks above the car-content file
    }

    /// A toy embedder so the index/rank pipeline is asserted deterministically,
    /// independent of whether the on-device NL model asset is present.
    private struct StubEmbedder: TextEmbedder {
        var dimension: Int { 2 }
        func embed(_ text: String) -> [Float]? {
            let lower = text.lowercased()
            let cat: Float = (lower.contains("cat") || lower.contains("kitten")) ? 1 : 0
            let car: Float = (lower.contains("car") || lower.contains("engine")) ? 1 : 0
            return [cat, car]
        }
    }

    @Test func rankAndIndexAreContentAwareWithInjectedEmbedder() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathem-stubsearch-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try "cat kitten purring".write(
            to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "car engine driving".write(
            to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let entries = (try? BulkEnumerator().entries(of: dir, includingHidden: false)) ?? []
        let stub = StubEmbedder()
        let index = SemanticSearcher.index(entries, in: dir, embedder: stub)
        #expect(!index.isEmpty)  // always builds with the stub (dimension > 0)

        let order = SemanticSearcher.rank(query: "kitten", in: index, embedder: stub)
        let ranked = order.compactMap { $0 < entries.count ? entries[$0].name : nil }
        #expect(ranked.first == "a.txt")  // cat-content ranks above car-content for "kitten"
    }
}
