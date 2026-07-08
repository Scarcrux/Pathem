import Foundation
import Testing

@testable import PathemEngine

@Suite struct SpotlightSearchTests {
    @Test func tagQueryEscapesAndIsCaseInsensitive() {
        #expect(SpotlightSearch.tagQuery("Red") == "kMDItemUserTags == \"Red\"c")
        #expect(SpotlightSearch.tagQuery("a\"b\\c") == "kMDItemUserTags == \"a\\\"b\\\\c\"c")
    }

    @Test func recentQueryUsesSeconds() {
        #expect(SpotlightSearch.recentQuery(days: 1) == "kMDItemFSContentChangeDate >= $time.now(-86400)")
        #expect(SpotlightSearch.recentQuery(days: 0) == "kMDItemFSContentChangeDate >= $time.now(-86400)")
    }

    @Test func filenameQueryMatchesSubstringCaseInsensitively() {
        #expect(SpotlightSearch.filenameQuery("Report") == "kMDItemFSName == \"*Report*\"c")
        #expect(SpotlightSearch.filenameQuery("  ") == "")  // blank -> no query
        #expect(SpotlightSearch.filenameQuery("a\"b") == "kMDItemFSName == \"*a\\\"b*\"c")
    }
}
