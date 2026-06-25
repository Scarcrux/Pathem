import Foundation
import Testing

@testable import PathemEngine

@Suite struct WebDAVListParserTests {
    // A realistic Depth:1 multistatus: the collection itself, a subfolder, and a file.
    private let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/projects/</d:href>
            <d:propstat><d:prop>
              <d:resourcetype><d:collection/></d:resourcetype>
            </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
          </d:response>
          <d:response>
            <d:href>/dav/projects/Photos/</d:href>
            <d:propstat><d:prop>
              <d:displayname>Photos</d:displayname>
              <d:resourcetype><d:collection/></d:resourcetype>
              <d:getlastmodified>Mon, 23 Jun 2025 10:00:00 GMT</d:getlastmodified>
            </d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/dav/projects/report%20final.pdf</d:href>
            <d:propstat><d:prop>
              <d:getcontentlength>2048</d:getcontentlength>
              <d:resourcetype/>
              <d:getlastmodified>Tue, 24 Jun 2025 12:30:00 GMT</d:getlastmodified>
            </d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """

    @Test func parsesChildrenAndSkipsTheCollectionItself() {
        let entries = WebDAVListParser.parse(Data(xml.utf8), requestPath: "/dav/projects/")
        #expect(entries.count == 2)  // collection itself is skipped
        let folder = entries.first { $0.name == "Photos" }
        #expect(folder?.isDirectory == true)
        let file = entries.first { $0.name == "report final.pdf" }  // percent-decoded
        #expect(file?.isDirectory == false)
        #expect(file?.size == 2048)
        #expect(file?.modificationDate != nil)
    }

    @Test func handlesFullURLHrefs() {
        #expect(WebDAVListParser.name(fromHref: "https://host.example/dav/a/b.txt") == "b.txt")
        #expect(WebDAVListParser.name(fromHref: "/dav/a/Sub%20Dir/") == "Sub Dir")
    }
}
