import Foundation
import Testing

@testable import PathomEngine

@Suite struct FolderFormatsTests {
    private let byDate = ViewFormat(sortKey: .date, ascending: false)
    private let bySize = ViewFormat(sortKey: .size, ascending: true)

    @Test func defaultWhenNoRules() {
        let formats = FolderFormats()
        #expect(formats.format(for: "/a/b") == .default)
    }

    @Test func exactBeatsSubtreeBeatsDefault() {
        var formats = FolderFormats()
        formats.setSubtree("/a", bySize)
        formats.setExact("/a/b", byDate)
        #expect(formats.format(for: "/a/b") == byDate)  // exact rule
        #expect(formats.format(for: "/a/c") == bySize)  // inherited from subtree
        #expect(formats.format(for: "/x") == .default)  // nothing matches
    }

    @Test func longestSubtreeWins() {
        var formats = FolderFormats()
        formats.setSubtree("/a", bySize)
        formats.setSubtree("/a/b", byDate)
        #expect(formats.format(for: "/a/b/c") == byDate)
        #expect(formats.format(for: "/a/x") == bySize)
    }

    @Test func subtreeMatchesItsRoot() {
        var formats = FolderFormats()
        formats.setSubtree("/a", bySize)
        #expect(formats.format(for: "/a") == bySize)
    }

    @Test func subtreePrefixDoesNotMatchSiblingByName() {
        var formats = FolderFormats()
        formats.setSubtree("/a", bySize)
        #expect(formats.format(for: "/ab") == .default)  // "/ab" is not under "/a"
    }

    @Test func setReplacesRatherThanDuplicating() {
        var formats = FolderFormats()
        formats.setExact("/a", bySize)
        formats.setExact("/a", byDate)
        #expect(formats.rules.filter { $0.scope == .exact && $0.path == "/a" }.count == 1)
        #expect(formats.format(for: "/a") == byDate)
    }

    @Test func codableRoundTrip() throws {
        var formats = FolderFormats()
        formats.setExact("/a", byDate)
        formats.setSubtree("/b", bySize)
        let data = try JSONEncoder().encode(formats)
        let restored = try JSONDecoder().decode(FolderFormats.self, from: data)
        #expect(restored.format(for: "/a") == byDate)
        #expect(restored.format(for: "/b/x") == bySize)
    }
}
