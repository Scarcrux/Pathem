import Foundation
import Testing

@testable import PathemEngine

// Adversarial coverage for the remote backends' injection guards. Each backend builds a
// curl / sftp command from user-controlled strings (bucket, key, filename, user, secret);
// these tests feed hostile inputs and assert the guard contains them. They exist so a
// future refactor can't silently reopen an injection the comments claim is closed.

@Suite struct S3SecurityTests {
    private func conn(user: String = "AKIAEXAMPLE", host: String = "s3.example.com", region: String = "us-east-1")
        -> RemoteConnection
    {
        RemoteConnection(name: "s3", proto: .s3, host: host, user: user, region: region)
    }

    @Test func secretCannotBreakOutOfTheCurlConfig() {
        // A secret carrying a quote + newline + a would-be curl option must stay inside the
        // quoted `user "..."` value: the only raw newline is the trailing line terminator.
        let evil = "sk\"\ninsecure\n-d @/etc/passwd"
        let creds = S3Provider.credentials(conn(user: "ak\"id"), evil)
        #expect(creds.hasSuffix("\"\n"))
        #expect(creds.filter { $0 == "\n" }.count == 1)  // no injected extra config line
        #expect(creds.contains("\\\""))  // the quote was escaped
        #expect(creds.contains("\\n"))  // the newline became the literal escape, not a break
        #expect(!creds.contains("\n-d"))  // the option never starts a fresh line
    }

    @Test func queryValuesAreEncoded() {
        // A prefix/token can't smuggle extra query parameters into ListObjectsV2.
        let q = S3Provider.q("a&evil=1?x")
        #expect(!q.contains("&"))
        #expect(!q.contains("="))
        #expect(!q.contains("?"))
        #expect(q.contains("%26") && q.contains("%3D") && q.contains("%3F"))
    }

    @Test func pathSegmentsAreEncoded() {
        #expect(S3Provider.seg("my bucket?x").contains("%20"))
        #expect(S3Provider.seg("my bucket?x").contains("%3F"))
        // encodeKey keeps "/" separators but encodes each segment.
        let key = S3Provider.encodeKey("a b/c?d")
        #expect(key == "a%20b/c%3Fd")
    }

    @Test func regionIsAllowlisted() {
        #expect(S3Provider.regionIsValid("us-east-1"))
        #expect(S3Provider.regionIsValid(""))  // empty defaults to us-east-1 later
        #expect(!S3Provider.regionIsValid("us-east-1;rm -rf /"))  // space + ;
        #expect(!S3Provider.regionIsValid("a:b"))  // ":" would split the --aws-sigv4 arg
        #expect(!S3Provider.regionIsValid("a b"))
    }

    @Test func splitBucketAndKey() {
        #expect(S3Provider.split("/bucket/key/deep") == ("bucket", "key/deep"))
        #expect(S3Provider.split("bucket") == ("bucket", ""))
        #expect(S3Provider.split("/bucket/") == ("bucket", ""))
        #expect(S3Provider.split("") == ("", ""))
        #expect(S3Provider.split("/") == ("", ""))
    }

    @Test func hostDefaultsFromRegion() {
        #expect(S3Provider.host(conn(host: "", region: "eu-west-2")) == "s3.eu-west-2.amazonaws.com")
        #expect(S3Provider.host(conn(host: "minio.local", region: "")) == "minio.local")
    }
}

@Suite struct WebDAVSecurityTests {
    private let provider = CurlWebDAVProvider()
    private func conn(host: String = "dav.example.com") -> RemoteConnection {
        RemoteConnection(name: "dav", proto: .webdavs, host: host, user: "u")
    }

    @Test func destinationHeaderCannotBeInjected() {
        // rename() puts endpoint(to) into a `Destination:` header. A filename with CRLF must
        // be percent-encoded so it can't terminate the header and inject a new one.
        let url = provider.endpoint(conn(), "/dir/evil\r\nX-Injected: 1/leaf")
        #expect(!url.contains("\r"))
        #expect(!url.contains("\n"))
        #expect(url.contains("%0D%0A"))
        #expect(!url.contains("X-Injected: 1"))  // present only in encoded form
    }

    @Test func endpointEncodesEachSegment() {
        let url = provider.endpoint(conn(), "/a b/c?d#e")
        #expect(url.hasPrefix("https://dav.example.com"))
        #expect(url.contains("/a%20b/"))  // "/" separators preserved, space encoded
        #expect(url.contains("%3F") && url.contains("%23"))  // ? and # encoded, not URL-structural
    }

    @Test func secretCannotBreakOutOfTheCurlConfig() {
        let creds = CurlWebDAVProvider.credentials(conn(), "p\"\n-d evil")
        #expect(creds.hasSuffix("\"\n"))
        #expect(creds.filter { $0 == "\n" }.count == 1)
        #expect(!creds.contains("\n-d"))
    }

    @Test func emptyUserMeansNoCredentials() {
        let c = RemoteConnection(name: "dav", proto: .webdav, host: "h", user: "")
        #expect(CurlWebDAVProvider.credentials(c, "ignored").isEmpty)
    }
}

@Suite struct SFTPSecurityTests {
    private let provider = SFTPProvider()

    @Test func quoteEscapesShellAndGlobMetacharacters() throws {
        #expect(try provider.quote("normal") == "\"normal\"")
        #expect(try provider.quote("a\"b") == "\"a\\\"b\"")  // quote escaped
        #expect(try provider.quote("a\\b") == "\"a\\\\b\"")  // backslash escaped
        let glob = try provider.quote("a*b?[c]")
        #expect(glob == "\"a\\*b\\?\\[c\\]\"")  // globs escaped so they stay literal
    }

    @Test func quoteRejectsUnrepresentableCharacters() {
        // The sftp batch protocol is line-based; a newline/CR/NUL would map to a DIFFERENT
        // path if silently stripped, so it must be rejected outright.
        #expect(throws: RemoteError.self) { try provider.quote("a\nb") }
        #expect(throws: RemoteError.self) { try provider.quote("a\rb") }
        #expect(throws: RemoteError.self) { try provider.quote("a\u{0}b") }
    }

    @Test func usernameCannotSmuggleAnSSHOption() {
        #expect(RemoteConnection.isValidUser(""))  // anonymous
        #expect(RemoteConnection.isValidUser("root"))
        #expect(RemoteConnection.isValidUser("a.b_c-d"))
        #expect(!RemoteConnection.isValidUser("-oProxyCommand=touch /tmp/pwned"))  // leading -
        #expect(!RemoteConnection.isValidUser("a@b"))  // would split the user@host token
        #expect(!RemoteConnection.isValidUser("a b"))  // whitespace
        #expect(!RemoteConnection.isValidUser("a;b"))
        #expect(!RemoteConnection.isValidUser(String(repeating: "x", count: 65)))  // too long
    }

    @Test func hostIsAllowlisted() {
        #expect(RemoteConnection.isValidHost("example.com"))
        #expect(RemoteConnection.isValidHost("[::1]"))  // bracketed IPv6
        #expect(!RemoteConnection.isValidHost(""))
        #expect(!RemoteConnection.isValidHost("a b"))
        #expect(!RemoteConnection.isValidHost("a/b"))
        #expect(!RemoteConnection.isValidHost("a=b"))
    }
}

@Suite(.serialized) struct RemoteLimitsTests {
    @Test func unlimitedProducesNoFlags() {
        let saved = RemoteLimits.bandwidthKBps
        defer { RemoteLimits.bandwidthKBps = saved }
        RemoteLimits.bandwidthKBps = 0
        #expect(RemoteLimits.curlArgs.isEmpty)
        #expect(RemoteLimits.sftpArgs.isEmpty)
    }

    @Test func capProducesCorrectFlagsAndKbitConversion() {
        let saved = RemoteLimits.bandwidthKBps
        defer { RemoteLimits.bandwidthKBps = saved }
        RemoteLimits.bandwidthKBps = 100
        #expect(RemoteLimits.curlArgs == ["--limit-rate", "100k"])
        #expect(RemoteLimits.sftpArgs == ["-l", "800"])  // sftp -l is Kbit/s: 100 KB/s * 8
    }

    @Test func negativeCapClampsToUnlimited() {
        let saved = RemoteLimits.bandwidthKBps
        defer { RemoteLimits.bandwidthKBps = saved }
        RemoteLimits.bandwidthKBps = -5
        #expect(RemoteLimits.bandwidthKBps == 0)
        #expect(RemoteLimits.curlArgs.isEmpty)
    }
}
