import Foundation
import Testing

@testable import PathemEngine

@Suite struct FilingDestinationsTests {
    @Test func defaultsDeriveUnderHome() {
        let home = URL(fileURLWithPath: "/fixture/home")
        let defaults = FilingDestinations.defaults(home: home)
        let documents = defaults.named("Documents")
        #expect(documents?.url.path == "/fixture/home/Documents")
        // Screenshots is a subfolder of Pictures, and the lookup is case-insensitive.
        #expect(defaults.named("screenshots")?.url.path == "/fixture/home/Pictures/Screenshots")
    }

    @Test func jsonRoundTrips() throws {
        let original = FilingDestinations(destinations: [
            .init(
                name: "Finance", url: URL(fileURLWithPath: "/fixture/home/Documents/Finance"),
                systemImage: "dollarsign"),
            .init(
                name: "Screenshots", url: URL(fileURLWithPath: "/fixture/home/Pictures/Screenshots")
            ),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FilingDestinations.self, from: data)
        #expect(decoded == original)
    }

    @Test func tolerantDecodeDoesNotThrow() throws {
        // An empty object and a malformed destinations value both decode to an empty set
        // rather than throwing (so one bad config file doesn't lose everything).
        let empty = try JSONDecoder().decode(FilingDestinations.self, from: Data("{}".utf8))
        #expect(empty.destinations.isEmpty)
        let garbage = try JSONDecoder().decode(
            FilingDestinations.self, from: Data(#"{"destinations": "nonsense"}"#.utf8))
        #expect(garbage.destinations.isEmpty)
    }
}
