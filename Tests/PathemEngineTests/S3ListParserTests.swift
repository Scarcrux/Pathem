import Foundation
import Testing

@testable import PathemEngine

@Suite struct S3ListParserTests {
    private let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>my-bucket</Name>
          <Prefix>docs/</Prefix>
          <Delimiter>/</Delimiter>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>TOKEN123</NextContinuationToken>
          <Contents>
            <Key>docs/</Key>
            <Size>0</Size>
            <LastModified>2025-06-20T08:00:00.000Z</LastModified>
          </Contents>
          <Contents>
            <Key>docs/report.pdf</Key>
            <Size>4096</Size>
            <LastModified>2025-06-24T12:30:00.000Z</LastModified>
          </Contents>
          <CommonPrefixes>
            <Prefix>docs/images/</Prefix>
          </CommonPrefixes>
        </ListBucketResult>
        """

    @Test func parsesFilesFoldersTokenAndSkipsMarker() {
        let r = S3ListParser.parse(Data(xml.utf8), prefix: "docs/")
        #expect(r.nextToken == "TOKEN123")
        #expect(r.entries.count == 2)  // the "docs/" marker object is skipped
        let file = r.entries.first { $0.name == "report.pdf" }
        #expect(file?.isDirectory == false)
        #expect(file?.size == 4096)
        #expect(file?.modificationDate != nil)
        let folder = r.entries.first { $0.name == "images" }
        #expect(folder?.isDirectory == true)
    }

    @Test func nextTokenNilWhenNotTruncated() {
        let xml = """
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
              <Prefix></Prefix><IsTruncated>false</IsTruncated>
              <Contents><Key>a.txt</Key><Size>1</Size></Contents>
            </ListBucketResult>
            """
        let r = S3ListParser.parse(Data(xml.utf8), prefix: "")
        #expect(r.nextToken == nil)
        #expect(r.entries.map(\.name) == ["a.txt"])
    }
}
