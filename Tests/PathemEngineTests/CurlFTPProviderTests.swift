import Foundation
import Testing

@testable import PathemEngine

@Suite struct CurlFTPProviderTests {
    private let provider = CurlFTPProvider()
    private func conn(host: String = "ftp.example.com", user: String = "alice", port: Int = 0) -> RemoteConnection {
        RemoteConnection(name: "x", proto: .ftp, host: host, port: port, user: user)
    }

    @Test func credentialsEscapeControlCharsToPreventInjection() {
        // A newline in the password must not start a second curl config directive.
        let line = CurlFTPProvider.credentials(conn(user: "alice"), "p\nupload evil")
        #expect(!line.dropLast().contains("\n"))  // only the single trailing newline
        #expect(line == "user \"alice:p\\nupload evil\"\n")
    }

    @Test func credentialsEscapeQuotesBackslashAndTabs() {
        #expect(CurlFTPProvider.credentials(conn(user: "a\"b"), "c\\d\te") == "user \"a\\\"b:c\\\\d\\te\"\n")
    }

    @Test func emptyUserBecomesAnonymous() {
        #expect(CurlFTPProvider.credentials(conn(user: ""), "pw") == "user \"anonymous:pw\"\n")
    }

    @Test func endpointPercentEncodesPathSegments() {
        let url = provider.endpoint(conn(), "/a b/c#d?/e")
        #expect(url == "ftp://ftp.example.com:21/a%20b/c%23d%3F/e")  // spaces/#/? encoded, slashes kept
    }

    @Test func endpointUsesEffectivePort() {
        #expect(provider.endpoint(conn(port: 2121), "/x").hasPrefix("ftp://ftp.example.com:2121/"))
    }
}
