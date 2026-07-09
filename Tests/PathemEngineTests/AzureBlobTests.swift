import Foundation
import Testing

@testable import PathemEngine

@Suite struct AzureBlobTests {
    // Decode a hex string to Data (for the HMAC test vector).
    private func hex(_ s: String) -> Data {
        var data = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            data.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return data
    }

    // MARK: Signature

    @Test func signatureMatchesRFC4231Vector() {
        // RFC 4231 Test Case 2: key = "Jefe", data = "what do ya want for nothing?".
        let key = Data("Jefe".utf8).base64EncodedString()
        let sig = AzureSharedKey.signature(key: key, stringToSign: "what do ya want for nothing?")
        let expected = hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
            .base64EncodedString()
        #expect(sig == expected)
    }

    @Test func signatureRejectsNonBase64Key() {
        #expect(AzureSharedKey.signature(key: "not base64!!", stringToSign: "x") == nil)
        #expect(AzureSharedKey.authorization(account: "a", key: "not base64!!", stringToSign: "x") == nil)
    }

    @Test func authorizationWrapsAccountAndSignature() {
        let key = Data("Jefe".utf8).base64EncodedString()
        let auth = AzureSharedKey.authorization(
            account: "myaccount", key: key, stringToSign: "what do ya want for nothing?")
        #expect(auth?.hasPrefix("SharedKey myaccount:") == true)
    }

    // MARK: String to sign

    @Test func stringToSignHasCanonicalShape() {
        let sts = AzureSharedKey.stringToSign(
            verb: "GET", contentLength: 0, contentType: "",
            xmsHeaders: ["x-ms-version": "2015-02-21", "x-ms-date": "Fri, 26 Jun 2015 23:39:12 GMT"],
            canonicalizedResource: "/myaccount/mycontainer\ncomp:list\nrestype:container")
        let expected =
            "GET" + String(repeating: "\n", count: 12)
            + "x-ms-date:Fri, 26 Jun 2015 23:39:12 GMT\n"  // x-ms headers sorted, each \n-terminated
            + "x-ms-version:2015-02-21\n"
            + "/myaccount/mycontainer\ncomp:list\nrestype:container"
        #expect(sts == expected)
    }

    @Test func nonZeroContentLengthAppearsInStringToSign() {
        let sts = AzureSharedKey.stringToSign(
            verb: "PUT", contentLength: 42, contentType: "", xmsHeaders: [:],
            canonicalizedResource: "/a/c/b")
        // The 4th field (Content-Length) is "42"; a zero length would be empty.
        #expect(sts.hasPrefix("PUT\n\n\n42\n"))
    }

    // MARK: Canonicalized resource

    @Test func canonicalizedResourceSortsAndLowercasesQuery() {
        let resource = AzureSharedKey.canonicalizedResource(
            account: "acct", path: "/container",
            query: [(name: "restype", value: "container"), (name: "Comp", value: "list")])
        #expect(resource == "/acct/container\ncomp:list\nrestype:container")
    }

    @Test func canonicalizedResourceJoinsRepeatedValues() {
        let resource = AzureSharedKey.canonicalizedResource(
            account: "acct", path: "/",
            query: [(name: "x", value: "b"), (name: "x", value: "a")])
        #expect(resource == "/acct/\nx:b,a")
    }

    // MARK: Date

    @Test func rfc1123FormatsGMT() {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (1994, 11, 6, 8, 49, 37)
        c.timeZone = TimeZone(identifier: "GMT")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "GMT")!
        let date = cal.date(from: c)!
        #expect(AzureSharedKey.rfc1123(date) == "Sun, 06 Nov 1994 08:49:37 GMT")
    }

    // MARK: Provider derivation

    @Test func hostDerivesFromAccountWhenBlank() {
        let blank = RemoteConnection(name: "x", proto: .azure, host: "", user: "myacct")
        #expect(AzureBlobProvider.host(blank) == "myacct.blob.core.windows.net")
        let custom = RemoteConnection(name: "x", proto: .azure, host: "127.0.0.1", user: "devstoreaccount1")
        #expect(AzureBlobProvider.host(custom) == "127.0.0.1")  // e.g. the Azurite emulator
    }

    @Test func accountValidation() {
        #expect(AzureBlobProvider.isValidAccount("myaccount1"))
        #expect(AzureBlobProvider.isValidAccount("devstoreaccount1"))
        #expect(!AzureBlobProvider.isValidAccount("ab"))  // too short
        #expect(!AzureBlobProvider.isValidAccount("My-Account"))  // uppercase + dash not allowed
        #expect(!AzureBlobProvider.isValidAccount("acct/../evil"))  // no path smuggling into the host
    }

    @Test func splitAndEncodePath() {
        let (container, key) = AzureBlobProvider.split("/logs/2026/app log.txt")
        #expect(container == "logs")
        #expect(key == "2026/app log.txt")
        #expect(
            AzureBlobProvider.encodePath(container: "logs", key: "2026/app log.txt")
                == "/logs/2026/app%20log.txt")
        #expect(AzureBlobProvider.encodePath(container: "logs", key: "") == "/logs")
    }

    @Test func buildProducesSignedURLForFixedDate() throws {
        let key = Data("Jefe".utf8).base64EncodedString()
        let conn = RemoteConnection(name: "x", proto: .azure, host: "", user: "myacct")
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2020, 1, 2, 3, 4, 5)
        c.timeZone = TimeZone(identifier: "GMT")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "GMT")!
        let date = cal.date(from: c)!
        let req = AzureBlobProvider.Request(
            method: "GET", encodedPath: "/mycontainer",
            query: [(name: "restype", value: "container"), (name: "comp", value: "list")])
        let (url, headerArgs) = try AzureBlobProvider.build(conn, key, req, date: date)
        #expect(url == "https://myacct.blob.core.windows.net/mycontainer?restype=container&comp=list")
        #expect(headerArgs.contains("x-ms-version: \(AzureSharedKey.apiVersion)"))
        #expect(headerArgs.contains("x-ms-date: Thu, 02 Jan 2020 03:04:05 GMT"))
        // A stable Authorization header is present for the account.
        #expect(headerArgs.contains { $0.hasPrefix("Authorization: SharedKey myacct:") })
    }
}

@Suite struct AzureListParserTests {
    @Test func parsesBlobsAndPrefixes() {
        let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <EnumerationResults>
              <Blobs>
                <Blob>
                  <Name>reports/q1.pdf</Name>
                  <Properties>
                    <Last-Modified>Wed, 09 Sep 2009 09:20:02 GMT</Last-Modified>
                    <Content-Length>2048</Content-Length>
                  </Properties>
                </Blob>
                <Blob>
                  <Name>reports/</Name>
                  <Properties><Content-Length>0</Content-Length></Properties>
                </Blob>
                <BlobPrefix><Name>reports/archive/</Name></BlobPrefix>
              </Blobs>
              <NextMarker/>
            </EnumerationResults>
            """
        let result = AzureListParser.parseBlobs(Data(xml.utf8), prefix: "reports/")
        // The folder-marker blob equal to the prefix is dropped; a file and a folder remain.
        #expect(result.entries.count == 2)
        let file = result.entries.first { !$0.isDirectory }
        #expect(file?.name == "q1.pdf")
        #expect(file?.size == 2048)
        #expect(file?.modificationDate != nil)
        let folder = result.entries.first { $0.isDirectory }
        #expect(folder?.name == "archive")
        #expect(result.nextMarker == nil)
    }

    @Test func parsesNextMarker() {
        let xml = """
            <EnumerationResults><Blobs></Blobs><NextMarker>abc123</NextMarker></EnumerationResults>
            """
        #expect(AzureListParser.parseBlobs(Data(xml.utf8), prefix: "").nextMarker == "abc123")
    }

    @Test func parsesContainers() {
        let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <EnumerationResults>
              <Containers>
                <Container><Name>backups</Name><Properties><Last-Modified>Wed, 09 Sep 2009 09:20:02 GMT</Last-Modified></Properties></Container>
                <Container><Name>media</Name><Properties/></Container>
              </Containers>
              <NextMarker/>
            </EnumerationResults>
            """
        let result = AzureListParser.parseContainers(Data(xml.utf8))
        #expect(result.entries.map(\.name) == ["backups", "media"])
        let allDirectories = result.entries.allSatisfy { $0.isDirectory }
        #expect(allDirectories)
    }
}
