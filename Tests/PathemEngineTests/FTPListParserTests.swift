import Foundation
import Testing

@testable import PathemEngine

@Suite struct FTPListParserTests {
    @Test func parsesUnixListing() {
        let text = """
            drwxr-xr-x   2 alice staff       4096 Jan 02 12:00 assets
            -rw-r--r--   1 alice staff     123456 Jan 02 12:00 index.html
            -rw-r--r--   1 alice staff        512 Jan 02 12:00 read me.txt
            lrwxrwxrwx   1 alice staff         11 Jan 02 12:00 current -> releases/v1
            """
        let entries = FTPListParser.parse(text)
        #expect(entries.count == 4)
        #expect(entries[0].name == "assets")
        #expect(entries[0].isDirectory)
        #expect(entries[1].name == "index.html")
        #expect(entries[1].isDirectory == false)
        #expect(entries[1].size == 123456)
        #expect(entries[2].name == "read me.txt")  // spaces in name preserved
        #expect(entries[3].name == "current")  // symlink target stripped
    }

    @Test func skipsDotEntriesAndGarbage() {
        let text = """
            drwxr-xr-x 2 a b 4096 Jan 02 12:00 .
            drwxr-xr-x 2 a b 4096 Jan 02 12:00 ..
            total 8
            garbage line
            """
        #expect(FTPListParser.parse(text).isEmpty)
    }
}
