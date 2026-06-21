import Foundation
import Testing

@testable import PathomEngine

@Suite struct ContentExtractorTests {
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathom-extract-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try body(dir)
    }

    @Test func readsTextLikeFiles() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("notes.md")
            try "hello semantic world".write(to: url, atomically: true, encoding: .utf8)
            let snippet = ContentExtractor.snippet(of: url)
            #expect(snippet?.contains("semantic") == true)
        }
    }

    @Test func skipsNonTextExtensions() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("image.jpg")
            try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: url)  // JPEG header bytes
            #expect(ContentExtractor.snippet(of: url) == nil)
        }
    }

    @Test func respectsByteCap() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("big.txt")
            try String(repeating: "a", count: 20_000).write(to: url, atomically: true, encoding: .utf8)
            let snippet = ContentExtractor.snippet(of: url, maxBytes: 8192)
            #expect(snippet != nil)
            #expect((snippet?.utf8.count ?? .max) <= 8192)
        }
    }

    @Test func returnsNilForMissingFile() {
        let url = URL(fileURLWithPath: "/no/such/pathom/file-\(UUID().uuidString).txt")
        #expect(ContentExtractor.snippet(of: url) == nil)
    }
}
