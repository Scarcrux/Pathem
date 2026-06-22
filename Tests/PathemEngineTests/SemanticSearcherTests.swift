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
        if let aPos = ranked.firstIndex(of: "a.txt"), let bPos = ranked.firstIndex(of: "b.txt") {
            #expect(aPos < bPos)  // the cat-content file ranks above the car-content file
        }
    }
}
