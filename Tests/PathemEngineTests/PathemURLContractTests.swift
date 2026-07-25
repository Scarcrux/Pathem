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
        #expect(PathemURLContract.parse(URL(string: "pathem://reveal?path=../../etc")!) == nil)  // relative path rejected
        #expect(PathemURLContract.parse(URL(string: "pathem://reveal?path=relative.txt")!) == nil)  // relative path rejected
    }

    @Test func schemeAndVerbAreCaseInsensitive() throws {
        // LaunchServices may not preserve the case of the scheme/host; a case-varied URL must still
        // route rather than silently no-op.
        for raw in ["PATHEM://reveal?path=/x", "pathem://REVEAL?path=/x", "pathem://Reveal?path=/x"] {
            let parsed = try #require(PathemURLContract.parse(URL(string: raw)!))
            #expect(parsed.verb == .reveal)
            #expect(parsed.path == "/x")
        }
    }

    @Test func pathWithQueryReservedCharactersSurvives() throws {
        let tricky = "/Users/me/notes/a?b&c=d.txt"  // ? & = in the filename
        let url = try #require(PathemURLContract.url(verb: .reveal, path: tricky))
        let parsed = try #require(PathemURLContract.parse(url))
        #expect(parsed.path == tricky)
    }
}
