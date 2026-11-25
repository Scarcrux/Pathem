import Foundation
import Testing

@testable import PathemEngine

@Suite struct ListingExportTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func file(_ name: String, size: Int64 = 1_500) -> FileEntry {
        FileEntry(name: name, isDirectory: false, size: size, modificationDate: t0)
    }

    /// An independent RFC 4180 reader, so the writer is checked against the format rather
    /// than against itself.
    private func parseCSV(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.unicodeScalars.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                record.append(field)
                field = ""
            } else if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" {
                record.append(field)
                records.append(record)
                record = []
                field = ""
                i += 1
            } else {
                field.unicodeScalars.append(c)
            }
            i += 1
        }
        return records
    }

    private let awkwardNames = [
        "plain.txt", "a,b.txt", "say \"hi\".txt", "two\nlines.txt", "cr\rlf\r\n.txt",
        "\"quoted\",and,commas\n.txt", "  spaces  .txt", "tab\there.txt", "back\\slash.txt",
        "caf\u{00E9} \u{1F600}.txt", ",", "\"",
    ]

    @Test func csvRoundTripsAwkwardNames() {
        let doc = ListingExport.Document(
            title: "t", fields: [.name, .size],
            items: awkwardNames.map {
                ListingItem(entry: file($0), relativePath: $0)
            })
        let text = ListingExport.render(doc, as: .csv, timeZone: utc)
        let parsed = parseCSV(text)
        #expect(parsed.count == awkwardNames.count + 1)
        #expect(parsed[0] == ["Name", "Size (bytes)", "Size"])
        #expect(Array(parsed.dropFirst().map { $0[0] }) == awkwardNames)
        #expect(parsed.dropFirst().allSatisfy { $0.count == 3 && $0[1] == "1500" })
    }

    @Test func csvQuotesOnlyWhenNeededAndEndsRecordsWithCRLF() {
        #expect(ListingExport.csv([["a", "b,c", "d\"e"]]) == "a,\"b,c\",\"d\"\"e\"\r\n")
        #expect(ListingExport.csv([["x"], ["y"]]) == "x\r\ny\r\n")
    }

    @Test func tsvKeepsEveryRecordOnOneLineAndUnescapes() {
        func unescape(_ value: String) -> String {
            var out = ""
            var iterator = value.makeIterator()
            while let ch = iterator.next() {
                guard ch == "\\", let next = iterator.next() else {
                    out.append(ch)
                    continue
                }
                switch next {
                case "t": out += "\t"
                case "n": out += "\n"
                case "r": out += "\r"
                default: out.append(next)
                }
            }
            return out
        }
        let doc = ListingExport.Document(
            title: "t", fields: [.name],
            items: awkwardNames.map {
                ListingItem(entry: file($0), relativePath: $0)
            })
        let text = ListingExport.render(doc, as: .tsv, timeZone: utc)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == awkwardNames.count + 1)
        #expect(Array(lines.dropFirst().map { unescape(String($0)) }) == awkwardNames)
    }

    @Test func datesAreISO8601AndFoldersLeaveSizeEmpty() {
        let folder = FileEntry(name: "d", isDirectory: true, size: 0, modificationDate: t0)
        let doc = ListingExport.Document(
            title: "t", fields: [.name, .size, .modified],
            items: [ListingItem(entry: folder, relativePath: "d")])
        let rows = ListingExport.rows(doc, timeZone: utc)
        #expect(rows == [["d", "", "", "2023-11-14T22:13:20Z"]])
    }

    @Test func sizeColumnsPairBytesWithAReadableValue() {
        let doc = ListingExport.Document(
            title: "t", fields: [.size],
            items: [ListingItem(entry: file("a", size: 1_500_000), relativePath: "a")])
        let row = ListingExport.rows(doc)[0]
        #expect(row[0] == "1500000")
        #expect(row[1].contains("MB"))
    }

    @Test func textAlignsColumnsAndEscapesNewlines() {
        let doc = ListingExport.Document(
            title: "t", fields: [.name, .modified],
            items: [
                ListingItem(entry: file("short"), relativePath: "short"),
                ListingItem(entry: file("a\nb-longer"), relativePath: "x"),
            ])
        let lines = ListingExport.render(doc, as: .text, timeZone: utc)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 4)  // header, rule, two rows
        let column = lines[0].range(of: "Date Modified")!.lowerBound
        #expect(
            lines[2].distance(from: lines[2].startIndex, to: lines[2].range(of: "2023")!.lowerBound)
                == lines[0].distance(from: lines[0].startIndex, to: column))
        #expect(lines[3].hasPrefix("a\\nb-longer"))
    }

    @Test func htmlEscapesNamesAndKeepsTheTableShape() {
        let evil = "<script>alert(1)</script> & \"x\"'.txt"
        let doc = ListingExport.Document(
            title: "/tmp/<dir>", fields: [.name],
            items: [ListingItem(entry: file(evil), relativePath: evil)])
        let page = ListingExport.render(doc, as: .html, timeZone: utc, accentHex: "#ff00aa")
        #expect(!page.contains("<script>"))
        #expect(page.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;x&quot;&#39;.txt"))
        #expect(page.contains("<title>/tmp/&lt;dir&gt;</title>"))
        #expect(page.contains("--accent: #ff00aa"))
        #expect(page.components(separatedBy: "<tr>").count == 3)  // header row + one item
        // A hostile accent never reaches the stylesheet.
        let bad = ListingExport.render(doc, as: .html, accentHex: "red;}</style><script>")
        #expect(!bad.contains("</style><script>"))
    }

    @Test func fieldsFollowTheVisibleColumnsAndAddPathWhenRecursive() {
        #expect(
            ListingField.fields(forColumnIDs: ["size", "tags", "date"], recursive: false)
                == [.name, .size, .modified])
        #expect(
            ListingField.fields(forColumnIDs: ["name", "size"], recursive: true)
                == [.name, .path, .size])
    }

    @Test func itemsHonorSelectionAndHiddenOptions() {
        let entries = [file("a"), file(".hidden"), file("b")]
        #expect(
            ListingExport.items(from: entries, selected: nil, includeHidden: false).map(
                \.entry.name) == ["a", "b"])
        #expect(ListingExport.items(from: entries, selected: nil, includeHidden: true).count == 3)
        #expect(
            ListingExport.items(from: entries, selected: ["b", ".hidden"], includeHidden: false)
                .map(\.entry.name) == ["b"])
    }

    @Test func recursiveCollectionUsesRelativePathsAndRespectsBounds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "export-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("top.txt"))
        try Data("y".utf8).write(to: root.appendingPathComponent("sub/mid, odd.txt"))
        try Data("z".utf8).write(to: root.appendingPathComponent("sub/deep/low.txt"))
        try Data("h".utf8).write(to: root.appendingPathComponent(".secret"))
        defer { try? fm.removeItem(at: root) }

        let all = ListingExport.collectRecursively(root: root, includeHidden: false)
        #expect(!all.truncated)
        #expect(
            Set(all.items.map(\.relativePath))
                == ["top.txt", "sub", "sub/mid, odd.txt", "sub/deep", "sub/deep/low.txt"])
        #expect(ListingExport.collectRecursively(root: root, includeHidden: true).items.count == 6)

        let capped = ListingExport.collectRecursively(root: root, includeHidden: true, maxItems: 2)
        #expect(capped.truncated && capped.items.count == 2)

        let cancelled = ListingExport.collectRecursively(
            root: root, includeHidden: true, isCancelled: { true })
        #expect(cancelled.truncated && cancelled.items.isEmpty)

        let only = ListingExport.collectRecursively(
            root: root, includeHidden: false, topLevelNames: ["sub"])
        #expect(
            Set(only.items.map(\.relativePath))
                == ["sub", "sub/mid, odd.txt", "sub/deep", "sub/deep/low.txt"])

        let shallow = ListingExport.collectRecursively(
            root: root, includeHidden: false, maxDepth: 0)
        #expect(!shallow.items.contains { $0.relativePath.hasPrefix("sub/") })
    }
}
