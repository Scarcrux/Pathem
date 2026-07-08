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

    @Test func contentAndTagClauses() throws {
        let search = SavedSearch(name: "x", contentContains: "invoice", tag: "Red")
        let query = search.mdfindQuery()
        #expect(query.contains("kMDItemTextContent == \"*invoice*\"cd"))
        #expect(query.contains("kMDItemUserTags == \"Red\"c"))
        #expect(query.contains(" && "))
        // Round-trips (and an older searches.json without these keys still decodes).
        let back = try JSONDecoder().decode(SavedSearch.self, from: JSONEncoder().encode(search))
        #expect(back.contentContains == "invoice" && back.tag == "Red")
    }

    @Test func defaultsAndTolerantDecode() throws {
        #expect(SavedSearches.default.searches.contains { $0.name == "Screenshots" })
        let set = try JSONDecoder().decode(SavedSearches.self, from: Data("{}".utf8))
        #expect(set.searches.isEmpty)
    }
}
