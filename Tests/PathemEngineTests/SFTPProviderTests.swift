import Foundation
import Testing

@testable import PathemEngine

@Suite struct SFTPProviderTests {
    private let provider = SFTPProvider()

    @Test func quoteStripsNewlinesToPreventBatchInjection() {
        // A name with a newline must not become a second sftp batch command.
        let quoted = provider.quote("a\nrm -rf b")
        #expect(!quoted.contains("\n"))
        #expect(quoted == "\"arm -rf b\"")
    }

    @Test func quoteEscapesQuotesBackslashAndGlobs() {
        #expect(provider.quote("a\"b") == "\"a\\\"b\"")
        #expect(provider.quote("a\\b") == "\"a\\\\b\"")
        // Glob metacharacters are backslash-escaped so a literal name still matches.
        #expect(provider.quote("a*b?[c]") == "\"a\\*b\\?\\[c\\]\"")
    }

    @Test func cleanErrorDropsKnownHostWarning() {
        let raw = "Warning: Permanently added 'host' (ED25519) to the list of known hosts.\nPermission denied"
        #expect(provider.cleanError(raw) == "Permission denied")
    }
}
