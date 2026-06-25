import Foundation
import Testing

@testable import PathemEngine

@Suite struct FileFilterTests {
    private func entry(_ name: String, dir: Bool = false, size: Int64 = 0) -> FileEntry {
        FileEntry(name: name, isDirectory: dir, size: size, modificationDate: nil)
    }

    @Test func emptyMatchesEverything() {
        #expect(FileFilter("").isEmpty)
        #expect(FileFilter("   ").isEmpty)
    }

    @Test func nameSubstringIsCaseInsensitive() {
        let f = FileFilter("report")
        #expect(f.matches(entry("Q3 Report.pdf")))
        #expect(!f.matches(entry("budget.xlsx")))
    }

    @Test func extensionTokenAndShorthand() {
        #expect(FileFilter("ext:pdf").matches(entry("a.pdf")))
        #expect(!FileFilter("ext:pdf").matches(entry("a.png")))
        #expect(FileFilter(".png").matches(entry("Photo.PNG")))  // shorthand + case-insensitive
        #expect(!FileFilter("ext:pdf").matches(entry("docs", dir: true)))  // folders have no ext
    }

    @Test func kindToken() {
        #expect(FileFilter("kind:image").matches(entry("a.heic")))
        #expect(FileFilter("kind:folder").matches(entry("src", dir: true)))
        #expect(!FileFilter("kind:folder").matches(entry("a.txt")))
        #expect(FileFilter("kind:code").matches(entry("main.swift")))
        #expect(!FileFilter("kind:video").matches(entry("song.mp3")))
    }

    @Test func sizeComparisons() {
        #expect(FileFilter("size:>10mb").matches(entry("big.bin", size: 11_000_000)))
        #expect(!FileFilter("size:>10mb").matches(entry("small.bin", size: 9_000_000)))
        #expect(FileFilter("size:<1kb").matches(entry("tiny.txt", size: 500)))
        #expect(FileFilter("size:>=2gb").matches(entry("huge", size: 2_000_000_000)))
        #expect(FileFilter("size:512").matches(entry("x", size: 600)))  // bare = at least
    }

    @Test func tokensAreAndedTogether() {
        let f = FileFilter("ext:pdf size:>1mb")
        #expect(f.matches(entry("big.pdf", size: 2_000_000)))
        #expect(!f.matches(entry("big.png", size: 2_000_000)))  // wrong ext
        #expect(!f.matches(entry("small.pdf", size: 100)))  // too small
    }

    @Test func unknownTokensFallBackToNameNeedle() {
        // An unparseable token is treated as a literal name substring, not dropped.
        #expect(FileFilter("kind:bogus").matches(entry("kind:bogus.txt")))
        #expect(FileFilter("size:abc").matches(entry("size:abc.txt")))
        #expect(!FileFilter("size:abc").matches(entry("unrelated.txt")))
    }
}
