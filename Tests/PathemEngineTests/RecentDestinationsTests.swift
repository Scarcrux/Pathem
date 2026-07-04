import Foundation
import Testing

@testable import PathemEngine

@Suite struct RecentDestinationsTests {
    @Test func prependsNewest() {
        var list: [String] = []
        list = RecentDestinations.recording("/a", into: list)
        list = RecentDestinations.recording("/b", into: list)
        #expect(list == ["/b", "/a"])
    }

    @Test func deduplicatesAndPromotes() {
        let list = RecentDestinations.recording("/a", into: ["/b", "/a", "/c"])
        #expect(list == ["/a", "/b", "/c"])  // /a moved to front, not duplicated
    }

    @Test func capsAtLimit() {
        var list: [String] = []
        for i in 0..<15 { list = RecentDestinations.recording("/d\(i)", into: list) }
        #expect(list.count == RecentDestinations.limit)
        #expect(list.first == "/d14")  // newest
        #expect(!list.contains("/d0"))  // oldest dropped
    }

    @Test func ignoresEmptyPath() {
        #expect(RecentDestinations.recording("", into: ["/a"]) == ["/a"])
    }
}
