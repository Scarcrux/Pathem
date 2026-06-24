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

    @Test func preservesInternalMultipleSpacesInName() {
        // The name is sliced verbatim, so runs of spaces inside it survive.
        let text = "-rw-r--r--   1 alice staff   42 Jan 02 12:00 a  b   c.txt"
        let entries = FTPListParser.parse(text)
        #expect(entries.count == 1)
        #expect(entries[0].name == "a  b   c.txt")
        #expect(entries[0].size == 42)
    }

    @Test func preservesNonUTF8NameBytes() {
        // A listing line whose name has an invalid UTF-8 byte (0xFF) keeps the exact
        // bytes in rawName, while `name` is the lossy decode for display.
        var line = Array("-rw-r--r--   1 a b 5 Jan 02 12:00 caf".utf8)
        line.append(0xFF)  // invalid UTF-8
        line.append(contentsOf: Array(".txt".utf8))
        let entries = FTPListParser.parse(Data(line))
        #expect(entries.count == 1)
        #expect(entries[0].rawName != nil)
        #expect(entries[0].rawName?.last == UInt8(ascii: "t"))  // "...txt"
        #expect(entries[0].rawName?.contains(0xFF) == true)  // exact byte kept
        #expect(entries[0].name.contains("\u{FFFD}"))  // display is lossy
    }

    @Test func utf8CleanNameHasNoRawName() {
        let entries = FTPListParser.parse("-rw-r--r-- 1 a b 5 Jan 02 12:00 plain.txt")
        #expect(entries.count == 1)
        #expect(entries[0].rawName == nil)  // only kept when it differs from a clean decode
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
