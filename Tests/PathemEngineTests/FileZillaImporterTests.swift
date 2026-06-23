import Foundation
import Testing

@testable import PathemEngine

@Suite struct FileZillaImporterTests {
    private let sample = """
        <?xml version="1.0" encoding="UTF-8"?>
        <FileZilla3 version="3.66.5">
          <Servers>
            <Server>
              <Host>ftp.example.com</Host>
              <Port>21</Port>
              <Protocol>0</Protocol>
              <Type>0</Type>
              <User>alice</User>
              <Pass encoding="base64">c2VjcmV0</Pass>
              <Logontype>1</Logontype>
              My FTP Site
            </Server>
            <Server>
              <Host>sftp.example.org</Host>
              <Port>2222</Port>
              <Protocol>1</Protocol>
              <User>bob</User>
              Work SFTP
            </Server>
            <Server>
              <Host>secure.example.net</Host>
              <Protocol>3</Protocol>
              <User>carol</User>
            </Server>
          </Servers>
        </FileZilla3>
        """

    @Test func parsesServersWithProtocolAndPort() {
        let sites = FileZillaImporter.parse(Data(sample.utf8))
        #expect(sites.count == 3)

        let ftp = sites[0]
        #expect(ftp.host == "ftp.example.com")
        #expect(ftp.proto == .ftp)
        #expect(ftp.port == 21)
        #expect(ftp.user == "alice")
        #expect(ftp.name == "My FTP Site")

        let sftp = sites[1]
        #expect(sftp.proto == .sftp)
        #expect(sftp.effectivePort == 2222)
        #expect(sftp.name == "Work SFTP")

        let ftps = sites[2]
        #expect(ftps.proto == .ftps)
        #expect(ftps.port == 0)
        #expect(ftps.effectivePort == 21)  // default when unspecified
        #expect(ftps.name == "secure.example.net")  // falls back to host
    }

    @Test func ignoresPasswords() {
        let sites = FileZillaImporter.parse(Data(sample.utf8))
        // RemoteConnection has no password field at all; nothing to leak.
        let encoded = try! JSONEncoder().encode(sites)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("c2VjcmV0"))
        #expect(!json.lowercased().contains("pass"))
    }

    @Test func emptyOrGarbageReturnsNothing() {
        #expect(FileZillaImporter.parse(Data("not xml".utf8)).isEmpty)
        #expect(FileZillaImporter.parse(Data("<FileZilla3></FileZilla3>".utf8)).isEmpty)
    }
}
