import Foundation
import Testing

@testable import PathemEngine

@Suite struct SFTPProviderTests {
    private let provider = SFTPProvider()

    @Test func quoteRejectsNewlinesInsteadOfMappingToAnotherPath() {
        // A newline can't be represented in the line-based batch protocol; stripping
        // it would silently target a different path, so quote() must throw.
        #expect(throws: RemoteError.self) { try provider.quote("a\nrm -rf b") }
        #expect(throws: RemoteError.self) { try provider.quote("a\rb") }
    }

    @Test func quoteEscapesQuotesBackslashAndGlobs() throws {
        #expect(try provider.quote("a\"b") == "\"a\\\"b\"")
        #expect(try provider.quote("a\\b") == "\"a\\\\b\"")
        // Glob metacharacters are backslash-escaped so a literal name still matches.
        #expect(try provider.quote("a*b?[c]") == "\"a\\*b\\?\\[c\\]\"")
    }

    @Test func cleanErrorDropsKnownHostWarning() {
        let raw = "Warning: Permanently added 'host' (ED25519) to the list of known hosts.\nPermission denied"
        #expect(provider.cleanError(raw) == "Permission denied")
    }
}
