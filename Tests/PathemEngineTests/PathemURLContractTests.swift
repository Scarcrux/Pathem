import Foundation
import Testing

@testable import PathemEngine

/// The `pathem://` seam that the CLI and the app both speak must round-trip and reject junk.
@Suite struct PathemURLContractTests {
    @Test func buildsAndParsesEachVerb() throws {
        for verb in [PathemURLContract.Verb.open, .reveal] {
            let url = try #require(PathemURLContract.url(verb: verb, path: "/Users/me/a folder/file.txt"))
            #expect(url.scheme == "pathem")
            let parsed = try #require(PathemURLContract.parse(url))
            #expect(parsed.verb == verb)
            #expect(parsed.path == "/Users/me/a folder/file.txt")  // spaces survive the round-trip
        }
    }

    @Test func rejectsNonPathemOrMalformedURLs() {
        #expect(PathemURLContract.parse(URL(string: "https://pathem.app/reveal?path=/x")!) == nil)  // wrong scheme
        #expect(PathemURLContract.parse(URL(string: "pathem://open")!) == nil)  // no path
        #expect(PathemURLContract.parse(URL(string: "pathem://open?path=")!) == nil)  // empty path
        #expect(PathemURLContract.parse(URL(string: "pathem://frobnicate?path=/x")!) == nil)  // unknown verb
    }

    @Test func pathWithQueryReservedCharactersSurvives() throws {
        let tricky = "/Users/me/notes/a?b&c=d.txt"  // ? & = in the filename
        let url = try #require(PathemURLContract.url(verb: .reveal, path: tricky))
        let parsed = try #require(PathemURLContract.parse(url))
        #expect(parsed.path == tricky)
    }
}
