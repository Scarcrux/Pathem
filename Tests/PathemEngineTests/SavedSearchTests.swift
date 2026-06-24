import Foundation
import Testing

@testable import PathemEngine

@Suite struct SavedSearchTests {
    @Test func buildsCombinedPredicate() {
        let search = SavedSearch(
            name: "x", nameContains: "report", minSizeBytes: 1000, modifiedWithinDays: 7,
            contentType: "public.image")
        let query = search.mdfindQuery()
        #expect(query.contains("kMDItemFSName == \"*report*\"c"))
        #expect(query.contains("kMDItemFSSize > 1000"))
        #expect(query.contains("kMDItemFSContentChangeDate >= $time.now(-604800)"))
        #expect(query.contains("kMDItemContentTypeTree == \"public.image\""))
        #expect(query.contains(" && "))
    }

    @Test func emptyCriteriaIsEmptyQuery() {
        #expect(SavedSearch(name: "x").mdfindQuery().isEmpty)
    }

    @Test func defaultsAndTolerantDecode() throws {
        #expect(SavedSearches.default.searches.contains { $0.name == "Screenshots" })
        let set = try JSONDecoder().decode(SavedSearches.self, from: Data("{}".utf8))
        #expect(set.searches.isEmpty)
    }
}
